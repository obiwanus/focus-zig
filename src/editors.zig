const std = @import("std");
const glfw = @import("glfw");

const focus = @import("focus.zig");
const u = focus.utils;
const style = focus.style;

const Allocator = std.mem.Allocator;
const Vec2 = u.Vec2;
const Rect = u.Rect;
const Buffer = focus.Buffer;
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
last_buffer_update_ms: f64 = 0,

const Editors = @This();
const BUFFER_REFRESH_TIMEOUT_MS = 500;

pub fn init(allocator: Allocator) Editors {
    return .{
        .allocator = allocator,
        .open_buffers = std.ArrayList(Buffer).initCapacity(allocator, 10) catch u.oom(),
        .open_editors = std.ArrayList(Editor).initCapacity(allocator, 10) catch u.oom(),
        .layout = .none,
    };
}

pub fn deinit(self: Editors) void {
    for (self.open_buffers.items) |buf| buf.deinit(self.allocator);
    for (self.open_editors.items) |ed| ed.cursor.clipboard.deinit();
}

pub fn updateAndDrawAll(self: *Editors, ui: *Ui, clock_ms: f64, tmp_allocator: Allocator) void {
    // Reload buffers from disk and check for conflicts
    if (clock_ms - self.last_buffer_update_ms > BUFFER_REFRESH_TIMEOUT_MS) {
        for (self.open_buffers.items) |*buf| buf.refreshFromDisk(self.allocator);
        self.last_buffer_update_ms = clock_ms;
    }

    // Always try to update all open buffers
    for (self.open_buffers.items) |*buf, buf_id| {
        if (buf.dirty) {
            buf.syncInternalData();

            // Remove selection on all cursors
            for (self.open_editors.items) |*ed| {
                if (ed.buffer == buf_id and !ed.cursor.keep_selection) {
                    ed.cursor.selection_start = null;
                }
                ed.cursor.keep_selection = false;
            }
        }
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

pub fn charEntered(self: *Editors, char: u.Char) void {
    if (self.activeEditor()) |editor| editor.typeChar(char, self.getBuffer(editor.buffer));
}

pub fn keyPress(self: *Editors, key: glfw.Key, mods: glfw.Mods) void {
    if (mods.control and mods.alt) {
        switch (key) {
            .left => {
                self.switchToLeft();
            },
            .right => {
                self.switchToRight();
            },
            .p => if (self.activeEditor()) |editor| {
                // Duplicate current editor on the other side
                if (self.getBuffer(editor.buffer).file) |file| self.openFile(file.path, true);
            },
            else => {},
        }
    } else if (mods.control and key == .w) {
        if (mods.shift) {
            self.closeOtherPane();
        } else {
            self.closeActivePane();
        }
    } else if (self.activeEditor()) |editor| {
        editor.keyPress(self.getBuffer(editor.buffer), key, mods);
    }
}

pub fn haveActiveScrollAnimation(self: *Editors) bool {
    if (self.activeEditor()) |editor| {
        return editor.scroll_animation != null;
    }
    return false;
}

pub fn activeEditor(self: *Editors) ?*Editor {
    switch (self.layout) {
        .none => return null,
        .single => |e| return &self.open_editors.items[e],
        .side_by_side => |e| return &self.open_editors.items[e.active],
    }
}

pub fn getActiveEditorFilePath(self: *Editors) ?[]const u8 {
    const active_editor = self.activeEditor() orelse return null;
    const file = self.getBuffer(active_editor.buffer).file orelse return "[unsaved buffer]";
    return file.path;
}

fn printState(self: *Editors) void {
    u.print("Buffers: ", .{});
    for (self.open_buffers.items) |buffer, i| {
        u.print("{}:{s} |", .{ i, buffer.file_path });
    }
    u.println("", .{});

    u.print("Editors: ", .{});
    for (self.open_editors.items) |editor, i| {
        u.print("{}:{} |", .{ i, editor.buffer });
    }
    u.println("", .{});

    u.print("Layout: ", .{});
    switch (self.layout) {
        .none => u.println("none", .{}),
        .single => |e| u.println("single - {}", .{e}),
        .side_by_side => |e| u.println("side by side. left = {}, right = {}, active = {}", .{ e.left, e.right, e.active }),
    }
}

pub fn openFile(self: *Editors, path: []const u8, on_the_side: bool) void {
    const buffer = self.findOpenBuffer(path) orelse self.openNewBuffer(path);
    switch (self.layout) {
        .none => {
            // Create a new editor and switch to single layout
            const editor = self.findOrCreateNewEditor(buffer);
            self.layout = .{ .single = editor };
        },
        .single => |e| {
            var editor = self.findOrCreateNewEditor(buffer);
            if (on_the_side) {
                // Open new editor on the right
                if (editor == e) editor = self.findAnotherEditorForBuffer(buffer, e) orelse self.createNewEditor(buffer);
                self.layout = .{ .side_by_side = .{ .left = e, .right = editor, .active = editor } };
            } else {
                // Replace the current editor
                self.layout = .{ .single = editor };
            }
        },
        .side_by_side => |e| {
            const target_is_left = (e.left == e.active and !on_the_side) or (e.right == e.active and on_the_side);
            const target = if (target_is_left) e.left else e.right;
            const other = if (target_is_left) e.right else e.left;

            // If the target editor is already for this buffer, just switch
            if (self.open_editors.items[target].buffer == buffer) {
                self.layout.side_by_side.active = target;
                return;
            }

            // Otherwise, replace target with a new editor
            var editor: usize = undefined;
            if (self.open_editors.items[other].buffer == buffer) {
                // Trying to open 2 editors for the same buffer side by side
                editor = self.findAnotherEditorForBuffer(buffer, other) orelse self.createNewEditor(buffer);
            } else {
                editor = self.findOrCreateNewEditor(buffer);
            }
            if (target_is_left) {
                self.layout.side_by_side.left = editor;
            } else {
                self.layout.side_by_side.right = editor;
            }
            self.layout.side_by_side.active = editor;
        },
    }
}

fn findEditorForBuffer(self: Editors, buffer: usize) ?usize {
    for (self.open_editors.items) |e, i| if (e.buffer == buffer) return i;
    return null;
}

fn findAnotherEditorForBuffer(self: Editors, buffer: usize, editor: usize) ?usize {
    for (self.open_editors.items) |e, i| if (e.buffer == buffer and i != editor) return i;
    return null;
}

fn findOrCreateNewEditor(self: *Editors, buffer: usize) usize {
    return self.findEditorForBuffer(buffer) orelse self.createNewEditor(buffer);
}

fn switchToLeft(self: *Editors) void {
    if (self.layout == .side_by_side) self.layout.side_by_side.active = self.layout.side_by_side.left;
}

fn switchToRight(self: *Editors) void {
    if (self.layout == .side_by_side) self.layout.side_by_side.active = self.layout.side_by_side.right;
}

fn closeActivePane(self: *Editors) void {
    switch (self.layout) {
        .none => {},
        .single => |_| self.layout = .none,
        .side_by_side => |e| {
            const other = if (e.active == e.left) e.right else e.left;
            self.layout = .{ .single = other };
        },
    }
}

fn closeOtherPane(self: *Editors) void {
    switch (self.layout) {
        .none => {},
        .single => |_| self.layout = .none,
        .side_by_side => |e| {
            const active = if (e.active == e.left) e.left else e.right;
            self.layout = .{ .single = active };
        },
    }
}

fn getBuffer(self: *Editors, buffer: usize) *Buffer {
    return &self.open_buffers.items[buffer];
}

fn findOpenBuffer(self: Editors, path: []const u8) ?usize {
    for (self.open_buffers.items) |buffer, i| {
        if (buffer.file) |file| {
            if (std.mem.eql(u8, path, file.path)) return i;
        }
    }
    return null;
}

fn openNewBuffer(self: *Editors, path: []const u8) usize {
    var buffer = Buffer.init(self.allocator);
    buffer.loadFile(self.allocator.dupe(u8, path) catch u.oom(), self.allocator);

    self.open_buffers.append(buffer) catch u.oom();
    return self.open_buffers.items.len - 1;
}

fn createNewEditor(self: *Editors, buffer: usize) usize {
    const new_editor = Editor{
        .buffer = buffer,
        .cursor = Cursor{ .clipboard = std.ArrayList(u.Char).init(self.allocator) },
    };
    self.open_editors.append(new_editor) catch u.oom();
    return self.open_editors.items.len - 1;
}

const Cursor = struct {
    pos: usize = 0,
    line: usize = 0, // from the beginning of buffer
    col: usize = 0, // actual column
    col_wanted: ?usize = null, // where the cursor wants to be
    selection_start: ?usize = null,
    keep_selection: bool = false,
    clipboard: std.ArrayList(u.Char),

    fn getSelectionRange(self: Cursor) ?Buffer.Range {
        const selection_start = self.selection_start orelse return null;
        if (self.pos == selection_start) return null;
        return Buffer.Range{
            .start = u.min(selection_start, self.pos),
            .end = u.max(selection_start, self.pos),
        };
    }

    // Returns the range that covers all selected lines
    // (or just the line on which the cursor is if nothing is selected)
    fn getRangeOnWholeLines(self: Cursor, buf: *const Buffer) Buffer.Range {
        var first_line: usize = self.line;
        var last_line: usize = self.line;
        if (self.getSelectionRange()) |selection| {
            first_line = buf.getLineCol(selection.start).line;
            last_line = buf.getLineCol(selection.end).line;
        }
        return .{
            .start = buf.lines.items[first_line].start,
            .end = buf.lines.items[last_line].end,
        };
    }

    fn selectWord(self: Cursor, buf: *const Buffer) ?Buffer.Range {
        // Search within the line boundaries
        const line = buf.lines.items[self.line];

        const start = if (self.pos < line.end and u.isWordChar(buf.chars.items[self.pos]))
            self.pos
        else if (self.pos -| 1 >= line.start and self.pos -| 1 < line.end and u.isWordChar(buf.chars.items[self.pos -| 1]))
            self.pos -| 1
        else
            return null;

        var word_start = start;
        word_start = while (word_start >= line.start) : (word_start -= 1) {
            const is_part_of_word = u.isWordChar(buf.chars.items[word_start]);
            if (!is_part_of_word) break word_start + 1;
            if (word_start == 0 and is_part_of_word) break word_start;
        } else word_start + 1;

        var word_end = start + 1;
        while (word_end < line.end and u.isWordChar(buf.chars.items[word_end])) : (word_end += 1) {}

        return Buffer.Range{ .start = word_start, .end = word_end };
    }

    fn copyToClipboard(self: *Cursor, chars: []const u.Char) void {
        self.clipboard.clearRetainingCapacity();
        self.clipboard.appendSlice(chars) catch u.oom();
    }
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
            if (self.cursor.pos > buf.numChars()) self.cursor.pos = buf.numChars();
            const cursor = buf.getLineCol(self.cursor.pos);
            self.cursor.line = cursor.line;
            self.cursor.col = cursor.col;
        }

        self.moveViewportToCursor(char_size); // depends on lines_per_screen etc
        self.animateScrolling(clock_ms);

        // Draw the text
        {
            // First and last visible lines
            // TODO: check how it behaves when scale changes
            const line_min = @floatToInt(usize, self.scroll.y / char_size.y) -| 1;
            const line_max = line_min + self.lines_per_screen + 3;
            const col_min = @floatToInt(usize, self.scroll.x / char_size.x);
            const col_max = col_min + self.cols_per_screen;

            const start_char = buf.getLine(line_min).start;
            const end_char = buf.getLine(line_max).end;
            const chars = buf.chars.items[start_char..end_char];
            const colors = buf.colors.items[start_char..end_char];

            // Offset from canonical position (for smooth scrolling)
            const offset = Vec2{
                .x = self.scroll.x - @intToFloat(f32, col_min) * char_size.x,
                .y = self.scroll.y - @intToFloat(f32, line_min) * char_size.y,
            };

            const top_left = Vec2{ .x = area.x - offset.x, .y = area.y - offset.y };
            const cursor_line = self.cursor.line -| line_min;
            const cursor_col = self.cursor.col -| col_min;
            const adjust_y = 2 * scale;

            // Highlight line with cursor
            {
                const highlight_rect = Rect{
                    .x = rect.x,
                    .y = top_left.y + @intToFloat(f32, cursor_line) * char_size.y - adjust_y,
                    .w = rect.w,
                    .h = char_size.y,
                };
                ui.drawSolidRect(highlight_rect, style.colors.BACKGROUND_HIGHLIGHT);
            }

            // First draw selections
            if (self.cursor.getSelectionRange()) |s| {
                const start = buf.getLineCol(s.start);
                const end = buf.getLineCol(s.end);

                const sel_color = if (is_active) style.colors.SELECTION_ACTIVE else style.colors.SELECTION_INACTIVE;

                var line: usize = start.line;
                while (line <= end.line) : (line += 1) {
                    const start_col = if (line == start.line) start.col -| col_min else 0;
                    var end_col = if (line == end.line) end.col else buf.getLine(line).len();
                    if (end_col > col_max + 1) end_col = col_max + 1;
                    end_col -|= col_min;

                    const r = Rect{
                        .x = top_left.x + @intToFloat(f32, start_col) * char_size.x,
                        .y = top_left.y + @intToFloat(f32, line -| line_min) * char_size.y - adjust_y,
                        .w = @intToFloat(f32, end_col - start_col) * char_size.x,
                        .h = char_size.y,
                    };
                    ui.drawSolidRect(r, sel_color);
                }
            }

            // Then draw cursor
            const cursor_rect = Rect{
                .x = top_left.x + @intToFloat(f32, cursor_col) * char_size.x,
                .y = top_left.y + @intToFloat(f32, cursor_line) * char_size.y - adjust_y,
                .w = char_size.x,
                .h = char_size.y,
            };
            const cursor_color = if (is_active) style.colors.CURSOR_ACTIVE else style.colors.CURSOR_INACTIVE;
            ui.drawSolidRect(cursor_rect, cursor_color);

            // Then draw text on top
            ui.drawText(chars, colors, top_left, col_min, col_max);

            // If some text on the left is invisible, add shadow
            if (col_min > 0) ui.drawRightShadow(Rect{ .x = area.x - 5, .y = area.y - margin.y, .w = 1, .h = area.h + margin.y }, 7 * scale);

            // Draw shadow on top if scrolled down
            if (self.scroll.y > 0) ui.drawBottomShadow(Rect{ .x = rect.x, .y = rect.y - 1, .w = rect.w, .h = 1 }, 7 * scale);
        }

        // Draw footer
        {
            var r = footer_rect;
            const text_y = r.y + 6 * scale;
            ui.drawSolidRect(footer_rect, style.colors.BACKGROUND_BRIGHT);
            ui.drawTopShadow(footer_rect, 5);
            _ = r.splitLeft(margin.x, 0);

            // File path and name
            if (buf.file) |file| {
                var name: []const u8 = undefined;
                var path_chunks_iter = u.pathChunksIterator(file.path);
                while (path_chunks_iter.next()) |chunk| name = chunk;

                const path_chars = u.bytesToChars(file.path[0 .. file.path.len - name.len], tmp_allocator) catch unreachable;
                ui.drawLabel(path_chars, .{ .x = r.x, .y = text_y }, style.colors.COMMENT);

                const name_chars = u.bytesToChars(name, tmp_allocator) catch unreachable;
                const name_color = if (buf.deleted or buf.modified_on_disk)
                    style.colors.ERROR
                else if (buf.modified)
                    style.colors.WARNING
                else
                    style.colors.PUNCTUATION;
                const name_pos = Vec2{ .x = r.x + @intToFloat(f32, path_chars.len) * char_size.x, .y = text_y };
                ui.drawLabel(name_chars, name_pos, name_color);

                if (buf.deleted) {
                    // Strike through
                    const strikethrough_rect = Rect{
                        .x = name_pos.x,
                        .y = name_pos.y + char_size.y / 2 - 2 * scale,
                        .w = char_size.x * @intToFloat(f32, name_chars.len),
                        .h = 2,
                    };
                    ui.drawSolidRect(strikethrough_rect, style.colors.ERROR);
                }
            }

            // Line:col
            const line_col = std.fmt.allocPrint(tmp_allocator, "{}:{}", .{ self.cursor.line + 1, self.cursor.col + 1 }) catch u.oom();
            const line_col_chars = u.bytesToChars(line_col, tmp_allocator) catch unreachable;
            const line_col_rect = r.splitRight(margin.x + @intToFloat(f32, line_col_chars.len) * char_size.x, margin.x);
            ui.drawLabel(line_col_chars, .{ .x = line_col_rect.x, .y = text_y }, style.colors.PUNCTUATION);
        }
    }

    fn typeChar(self: *Editor, char: u.Char, buf: *Buffer) void {
        if (self.cursor.getSelectionRange()) |selection| {
            buf.chars.replaceRange(selection.start, selection.len(), &[_]u.Char{char}) catch u.oom();
            self.cursor.pos = selection.start + 1;
        } else {
            const last_char = buf.numChars() -| 1;
            if (self.cursor.pos <= last_char) {
                buf.chars.insert(self.cursor.pos, char) catch u.oom();
            } else {
                buf.chars.append(char) catch u.oom();
            }
            self.cursor.pos += 1;
        }
        self.cursor.col_wanted = null;
        buf.dirty = true;
        buf.modified = true;
    }

    fn keyPress(self: *Editor, buf: *Buffer, key: glfw.Key, mods: glfw.Mods) void {
        const TAB_SIZE = 4;

        buf.dirty = true;

        // Insertions/deletions of sorts
        switch (key) {
            .tab => {
                const SPACES = [1]u.Char{' '} ** TAB_SIZE;

                if (self.cursor.getSelectionRange()) |selection| {
                    const first_line = buf.getLineCol(selection.start).line;
                    const last_line = buf.getLineCol(selection.end).line;
                    const lines = buf.lines.items[first_line .. last_line + 1];

                    if (!mods.shift) {
                        // Indent selected block
                        var spaces_inserted: usize = 0;
                        for (lines) |line| {
                            buf.chars.insertSlice(line.start + spaces_inserted, &SPACES) catch u.oom();
                            spaces_inserted += TAB_SIZE;
                        }
                        // Adjust selection
                        if (self.cursor.pos == selection.start) {
                            self.cursor.pos += TAB_SIZE;
                            self.cursor.selection_start.? += spaces_inserted;
                        } else {
                            self.cursor.selection_start.? += TAB_SIZE;
                            self.cursor.pos += spaces_inserted;
                        }
                    } else {
                        // Un-indent selected block
                        var sel_start_adjust: usize = 0;
                        var removed: usize = 0;
                        for (lines) |line, i| {
                            const spaces_to_remove = u.min(TAB_SIZE, line.lenWhitespace());
                            buf.chars.replaceRange(line.start - removed, spaces_to_remove, &[_]u.Char{}) catch unreachable;
                            removed += spaces_to_remove;
                            if (i == 0) sel_start_adjust = u.min(selection.start - line.start, spaces_to_remove);
                        }
                        // Adjust selection
                        if (self.cursor.pos == selection.start) {
                            self.cursor.pos -= sel_start_adjust;
                            self.cursor.selection_start.? -|= removed;
                        } else {
                            self.cursor.selection_start.? -|= sel_start_adjust;
                            self.cursor.pos -|= removed;
                        }
                    }

                    self.cursor.keep_selection = true;
                } else {
                    // Insert spaces
                    if (!mods.shift) {
                        const to_next_tabstop = TAB_SIZE - self.cursor.col % TAB_SIZE;
                        if (self.cursor.pos >= buf.numChars()) {
                            buf.chars.appendSlice(SPACES[0..to_next_tabstop]) catch u.oom();
                        } else {
                            buf.chars.insertSlice(self.cursor.pos, SPACES[0..to_next_tabstop]) catch u.oom();
                        }
                        self.cursor.pos += to_next_tabstop;
                    } else {
                        // Un-indent current line
                        const line = buf.getLine(self.cursor.line);
                        const spaces_to_remove = u.min(TAB_SIZE, line.lenWhitespace());
                        const cursor_adjust = u.min(self.cursor.pos - line.start, spaces_to_remove);
                        buf.chars.replaceRange(line.start, spaces_to_remove, &[_]u.Char{}) catch unreachable;
                        self.cursor.pos -|= cursor_adjust;
                    }
                }

                self.cursor.col_wanted = null;
            },
            .enter => {
                const line = buf.getLine(self.cursor.line);
                var indent = blk: {
                    var indent: usize = 0;
                    var cursor = line.start;
                    while (cursor < buf.numChars() and cursor < self.cursor.pos and buf.chars.items[cursor] == ' ') : (cursor += 1) indent += 1;
                    break :blk indent;
                };
                var char_buf: [1024]u.Char = undefined;
                if (mods.control and mods.shift) {
                    // Insert line above
                    std.mem.set(u.Char, char_buf[0..indent], ' ');
                    char_buf[indent] = '\n';
                    self.cursor.pos = line.start;
                    buf.insertSlice(self.cursor.pos, char_buf[0 .. indent + 1]);
                    self.cursor.pos += indent;
                } else if (mods.control) {
                    // Insert line below
                    std.mem.set(u.Char, char_buf[0..indent], ' ');
                    char_buf[indent] = '\n';
                    self.cursor.pos = buf.getLine(self.cursor.line + 1).start;
                    buf.insertSlice(self.cursor.pos, char_buf[0 .. indent + 1]);
                } else {
                    // Break the line normally
                    const prev_char = if (buf.numChars() > 0) buf.chars.items[self.cursor.pos -| 1] else null;
                    const next_char = if (self.cursor.pos < buf.numChars()) buf.chars.items[self.cursor.pos] else null;

                    const opening_block = prev_char != null and prev_char.? == '{' and (next_char == null or next_char != null and next_char.? == '\n');
                    if (opening_block) {
                        indent += TAB_SIZE;
                    }

                    char_buf[0] = '\n';
                    std.mem.set(u.Char, char_buf[1 .. indent + 1], ' ');
                    if (self.cursor.pos >= buf.numChars()) {
                        buf.chars.appendSlice(char_buf[0 .. indent + 1]) catch u.oom();
                    } else {
                        buf.chars.insertSlice(self.cursor.pos, char_buf[0 .. indent + 1]) catch u.oom();
                    }
                    self.cursor.pos += 1 + indent;

                    if (opening_block) {
                        // Insert a closing brace
                        indent -= TAB_SIZE;
                        buf.insertSlice(self.cursor.pos, char_buf[0 .. indent + 1]);
                        buf.insertChar(self.cursor.pos + indent + 1, '}');
                    }
                }
                self.cursor.col_wanted = null;
            },
            .backspace => {
                if (self.cursor.getSelectionRange()) |selection| {
                    buf.chars.replaceRange(selection.start, selection.len(), &[_]u.Char{}) catch unreachable;
                    self.cursor.pos = selection.start;
                } else if (self.cursor.pos > 0) {
                    const to_prev_tabstop = x: {
                        var spaces = self.cursor.col % TAB_SIZE;
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
                            buf.chars.replaceRange(self.cursor.pos, to_prev_tabstop, &[_]u.Char{}) catch unreachable;
                        }
                    }
                    if (!all_spaces) {
                        // Just delete 1 char
                        self.cursor.pos -= 1;
                        _ = buf.chars.orderedRemove(self.cursor.pos);
                    }
                }
                self.cursor.col_wanted = null;
            },
            .delete => {
                if (self.cursor.getSelectionRange()) |selection| {
                    buf.chars.replaceRange(selection.start, selection.len(), &[_]u.Char{}) catch unreachable;
                    self.cursor.pos = selection.start;
                } else if (buf.numChars() >= 1 and self.cursor.pos < buf.numChars()) {
                    _ = buf.chars.orderedRemove(self.cursor.pos);
                }
                self.cursor.col_wanted = null;
            },
            else => {
                buf.dirty = false; // nothing needs to be done
            },
        }

        var old_pos = self.cursor.pos;

        // Cursor movements
        switch (key) {
            .left => {
                self.cursor.pos -|= 1;
                self.cursor.col_wanted = null;
            },
            .right => {
                if (self.cursor.pos < buf.numChars()) {
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
                const line = buf.getLine(self.cursor.line);
                if (self.cursor.pos != line.text_start) {
                    self.cursor.pos = line.text_start;
                } else {
                    self.cursor.pos = line.start;
                }
                self.cursor.col_wanted = null;
            },
            .end => {
                self.cursor.pos = buf.getLine(self.cursor.line).end;
                self.cursor.col_wanted = null;
            },
            else => {},
        }
        if (old_pos != self.cursor.pos) {
            if (mods.shift) {
                if (self.cursor.selection_start == null) {
                    // Start new selection
                    self.cursor.selection_start = old_pos;
                }
            } else {
                self.cursor.selection_start = null;
            }
        }

        if (u.modsOnlyCtrl(mods)) {
            old_pos = self.cursor.pos;
            switch (key) {
                .a => {
                    // Select all
                    self.cursor.selection_start = 0;
                    self.cursor.pos = buf.numChars();
                },
                .c, .x => {
                    // Copy / cut
                    if (self.cursor.getSelectionRange()) |s| {
                        self.cursor.copyToClipboard(buf.chars.items[s.start..s.end]);
                        if (key == .x) {
                            buf.chars.replaceRange(s.start, s.end - s.start, &[_]u.Char{}) catch unreachable;
                            self.cursor.pos = s.start;
                            buf.dirty = true;
                        }
                    }
                },
                .v => {
                    // Paste
                    if (self.cursor.clipboard.items.len > 0) {
                        const paste_data = self.cursor.clipboard.items;
                        var paste_start: usize = undefined;
                        if (self.cursor.getSelectionRange()) |s| {
                            buf.chars.replaceRange(s.start, s.end - s.start, paste_data) catch u.oom();
                            paste_start = s.start;
                        } else if (self.cursor.pos >= buf.numChars()) {
                            paste_start = buf.numChars();
                            buf.chars.appendSlice(paste_data) catch u.oom();
                        } else {
                            buf.chars.insertSlice(self.cursor.pos, paste_data) catch u.oom();
                            paste_start = self.cursor.pos;
                        }
                        self.cursor.pos = paste_start + paste_data.len;
                        buf.dirty = true;
                    }
                },
                .l => {
                    // Select line
                    const range = self.cursor.getRangeOnWholeLines(buf);
                    self.cursor.selection_start = range.start;
                    self.cursor.pos = range.end;
                },
                .d => {
                    // TODO:
                    // - When single cursor has a selection, create more cursors
                    // - When more than one cursor:
                    //     - select words under each
                    //     - do nothing else
                    if (self.cursor.selectWord(buf)) |range| {
                        self.cursor.selection_start = range.start;
                        self.cursor.pos = range.end;
                    }
                },
                else => {},
            }
            if (self.cursor.pos != old_pos) self.cursor.col_wanted = null;
        }

        if (mods.control and mods.shift and key == .d) {
            // Duplicate lines
            var range = self.cursor.getRangeOnWholeLines(buf);

            // Make sure we won't reallocate when copying
            buf.chars.ensureTotalCapacity(buf.numChars() + range.len()) catch u.oom();
            buf.insertSlice(range.start, buf.chars.items[range.start..range.end]);
            buf.insertChar(range.end, '\n');
            range.end += 1;

            // Move selection forward
            self.cursor.pos += range.len();
            if (self.cursor.selection_start != null) self.cursor.selection_start.? += range.len();
            self.cursor.keep_selection = true;

            buf.dirty = true;
        }

        if (buf.dirty) buf.modified = true;

        // Save to disk
        if (mods.control and key == .s and buf.file != null) {
            // Strip trailing spaces
            {
                var i: usize = 0;
                var start: ?usize = null;
                while (i < buf.numChars()) : (i += 1) {
                    const char = buf.chars.items[i];
                    if (char == ' ') {
                        if (start == null) start = i;
                    } else {
                        if (char == '\n' and start != null) {
                            const range = Buffer.Range{ .start = start.?, .end = i };
                            buf.removeRange(range);
                            i -|= range.len();
                        }
                        start = null;
                        buf.dirty = true;
                    }
                }
                if (start) |s| buf.removeRange(.{ .start = s, .end = buf.numChars() });

                // TODO:
                // buf.recalculateLines();
                // self.cursor.pos = buf.getPosFromLineCol(self.cursor.line, self.cursor.col);
            }
            buf.saveToDisk() catch unreachable; // TODO: handle
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

    fn moveCursorToLine(self: *Editor, line: usize, buf: *Buffer) void {
        const target_line = buf.getLine(line);
        const wanted_pos = self.cursor.col_wanted orelse self.cursor.col;
        const new_line_pos = u.min(wanted_pos, target_line.len());
        self.cursor.col_wanted = if (new_line_pos < wanted_pos) wanted_pos else null; // reset or remember wanted position
        self.cursor.pos = target_line.start + new_line_pos;
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
