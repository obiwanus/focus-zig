const std = @import("std");

const focus = @import("focus.zig");
const u = focus.utils;

const Allocator = std.mem.Allocator;
const TextColor = focus.style.TextColor;
const Char = u.Char;
const LineCol = u.LineCol;

const Buffer = @This();

file: ?File, // buffer may be tied to a file or may be just freestanding

bytes: std.ArrayList(u8),
chars: std.ArrayList(Char),
colors: std.ArrayList(TextColor),
lines: std.ArrayList(Line),

edit_alloc: Allocator,
undos: std.ArrayList(EditGroup),
redos: std.ArrayList(EditGroup),
edits: std.ArrayList(EditWithCursor), // most recent edits, which will be put into an undo group soon

dirty: bool = true, // needs syncing internal structures
modified: bool = false, // hasn't been saved to disk
modified_on_disk: bool = false, // modified on disk by someone else
deleted: bool = false, // was deleted from disk by someone else

last_edit_ms: f64 = 0,
last_undo_len: usize = 0,

const File = struct {
    path: []const u8,
    mtime: i128 = 0,
};

pub const CursorState = struct {
    pos: usize,
    selection_start: ?usize,
};

const Edit = union(enum) {
    Insert: struct {
        pos: usize,
        new_chars: []Char,
    },
    Replace: struct {
        range: Range,
        new_chars: []Char,
        old_chars: []Char,
    },
    Delete: struct {
        range: Range,
        old_chars: []Char,
    },

    fn deinit(self: Edit, allocator: Allocator) void {
        switch (self) {
            .Insert => |edit| allocator.free(edit.new_chars),
            .Replace => |edit| {
                allocator.free(edit.new_chars);
                allocator.free(edit.old_chars);
            },
            .Delete => |edit| allocator.free(edit.old_chars),
        }
    }
};

// To store current edits
const EditWithCursor = struct {
    edit: Edit,
    old_cursor: CursorState,
    new_cursor: CursorState,
};

// To store multiple edits in an undo/redo group
const EditGroup = struct {
    edits: []Edit,
    old_cursor: CursorState,
    new_cursor: CursorState,

    fn deinit(self: EditGroup, allocator: Allocator) void {
        for (self.edits) |edit| edit.deinit(allocator);
        allocator.free(self.edits);
    }
};

pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }
};

pub const Line = struct {
    start: usize,
    text_start: usize,
    end: usize,

    pub fn len(self: Line) usize {
        return self.end - self.start;
    }

    pub fn lenWhitespace(self: Line) usize {
        return self.text_start - self.start;
    }
};

pub const SearchResultsIter = struct {
    buf: []const Char,
    search_str: []const Char,
    pos: usize = 0,

    pub fn next(self: *SearchResultsIter) ?usize {
        if (self.pos >= self.buf.len) return null;
        const found = std.mem.indexOfPos(Char, self.buf, self.pos, self.search_str) orelse return null;
        self.pos = found + self.search_str.len;
        return found;
    }
};

pub fn init(allocator: Allocator) Buffer {
    return .{
        .file = null,
        .bytes = std.ArrayList(u8).init(allocator),
        .chars = std.ArrayList(Char).init(allocator),
        .colors = std.ArrayList(TextColor).init(allocator),
        .lines = std.ArrayList(Line).init(allocator),

        .edit_alloc = allocator,
        .undos = std.ArrayList(EditGroup).init(allocator),
        .redos = std.ArrayList(EditGroup).init(allocator),
        .edits = std.ArrayList(EditWithCursor).init(allocator),
    };
}

pub fn deinit(self: Buffer, allocator: Allocator) void {
    self.bytes.deinit();
    self.chars.deinit();
    self.colors.deinit();
    self.lines.deinit();
    if (self.file) |file| allocator.free(file.path);

    for (self.undos.items) |edit_group| edit_group.deinit(self.edit_alloc);
    self.undos.deinit();

    for (self.redos.items) |edit_group| edit_group.deinit(self.edit_alloc);
    self.redos.deinit();

    for (self.edits.items) |e| e.edit.deinit(self.edit_alloc);
    self.edits.deinit();
}

pub fn saveToDisk(self: *Buffer) !void {
    if (self.file == null) return;

    self.updateBytesFromChars();
    if (self.bytes.items.len == 0 or self.bytes.items[self.bytes.items.len -| 1] != '\n') self.bytes.append('\n') catch u.oom();

    const file_path = self.file.?.path;
    const file = try std.fs.cwd().createFile(file_path, .{ .truncate = true, .read = true });
    defer file.close();
    try file.writeAll(self.bytes.items);
    const stat = file.stat() catch |err| u.panic("{} while getting stat on '{s}'", .{ err, file_path });
    self.file.?.mtime = stat.mtime;

    self.modified = false;
    self.modified_on_disk = false;
    self.deleted = false;
}

pub fn refreshFromDisk(self: *Buffer, allocator: Allocator) void {
    if (self.file == null) return;

    const file_path = self.file.?.path;
    const file_mtime = self.file.?.mtime;

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                self.deleted = true;
                return;
            },
            else => u.panic("{} while refreshing from disk '{s}'\n", .{ err, file_path }),
        }
    };
    defer file.close();

    self.deleted = false; // since we're here it means it's not deleted

    const stat = file.stat() catch |err| u.panic("{} while getting stat on '{s}'", .{ err, file_path });
    if (stat.mtime != file_mtime) {
        // File has been modified on disk
        if (self.modified) {
            self.modified_on_disk = true; // mark conflict
            return;
        }
        // Reload buffer if not modified
        self.loadFile(self.file.?.path, allocator);
    }
}

pub fn loadFile(self: *Buffer, path: []const u8, allocator: Allocator) void {
    // NOTE: taking ownership of the passed path
    self.file = .{ .path = path };
    const file = std.fs.cwd().openFile(path, .{ .read = true }) catch u.panic("Can't open '{s}'", .{path});
    defer file.close();

    const stat = file.stat() catch |err| u.panic("{} while getting stat on '{s}'", .{ err, path });
    self.file.?.mtime = stat.mtime;

    const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10 Mb
    const file_contents = file.reader().readAllAlloc(allocator, MAX_FILE_SIZE) catch |e| switch (e) {
        error.StreamTooLong => u.panic("File '{s}' is more than 10 Mb in size", .{path}),
        else => u.oom(),
    };
    defer allocator.free(file_contents);

    self.bytes.clearRetainingCapacity();
    self.bytes.appendSlice(file_contents) catch u.oom();

    // For simplicity we assume that a codepoint equals a character (though it's not true).
    // If we ever encounter multi-codepoint characters, we can revisit this
    self.chars.clearRetainingCapacity();
    self.chars.ensureTotalCapacity(self.bytes.items.len) catch u.oom();
    const utf8_view = std.unicode.Utf8View.init(self.bytes.items) catch @panic("invalid utf-8");
    var iterator = utf8_view.iterator();
    while (iterator.nextCodepoint()) |char| {
        self.chars.append(char) catch u.oom();
    }

    self.modified = false;
    self.modified_on_disk = false;
    self.dirty = true;
}

pub fn syncInternalData(self: *Buffer) void {
    self.recalculateLines();

    // Highlight code
    {
        // Have the color array ready
        self.colors.ensureTotalCapacity(self.chars.items.len) catch u.oom();
        self.colors.expandToCapacity();
        var colors = self.colors.items;
        std.mem.set(TextColor, colors, .comment);

        self.updateBytesFromChars();
        self.bytes.append(0) catch u.oom(); // null-terminate

        // NOTE: we're tokenizing the whole source file. At least for zig this can be optimised,
        // but we're not doing it just yet
        const source_bytes = self.bytes.items[0..self.bytes.items.len -| 1 :0];
        var tokenizer = std.zig.Tokenizer.init(source_bytes);
        while (true) {
            var token = tokenizer.next();
            const token_color: TextColor = switch (token.tag) {
                .eof => break,
                .invalid => .@"error",
                .string_literal, .multiline_string_literal_line, .char_literal => .string,
                .builtin => .function,
                .identifier => TextColor.getForIdentifier(self.chars.items[token.loc.start..token.loc.end], if (token.loc.end < self.chars.items.len) self.chars.items[token.loc.end] else null),
                .integer_literal, .float_literal => .value,
                .doc_comment, .container_doc_comment => .comment,
                .keyword_addrspace, .keyword_align, .keyword_allowzero, .keyword_and, .keyword_anyframe, .keyword_anytype, .keyword_asm, .keyword_async, .keyword_await, .keyword_break, .keyword_callconv, .keyword_catch, .keyword_comptime, .keyword_const, .keyword_continue, .keyword_defer, .keyword_else, .keyword_enum, .keyword_errdefer, .keyword_error, .keyword_export, .keyword_extern, .keyword_fn, .keyword_for, .keyword_if, .keyword_inline, .keyword_noalias, .keyword_noinline, .keyword_nosuspend, .keyword_opaque, .keyword_or, .keyword_orelse, .keyword_packed, .keyword_pub, .keyword_resume, .keyword_return, .keyword_linksection, .keyword_struct, .keyword_suspend, .keyword_switch, .keyword_test, .keyword_threadlocal, .keyword_try, .keyword_union, .keyword_unreachable, .keyword_usingnamespace, .keyword_var, .keyword_volatile, .keyword_while => .keyword,
                .bang, .pipe, .pipe_pipe, .pipe_equal, .equal, .equal_equal, .equal_angle_bracket_right, .bang_equal, .l_paren, .r_paren, .semicolon, .percent, .percent_equal, .l_brace, .r_brace, .l_bracket, .r_bracket, .period, .period_asterisk, .ellipsis2, .ellipsis3, .caret, .caret_equal, .plus, .plus_plus, .plus_equal, .plus_percent, .plus_percent_equal, .plus_pipe, .plus_pipe_equal, .minus, .minus_equal, .minus_percent, .minus_percent_equal, .minus_pipe, .minus_pipe_equal, .asterisk, .asterisk_equal, .asterisk_asterisk, .asterisk_percent, .asterisk_percent_equal, .asterisk_pipe, .asterisk_pipe_equal, .arrow, .colon, .slash, .slash_equal, .comma, .ampersand, .ampersand_equal, .question_mark, .angle_bracket_left, .angle_bracket_left_equal, .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_left_equal, .angle_bracket_angle_bracket_left_pipe, .angle_bracket_angle_bracket_left_pipe_equal, .angle_bracket_right, .angle_bracket_right_equal, .angle_bracket_angle_bracket_right, .angle_bracket_angle_bracket_right_equal, .tilde => .punctuation,
                else => .default,
            };
            std.mem.set(TextColor, colors[token.loc.start..token.loc.end], token_color);
        }

        _ = self.bytes.pop(); // un-null-terminate
    }
}

pub fn recalculateLines(self: *Buffer) void {
    self.lines.clearRetainingCapacity();

    var line_start: usize = 0;
    var text_start: ?usize = null;
    for (self.chars.items) |char, i| {
        if (text_start == null and char != ' ') {
            text_start = i;
        }
        if (char == '\n') {
            self.lines.append(.{ .start = line_start, .text_start = text_start.?, .end = i }) catch u.oom();
            line_start = i + 1;
            text_start = null;
        }
    }
    const end_char = self.numChars();
    self.lines.append(.{ .start = line_start, .text_start = text_start orelse end_char, .end = end_char }) catch u.oom();
}

/// Returns line and column given a position in the buffer
pub fn getLineColFromPos(self: Buffer, pos: usize) LineCol {
    // Binary search
    const lines = self.lines.items;
    var left: usize = 0;
    var right: usize = lines.len - 1;
    const line = if (pos >= lines[right].start)
        right
    else while (right - left > 1) {
        const mid = left + (right - left) / 2;
        const line_start = lines[mid].start;
        if (pos == line_start) break mid;
        if (pos < line_start) {
            right = mid;
        } else {
            left = mid;
        }
    } else left;
    const col = pos - lines[line].start;
    return .{ .line = line, .col = col };
}

pub fn getPosFromLineCol(self: Buffer, line: usize, col: usize) usize {
    const new_line = self.getLine(line); // may be different if outside of range
    if (col >= new_line.len()) {
        return new_line.end;
    } else {
        return new_line.start + col;
    }
}

pub fn getLine(self: Buffer, line_num: usize) Line {
    const line = u.min(line_num, self.numLines() - 1);
    return self.lines.items[line];
}

pub fn getLineOrNull(self: Buffer, line_num: usize) ?Line {
    if (line_num >= self.numLines()) return null;
    return self.lines.items[line_num];
}

pub fn numChars(self: Buffer) usize {
    return self.chars.items.len;
}

pub fn numLines(self: Buffer) usize {
    return self.lines.items.len;
}

pub fn expandRangeToWholeLines(self: Buffer, start: usize, end: usize, include_end_newline: bool) Range {
    const range = self.getValidRange(start, end);
    const first_line = self.getLineColFromPos(range.start).line;
    const last_line = self.getLineColFromPos(range.end).line;

    const new_start = self.lines.items[first_line].start;
    var new_end = self.lines.items[last_line].end;
    if (include_end_newline and last_line < self.numLines() - 1) new_end += 1;

    return .{ .start = new_start, .end = new_end};
}

pub fn selectWord(self: Buffer, pos: usize) ?Range {
    // Search within the line boundaries
    const line = self.getLine(self.getLineColFromPos(pos).line);
    const chars = self.chars.items;

    const pos2 = pos -| 1; // check pos on the left too if pos doesn't work

    const start = if (pos < line.end and u.isWordChar(chars[pos]))
        pos
    else if (pos2 >= line.start and pos2 < line.end and u.isWordChar(chars[pos2]))
        pos2
    else
        return null;

    var word_start = start;
    word_start = while (word_start >= line.start) : (word_start -= 1) {
        const is_part_of_word = u.isWordChar(chars[word_start]);
        if (!is_part_of_word) break word_start + 1;
        if (word_start == 0 and is_part_of_word) break word_start;
    } else word_start + 1;

    var word_end = start + 1;
    while (word_end < line.end and u.isWordChar(chars[word_end])) : (word_end += 1) {}

    return Range{ .start = word_start, .end = word_end };
}

fn copyChars(self: Buffer, start: usize, end: usize) []Char {
    return self.edit_alloc.dupe(Char, self.chars.items[start..end]) catch u.oom();
}

fn clearRedos(self: *Buffer) void {
    for (self.redos.items) |edit_group| edit_group.deinit(self.edit_alloc);
    self.redos.clearRetainingCapacity();
}

pub fn getValidRange(self: Buffer, start: usize, end: usize) Range {
    const max_end = self.numChars();
    const new_end = if (end > max_end) max_end else end;
    u.assert(start <= new_end);
    return Range{ .start = start, .end = new_end };
}

fn deleteRaw(self: *Buffer, range: Range) void {
    self.chars.replaceRange(range.start, range.len(), &[_]Char{}) catch unreachable;
    self.dirty = true;
}

fn insertRaw(self: *Buffer, pos: usize, chars: []const Char) void {
    self.chars.insertSlice(pos, chars) catch u.oom();
    self.dirty = true;
}

fn replaceRaw(self: *Buffer, start: usize, len: usize, chars: []const Char) void {
    self.chars.replaceRange(start, len, chars) catch u.oom();
    self.dirty = true;
}

pub fn deleteRange(self: *Buffer, start: usize, end: usize, old_cursor: CursorState, new_cursor: CursorState) void {
    const range = self.getValidRange(start, end);
    if (range.start == range.end) return;
    self.edits.append(EditWithCursor{
        .edit = .{ .Delete = .{
            .range = range,
            .old_chars = self.copyChars(range.start, range.end),
        } },
        .old_cursor = old_cursor,
        .new_cursor = new_cursor,
    }) catch u.oom();
    self.clearRedos();
    self.deleteRaw(range);
}

pub fn deleteChar(self: *Buffer, pos: usize, old_cursor: CursorState, new_cursor: CursorState) void {
    self.deleteRange(pos, pos + 1, old_cursor, new_cursor);
}

pub fn replaceRange(self: *Buffer, start: usize, end: usize, new_chars: []const Char, old_cursor: CursorState, new_cursor: CursorState) void {
    const range = self.getValidRange(start, end);
    if (std.mem.eql(Char, new_chars, self.chars.items[start..end])) return;
    self.putCurrentEditsIntoUndoGroup();
    self.edits.append(EditWithCursor{
        .edit = .{ .Replace = .{
            .range = range,
            .new_chars = self.edit_alloc.dupe(Char, new_chars) catch u.oom(),
            .old_chars = self.copyChars(range.start, range.end),
        } },
        .old_cursor = old_cursor,
        .new_cursor = new_cursor,
    }) catch u.oom();
    self.clearRedos();
    self.replaceRaw(range.start, range.len(), new_chars);
    self.putCurrentEditsIntoUndoGroup();
}

pub fn insertSlice(self: *Buffer, pos: usize, chars: []const Char, old_cursor: CursorState, new_cursor: CursorState) void {
    self.edits.append(EditWithCursor{
        .edit = .{ .Insert = .{
            .pos = pos,
            .new_chars = self.edit_alloc.dupe(Char, chars) catch u.oom(),
        } },
        .old_cursor = old_cursor,
        .new_cursor = new_cursor,
    }) catch u.oom();
    self.clearRedos();
    self.insertRaw(pos, chars);
}

pub fn insertChar(self: *Buffer, pos: usize, char: Char, old_cursor: CursorState, new_cursor: CursorState) void {
    self.insertSlice(pos, &[_]Char{char}, old_cursor, new_cursor);
}

pub fn moveRange(self: *Buffer, range: Range, target_pos: usize, old_cursor: CursorState, new_cursor: CursorState) void {
    u.assert(target_pos < range.start or range.end < target_pos); // can't copy into itself
    const chars = self.copyChars(range.start, range.end);
    self.deleteRange(range.start, range.end, old_cursor, old_cursor);
    if (target_pos < range.start) {
        self.insertSlice(target_pos, chars, old_cursor, new_cursor);
    } else {
        self.insertSlice(target_pos - range.len(), chars, old_cursor, new_cursor);
    }
    self.edit_alloc.free(chars);
}

pub fn undo(self: *Buffer) ?CursorState {
    self.putCurrentEditsIntoUndoGroup();
    if (self.undos.popOrNull()) |edit_group| {
        for (edit_group.edits) |edit| switch (edit) {
            .Insert => |e| {
                // u.print("Reverting insert into pos {} | '", .{e.pos});
                // u.printChars(e.new_chars);
                // u.println("'", .{});
                self.deleteRaw(.{ .start = e.pos, .end = e.pos + e.new_chars.len });
            },
            .Delete => |e| self.insertRaw(e.range.start, e.old_chars),
            .Replace => |e| self.replaceRaw(e.range.start, e.new_chars.len, e.old_chars),
        };
        std.mem.reverse(Edit, edit_group.edits);
        self.redos.append(edit_group) catch u.oom();
        return edit_group.old_cursor;
    }
    return null;
}

pub fn redo(self: *Buffer) ?CursorState {
    if (self.redos.popOrNull()) |edit_group| {
        for (edit_group.edits) |edit| switch (edit) {
            .Insert => |e| self.insertRaw(e.pos, e.new_chars),
            .Delete => |e| self.deleteRaw(e.range),
            .Replace => |e| self.replaceRaw(e.range.start, e.old_chars.len, e.new_chars),
        };
        std.mem.reverse(Edit, edit_group.edits);
        self.undos.append(edit_group) catch u.oom();
        return edit_group.new_cursor;
    }
    return null;
}

pub fn putCurrentEditsIntoUndoGroup(self: *Buffer) void {
    const num_edits = self.edits.items.len;
    if (num_edits == 0) return;

    var edits = self.edit_alloc.alloc(Edit, num_edits) catch u.oom();
    const old_cursor = self.edits.items[0].old_cursor;
    const new_cursor = self.edits.items[num_edits - 1].new_cursor;

    // Add edits to the group in the reverse order
    for (self.edits.items) |e, i| edits[num_edits - 1 - i] = e.edit;
    self.edits.clearRetainingCapacity();

    self.undos.append(EditGroup{
        .edits = edits,
        .old_cursor = old_cursor,
        .new_cursor = new_cursor,
    }) catch u.oom();
}

pub fn stripTrailingSpaces(self: *Buffer) void {
    var i: usize = 0;
    var start: ?usize = null;
    while (i < self.numChars()) : (i += 1) {
        const char = self.chars.items[i];
        if (char == ' ') {
            if (start == null) start = i;
        } else {
            if (char == '\n' and start != null) {
                const range = Buffer.Range{ .start = start.?, .end = i };
                self.deleteRaw(range);
                i -|= range.len();
            }
            start = null;
            self.dirty = true;
        }
    }
    if (start) |s| self.deleteRaw(.{ .start = s, .end = self.numChars() });
}

pub fn search(self: Buffer, search_str: []const Char) SearchResultsIter {
    return .{ .buf = self.chars.items, .search_str = search_str };
}

fn updateBytesFromChars(self: *Buffer) void {
    self.bytes.ensureTotalCapacity(self.chars.items.len * 4) catch u.oom(); // enough to store 4-byte chars
    self.bytes.expandToCapacity();
    var cursor: usize = 0;
    for (self.chars.items) |char| {
        const num_bytes = std.unicode.utf8Encode(char, self.bytes.items[cursor..]) catch unreachable;
        cursor += @intCast(usize, num_bytes);
    }
    self.bytes.shrinkRetainingCapacity(cursor);
}
