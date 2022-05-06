const std = @import("std");

const focus = @import("focus.zig");
const u = focus.utils;

const Allocator = std.mem.Allocator;
const TextColor = focus.style.TextColor;

const Buffer = @This();

file: ?File, // buffer may be tied to a file or may be just freestanding

bytes: std.ArrayList(u8),
chars: std.ArrayList(u.Char),
colors: std.ArrayList(TextColor),
lines: std.ArrayList(usize),
lines_whitespace: std.ArrayList(usize),

dirty: bool = true, // needs syncing internal structures
modified: bool = false, // hasn't been saved to disk
modified_on_disk: bool = false, //
deleted: bool = false, // was deleted from disk by someone else

const File = struct {
    path: []const u8,
    mtime: i128,
};

pub const LineCol = struct {
    line: usize,
    col: usize,
};

pub fn saveToDisk(self: *Buffer) !void {
    if (self.file == null) return;

    self.recalculateBytes();
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
        self.load(allocator);
    }
}

pub fn load(self: *Buffer, allocator: Allocator) void {
    const file_path = self.file.?.path;
    const file = std.fs.cwd().openFile(file_path, .{ .read = true }) catch u.panic("Can't open '{s}'", .{file_path});
    defer file.close();

    const stat = file.stat() catch |err| u.panic("{} while getting stat on '{s}'", .{ err, file_path });
    self.file.?.mtime = stat.mtime;

    const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10 Mb
    const file_contents = file.reader().readAllAlloc(allocator, MAX_FILE_SIZE) catch |e| switch (e) {
        error.StreamTooLong => u.panic("File '{s}' is more than 10 Mb in size", .{file_path}),
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

    self.colors.clearRetainingCapacity();
    self.colors.ensureTotalCapacity(self.chars.items.len) catch u.oom();

    self.lines.clearRetainingCapacity();
    self.lines.append(0) catch u.oom(); // first line is always at the buffer start

    self.modified = false;
    self.modified_on_disk = false;
    self.dirty = true; // trigger the syncing of the above structures
}

pub fn syncInternalData(self: *Buffer) void {
    // Recalculate lines
    {
        self.lines.shrinkRetainingCapacity(1);
        self.lines_whitespace.clearRetainingCapacity();
        var new_line = true;
        for (self.chars.items) |char, i| {
            if (new_line and char != ' ') {
                self.lines_whitespace.append(i) catch u.oom();
                new_line = false;
            }
            if (char == '\n') {
                self.lines.append(i + 1) catch u.oom();
                new_line = true;
            }
        }

        if (self.lines.items.len > self.lines_whitespace.items.len) {
            // If the last line is empty, manually add an entry
            self.lines_whitespace.append(self.chars.items.len) catch u.oom();
            // Temporary assert. Can be removed if never triggered
            u.assert(self.lines.items.len == self.lines_whitespace.items.len);
        }
    }

    // Highlight code
    {
        // Have the color array ready
        self.colors.ensureTotalCapacity(self.chars.items.len) catch u.oom();
        self.colors.expandToCapacity();
        var colors = self.colors.items;
        std.mem.set(TextColor, colors, .comment);

        self.recalculateBytes();
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

    self.dirty = false;
}

/// Returns line and column given a position in the buffer
pub fn getLineCol(self: Buffer, pos: usize) LineCol {
    // Binary search
    const lines = self.lines.items;
    var left: usize = 0;
    var right: usize = lines.len - 1;
    const line = if (pos >= lines[right])
        right
    else while (right - left > 1) {
        const mid = left + (right - left) / 2;
        const mid_value = lines[mid];
        if (pos == mid_value) break mid;
        if (pos < mid_value) {
            right = mid;
        } else {
            left = mid;
        }
    } else left;
    const col = pos - lines[line];
    return .{ .line = line, .col = col };
}

fn recalculateBytes(self: *Buffer) void {
    self.bytes.ensureTotalCapacity(self.chars.items.len * 4) catch u.oom(); // enough to store 4-byte chars
    self.bytes.expandToCapacity();
    var cursor: usize = 0;
    for (self.chars.items) |char| {
        const num_bytes = std.unicode.utf8Encode(char, self.bytes.items[cursor..]) catch unreachable;
        cursor += @intCast(usize, num_bytes);
    }
    self.bytes.shrinkRetainingCapacity(cursor);
}
