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

allocator: Allocator,
open_buffers: std.ArrayList(Buffer),
open_editors: std.ArrayList(Editor),
layout: union(enum) {
    none,
    single: usize,
    side_by_side: struct {
        left: usize,
        right: usize,
        active: usize,
    },
},

const Self = @This();

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
        .open_buffers = std.ArrayList(Buffer).initCapacity(allocator, 10) catch u.oom(),
        .open_editors = std.ArrayList(Editor).initCapacity(allocator, 10) catch u.oom(),
        .layout = .none,
    };
}

pub fn deinit(self: Self) void {
    for (self.open_buffers.items) |buf| {
        buf.bytes.deinit();
        buf.chars.deinit();
        buf.colors.deinit();
        buf.lines.deinit();
        self.allocator.free(buf.file_path);
    }
}

pub fn updateAndDrawAll(self: *Self, ui: *Ui, clock_ms: f64, tmp_allocator: Allocator) void {
    // Always try to update all open buffers
    for (self.open_buffers.items) |*buf| {
        if (buf.dirty) buf.syncInternalData();
    }

    // The editors always take the entire screen area
    var area = ui.screen.getRect();

    // Lay out the editors in rects and draw each
    switch (self.layout) {
        .none => {}, // nothing to draw
        .single => |e| {
            var editor = &self.open_editors.items[e];
            editor.updateAndDraw(self.getBuffer(editor.buffer), ui, area, clock_ms, true, tmp_allocator);
        },
        .side_by_side => |e| {
            const left_rect = area.splitLeft(area.w / 2 - 1, 1);
            const right_rect = area;

            var e1 = &self.open_editors.items[e.left];
            var e2 = &self.open_editors.items[e.right];
            e1.updateAndDraw(self.getBuffer(e1.buffer), ui, left_rect, clock_ms, e.active == e.left, tmp_allocator);
            e2.updateAndDraw(self.getBuffer(e2.buffer), ui, right_rect, clock_ms, e.active == e.right, tmp_allocator);

            const splitter_rect = Rect{ .x = area.x - 2, .y = area.y, .w = 2, .h = area.h };
            ui.drawSolidRect(splitter_rect, style.colors.BACKGROUND_BRIGHT);
        },
    }
}

pub fn charEntered(self: *Self, char: u.Char) void {
    if (self.activeEditor()) |editor| editor.typeChar(char, self.getBuffer(editor.buffer));
}

pub fn keyPress(self: *Self, key: glfw.Key, mods: glfw.Mods) void {
    if (mods.control and mods.alt) {
        switch (key) {
            .left => {
                self.switchToLeft();
                return;
            },
            .right => {
                self.switchToRight();
                return;
            },
            .p => if (self.activeEditor()) |editor| {
                // Duplicate current editor on the other side
                const file_path = self.getBuffer(editor.buffer).file_path;
                self.openFile(file_path, true);
            },
            else => {},
        }
    }
    if (self.activeEditor()) |editor| editor.keyPress(self.getBuffer(editor.buffer), key, mods);
}

pub fn haveActiveScrollAnimation(self: *Self) bool {
    if (self.activeEditor()) |editor| {
        return editor.scroll_animation != null;
    }
    return false;
}

pub fn openFile(self: *Self, path: []const u8, on_the_side: bool) void {
    const buffer = if (self.findOpenBuffer(path)) |buffer| buffer else self.openNewBuffer(path);
    switch (self.layout) {
        .none => {
            // Create a new editor and switch to single layout
            const new_editor = self.createNewEditor(buffer);
            self.layout = .{ .single = new_editor };
        },
        .single => |e| {
            if (on_the_side) {
                // Always switch to a new editor
                const new_editor = self.createNewEditor(buffer);
                self.layout = .{ .side_by_side = .{ .left = e, .right = new_editor, .active = new_editor } };
            } else {
                // If already editing this buffer, nothing to do
                if (self.open_editors.items[e].buffer == buffer) return;

                // Replace the current editor
                const new_editor = self.createNewEditor(buffer);
                self.layout = .{ .single = new_editor };
                self.removeEditor(e);
            }
        },
        .side_by_side => |e| {
            const target_is_left = (e.left == e.active and !on_the_side) or (e.right == e.active and on_the_side);
            const target = if (target_is_left) e.left else e.right;

            // If the target editor is already for this buffer, just switch
            if (self.open_editors.items[target].buffer == buffer) {
                self.layout.side_by_side.active = target;
                return;
            }

            // Otherwise, replace with a new editor
            const new_editor = self.createNewEditor(buffer);
            if (target_is_left) {
                self.layout.side_by_side.left = new_editor;
            } else {
                self.layout.side_by_side.right = new_editor;
            }
            self.layout.side_by_side.active = new_editor;
            self.removeEditor(target);
        },
    }
}

fn switchToLeft(self: *Self) void {
    if (self.layout == .side_by_side) self.layout.side_by_side.active = self.layout.side_by_side.left;
}

fn switchToRight(self: *Self) void {
    if (self.layout == .side_by_side) self.layout.side_by_side.active = self.layout.side_by_side.right;
}

fn getBuffer(self: *Self, buffer: usize) *Buffer {
    return &self.open_buffers.items[buffer];
}

fn findOpenBuffer(self: Self, path: []const u8) ?usize {
    for (self.open_buffers.items) |buffer, i| {
        if (std.mem.eql(u8, path, buffer.file_path)) return i;
    }
    return null;
}

fn openNewBuffer(self: *Self, path: []const u8) usize {
    const new_buffer = blk: {
        const file_contents = u.readEntireFile(path, self.allocator) catch @panic("couldn't read file");
        defer self.allocator.free(file_contents);
        var bytes = std.ArrayList(u8).init(self.allocator);
        bytes.appendSlice(file_contents) catch u.oom();

        // For simplicity we assume that a codepoint equals a character (though it's not true).
        // If we ever encounter multi-codepoint characters, we can revisit this
        var chars = std.ArrayList(u.Char).init(self.allocator);
        chars.ensureTotalCapacity(bytes.items.len) catch u.oom();
        const utf8_view = std.unicode.Utf8View.init(bytes.items) catch @panic("invalid utf-8");
        var iterator = utf8_view.iterator();
        while (iterator.nextCodepoint()) |char| {
            chars.append(char) catch u.oom();
        }

        var colors = std.ArrayList(TextColor).init(self.allocator);
        colors.ensureTotalCapacity(chars.items.len) catch u.oom();

        var lines = std.ArrayList(usize).init(self.allocator);
        lines.append(0) catch u.oom(); // first line is always at the buffer start

        break :blk Buffer{
            .file_path = self.allocator.dupe(u8, path) catch u.oom(),
            .bytes = bytes,
            .chars = chars,
            .colors = colors,
            .lines = lines,
        };
    };
    self.open_buffers.append(new_buffer) catch u.oom();
    return self.open_buffers.items.len - 1;
}

fn createNewEditor(self: *Self, buffer: usize) usize {
    const new_editor = Editor{ .buffer = buffer };
    self.open_editors.append(new_editor) catch u.oom();
    return self.open_editors.items.len - 1;
}

fn removeEditor(self: *Self, editor: usize) void {
    // Replace all references to the last element to its new id
    const last = self.open_editors.items.len - 1;
    switch (self.layout) {
        .none => {},
        .single => |e| if (e == last) {
            self.layout.single = editor;
        },
        .side_by_side => |e| {
            if (e.left == last) self.layout.side_by_side.left = editor;
            if (e.right == last) self.layout.side_by_side.right = editor;
            if (e.active == last) self.layout.side_by_side.active = editor;
        },
    }
    // Now we can safely remove
    _ = self.open_editors.swapRemove(editor);
}

pub fn activeEditor(self: *Self) ?*Editor {
    switch (self.layout) {
        .none => return null,
        .single => |e| return &self.open_editors.items[e],
        .side_by_side => |e| return &self.open_editors.items[e.active],
    }
}

pub fn getActiveEditorFilePath(self: *Self) ?[]const u8 {
    const active_editor = self.activeEditor() orelse return null;
    return self.getBuffer(active_editor.buffer).file_path;
}

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
    buffer: usize,

    // Updated every time we draw UI (because that's when we know the layout and therefore size)
    lines_per_screen: usize = 60,
    cols_per_screen: usize = 120,
    cursor: Cursor = Cursor{},
    scroll: Vec2 = Vec2{}, // how many px we have scrolled to the left and to the top
    scroll_animation: ?ScrollAnimation = null,

    pub fn updateAndDraw(self: *Editor, buf: *Buffer, ui: *Ui, rect: Rect, clock_ms: f64, is_active: bool, tmp_allocator: Allocator) void {
        const scale = ui.screen.scale;
        const char_size = ui.screen.font.charSize();
        const margin = Vec2{ .x = 30 * scale, .y = 15 * scale };

        var area = rect.copy();
        var footer_rect = area.splitBottom(char_size.y + 2 * 4 * scale, 0);
        area = area.shrink(margin.x, margin.y, margin.x, 0);

        // Retain info about size - we only know it now
        self.lines_per_screen = @floatToInt(usize, area.h / char_size.y);
        self.cols_per_screen = @floatToInt(usize, area.w / char_size.x);

        // Update cursor line, col and pos
        {
            if (self.cursor.pos >= buf.chars.items.len) self.cursor.pos = buf.chars.items.len -| 1;
            self.cursor.line = for (buf.lines.items) |line_start, line| {
                if (self.cursor.pos < line_start) {
                    break line -| 1;
                }
            } else buf.lines.items.len -| 1;
            self.cursor.col = self.cursor.pos - buf.lines.items[self.cursor.line];
        }

        self.moveViewportToCursor(char_size); // depends on lines_per_screen etc
        self.animateScrolling(clock_ms);

        // Draw the text
        {
            // First and last visible lines
            // TODO: check how it behaves when scale changes
            const line_min = @floatToInt(usize, self.scroll.y / char_size.y) -| 1;
            var line_max = line_min + self.lines_per_screen + 3;
            if (line_max >= buf.lines.items.len) {
                line_max = buf.lines.items.len - 1;
            }
            const col_min = @floatToInt(usize, self.scroll.x / char_size.x);
            const col_max = col_min + self.cols_per_screen;

            // Offset from canonical position (for smooth scrolling)
            const offset = Vec2{
                .x = self.scroll.x - @intToFloat(f32, col_min) * char_size.x,
                .y = self.scroll.y - @intToFloat(f32, line_min) * char_size.y,
            };

            const start_char = buf.lines.items[line_min];
            const end_char = buf.lines.items[line_max];

            const chars = buf.chars.items[start_char..end_char];
            const colors = buf.colors.items[start_char..end_char];
            const top_left = Vec2{ .x = area.x - offset.x, .y = area.y - offset.y };

            // Draw cursor first
            const size = Vec2{ .x = char_size.x, .y = ui.screen.font.letter_height };
            const advance = Vec2{ .x = char_size.x, .y = char_size.y };
            const padding = Vec2{ .x = 0, .y = 4 };
            const cursor_offset = Vec2{
                .x = @intToFloat(f32, self.cursor.col),
                .y = @intToFloat(f32, self.cursor.line -| line_min),
            };
            const highlight_rect = Rect{
                .x = area.x - 4,
                .y = area.y - offset.y + cursor_offset.y * advance.y - padding.y,
                .w = area.w + 8,
                .h = size.y + 2 * padding.y,
            };
            ui.drawSolidRect(highlight_rect, style.colors.BACKGROUND_HIGHLIGHT);
            const cursor_rect = Rect{
                .x = area.x - offset.x + cursor_offset.x * advance.x - padding.x,
                .y = area.y - offset.y + cursor_offset.y * advance.y - padding.y,
                .w = size.x + 2 * padding.x,
                .h = size.y + 2 * padding.y,
            };
            const color = if (is_active) style.colors.CURSOR_ACTIVE else style.colors.CURSOR_INACTIVE;
            ui.drawSolidRect(cursor_rect, color);

            // Then draw text on top
            ui.drawText(chars, colors, top_left, col_min, col_max);
        }

        // Draw footer
        {
            var r = footer_rect;
            const text_y = r.y + 6 * scale;
            ui.drawSolidRect(footer_rect, style.colors.BACKGROUND_BRIGHT);
            ui.drawTopShadow(footer_rect, 5);
            _ = r.splitLeft(margin.x, 0);

            // File path and name
            var name: []const u8 = undefined;
            var path_chunks_iter = u.pathChunksIterator(buf.file_path);
            while (path_chunks_iter.next()) |chunk| name = chunk;

            const path_chars = u.bytesToChars(buf.file_path[0 .. buf.file_path.len - name.len], tmp_allocator) catch unreachable;
            ui.drawLabel(path_chars, .{ .x = r.x, .y = text_y }, style.colors.COMMENT);
            const name_chars = u.bytesToChars(name, tmp_allocator) catch unreachable;
            ui.drawLabel(
                name_chars,
                .{ .x = r.x + @intToFloat(f32, path_chars.len) * char_size.x, .y = text_y },
                if (buf.modified) style.colors.STRING else style.colors.PUNCTUATION,
            );

            // Line:col
            const line_col = std.fmt.allocPrint(tmp_allocator, "{}:{}", .{ self.cursor.line, self.cursor.col }) catch u.oom();
            const line_col_chars = u.bytesToChars(line_col, tmp_allocator) catch unreachable;
            const line_col_rect = r.splitRight(margin.x + @intToFloat(f32, line_col_chars.len) * char_size.x, margin.x);
            ui.drawLabel(line_col_chars, .{ .x = line_col_rect.x, .y = text_y }, style.colors.PUNCTUATION);
        }
    }

    fn typeChar(self: *Editor, char: u.Char, buf: *Buffer) void {
        buf.chars.insert(self.cursor.pos, char) catch u.oom();
        self.cursor.pos += 1;
        self.cursor.col_wanted = null;
        buf.dirty = true;
        buf.modified = true;
    }

    fn keyPress(self: *Editor, buf: *Buffer, key: glfw.Key, mods: glfw.Mods) void {
        const tab_size = 4;

        buf.dirty = true;

        // Things that modify the buffer
        switch (key) {
            .tab => {
                const SPACES = [1]u.Char{' '} ** tab_size;
                const to_next_tabstop = tab_size - self.cursor.col % tab_size;
                buf.chars.insertSlice(self.cursor.pos, SPACES[0..to_next_tabstop]) catch u.oom();
                self.cursor.pos += to_next_tabstop;
                self.cursor.col_wanted = null;
            },
            .enter => {
                var indent = blk: {
                    var indent: usize = 0;
                    var cursor: usize = buf.lines.items[self.cursor.line];
                    while (buf.chars.items[cursor] == ' ') : (cursor += 1) indent += 1;
                    break :blk indent;
                };
                var char_buf: [1024]u.Char = undefined;
                if (mods.control and mods.shift) {
                    // Insert line above
                    std.mem.set(u.Char, char_buf[0..indent], ' ');
                    char_buf[indent] = '\n';
                    self.cursor.pos = buf.lines.items[self.cursor.line];
                    buf.chars.insertSlice(self.cursor.pos, char_buf[0 .. indent + 1]) catch u.oom();
                    self.cursor.pos += indent;
                } else if (mods.control) {
                    // Insert line below
                    std.mem.set(u.Char, char_buf[0..indent], ' ');
                    char_buf[indent] = '\n';
                    self.cursor.pos = buf.lines.items[self.cursor.line + 1];
                    buf.chars.insertSlice(self.cursor.pos, char_buf[0 .. indent + 1]) catch u.oom();
                    self.cursor.pos += indent;
                } else {
                    // Break the line normally
                    const prev_char = buf.chars.items[self.cursor.pos -| 1];
                    const next_char = buf.chars.items[self.cursor.pos]; // TODO: fix when near the end
                    if (prev_char == '{' and next_char == '\n') {
                        indent += tab_size;
                    }
                    char_buf[0] = '\n';
                    std.mem.set(u.Char, char_buf[1 .. indent + 1], ' ');
                    buf.chars.insertSlice(self.cursor.pos, char_buf[0 .. indent + 1]) catch u.oom();
                    self.cursor.pos += 1 + indent;
                    if (prev_char == '{' and next_char == '\n') {
                        // Insert a closing brace
                        indent -= tab_size;
                        buf.chars.insertSlice(self.cursor.pos, char_buf[0 .. indent + 1]) catch u.oom();
                        buf.chars.insert(self.cursor.pos + indent + 1, '}') catch u.oom();
                    }
                }
                self.cursor.col_wanted = null;
            },
            .backspace => if (self.cursor.pos > 0) {
                const to_prev_tabstop = x: {
                    var spaces = self.cursor.col % tab_size;
                    if (spaces == 0 and self.cursor.col > 0) spaces = 4;
                    break :x spaces;
                };
                // Check if we can delete spaces to the previous tabstop
                var all_spaces: bool = false;
                if (to_prev_tabstop > 0) {
                    const pos = self.cursor.pos;
                    all_spaces = for (buf.chars.items[(pos - to_prev_tabstop)..pos]) |char| {
                        if (char != ' ') break false;
                    } else true;
                    if (all_spaces) {
                        // Delete all spaces
                        self.cursor.pos -= to_prev_tabstop;
                        const EMPTY_ARRAY = [_]u.Char{};
                        buf.chars.replaceRange(self.cursor.pos, to_prev_tabstop, EMPTY_ARRAY[0..]) catch unreachable;
                    }
                }
                if (!all_spaces) {
                    // Just delete 1 char
                    self.cursor.pos -= 1;
                    _ = buf.chars.orderedRemove(self.cursor.pos);
                }
                self.cursor.col_wanted = null;
            },
            .delete => if (buf.chars.items.len > 1 and self.cursor.pos < buf.chars.items.len - 1) {
                _ = buf.chars.orderedRemove(self.cursor.pos);
                self.cursor.col_wanted = null;
            },
            else => {
                buf.dirty = false; // nothing needs to be done
            },
        }

        // Things that don't modify the buffer
        switch (key) {
            .left => {
                self.cursor.pos -|= 1;
                self.cursor.col_wanted = null;
            },
            .right => {
                if (self.cursor.pos < buf.chars.items.len - 1) {
                    self.cursor.pos += 1;
                    self.cursor.col_wanted = null;
                }
            },
            .up => {
                const offset: usize = if (mods.control) 5 else 1;
                self.moveCursorToLine(self.cursor.line -| offset, buf);
            },
            .down => {
                const offset: usize = if (mods.control) 5 else 1;
                self.moveCursorToLine(self.cursor.line + offset, buf);
            },
            .page_up => {
                self.moveCursorToLine(self.cursor.line -| self.lines_per_screen, buf);
            },
            .page_down => {
                self.moveCursorToLine(self.cursor.line + self.lines_per_screen, buf);
            },
            .home => {
                self.cursor.pos = buf.lines.items[self.cursor.line];
                self.cursor.col_wanted = null;
            },
            .end => {
                self.cursor.pos = buf.lines.items[self.cursor.line + 1] - 1;
                self.cursor.col_wanted = std.math.maxInt(usize);
            },
            else => {},
        }

        // Need to make sure there are no early returns from this function
        if (buf.dirty) buf.modified = true;

        if (mods.control and key == .s and buf.modified) buf.saveToDisk() catch unreachable; // TODO: handle
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

    fn moveCursorToLine(self: *Editor, line: usize, buf: *Buffer) void {
        const target_line = if (line > buf.lines.items.len - 2)
            buf.lines.items.len - 2
        else
            line;
        const chars_on_target_line = buf.lines.items[target_line + 1] - buf.lines.items[target_line] -| 1;
        const wanted_pos = if (self.cursor.col_wanted) |wanted|
            wanted
        else
            self.cursor.col;
        const new_line_pos = std.math.min(wanted_pos, chars_on_target_line);
        self.cursor.col_wanted = if (new_line_pos < wanted_pos) wanted_pos else null; // reset or remember wanted position
        self.cursor.pos = buf.lines.items[target_line] + new_line_pos;
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
};

pub const Buffer = struct {
    file_path: []const u8,
    bytes: std.ArrayList(u8),
    chars: std.ArrayList(u.Char),
    colors: std.ArrayList(TextColor),
    lines: std.ArrayList(usize),

    dirty: bool = true, // needs syncing internal structures
    modified: bool = false, // hasn't been saved to disk

    fn saveToDisk(self: *Buffer) !void {
        if (!self.modified) return;
        self.recalculateBytes();
        if (self.bytes.items[self.bytes.items.len -| 1] != '\n') self.bytes.append('\n') catch u.oom();
        try u.writeEntireFile(self.file_path, self.bytes.items);
        self.modified = false;
    }

    fn syncInternalData(self: *Buffer) void {
        // Recalculate lines
        {
            self.lines.shrinkRetainingCapacity(1);
            for (self.chars.items) |char, i| {
                if (char == '\n') {
                    self.lines.append(i + 1) catch u.oom();
                }
            }
            if (self.chars.items[self.chars.items.len -| 1] != '\n') {
                self.lines.append(self.chars.items.len) catch u.oom();
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
            const source_bytes = self.bytes.items[0 .. self.bytes.items.len - 1 :0];
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

            _ = self.bytes.pop(); // un-null-terminate
        }

        self.dirty = false;
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
};
