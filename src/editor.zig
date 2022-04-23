const std = @import("std");
const u = @import("utils.zig");

const Allocator = std.mem.Allocator;
const Vec2 = u.Vec2;

const Cursor = struct {
    pos: usize = 0,
    line: usize = 0, // from the beginning of buffer
    col: usize = 0, // actual column
    col_wanted: ?usize = null, // where the cursor wants to be
};

pub const Editor = struct {
    // TODO: implement 2 editors using the same buffer

    // buffer
    bytes: std.ArrayList(u8),
    chars: std.ArrayList(u.Codepoint),
    colors: std.ArrayList(u.TextColor),
    lines: std.ArrayList(usize),

    // editor
    cursor: Cursor,
    offset: Vec2, // how many px we have scrolled to the left and to the top
    offset_wanted: Vec2, // where we want to scroll

    // TODO:
    // text_changed: bool = false,
    // view_changed: bool = false,

    pub fn init(allocator: Allocator, comptime file_name: []const u8) !Editor {
        const initial = @embedFile(file_name);
        var bytes = std.ArrayList(u8).init(allocator);
        try bytes.appendSlice(initial);

        // For simplicity we assume that a codepoint equals a character (though it's not true).
        // If we ever encounter multi-codepoint characters, we can revisit this
        var chars = std.ArrayList(u.Codepoint).init(allocator);
        try chars.ensureTotalCapacity(bytes.items.len);
        const utf8_view = try std.unicode.Utf8View.init(bytes.items);
        var codepoints = utf8_view.iterator();
        while (codepoints.nextCodepoint()) |codepoint| {
            try chars.append(codepoint);
        }

        var colors = std.ArrayList(u.TextColor).init(allocator);
        try colors.ensureTotalCapacity(chars.items.len);

        var lines = std.ArrayList(usize).init(allocator);
        try lines.append(0); // first line is always at the buffer start

        return Editor{
            .bytes = bytes,
            .chars = chars,
            .colors = colors,
            .lines = lines,
            .cursor = Cursor{},
            .offset = Vec2{},
            .offset_wanted = Vec2{},
        };
    }

    pub fn deinit(self: Editor) void {
        self.bytes.deinit();
        self.chars.deinit();
        self.colors.deinit();
        self.lines.deinit();
    }

    pub fn recalculateLines(self: *Editor) !void {
        self.lines.shrinkRetainingCapacity(1);
        for (self.chars.items) |char, i| {
            if (char == '\n') {
                try self.lines.append(i + 1);
            }
        }
        try self.lines.append(self.chars.items.len);
    }

    pub fn recalculateBytes(self: *Editor) !void {
        try self.bytes.ensureTotalCapacity(self.chars.items.len * 4); // enough to store 4-byte chars
        self.bytes.expandToCapacity();
        var cursor: usize = 0;
        for (self.chars.items) |char| {
            const num_bytes = try std.unicode.utf8Encode(char, self.bytes.items[cursor..]);
            cursor += @intCast(usize, num_bytes);
        }
        self.bytes.shrinkRetainingCapacity(cursor);
        try self.bytes.append(0); // so we can pass it to tokenizer
    }

    pub fn highlightCode(self: *Editor) !void {
        // Have the color array ready
        try self.colors.ensureTotalCapacity(self.chars.items.len);
        self.colors.expandToCapacity();
        var colors = self.colors.items;
        std.mem.set(u.TextColor, colors, .comment);

        // NOTE: we're tokenizing the whole source file. At least for zig this can be optimised,
        // but we're not doing it just yet
        const source_bytes = self.bytes.items[0 .. self.bytes.items.len - 1 :0]; // has to be null-terminated
        var tokenizer = std.zig.Tokenizer.init(source_bytes);
        while (true) {
            var token = tokenizer.next();
            const token_color: u.TextColor = switch (token.tag) {
                .eof => break,
                .invalid => .@"error",
                .string_literal, .multiline_string_literal_line, .char_literal => .string,
                .builtin => .function,
                .identifier => u.TextColor.getForIdentifier(self.chars.items[token.loc.start..token.loc.end], self.chars.items[token.loc.end]),
                .integer_literal, .float_literal => .value,
                .doc_comment, .container_doc_comment => .comment,
                .keyword_addrspace, .keyword_align, .keyword_allowzero, .keyword_and, .keyword_anyframe, .keyword_anytype, .keyword_asm, .keyword_async, .keyword_await, .keyword_break, .keyword_callconv, .keyword_catch, .keyword_comptime, .keyword_const, .keyword_continue, .keyword_defer, .keyword_else, .keyword_enum, .keyword_errdefer, .keyword_error, .keyword_export, .keyword_extern, .keyword_fn, .keyword_for, .keyword_if, .keyword_inline, .keyword_noalias, .keyword_noinline, .keyword_nosuspend, .keyword_opaque, .keyword_or, .keyword_orelse, .keyword_packed, .keyword_pub, .keyword_resume, .keyword_return, .keyword_linksection, .keyword_struct, .keyword_suspend, .keyword_switch, .keyword_test, .keyword_threadlocal, .keyword_try, .keyword_union, .keyword_unreachable, .keyword_usingnamespace, .keyword_var, .keyword_volatile, .keyword_while => .keyword,
                .bang, .pipe, .pipe_pipe, .pipe_equal, .equal, .equal_equal, .equal_angle_bracket_right, .bang_equal, .l_paren, .r_paren, .semicolon, .percent, .percent_equal, .l_brace, .r_brace, .l_bracket, .r_bracket, .period, .period_asterisk, .ellipsis2, .ellipsis3, .caret, .caret_equal, .plus, .plus_plus, .plus_equal, .plus_percent, .plus_percent_equal, .plus_pipe, .plus_pipe_equal, .minus, .minus_equal, .minus_percent, .minus_percent_equal, .minus_pipe, .minus_pipe_equal, .asterisk, .asterisk_equal, .asterisk_asterisk, .asterisk_percent, .asterisk_percent_equal, .asterisk_pipe, .asterisk_pipe_equal, .arrow, .colon, .slash, .slash_equal, .comma, .ampersand, .ampersand_equal, .question_mark, .angle_bracket_left, .angle_bracket_left_equal, .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_left_equal, .angle_bracket_angle_bracket_left_pipe, .angle_bracket_angle_bracket_left_pipe_equal, .angle_bracket_right, .angle_bracket_right_equal, .angle_bracket_angle_bracket_right, .angle_bracket_angle_bracket_right_equal, .tilde => .punctuation,
                else => .default,
            };
            std.mem.set(u.TextColor, colors[token.loc.start..token.loc.end], token_color);
        }
    }
};
