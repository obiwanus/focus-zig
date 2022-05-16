const std = @import("std");

const focus = @import("focus.zig");
const u = focus.utils;

const Allocator = std.mem.Allocator;
const TextColor = focus.style.TextColor;
const Char = u.Char;

const Buffer = @This();

file: ?File, // buffer may be tied to a file or may be just freestanding

bytes: std.ArrayList(u8),
chars: std.ArrayList(Char),
colors: std.ArrayList(TextColor),
lines: std.ArrayList(Line),

edit_alloc: Allocator,
undos: std.ArrayList([]Edit),
redos: std.ArrayList([]Edit),
edits: std.ArrayList(Edit), // most recent edits, which will be put into an undo group soon

dirty: bool = true, // needs syncing internal structures
modified: bool = false, // hasn't been saved to disk
modified_on_disk: bool = false, //
deleted: bool = false, // was deleted from disk by someone else

const File = struct {
    path: []const u8,
    mtime: i128 = 0,
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

pub const LineCol = struct {
    line: usize,
    col: usize,
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

pub fn init(allocator: Allocator) Buffer {
    return .{
        .file = null,
        .bytes = std.ArrayList(u8).init(allocator),
        .chars = std.ArrayList(Char).init(allocator),
        .colors = std.ArrayList(TextColor).init(allocator),
        .lines = std.ArrayList(Line).init(allocator),

        .edit_alloc = allocator,
        .undos = std.ArrayList([]Edit).init(allocator),
        .redos = std.ArrayList([]Edit).init(allocator),
        .edits = std.ArrayList(Edit).init(allocator),
    };
}

pub fn deinit(self: Buffer, allocator: Allocator) void {
    self.bytes.deinit();
    self.chars.deinit();
    self.colors.deinit();
    self.lines.deinit();
    if (self.file) |file| allocator.free(file.path);

    for (self.undos.items) |edits| {
        for (edits) |edit| edit.deinit(self.edit_alloc);
        self.edit_alloc.free(edits);
    }
    self.undos.deinit();

    for (self.redos.items) |edits| {
        for (edits) |edit| edit.deinit(self.edit_alloc);
        self.edit_alloc.free(edits);
    }
    self.redos.deinit();

    for (self.edits.items) |edit| edit.deinit(self.edit_alloc);
    self.edits.deinit();
}

pub fn saveToDisk(self: *Buffer) !void {
    if (self.file == null) return;

    self.updateBytesFromChars();
    if (self.bytes.items[self.bytes.items.len -| 1] != '\n') self.bytes.append('\n') catch u.oom();

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

pub fn expandRangeToWholeLines(self: Buffer, start: usize, end: usize) Range {
    const range = self.getValidRange(start, end);
    const first_line = self.getLineColFromPos(range.start).line;
    const last_line = self.getLineColFromPos(range.end).line;
    return .{
        .start = self.lines.items[first_line].start,
        .end = self.lines.items[last_line].end,
    };
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
    for (self.redos.items) |edits| {
        for (edits) |edit| edit.deinit(self.edit_alloc);
        self.edit_alloc.free(edits);
    }
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
}

fn insertRaw(self: *Buffer, pos: usize, chars: []const Char) void {
    if (pos >= self.numChars()) {
        self.chars.appendSlice(chars) catch u.oom();
    } else {
        self.chars.insertSlice(pos, chars) catch u.oom();
    }
}

fn replaceRaw(self: *Buffer, start: usize, end: usize, chars: []const Char) void {
    self.chars.replaceRange(start, end - start, chars) catch u.oom();
}

pub fn deleteRange(self: *Buffer, start: usize, end: usize) void {
    const range = self.getValidRange(start, end);
    if (range.start == range.end) return;
    self.edits.append(.{ .Delete = .{ .range = range, .old_chars = self.copyChars(range.start, range.end) } }) catch u.oom();
    self.clearRedos();
    self.deleteRaw(range);
}

pub fn replaceRange(self: *Buffer, start: usize, end: usize, new_chars: []const Char) void {
    const range = self.getValidRange(start, end);
    self.edits.append(.{ .Replace = .{
        .range = range,
        .new_chars = self.edit_alloc.dupe(Char, new_chars) catch u.oom(),
        .old_chars = self.copyChars(range.start, range.end),
    } }) catch u.oom();
    self.clearRedos();
    self.replaceRaw(range.start, range.end, new_chars);
}

pub fn insertSlice(self: *Buffer, pos: usize, chars: []const Char) void {
    self.edits.append(.{ .Insert = .{
        .pos = pos,
        .new_chars = self.edit_alloc.dupe(Char, chars) catch u.oom(),
    } }) catch u.oom();
    self.clearRedos();
    self.insertRaw(pos, chars);
}

pub fn undo(self: *Buffer) void {
    if (self.edits.popOrNull()) |edit| {
        self.revertEdit(edit);
        // for (edits) |edit| self.revertEdit(edit);
        // std.mem.reverse(Edit, edits);
        // self.redos.append(edits) catch u.oom();
    }
    self.dirty = true;
}

fn revertEdit(self: *Buffer, edit: Edit) void {
    switch (edit) {
        .Insert => |e| {
            self.deleteRaw(.{ .start = e.pos, .end = e.pos + e.new_chars.len });
        },
        .Delete => |e| {
            self.insertRaw(e.range.start, e.old_chars);
        },
        .Replace => |e| {
            self.replaceRaw(e.range.start, e.new_chars.len, e.old_chars);
        },
    }
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

pub fn insertChar(self: *Buffer, pos: usize, char: Char) void {
    self.insertSlice(pos, &[_]Char{char});
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
