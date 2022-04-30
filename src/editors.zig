const std = @import("std");
const glfw = @import("glfw");

const focus = @import("focus.zig");
const u = focus.utils;
const style = focus.style;

const Allocator = std.mem.Allocator;
const Vec2 = u.Vec2;
const Rect = u.Rect;
const Font = focus.fonts.Font;
const TextColor = focus.style.TextColor;
const Ui = focus.ui.Ui;

const TAB_SIZE = 4;

const EditorLayout = enum {
    none,
    single,
    side_by_side,
};

pub const EditorManager = struct {
    allocator: Allocator,
    open_editors: std.ArrayList(Editor),
    left: ?usize = null,
    right: ?usize = null,
    active: ?usize = null,

    pub fn init(allocator: Allocator) EditorManager {
        return .{
            .allocator = allocator,
            .open_editors = std.ArrayList(Editor).initCapacity(allocator, 10) catch u.oom(),
        };
    }

    pub fn deinit(self: EditorManager) void {
        for (self.open_editors.items) |editor| {
            editor.deinit();
        }
    }

    pub fn updateAndDrawAll(self: *EditorManager, ui: *Ui, clock_ms: f64) void {
        // Always try to update all open editors
        for (self.open_editors.items) |*editor| {
            if (editor.dirty) editor.syncInternalData();
        }

        // The editors always take the entire screen area
        var area = ui.screen.getRect();

        // Lay out the editors in rects and draw each
        switch (self.layout()) {
            .single => {
                self.leftEditor().updateAndDraw(ui, area, clock_ms, true);
            },
            .side_by_side => {
                const left_rect = area.splitLeft(area.w / 2 - 1, 1);
                const right_rect = area;

                self.leftEditor().updateAndDraw(ui, left_rect, clock_ms, self.isLeftActive());
                self.rightEditor().updateAndDraw(ui, right_rect, clock_ms, self.isRightActive());

                const splitter_rect = Rect{ .x = area.x - 2, .y = area.y, .w = 2, .h = area.h };
                ui.drawSolidRect(splitter_rect, style.colors.BACKGROUND_BRIGHT);
            },
            else => {},
        }
    }

    pub fn openFileLeft(self: *EditorManager, path: []const u8) void {
        const editor = if (self.editorExistsForFile(path)) |editor| editor else self.openNewEditor(path);
        self.left = editor;
        self.active = editor;
    }

    pub fn openFileRight(self: *EditorManager, path: []const u8) void {
        const editor = if (self.editorExistsForFile(path)) |editor| editor else self.openNewEditor(path);
        if (self.left == null) {
            self.left = editor;
        } else {
            self.right = editor;
        }
        self.active = editor;
    }

    pub fn haveActiveScrollAnimation(self: *EditorManager) bool {
        if (self.activeEditor()) |editor| {
            return editor.scroll_animation != null;
        }
        return false;
    }

    fn editorExistsForFile(self: EditorManager, path: []const u8) ?usize {
        for (self.open_editors.items) |editor, i| {
            if (std.mem.eql(u8, path, editor.file_path)) return i;
        }
        return null;
    }

    fn openNewEditor(self: *EditorManager, path: []const u8) usize {
        const new_editor = Editor.init(self.allocator, path) catch unreachable;
        self.open_editors.append(new_editor) catch u.oom();
        return self.open_editors.items.len - 1;
    }

    fn layout(self: EditorManager) EditorLayout {
        if (self.left != null and self.right != null) return .side_by_side;
        if (self.left != null) return .single;
        u.assert(self.right == null);
        return .none;
    }

    pub fn activeEditor(self: *EditorManager) ?*Editor {
        if (self.active) |active| {
            return &self.open_editors.items[active];
        }
        return null;
    }

    fn leftEditor(self: *EditorManager) *Editor {
        return &self.open_editors.items[self.left.?];
    }

    fn rightEditor(self: *EditorManager) *Editor {
        return &self.open_editors.items[self.right.?];
    }

    fn isLeftActive(self: EditorManager) bool {
        return self.left != null and self.active != null and self.left.? == self.active.?;
    }

    fn isRightActive(self: EditorManager) bool {
        return self.right != null and self.active != null and self.right.? == self.active.?;
    }
};

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
    allocator: Allocator,
    file_path: []const u8,
    bytes: std.ArrayList(u8),
    chars: std.ArrayList(u.Char),
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

    pub fn init(allocator: Allocator, file_path: []const u8) !Editor {
        const file_contents = try u.readEntireFile(file_path, allocator);
        defer allocator.free(file_contents);
        var bytes = std.ArrayList(u8).init(allocator);
        bytes.appendSlice(file_contents) catch u.oom();

        // For simplicity we assume that a codepoint equals a character (though it's not true).
        // If we ever encounter multi-codepoint characters, we can revisit this
        var chars = std.ArrayList(u.Char).init(allocator);
        try chars.ensureTotalCapacity(bytes.items.len);
        const utf8_view = try std.unicode.Utf8View.init(bytes.items);
        var iterator = utf8_view.iterator();
        while (iterator.nextCodepoint()) |char| {
            try chars.append(char);
        }

        var colors = std.ArrayList(TextColor).init(allocator);
        try colors.ensureTotalCapacity(chars.items.len);

        var lines = std.ArrayList(usize).init(allocator);
        try lines.append(0); // first line is always at the buffer start

        return Editor{
            .allocator = allocator,
            .file_path = allocator.dupe(u8, file_path) catch u.oom(),
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
        self.allocator.free(self.file_path);
    }

    pub fn updateAndDraw(self: *Editor, ui: *Ui, rect: Rect, clock_ms: f64, is_active: bool) void {
        const scale = ui.screen.scale;
        const char_size = ui.screen.font.charSize();
        const margin = Vec2{ .x = 30 * scale, .y = 15 * scale };

        var area = rect.copy();
        const footer_rect = area.splitBottom(char_size.y + 4, 0);
        area = area.shrink(margin.x, margin.y, margin.x, 0);

        // Retain info about size - we only know it now
        self.lines_per_screen = @floatToInt(usize, area.h / char_size.y);
        self.cols_per_screen = @floatToInt(usize, area.w / char_size.x);

        self.updateCursorLineAndCol();
        self.moveViewportToCursor(char_size); // depends on lines_per_screen etc
        self.animateScrolling(clock_ms);

        // Draw the text
        {
            // TODO:
            ui.drawEditor(self, area, is_active);
        }

        // Draw footer
        ui.drawSolidRect(footer_rect, style.colors.BACKGROUND_BRIGHT);
        ui.drawTopShadow(footer_rect, 5);
    }

    /// Inserts a char at the cursor
    pub fn typeChar(self: *Editor, char: u.Char) void {
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
                const SPACES = [1]u.Char{' '} ** TAB_SIZE;
                const to_next_tabstop = TAB_SIZE - self.cursor.col % TAB_SIZE;
                self.chars.insertSlice(self.cursor.pos, SPACES[0..to_next_tabstop]) catch u.oom();
                self.cursor.pos += to_next_tabstop;
                self.cursor.col_wanted = null;
            },
            .enter => {
                var indent = self.getCurrentLineIndent();
                var buf: [1024]u.Char = undefined;
                if (mods.control and mods.shift) {
                    // Insert line above
                    std.mem.set(u.Char, buf[0..indent], ' ');
                    buf[indent] = '\n';
                    self.cursor.pos = self.lines.items[self.cursor.line];
                    self.chars.insertSlice(self.cursor.pos, buf[0 .. indent + 1]) catch u.oom();
                    self.cursor.pos += indent;
                } else if (mods.control) {
                    // Insert line below
                    std.mem.set(u.Char, buf[0..indent], ' ');
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
                    std.mem.set(u.Char, buf[1 .. indent + 1], ' ');
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
                        const EMPTY_ARRAY = [_]u.Char{};
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

    pub fn animateScrolling(self: *Editor, clock_ms: f64) void {
        if (self.scroll_animation) |animation| {
            self.scroll = animation.getValue(clock_ms);
            if (animation.isFinished(clock_ms)) {
                self.scroll_animation = null;
            }
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

    fn updateCursorLineAndCol(self: *Editor) void {
        self.cursor.line = for (self.lines.items) |line_start, line| {
            if (self.cursor.pos < line_start) {
                break line -| 1;
            }
        } else self.lines.items.len;
        self.cursor.col = self.cursor.pos - self.lines.items[self.cursor.line];
    }

    fn moveViewportToCursor(self: *Editor, char_size: Vec2) void {
        // Current scroll offset in characters
        var viewport_top = @floatToInt(usize, self.scroll.y / char_size.y);
        var viewport_left = @floatToInt(usize, self.scroll.x / char_size.x);

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

        self.scroll.y = @intToFloat(f32, viewport_top) * char_size.y;
        self.scroll.x = @intToFloat(f32, viewport_left) * char_size.x;
    }

    fn syncInternalData(self: *Editor) void {
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
