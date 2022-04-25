const std = @import("std");
const glfw = @import("glfw");
const u = @import("utils.zig");

const Allocator = std.mem.Allocator;
const Vec2 = u.Vec2;
const Font = @import("fonts.zig").Font;
const TextColor = @import("style.zig").TextColor;

const TAB_SIZE = 4;

const Cursor = struct {
    pos: usize = 0,
    line: usize = 0, // from the beginning of buffer
    col: usize = 0, // actual column
    col_wanted: ?usize = null, // where the cursor wants to be
};

const ScrollAnimation = struct {
    start_ms: f64,
    target_ms: f64,
    value1: Vec2,
    value2: Vec2,

    const DURATION_MS: f64 = 32;

    fn getValue(self: ScrollAnimation, clock_ms: f64) Vec2 {
        const total = self.target_ms - self.start_ms;
        const delta = if (clock_ms <= self.target_ms)
            clock_ms - self.start_ms
        else
            total;
        const t = @floatCast(f32, delta / total);
        return Vec2{
            .x = self.value1.x * (1 - t) + self.value2.x * t,
            .y = self.value1.y * (1 - t) + self.value2.y * t,
        };
    }

    fn isFinished(self: ScrollAnimation, clock_ms: f64) bool {
        return self.target_ms <= clock_ms;
    }
};

pub const Editor = struct {
    // TODO: implement 2 editors using the same buffer

    // buffer
    bytes: std.ArrayList(u8),
    chars: std.ArrayList(u.Codepoint),
    colors: std.ArrayList(TextColor),
    lines: std.ArrayList(usize),
    dirty: bool = true, // needs syncing internal structures

    // Updated every time we draw UI (because that's when we know the layout and therefore size)
    lines_per_screen: usize = 60,
    cols_per_screen: usize = 120,

    // editor
    cursor: Cursor,
    scroll: Vec2, // how many px we have scrolled to the left and to the top
    scroll_animation: ?ScrollAnimation = null,

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

        var colors = std.ArrayList(TextColor).init(allocator);
        try colors.ensureTotalCapacity(chars.items.len);

        var lines = std.ArrayList(usize).init(allocator);
        try lines.append(0); // first line is always at the buffer start

        return Editor{
            .bytes = bytes,
            .chars = chars,
            .colors = colors,
            .lines = lines,
            .cursor = Cursor{},
            .scroll = Vec2{},
        };
    }

    pub fn deinit(self: Editor) void {
        self.bytes.deinit();
        self.chars.deinit();
        self.colors.deinit();
        self.lines.deinit();
    }

    /// Inserts a char at the cursor
    pub fn typeChar(self: *Editor, char: u.Codepoint) void {
        self.chars.insert(self.cursor.pos, char) catch u.oom();
        self.cursor.pos += 1;
        self.cursor.col_wanted = null;
        self.dirty = true;
    }

    /// Processes a key press event
    pub fn keyPress(self: *Editor, key: glfw.Key, mods: glfw.Mods) void {
        self.dirty = true;

        switch (key) {
            .left => {
                self.cursor.pos -|= 1;
                self.cursor.col_wanted = null;
            },
            .right => {
                if (self.cursor.pos < self.chars.items.len - 1) {
                    self.cursor.pos += 1;
                    self.cursor.col_wanted = null;
                }
            },
            .up => {
                const offset: usize = if (mods.control) 5 else 1;
                self.moveCursorToLine(self.cursor.line -| offset);
            },
            .down => {
                const offset: usize = if (mods.control) 5 else 1;
                self.moveCursorToLine(self.cursor.line + offset);
            },
            .page_up => {
                self.moveCursorToLine(self.cursor.line -| self.lines_per_screen);
            },
            .page_down => {
                self.moveCursorToLine(self.cursor.line + self.lines_per_screen);
            },
            .home => {
                self.cursor.pos = self.lines.items[self.cursor.line];
                self.cursor.col_wanted = null;
            },
            .end => {
                self.cursor.pos = self.lines.items[self.cursor.line + 1] - 1;
                self.cursor.col_wanted = std.math.maxInt(usize);
            },
            .tab => {
                const SPACES = [1]u.Codepoint{' '} ** TAB_SIZE;
                const to_next_tabstop = TAB_SIZE - self.cursor.col % TAB_SIZE;
                self.chars.insertSlice(self.cursor.pos, SPACES[0..to_next_tabstop]) catch u.oom();
                self.cursor.pos += to_next_tabstop;
                self.cursor.col_wanted = null;
            },
            .enter => {
                var indent = self.getCurrentLineIndent();
                var buf: [1024]u.Codepoint = undefined;
                if (mods.control and mods.shift) {
                    // Insert line above
                    std.mem.set(u.Codepoint, buf[0..indent], ' ');
                    buf[indent] = '\n';
                    self.cursor.pos = self.lines.items[self.cursor.line];
                    self.chars.insertSlice(self.cursor.pos, buf[0 .. indent + 1]) catch u.oom();
                    self.cursor.pos += indent;
                } else if (mods.control) {
                    // Insert line below
                    std.mem.set(u.Codepoint, buf[0..indent], ' ');
                    buf[indent] = '\n';
                    self.cursor.pos = self.lines.items[self.cursor.line + 1];
                    self.chars.insertSlice(self.cursor.pos, buf[0 .. indent + 1]) catch u.oom();
                    self.cursor.pos += indent;
                } else {
                    // Break the line normally
                    const prev_char = self.chars.items[self.cursor.pos -| 1];
                    const next_char = self.chars.items[self.cursor.pos]; // TODO: fix when near the end
                    if (prev_char == '{' and next_char == '\n') {
                        indent += TAB_SIZE;
                    }
                    buf[0] = '\n';
                    std.mem.set(u.Codepoint, buf[1 .. indent + 1], ' ');
                    self.chars.insertSlice(self.cursor.pos, buf[0 .. indent + 1]) catch u.oom();
                    self.cursor.pos += 1 + indent;
                    if (prev_char == '{' and next_char == '\n') {
                        // Insert a closing brace
                        indent -= TAB_SIZE;
                        self.chars.insertSlice(self.cursor.pos, buf[0 .. indent + 1]) catch u.oom();
                        self.chars.insert(self.cursor.pos + indent + 1, '}') catch u.oom();
                    }
                }
                self.cursor.col_wanted = null;
            },
            .backspace => if (self.cursor.pos > 0) {
                const to_prev_tabstop = x: {
                    var spaces = self.cursor.col % TAB_SIZE;
                    if (spaces == 0 and self.cursor.col > 0) spaces = 4;
                    break :x spaces;
                };
                // Check if we can delete spaces to the previous tabstop
                var all_spaces: bool = false;
                if (to_prev_tabstop > 0) {
                    const pos = self.cursor.pos;
                    all_spaces = for (self.chars.items[(pos - to_prev_tabstop)..pos]) |char| {
                        if (char != ' ') break false;
                    } else true;
                    if (all_spaces) {
                        // Delete all spaces
                        self.cursor.pos -= to_prev_tabstop;
                        const EMPTY_ARRAY = [_]u.Codepoint{};
                        self.chars.replaceRange(self.cursor.pos, to_prev_tabstop, EMPTY_ARRAY[0..]) catch unreachable;
                    }
                }
                if (!all_spaces) {
                    // Just delete 1 char
                    self.cursor.pos -= 1;
                    _ = self.chars.orderedRemove(self.cursor.pos);
                }
                self.cursor.col_wanted = null;
            },
            .delete => if (self.chars.items.len > 1 and self.cursor.pos < self.chars.items.len - 1) {
                _ = self.chars.orderedRemove(self.cursor.pos);
                self.cursor.col_wanted = null;
            },
            else => {
                self.dirty = false; // nothing needs to be done
            },
        }
    }

    pub fn setNewScrollTarget(self: *Editor, target: f32, clock_ms: f64) void {
        self.scroll_animation = ScrollAnimation{
            .start_ms = clock_ms,
            .target_ms = clock_ms + ScrollAnimation.DURATION_MS,
            .value1 = self.scroll,
            .value2 = Vec2{ .x = self.scroll.x, .y = target }, // TODO: support x
        };
    }

    pub fn animateScrolling(self: *Editor, clock_ms: f64) bool {
        if (self.scroll_animation) |animation| {
            self.scroll = animation.getValue(clock_ms);
            if (animation.isFinished(clock_ms)) {
                self.scroll_animation = null;
            }
            return true;
        } else {
            return false;
        }
    }

    fn moveCursorToLine(self: *Editor, line: usize) void {
        const target_line = if (line > self.lines.items.len - 2)
            self.lines.items.len - 2
        else
            line;
        const chars_on_target_line = self.lines.items[target_line + 1] - self.lines.items[target_line] -| 1;
        const wanted_pos = if (self.cursor.col_wanted) |wanted|
            wanted
        else
            self.cursor.col;
        const new_line_pos = std.math.min(wanted_pos, chars_on_target_line);
        self.cursor.col_wanted = if (new_line_pos < wanted_pos) wanted_pos else null; // reset or remember wanted position
        self.cursor.pos = self.lines.items[target_line] + new_line_pos;
    }

    fn getCurrentLineIndent(self: Editor) usize {
        var indent: usize = 0;
        var cursor: usize = self.lines.items[self.cursor.line];
        while (self.chars.items[cursor] == ' ') {
            indent += 1;
            cursor += 1;
        }
        return indent;
    }

    pub fn updateCursor(self: *Editor) void {
        self.cursor.line = for (self.lines.items) |line_start, line| {
            if (self.cursor.pos < line_start) {
                break line - 1;
            } else if (self.cursor.pos == line_start) {
                break line; // for one-line files
            }
        } else self.lines.items.len;
        self.cursor.col = self.cursor.pos - self.lines.items[self.cursor.line];
    }

    pub fn moveViewportToCursor(self: *Editor, font: Font) void {
        // Current scroll offset in characters
        var viewport_top = @floatToInt(usize, self.scroll.y / font.line_height);
        var viewport_left = @floatToInt(usize, self.scroll.x / font.xadvance);

        // Allowed cursor positions within viewport
        const padding = 4;
        const line_min = viewport_top + padding;
        const line_max = viewport_top + self.lines_per_screen -| padding -| 1;
        const col_min = viewport_left + padding;
        const col_max = viewport_left + self.cols_per_screen -| padding -| 1;

        // Detect if cursor is outside viewport
        if (self.cursor.line < line_min) {
            viewport_top = self.cursor.line -| padding;
        } else if (self.cursor.line > line_max) {
            viewport_top = self.cursor.line + padding + 1 -| self.lines_per_screen;
        }
        if (self.cursor.col < col_min) {
            viewport_left -|= (col_min - self.cursor.col);
        } else if (self.cursor.col > col_max) {
            viewport_left += (self.cursor.col -| col_max);
        }

        self.scroll.y = @intToFloat(f32, viewport_top) * font.line_height;
        self.scroll.x = @intToFloat(f32, viewport_left) * font.xadvance;
    }

    pub fn syncInternalData(self: *Editor) void {
        self.recalculateLines();
        self.recalculateBytes();
        self.highlightCode();
        self.dirty = false;
    }

    fn recalculateLines(self: *Editor) void {
        self.lines.shrinkRetainingCapacity(1);
        for (self.chars.items) |char, i| {
            if (char == '\n') {
                self.lines.append(i + 1) catch u.oom();
            }
        }
        self.lines.append(self.chars.items.len) catch u.oom();
    }

    fn recalculateBytes(self: *Editor) void {
        self.bytes.ensureTotalCapacity(self.chars.items.len * 4) catch u.oom(); // enough to store 4-byte chars
        self.bytes.expandToCapacity();
        var cursor: usize = 0;
        for (self.chars.items) |char| {
            const num_bytes = std.unicode.utf8Encode(char, self.bytes.items[cursor..]) catch unreachable;
            cursor += @intCast(usize, num_bytes);
        }
        self.bytes.shrinkRetainingCapacity(cursor);
        self.bytes.append(0) catch u.oom(); // so we can pass it to tokenizer
    }

    fn highlightCode(self: *Editor) void {
        // Have the color array ready
        self.colors.ensureTotalCapacity(self.chars.items.len) catch u.oom();
        self.colors.expandToCapacity();
        var colors = self.colors.items;
        std.mem.set(TextColor, colors, .comment);

        // NOTE: we're tokenizing the whole source file. At least for zig this can be optimised,
        // but we're not doing it just yet
        const source_bytes = self.bytes.items[0 .. self.bytes.items.len - 1 :0]; // has to be null-terminated
        var tokenizer = std.zig.Tokenizer.init(source_bytes);
        while (true) {
            var token = tokenizer.next();
            const token_color: TextColor = switch (token.tag) {
                .eof => break,
                .invalid => .@"error",
                .string_literal, .multiline_string_literal_line, .char_literal => .string,
                .builtin => .function,
                .identifier => TextColor.getForIdentifier(self.chars.items[token.loc.start..token.loc.end], self.chars.items[token.loc.end]),
                .integer_literal, .float_literal => .value,
                .doc_comment, .container_doc_comment => .comment,
                .keyword_addrspace, .keyword_align, .keyword_allowzero, .keyword_and, .keyword_anyframe, .keyword_anytype, .keyword_asm, .keyword_async, .keyword_await, .keyword_break, .keyword_callconv, .keyword_catch, .keyword_comptime, .keyword_const, .keyword_continue, .keyword_defer, .keyword_else, .keyword_enum, .keyword_errdefer, .keyword_error, .keyword_export, .keyword_extern, .keyword_fn, .keyword_for, .keyword_if, .keyword_inline, .keyword_noalias, .keyword_noinline, .keyword_nosuspend, .keyword_opaque, .keyword_or, .keyword_orelse, .keyword_packed, .keyword_pub, .keyword_resume, .keyword_return, .keyword_linksection, .keyword_struct, .keyword_suspend, .keyword_switch, .keyword_test, .keyword_threadlocal, .keyword_try, .keyword_union, .keyword_unreachable, .keyword_usingnamespace, .keyword_var, .keyword_volatile, .keyword_while => .keyword,
                .bang, .pipe, .pipe_pipe, .pipe_equal, .equal, .equal_equal, .equal_angle_bracket_right, .bang_equal, .l_paren, .r_paren, .semicolon, .percent, .percent_equal, .l_brace, .r_brace, .l_bracket, .r_bracket, .period, .period_asterisk, .ellipsis2, .ellipsis3, .caret, .caret_equal, .plus, .plus_plus, .plus_equal, .plus_percent, .plus_percent_equal, .plus_pipe, .plus_pipe_equal, .minus, .minus_equal, .minus_percent, .minus_percent_equal, .minus_pipe, .minus_pipe_equal, .asterisk, .asterisk_equal, .asterisk_asterisk, .asterisk_percent, .asterisk_percent_equal, .asterisk_pipe, .asterisk_pipe_equal, .arrow, .colon, .slash, .slash_equal, .comma, .ampersand, .ampersand_equal, .question_mark, .angle_bracket_left, .angle_bracket_left_equal, .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_left_equal, .angle_bracket_angle_bracket_left_pipe, .angle_bracket_angle_bracket_left_pipe_equal, .angle_bracket_right, .angle_bracket_right_equal, .angle_bracket_angle_bracket_right, .angle_bracket_angle_bracket_right_equal, .tilde => .punctuation,
                else => .default,
            };
            std.mem.set(TextColor, colors[token.loc.start..token.loc.end], token_color);
        }
    }
};
