const std = @import("std");
const builtin = @import("builtin");

const focus = @import("focus.zig");
const u = focus.utils;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const TextColor = focus.style.TextColor;
const Char = u.Char;
const Cursor = focus.Editors.Cursor;
const LineCol = u.LineCol;

const Buffer = @This();

gpa: Allocator,

file: ?File, // buffer may be tied to a file or may be just freestanding
language: Language = .unknown,

bytes: ArrayList(u8),
chars: ArrayList(Char),
colors: ArrayList(TextColor),
lines: ArrayList(Line),

edit_alloc: Allocator,
undos: ArrayList(EditGroup),
redos: ArrayList(EditGroup),
edits: ArrayList(Edit), // most recent edits, which will be put into an undo group soon
cursors: ArrayList(CursorState),
new_edit_group_required: bool = false,

dirty: bool = true, // needs syncing internal structures
modified: bool = false, // hasn't been saved to disk
modified_on_disk: bool = false, // modified on disk by someone else
deleted: bool = false, // was deleted from disk by someone else

last_edit_ms: f64 = 0,
last_undo_len: usize = 0,

pub const Language = enum {
    zig,
    log,
    markdown,
    unknown,
};

const File = struct {
    path: []const u8,
    mtime: i128 = 0,
    uri: []const u8, // for the language server
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

pub const CursorState = struct {
    pos: usize = 0,
    selection_start: ?usize = null,
};

// To store multiple edits in an undo/redo group
const EditGroup = struct {
    edits: []Edit,
    cursors: []CursorState,

    fn deinit(self: EditGroup, allocator: Allocator) void {
        for (self.edits) |edit| edit.deinit(allocator);
        allocator.free(self.edits);
        allocator.free(self.cursors);
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

    pub fn isEmpty(self: Line) bool {
        return self.lenWhitespace() == self.len();
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
        .gpa = allocator,

        .file = null,
        .bytes = ArrayList(u8).init(allocator),
        .chars = ArrayList(Char).init(allocator),
        .colors = ArrayList(TextColor).init(allocator),
        .lines = ArrayList(Line).init(allocator),

        .edit_alloc = allocator,
        .undos = ArrayList(EditGroup).init(allocator),
        .redos = ArrayList(EditGroup).init(allocator),
        .edits = ArrayList(Edit).init(allocator),
        .cursors = ArrayList(CursorState).init(allocator),
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

    for (self.edits.items) |e| e.deinit(self.edit_alloc);
    self.edits.deinit();

    self.cursors.deinit();
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

pub fn refreshFromDisk(self: *Buffer, tmp_allocator: Allocator) void {
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
        self.loadFile(self.file.?.path, true, tmp_allocator);
    }
}

pub fn loadFile(self: *Buffer, path: []const u8, support_undo: bool, tmp_allocator: Allocator) void {
    if (self.file) |file| {
        self.gpa.free(file.path);
        self.gpa.free(file.uri);
    }
    self.file = .{
        .path = self.gpa.dupe(u8, path) catch u.oom(),
        .uri = self.gpa.dupe(u8, u.getUriFromPath(path, tmp_allocator)) catch u.oom(),
    };
    const file = std.fs.cwd().openFile(path, .{ .read = true }) catch u.panic("Can't open '{s}'", .{path});
    defer file.close();

    const stat = file.stat() catch |err| u.panic("{} while getting stat on '{s}'", .{ err, path });
    self.file.?.mtime = stat.mtime;

    const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10 Mb
    const file_contents = file.reader().readAllAlloc(tmp_allocator, MAX_FILE_SIZE) catch |e| switch (e) {
        error.StreamTooLong => u.panic("File '{s}' is more than 10 Mb in size", .{path}),
        else => u.oom(),
    };

    const chars = u.bytesToChars(file_contents, tmp_allocator) catch @panic("Invalid UTF-8");
    if (support_undo) {
        self.replaceRange(0, self.chars.items.len, chars);
    } else {
        self.replaceRaw(0, self.chars.items.len, chars);
    }

    self.modified = false;
    self.modified_on_disk = false;
    self.dirty = true;

    // Determine language from file name
    self.language = if (std.mem.eql(u8, path, "LOG.md"))
        Language.log
    else if (std.mem.endsWith(u8, path, ".zig"))
        Language.zig
    else if (std.mem.endsWith(u8, path, ".md"))
        Language.markdown
    else
        Language.unknown;
}

pub fn maybeFormat(self: *Buffer, tmp_allocator: Allocator) bool {
    switch (self.language) {
        .zig => self.formatZig(tmp_allocator),
        else => return false,
    }
    return true;
}

fn formatZig(self: *Buffer, tmp_allocator: Allocator) void {
    var process = std.ChildProcess.init(
        &[_][]const u8{ "zig", "fmt", "--stdin" },
        tmp_allocator,
    ) catch |err| u.panic("Error initialising zig fmt: {}", .{err});
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;
    process.spawn() catch |err| u.panic("Error spawning zig fmt: {}", .{err});
    process.stdin.?.writer().writeAll(self.bytes.items) catch |err| u.panic("Error writing to zig fmt: {}", .{err});
    process.stdin.?.close();
    process.stdin = null;
    // NOTE this is fragile - currently zig fmt closes stdout before stderr so this works but reading the other way round will sometimes block
    const stdout = process.stdout.?.reader().readAllAlloc(tmp_allocator, 10 * 1024 * 1024 * 1024) catch |err| u.panic("Error reading zig fmt stdout: {}", .{err});
    const stderr = process.stderr.?.reader().readAllAlloc(tmp_allocator, 10 * 1024 * 1024) catch |err| u.panic("Error reading zig fmt stderr: {}", .{err});
    const result = process.wait() catch |err| u.panic("Error waiting for zig fmt: {}", .{err});
    u.assert(result == .Exited);
    if (result.Exited != 0) {
        u.println("Error formatting zig buffer: \n{s}", .{stderr});
    } else {
        const chars = u.bytesToChars(stdout, tmp_allocator) catch u.panic("Invalid UTF-8", .{});
        self.replaceRange(0, self.chars.items.len, chars);
    }
}

pub fn syncInternalData(self: *Buffer) void {
    self.recalculateLines();

    // Highlight code
    self.colors.ensureTotalCapacity(self.chars.items.len) catch u.oom();
    self.colors.expandToCapacity();
    var colors = self.colors.items;

    if (self.language == .zig) {
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
    } else if (self.language == .log) {
        std.mem.set(TextColor, colors, .default);
        for (self.lines.items) |line| {
            const item_to_do = [_]Char{ '-', ' ' };
            const item_done = [_]Char{ '+', ' ' };
            const heading = [_]Char{ '#', ' ' };
            const bug = [_]Char{ '-', ' ', '[', 'b', 'u', 'g', ']' };
            const tech_debt = [_]Char{ '-', ' ', '[', 't', 'e', 'c', 'h', '-', 'd', 'e', 'b', 't', ']' };
            const chars = self.chars.items[line.text_start..line.end];
            if (std.mem.startsWith(Char, chars, &bug)) {
                std.mem.set(TextColor, colors[line.text_start .. line.text_start + bug.len], .keyword);
            } else if (std.mem.startsWith(Char, chars, &tech_debt)) {
                std.mem.set(TextColor, colors[line.text_start .. line.text_start + tech_debt.len], .value);
            } else if (std.mem.startsWith(Char, chars, &item_to_do)) {
                var word_end: usize = line.text_start + 2;
                while (word_end <= line.end and self.chars.items[word_end] != ' ') : (word_end += 1) {}
                std.mem.set(TextColor, colors[line.text_start..word_end], .@"type");
            } else if (std.mem.startsWith(Char, chars, &item_done)) {
                std.mem.set(TextColor, colors[line.text_start..line.end], .function);
            } else if (std.mem.startsWith(Char, chars, &heading)) {
                std.mem.set(TextColor, colors[line.text_start..line.end], .string);
            }
        }
    } else {
        std.mem.set(TextColor, colors, .default);
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

pub fn getPosFromLineCol(self: Buffer, line_col: LineCol) usize {
    const new_line = self.getLine(line_col.line); // may be different if outside of range
    if (line_col.col >= new_line.len()) {
        return new_line.end;
    } else {
        return new_line.start + line_col.col;
    }
}

pub fn getLine(self: Buffer, line_num: usize) Line {
    const line = u.min(line_num, self.numLines() -| 1);
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

    return .{ .start = new_start, .end = new_end };
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

pub fn deleteRange(self: *Buffer, start: usize, end: usize) void {
    const range = self.getValidRange(start, end);
    if (range.start == range.end) return;
    self.edits.append(.{ .Delete = .{
        .range = range,
        .old_chars = self.copyChars(range.start, range.end),
    } }) catch u.oom();
    self.clearRedos();
    self.deleteRaw(range);
}

pub fn deleteChar(self: *Buffer, pos: usize) void {
    self.deleteRange(pos, pos + 1);
}

pub fn replaceRange(self: *Buffer, start: usize, end: usize, new_chars: []const Char) void {
    const range = self.getValidRange(start, end);
    if (std.mem.eql(Char, new_chars, self.chars.items[start..end])) return;
    self.edits.append(.{ .Replace = .{
        .range = range,
        .new_chars = self.edit_alloc.dupe(Char, new_chars) catch u.oom(),
        .old_chars = self.copyChars(range.start, range.end),
    } }) catch u.oom();
    self.clearRedos();
    self.replaceRaw(range.start, range.len(), new_chars);
}

pub fn insertSlice(self: *Buffer, pos: usize, chars: []const Char) void {
    self.edits.append(.{ .Insert = .{
        .pos = pos,
        .new_chars = self.edit_alloc.dupe(Char, chars) catch u.oom(),
    } }) catch u.oom();
    self.clearRedos();
    self.insertRaw(pos, chars);
}

pub fn insertChar(self: *Buffer, pos: usize, char: Char) void {
    self.insertSlice(pos, &[_]Char{char});
}

pub fn moveRange(self: *Buffer, range: Range, target_pos: usize) void {
    u.assert(target_pos < range.start or range.end < target_pos); // can't copy into itself
    const chars = self.copyChars(range.start, range.end);
    self.deleteRange(range.start, range.end);
    if (target_pos < range.start) {
        self.insertSlice(target_pos, chars);
    } else {
        self.insertSlice(target_pos - range.len(), chars);
    }
    self.edit_alloc.free(chars);
}

pub fn undo(self: *Buffer) ?[]const CursorState {
    if (self.undos.popOrNull()) |edit_group| {
        for (edit_group.edits) |edit| switch (edit) {
            .Insert => |e| self.deleteRaw(.{ .start = e.pos, .end = e.pos + e.new_chars.len }),
            .Delete => |e| self.insertRaw(e.range.start, e.old_chars),
            .Replace => |e| self.replaceRaw(e.range.start, e.new_chars.len, e.old_chars),
        };
        std.mem.reverse(Edit, edit_group.edits);
        self.redos.append(EditGroup{ .edits = edit_group.edits, .cursors = self.cursors.toOwnedSlice() }) catch u.oom();
        self.cursors.appendSlice(edit_group.cursors) catch u.oom();
        self.edit_alloc.free(edit_group.cursors);
        return self.cursors.items;
    }
    return null;
}

pub fn redo(self: *Buffer) ?[]const CursorState {
    if (self.redos.popOrNull()) |edit_group| {
        for (edit_group.edits) |edit| switch (edit) {
            .Insert => |e| self.insertRaw(e.pos, e.new_chars),
            .Delete => |e| self.deleteRaw(e.range),
            .Replace => |e| self.replaceRaw(e.range.start, e.old_chars.len, e.new_chars),
        };
        std.mem.reverse(Edit, edit_group.edits);
        self.undos.append(EditGroup{ .edits = edit_group.edits, .cursors = self.cursors.toOwnedSlice() }) catch u.oom();
        self.cursors.appendSlice(edit_group.cursors) catch u.oom();
        self.edit_alloc.free(edit_group.cursors);
        return self.cursors.items;
    }
    return null;
}

pub fn newEditGroup(self: *Buffer, current_cursors: []const Cursor) void {
    self.new_edit_group_required = false;

    const num_edits = self.edits.items.len;
    if (num_edits == 0) return;

    // Store edits in the reverse order
    const edits = self.edits.toOwnedSlice();
    std.mem.reverse(Edit, edits);

    self.undos.append(EditGroup{ .edits = edits, .cursors = self.cursors.toOwnedSlice() }) catch u.oom();

    // Remember current cursor state
    self.cursors.ensureUnusedCapacity(current_cursors.len) catch u.oom();
    for (current_cursors) |cursor| self.cursors.appendAssumeCapacity(cursor.state());
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
