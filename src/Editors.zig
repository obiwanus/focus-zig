const std = @import("std");
const glfw = @import("glfw");

const focus = @import("focus.zig");
const u = focus.utils;
const style = focus.style;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Char = u.Char;
const Vec2 = u.Vec2;
const Rect = u.Rect;
const LineCol = u.LineCol;
const Buffer = focus.Buffer;
const Font = focus.fonts.Font;
const TextColor = focus.style.TextColor;
const Ui = focus.ui.Ui;

const SCROLL_PADDING = 4;

allocator: Allocator,
open_buffers: ArrayList(Buffer),
open_editors: ArrayList(Editor),
layout: union(enum) {
    none,
    single: usize,
    side_by_side: struct {
        left: usize,
        right: usize,
        active: usize,
    },
},
last_update_from_disk_ms: f64 = 0,
focused: bool = true,

const Editors = @This();
const BUFFER_REFRESH_TIMEOUT_MS = 500;
const UNDO_GROUP_TIMEOUT_MS = 200;

pub fn init(allocator: Allocator) Editors {
    return .{
        .allocator = allocator,
        .open_buffers = ArrayList(Buffer).initCapacity(allocator, 10) catch u.oom(),
        .open_editors = ArrayList(Editor).initCapacity(allocator, 10) catch u.oom(),
        .layout = .none,
    };
}

pub fn deinit(self: Editors) void {
    for (self.open_buffers.items) |buf| buf.deinit(self.allocator);
    for (self.open_editors.items) |ed| ed.deinit();
}

pub fn updateAndDrawAll(self: *Editors, ui: *Ui, clock_ms: f64, tmp_allocator: Allocator) bool {
    // Reload buffers from disk and check for conflicts
    if (clock_ms - self.last_update_from_disk_ms > BUFFER_REFRESH_TIMEOUT_MS) {
        for (self.open_buffers.items) |*buf| buf.refreshFromDisk(self.allocator);
        self.last_update_from_disk_ms = clock_ms;
    }

    // Always try to update all open buffers
    for (self.open_buffers.items) |*buf, buf_id| {
        if (clock_ms - buf.last_edit_ms >= UNDO_GROUP_TIMEOUT_MS) buf.new_edit_group_required = true;
        if (buf.dirty) {
            buf.syncInternalData();
            buf.dirty = false;

            // Remove selection on all cursors
            for (self.open_editors.items) |*ed| {
                if (ed.buffer == buf_id and !ed.keep_selection) {
                    for (ed.cursors.items) |*cursor| cursor.selection_start = null;
                }
                ed.keep_selection = false;
            }
        }
    }

    // Update selected text occurrences
    for (self.open_editors.items) |*ed| {
        const buf = self.getBuffer(ed.buffer);
        const selected_text = ed.selectedText(buf);
        if (selected_text != null and ed.highlights.items.len == 0) {
            ed.updateHighlights(buf, selected_text.?);
        }
    }

    // The editors always take the entire screen area
    var area = ui.screen.getRect();

    // Lay out the editors in rects and draw each
    var need_redraw = false;
    switch (self.layout) {
        .none => {}, // nothing to draw
        .single => |e| {
            var editor = &self.open_editors.items[e];
            need_redraw = editor.updateAndDraw(self.getBuffer(editor.buffer), ui, area, self.focused, clock_ms, tmp_allocator);
        },
        .side_by_side => |e| {
            const left_rect = area.splitLeft(area.w / 2 - 1, 1);
            const right_rect = area;

            var e1 = &self.open_editors.items[e.left];
            var e2 = &self.open_editors.items[e.right];
            var redraw1 = e1.updateAndDraw(self.getBuffer(e1.buffer), ui, left_rect, self.focused and e.active == e.left, clock_ms, tmp_allocator);
            var redraw2 = e2.updateAndDraw(self.getBuffer(e2.buffer), ui, right_rect, self.focused and e.active == e.right, clock_ms, tmp_allocator);
            need_redraw = redraw1 or redraw2;

            const splitter_rect = Rect{ .x = area.x - 2, .y = area.y, .w = 2, .h = area.h };
            ui.drawSolidRect(splitter_rect, style.colors.BACKGROUND_BRIGHT);
        },
    }

    return need_redraw;
}

pub fn charEntered(self: *Editors, char: Char, clock_ms: f64) void {
    if (self.activeEditor()) |editor| editor.typeChar(char, self.getBuffer(editor.buffer), clock_ms);
}

pub fn keyPress(self: *Editors, key: glfw.Key, mods: glfw.Mods, tmp_allocator: Allocator, clock_ms: f64) void {
    if (u.modsCmd(mods) and mods.alt) {
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
    } else if (u.modsOnlyCmd(mods) and key == .w) {
        if (mods.shift) {
            self.closeOtherPane();
        } else {
            self.closeActivePane();
        }
    } else if (self.activeEditor()) |editor| {
        editor.keyPress(self.getBuffer(editor.buffer), key, mods, tmp_allocator, clock_ms);
    }
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

fn copyToClipboard(chars: []const Char, tmp_allocator: Allocator) void {
    const bytes = u.charsToBytes(chars, tmp_allocator) catch return;
    glfw.setClipboardString(bytes.ptr) catch unreachable;
}

/// Returns a temporarily allocated string, so don't store it anywhere
fn getClipboardString(tmp_allocator: Allocator) []const Char {
    const bytes = glfw.getClipboardString() catch unreachable;
    return u.bytesToChars(bytes, tmp_allocator) catch unreachable;
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
    const new_editor = Editor.init(buffer, self.allocator);
    self.open_editors.append(new_editor) catch u.oom();
    return self.open_editors.items.len - 1;
}

pub const Cursor = struct {
    pos: usize = 0,
    line: usize = 0, // from the beginning of buffer
    col: usize = 0, // actual column
    col_wanted: ?usize = null, // where the cursor wants to be
    selection_start: ?usize = null,
    clipboard: ArrayList(Char) = undefined,

    fn init(allocator: Allocator) Cursor {
        return .{ .clipboard = ArrayList(Char).init(allocator) };
    }

    fn deinit(self: Cursor) void {
        self.clipboard.deinit();
    }

    fn getSelectionRange(self: Cursor) ?Buffer.Range {
        const selection_start = self.selection_start orelse return null;
        if (self.pos == selection_start) return null;
        return Buffer.Range{
            .start = u.min(selection_start, self.pos),
            .end = u.max(selection_start, self.pos),
        };
    }

    fn hasSelection(self: Cursor) bool {
        return self.selection_start != null;
    }

    fn range(self: Cursor) Buffer.Range {
        return self.getSelectionRange() orelse .{ .start = self.pos, .end = self.pos };
    }

    fn start(self: Cursor) usize {
        return self.range().start;
    }

    fn end(self: Cursor) usize {
        return self.range().end;
    }

    fn maybeSubsume(self: *Cursor, other_cursor: Cursor) bool {
        const this = self.range();
        const other = other_cursor.range();
        if (this.end < other.start or other.end < this.start) return false; // disjoint
        const new_start = u.min(this.start, other.start);
        const new_end = u.max(this.end, other.end);
        const on_right = ((self.selection_start orelse self.pos) < self.pos) or ((other_cursor.selection_start orelse other_cursor.pos) < other_cursor.pos);
        if (on_right) {
            self.selection_start = new_start;
            self.pos = new_end;
        } else {
            self.pos = new_start;
            self.selection_start = new_end;
        }
        if (new_start == new_end) self.selection_start = null;
        return true;
    }

    pub fn state(self: Cursor) Buffer.CursorState {
        // Used to save in undos/redos
        return .{ .pos = self.pos, .selection_start = self.selection_start };
    }

    fn copyToClipboard(self: *Cursor, chars: []const Char) void {
        self.clipboard.clearRetainingCapacity();
        self.clipboard.appendSlice(chars) catch u.oom();
    }

    fn adjust(self: *Cursor, delta: isize, buf: *const Buffer) void {
        if (delta < 0) self.moveLeft(@intCast(usize, -delta));
        if (delta > 0) self.moveRight(@intCast(usize, delta));
        if (delta != 0) {
            const line_col = buf.getLineColFromPos(self.pos);
            self.line = line_col.line;
            self.col = line_col.col;
        }
    }

    fn moveLeft(self: *Cursor, delta: usize) void {
        self.pos -|= delta;
        if (self.selection_start) |sel_start| self.selection_start = sel_start - delta;
    }

    fn moveRight(self: *Cursor, delta: usize) void {
        self.pos += delta;
        if (self.selection_start) |sel_start| self.selection_start = sel_start + delta;
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

const SearchBox = struct {
    open: bool = false,
    text: ArrayList(Char),
    text_selected: bool = false,
    results: ArrayList(usize),
    result_selected: usize = 0,

    fn init(allocator: Allocator) SearchBox {
        return .{
            .text = ArrayList(Char).init(allocator),
            .results = ArrayList(usize).init(allocator),
        };
    }

    fn deinit(self: SearchBox) void {
        self.text.deinit();
        self.results.deinit();
    }

    fn search(self: *SearchBox, buf: *const Buffer, cursor_pos: usize) void {
        self.results.clearRetainingCapacity();
        self.result_selected = 0;
        if (self.text.items.len == 0) return;

        var i: usize = 0;
        var selected_found = false;
        var results_iter = buf.search(self.text.items);
        while (results_iter.next()) |pos| : (i += 1) {
            self.results.append(pos) catch u.oom();
            if (pos >= cursor_pos and !selected_found) {
                self.result_selected = i;
                selected_found = true;
            }
        }
    }

    fn setText(self: *SearchBox, text: []const Char) void {
        self.text.clearRetainingCapacity();
        self.text.appendSlice(text) catch u.oom();
    }

    fn clearResults(self: *SearchBox) void {
        self.results.clearRetainingCapacity();
        self.result_selected = 0;
    }

    fn prevResult(self: *SearchBox) void {
        if (self.result_selected == 0) {
            self.result_selected = self.results.items.len -| 1;
        } else {
            self.result_selected -= 1;
        }
    }

    fn nextResult(self: *SearchBox) void {
        self.result_selected += 1;
        if (self.result_selected >= self.results.items.len) self.result_selected = 0;
    }

    fn getCurrentResultPos(self: SearchBox) ?usize {
        if (!self.open or self.results.items.len == 0) return null;
        return self.results.items[self.result_selected] + self.text.items.len;
    }

    fn getVisibleResults(self: SearchBox, start_char: usize, end_char: usize) ?[]const usize {
        if (!self.open or self.results.items.len == 0 or start_char >= end_char) return null;
        var start_set = false;
        var start: usize = 0;
        var end: usize = 0;
        for (self.results.items) |result, i| {
            if (start_char <= result and result <= end_char and !start_set) {
                start = i;
                start_set = true;
            }
            if (end_char < result) break;
            end = i + 1;
        }
        if (end <= start) return null;
        return self.results.items[start..end];
    }
};

pub const Editor = struct {
    allocator: Allocator,
    buffer: usize,

    // Updated every time we draw UI (because that's when we know the layout and therefore size)
    lines_per_screen: usize = 60,
    cols_per_screen: usize = 120,
    char_size: Vec2 = Vec2{},
    keep_selection: bool = false,

    cursors: ArrayList(Cursor),
    main_cursor_index: usize = 0,
    scroll: LineCol = LineCol{},
    search_box: SearchBox,
    highlights: ArrayList(usize),

    scrollbar: struct {
        opacity: f32 = 0,
        start_fade_ms: f64 = 0,
        started_fading: bool = false,
    },
    const scrollbar_fade_timeout_ms = 500;
    const scrollbar_fade_duration_ms = 500;

    fn init(buffer: usize, allocator: Allocator) Editor {
        var cursors = ArrayList(Cursor).init(allocator);
        cursors.append(Cursor.init(allocator)) catch u.oom();
        return .{
            .allocator = allocator,
            .buffer = buffer,
            .cursors = cursors,
            .search_box = SearchBox.init(allocator),
            .highlights = ArrayList(usize).init(allocator),
            .scrollbar = .{},
        };
    }

    fn deinit(self: Editor) void {
        for (self.cursors.items) |cursor| cursor.deinit();
        self.cursors.deinit();
        self.search_box.deinit();
        self.highlights.deinit();
    }

    fn mainCursor(self: *Editor) *Cursor {
        // We must always have at least one
        return &self.cursors.items[self.main_cursor_index];
    }

    fn removeExtraCursors(self: *Editor) void {
        var main_cursor = self.cursors.items[self.main_cursor_index];
        main_cursor.clipboard.clearRetainingCapacity();
        self.cursors.clearRetainingCapacity();
        self.cursors.append(main_cursor) catch unreachable;
        self.main_cursor_index = 0;
    }

    fn showScrollbar(self: *Editor, clock_ms: f64) void {
        self.scrollbar.opacity = 1.0;
        self.scrollbar.start_fade_ms = clock_ms + scrollbar_fade_timeout_ms;
        self.scrollbar.started_fading = false;
    }

    fn maybeFadeOutScrollbar(self: *Editor, clock_ms: f64) bool {
        if (self.scrollbar.opacity <= 0 or clock_ms < self.scrollbar.start_fade_ms) return false;
        if (!self.scrollbar.started_fading) {
            // Remember the exact time we started fading so it's consistent (we could've been sleeping)
            self.scrollbar.start_fade_ms = clock_ms;
            self.scrollbar.started_fading = true;
        }

        const t = (clock_ms - self.scrollbar.start_fade_ms) / scrollbar_fade_duration_ms;
        self.scrollbar.opacity = if (t <= 1) @floatCast(f32, 1 - t) else 0;
        return true;
    }

    fn updateAndDraw(self: *Editor, buf: *Buffer, ui: *Ui, rect: Rect, is_active: bool, clock_ms: f64, tmp_allocator: Allocator) bool {
        const scale = ui.screen.scale;
        const char_size = ui.screen.font.charSize();
        const margin = Vec2{ .x = 30 * scale, .y = 15 * scale };
        const cursor_active = is_active and !self.search_box.open;

        var area = rect.copy();
        var footer_rect = area.splitBottom(char_size.y + 2 * 4 * scale, 0);
        const scroll_area_rect = area.copy().splitRight(10 * scale, 0);
        area = area.shrink(margin.x, margin.y, margin.x, 0);

        // Retain info about size - we only know it now
        self.lines_per_screen = @floatToInt(usize, area.h / char_size.y);
        self.cols_per_screen = @floatToInt(usize, area.w / char_size.x);
        self.char_size = char_size;

        // Update cursor line, col and pos
        for (self.cursors.items) |*cursor| {
            if (cursor.pos > buf.numChars()) cursor.pos = buf.numChars();
            const line_col = buf.getLineColFromPos(cursor.pos);
            cursor.line = line_col.line;
            cursor.col = line_col.col;
        }

        // Move viewport
        const old_scroll_line = self.scroll.line;
        if (self.search_box.getCurrentResultPos()) |pos| {
            // Center viewport on current search result
            const line_col = buf.getLineColFromPos(pos);
            self.moveViewportToLineCol(line_col, true); // depends on lines_per_screen etc
        } else {
            // Move viewport to cursor (not centered)
            const line_col = buf.getLineColFromPos(self.mainCursor().pos);
            self.moveViewportToLineCol(line_col, false); // depends on lines_per_screen etc
        }
        if (self.scroll.line != old_scroll_line) self.showScrollbar(clock_ms);

        const need_redraw = self.maybeFadeOutScrollbar(clock_ms);

        // Draw the text
        {
            // First and last visible lines
            const line_min = self.scroll.line -| 1;
            const line_max = line_min + self.lines_per_screen + 3;
            const col_min = self.scroll.col;
            const col_max = col_min + self.cols_per_screen;

            const start_char = buf.getLine(line_min).start;
            const end_char = buf.getLine(line_max).end;

            const chars = buf.chars.items[start_char..end_char];
            const colors = buf.colors.items[start_char..end_char];
            const adjust_y = 2 * scale;

            const top_left = area.topLeft();

            // Draw cursor line highlights
            if (is_active) {
                for (self.cursors.items) |cursor| {
                    const highlight_rect = Rect{
                        .x = rect.x,
                        .y = top_left.y + @intToFloat(f32, cursor.line -| line_min) * char_size.y - adjust_y,
                        .w = rect.w,
                        .h = char_size.y,
                    };
                    ui.drawSolidRect(highlight_rect, style.colors.BACKGROUND_HIGHLIGHT);
                }
            }

            // Draw selected text occurrences
            if (!self.search_box.open) {
                if (self.mainCursor().getSelectionRange()) |s| {
                    if (self.getVisibleHighlights(start_char, end_char)) |highlights| {
                        for (highlights) |start_pos| {
                            const color = style.colors.CURSOR_INACTIVE;
                            const start = buf.getLineColFromPos(start_pos);
                            const end = buf.getLineColFromPos(start_pos + s.len());
                            drawSelection(ui, buf, top_left, start, end, color, line_min, col_min, col_max);
                        }
                    }
                }
            }

            // Draw selections
            for (self.cursors.items) |cursor| {
                if (cursor.getSelectionRange()) |s| {
                    const color = if (cursor_active) style.colors.SELECTION_ACTIVE else style.colors.SELECTION_INACTIVE;
                    const start = buf.getLineColFromPos(s.start);
                    const end = buf.getLineColFromPos(s.end);
                    drawSelection(ui, buf, top_left, start, end, color, line_min, col_min, col_max);
                }
            }

            // Draw search results
            if (self.search_box.getVisibleResults(start_char, end_char)) |results| {
                const selected_result = self.search_box.results.items[self.search_box.result_selected];
                const word_len = self.search_box.text.items.len;

                for (results) |start_pos| {
                    const color = if (start_pos == selected_result) style.colors.SEARCH_RESULT_ACTIVE else style.colors.SEARCH_RESULT_INACTIVE;
                    const start = buf.getLineColFromPos(start_pos);
                    const end = buf.getLineColFromPos(start_pos + word_len);
                    drawSelection(ui, buf, top_left, start, end, color, line_min, col_min, col_max);
                }
            }

            // Then draw cursors
            for (self.cursors.items) |cursor| {
                if (cursor.col < col_min or cursor.line < line_min) continue;
                const cursor_rect = Rect{
                    .x = top_left.x + @intToFloat(f32, cursor.col -| col_min) * char_size.x,
                    .y = top_left.y + @intToFloat(f32, cursor.line -| line_min) * char_size.y - adjust_y,
                    .w = char_size.x,
                    .h = char_size.y,
                };
                const cursor_color = if (cursor_active) style.colors.CURSOR_ACTIVE else style.colors.CURSOR_INACTIVE;
                ui.drawSolidRect(cursor_rect, cursor_color);
            }

            // Then draw text on top
            ui.drawText(chars, colors, top_left, col_min, col_max);

            // If some text on the left is invisible, add shadow
            if (col_min > 0) ui.drawRightShadow(Rect{ .x = area.x - 5, .y = area.y - margin.y, .w = 1, .h = area.h + margin.y }, 7 * scale);

            // Draw shadow on top if scrolled down
            if (self.scroll.line > 0) ui.drawBottomShadow(Rect{ .x = rect.x, .y = rect.y - 1, .w = rect.w, .h = 1 }, 7 * scale);

            // Draw scrollbar-area elements
            {
                const lines_per_screen = @intToFloat(f32, self.lines_per_screen);
                const scrollable_lines = @intToFloat(f32, buf.numLines() + self.lines_per_screen - SCROLL_PADDING);

                // Scrollbar
                const height_percentage = lines_per_screen / scrollable_lines;
                if (height_percentage <= 1.0) {
                    const height = scroll_area_rect.h * height_percentage;
                    const top = (scroll_area_rect.h - height) * @intToFloat(f32, self.scroll.line) / (scrollable_lines - lines_per_screen - 1);
                    const scrollbar_rect = Rect{
                        .x = scroll_area_rect.x,
                        .y = scroll_area_rect.y + top,
                        .w = scroll_area_rect.w,
                        .h = height,
                    };
                    ui.drawSolidRectWithOpacity(scrollbar_rect, style.colors.SCROLLBAR, self.scrollbar.opacity);
                }

                if (is_active) {
                    // Cursors and selections
                    const width = scroll_area_rect.w / 2;
                    const real_height = scroll_area_rect.h / scrollable_lines;
                    const height = 4 * scale;
                    for (self.cursors.items) |cursor| {
                        if (cursor.getSelectionRange()) |s| {
                            const top_line = if (cursor.pos == s.start) cursor.line else buf.getLineColFromPos(s.start).line;
                            const bottom_line = if (cursor.pos == s.end) cursor.line else buf.getLineColFromPos(s.end).line;
                            const top = scroll_area_rect.h *  @intToFloat(f32, top_line) / scrollable_lines;
                            const cursor_rect = Rect{
                                .x = scroll_area_rect.x,
                                .y = scroll_area_rect.y + top,
                                .w = width,
                                .h = u.max(@intToFloat(f32, bottom_line - top_line + 1) * real_height, height),
                            };
                            ui.drawSolidRect(cursor_rect, style.colors.CURSOR_ACTIVE);
                        } else {
                            const top = scroll_area_rect.h *  @intToFloat(f32, cursor.line) / scrollable_lines;
                            const cursor_rect = Rect{
                                .x = scroll_area_rect.x,
                                .y = scroll_area_rect.y + top,
                                .w = width,
                                .h = height,
                            };
                            ui.drawSolidRect(cursor_rect, style.colors.CURSOR_ACTIVE);
                        }
                    }

                    if (self.search_box.open and self.search_box.results.items.len > 0) {
                        // Search results
                        const search_str_len = self.search_box.text.items.len;
                        const selected_result = self.search_box.results.items[self.search_box.result_selected];

                        for (self.search_box.results.items) |start_pos| {
                            const end_pos = start_pos + search_str_len;
                            const top_line = buf.getLineColFromPos(start_pos).line;
                            const bottom_line = buf.getLineColFromPos(end_pos).line;
                            const top = scroll_area_rect.h *  @intToFloat(f32, top_line) / scrollable_lines;
                            const highlight_rect = Rect{
                                .x = scroll_area_rect.x + width,
                                .y = scroll_area_rect.y + top,
                                .w = width,
                                .h = if (top_line != bottom_line) @intToFloat(f32, bottom_line - top_line + 1) * real_height else height,
                            };
                            const color = if (start_pos == selected_result) style.colors.SEARCH_RESULT_ACTIVE else style.colors.SEARCH_RESULT_INACTIVE;
                            ui.drawSolidRect(highlight_rect, color);
                        }
                    } else if (self.mainCursor().getSelectionRange()) |s| {
                        // Selection occurrence highlights
                        for (self.highlights.items) |start_pos| {
                            const end_pos = start_pos + s.len();
                            const top_line = buf.getLineColFromPos(start_pos).line;
                            const bottom_line = buf.getLineColFromPos(end_pos).line;
                            const top = scroll_area_rect.h *  @intToFloat(f32, top_line) / scrollable_lines;
                            const highlight_rect = Rect{
                                .x = scroll_area_rect.x + width,
                                .y = scroll_area_rect.y + top,
                                .w = width,
                                .h = if (top_line != bottom_line) @intToFloat(f32, bottom_line - top_line + 1) * real_height else height,
                            };
                            ui.drawSolidRect(highlight_rect, style.colors.CURSOR_INACTIVE);
                        }
                    }
                }
            }
        }

        // Draw footer
        {
            var r = footer_rect;
            const text_y = r.y + 4 * scale;
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
                        .y = name_pos.y + char_size.y / 2,
                        .w = char_size.x * @intToFloat(f32, name_chars.len),
                        .h = 2,
                    };
                    ui.drawSolidRect(strikethrough_rect, style.colors.ERROR);
                }
            }

            // Line:col
            const main_cursor = self.mainCursor();
            const line_col = std.fmt.allocPrint(tmp_allocator, "{}:{}", .{ main_cursor.line + 1, main_cursor.col + 1 }) catch u.oom();
            const line_col_chars = u.bytesToChars(line_col, tmp_allocator) catch unreachable;
            const line_col_width = margin.x + @intToFloat(f32, line_col_chars.len) * char_size.x;
            if (r.w > line_col_width) {
                // Draw only if enough space
                const line_col_rect = r.splitRight(line_col_width, margin.x);
                ui.drawLabel(line_col_chars, .{ .x = line_col_rect.x, .y = text_y }, style.colors.PUNCTUATION);
            }
        }

        // Draw search box
        if (self.search_box.open) {
            const input_margin_top = 8 * scale;
            const input_margin = 5 * scale;
            const input_padding = 5 * scale;
            const box_right_margin = char_size.x * 2 * scale;
            const min_width = char_size.x * 10 + input_margin * 2 + input_padding * 2;

            var box_rect = rect.copy().splitTop(char_size.y + input_margin_top + input_margin + input_padding * 2 + 2, 0);
            if (box_rect.w > min_width + box_right_margin) {
                box_rect = box_rect.shrink(0, 0, box_right_margin, 0);
                box_rect = box_rect.splitRight(u.max(min_width, box_rect.w / 2), 0);
            }
            ui.drawSolidRectWithShadow(box_rect, style.colors.BACKGROUND_LIGHT, 5);

            var input_rect = box_rect.shrink(input_margin, input_margin_top, input_margin, input_margin);
            ui.drawSolidRect(input_rect, style.colors.BACKGROUND_DARK);
            input_rect = input_rect.shrinkEvenly(1);
            ui.drawSolidRect(input_rect, style.colors.BACKGROUND);

            var text_rect = input_rect.shrinkEvenly(input_margin);
            const max_chars = @floatToInt(usize, text_rect.w / char_size.x) -| 1; // leave one for cursor
            const text = self.search_box.text.items[self.search_box.text.items.len -| max_chars..];
            if (self.search_box.text_selected) {
                // Draw selection
                var selection_rect = text_rect;
                selection_rect.w = char_size.x * @intToFloat(f32, text.len);
                ui.drawSolidRect(selection_rect, style.colors.SELECTION_ACTIVE);
            }
            // Draw text
            ui.drawLabel(text, .{ .x = text_rect.x, .y = text_rect.y }, style.colors.PUNCTUATION);

            // Draw cursor
            const cursor_char_pos = @intToFloat(f32, text.len);
            const cursor_rect = Rect{
                .x = text_rect.x + cursor_char_pos * char_size.x,
                .y = text_rect.y,
                .w = char_size.x,
                .h = char_size.y,
            };
            ui.drawSolidRect(cursor_rect, style.colors.CURSOR_ACTIVE);
        }

        return need_redraw;
    }

    fn updateHighlights(self: *Editor, buf: *const Buffer, selected_text: []const Char) void {
        if (selected_text.len <= 2) return;
        u.assert(self.highlights.items.len == 0);
        const main_cursor_pos = self.mainCursor().start();
        var results_iter = buf.search(selected_text);
        while (results_iter.next()) |pos| {
            if (pos != main_cursor_pos) self.highlights.append(pos) catch u.oom();
        }
    }

    fn getVisibleHighlights(self: Editor, start_char: usize, end_char: usize) ?[]const usize {
        if (self.highlights.items.len == 0 or start_char >= end_char) return null;
        var start_set = false;
        var start: usize = 0;
        var end: usize = 0;
        for (self.highlights.items) |pos, i| {
            if (start_char <= pos and pos <= end_char and !start_set) {
                start = i;
                start_set = true;
            }
            if (end_char < pos) break;
            end = i + 1;
        }
        if (end <= start) return null;
        return self.highlights.items[start..end];
    }

    fn typeChar(self: *Editor, char: Char, buf: *Buffer, clock_ms: f64) void {
        // Type into search box
        if (self.search_box.open) {
            if (self.search_box.text_selected) {
                self.search_box.text.clearRetainingCapacity();
                self.search_box.text_selected = false;
            }
            self.search_box.text.append(char) catch u.oom();
            self.search_box.search(buf, self.mainCursor().pos);
            return;
        }

        if (buf.new_edit_group_required) buf.newEditGroup(self.cursors.items);

        // Or type into the editor
        var adjust: isize = 0;
        var buf_len = @intCast(isize, buf.numChars());
        for (self.cursors.items) |*cursor| {
            // Adjust cursor pos if the previous cursor has changed the buffer
            const new_len = @intCast(isize, buf.numChars());
            if (new_len != buf_len) {
                buf.recalculateLines();
                adjust += (new_len - buf_len);
                cursor.adjust(adjust, buf);
                buf_len = new_len;
            }

            const old_cursor = cursor.state();

            // Type
            if (cursor.getSelectionRange()) |selection| {
                cursor.pos = selection.start + 1;
                buf.replaceRange(selection.start, selection.end, &[_]Char{char});
            } else {
                cursor.pos += 1;
                buf.insertChar(old_cursor.pos, char);
            }
            cursor.col_wanted = null;
        }

        buf.modified = true;
        buf.last_edit_ms = clock_ms;
    }

    fn keyPress(self: *Editor, buf: *Buffer, key: glfw.Key, mods: glfw.Mods, tmp_allocator: Allocator, clock_ms: f64) void {
        // Process search box
        {
            var search_box = &self.search_box;
            var cursor = self.mainCursor();

            if (search_box.open) {
                switch (key) {
                    .escape => {
                        if (search_box.getCurrentResultPos()) |pos| {
                            cursor.pos = pos;
                            cursor.selection_start = pos - search_box.text.items.len;
                        }
                        search_box.open = false;
                        self.highlights.clearRetainingCapacity();
                    },
                    .backspace => {
                        if (search_box.text_selected or u.modsCmd(mods)) {
                            search_box.text.clearRetainingCapacity();
                            search_box.text_selected = false;
                        } else {
                            _ = search_box.text.popOrNull();
                        }
                        search_box.search(buf, cursor.pos);
                    },
                    .enter => {
                        if (search_box.results.items.len == 0) {
                            search_box.search(buf, cursor.pos);
                        } else {
                            if (mods.shift) search_box.prevResult() else search_box.nextResult();
                        }
                    },
                    .up => search_box.prevResult(),
                    .down => search_box.nextResult(),
                    .left, .right => search_box.text_selected = false,
                    else => {},
                }
                return;
            }

            // Open search box
            if (u.modsOnlyCmd(mods) and key == .f) {
                search_box.open = true;
                search_box.text_selected = true;
                search_box.clearResults();
                if (cursor.getSelectionRange()) |s| {
                    search_box.setText(buf.chars.items[s.start..s.end]);
                    search_box.search(buf, s.start);
                }
                return;
            }
        }

        if (buf.new_edit_group_required) buf.newEditGroup(self.cursors.items);

        if (key == .escape) self.removeExtraCursors();

        // Maybe create more cursors
        var new_cursor_created = false;
        if (key == .z and u.modsCmd(mods)) {
            if (!mods.shift) {
                // Undo
                buf.newEditGroup(self.cursors.items);
                if (buf.undo()) |cursors| self.replaceCursors(cursors, buf);
            } else {
                // Redo
                if (buf.redo()) |cursors| self.replaceCursors(cursors, buf);
            }
        }

        if (key == .d and u.modsOnlyCmd(mods)) more_cursors: {
            // Should only try to create a new cursor if all cursors have the same text selected
            const selected_text = self.selectedText(buf) orelse break :more_cursors;

            // Search from main cursor downwards, possibly with a wraparound
            const start_pos = self.mainCursor().end();
            const new_cursor_pos = blk: {
                if (self.main_cursor_index == self.cursors.items.len - 1) {
                    // Main cursor is last - search with a wraparound
                    const end_pos = self.cursors.items[0].start();
                    if (std.mem.indexOfPos(Char, buf.chars.items, start_pos, selected_text)) |pos| break :blk pos;
                    if (std.mem.indexOf(Char, buf.chars.items[0..end_pos], selected_text)) |pos| break :blk pos;
                } else {
                    // Main cursor is not last - search until the next cursor
                    const end_pos = self.cursors.items[self.main_cursor_index + 1].start();
                    if (std.mem.indexOfPos(Char, buf.chars.items[0..end_pos], start_pos, selected_text)) |pos| break :blk pos;
                }
                break :more_cursors; // not found
            };

            const line_col = buf.getLineColFromPos(new_cursor_pos);
            self.cursors.append(Cursor{
                .selection_start = new_cursor_pos,
                .pos = new_cursor_pos + selected_text.len,
                .line = line_col.line,
                .col = line_col.col,
                .clipboard = ArrayList(Char).init(self.allocator),
            }) catch u.oom();
            self.main_cursor_index = self.cursors.items.len - 1;
            new_cursor_created = true;
        }

        // Process multiple cursors
        if (!new_cursor_created) {
            var adjust: isize = 0;
            var buf_len = @intCast(isize, buf.numChars());
            for (self.cursors.items) |*cursor| {
                // Adjust cursor pos if the previous cursor has changed the buffer
                const new_len = @intCast(isize, buf.numChars());
                if (new_len != buf_len) {
                    buf.recalculateLines();
                    adjust += (new_len - buf_len);
                    cursor.adjust(adjust, buf);
                    buf_len = new_len;
                }

                self.processKeyForCursor(buf, key, mods, cursor, tmp_allocator);
            }
        }

        // Organise cursors
        {
            const main_cursor = self.mainCursor().start();

            // Sort cursors so that they are strictly ordered by pos
            std.sort.sort(
                Cursor,
                self.cursors.items,
                {},
                struct { fn lessThan(_: void, lhs: Cursor, rhs: Cursor) bool { return lhs.start() < rhs.start(); } }.lessThan,
            );

            // Reset main cursor index because it could have moved
            for (self.cursors.items) |cursor, i| {
                if (cursor.start() == main_cursor) {
                    self.main_cursor_index = i;
                    break;
                }
            } else unreachable;

            // Merge overlapping cursors
            {
                var i: usize = 0;
                while (i + 1 < self.cursors.items.len) {
                    var cursor = &self.cursors.items[i];
                    if (cursor.maybeSubsume(self.cursors.items[i + 1])) {
                        _ = self.cursors.orderedRemove(i + 1);
                        if (self.main_cursor_index > i) self.main_cursor_index -= 1;
                    } else {
                        i += 1;
                    }
                }
            }
        }

        if (buf.dirty) {
            buf.modified = true;
            self.highlights.clearRetainingCapacity();
            buf.last_edit_ms = clock_ms;
        }

        // Save to disk
        if (u.modsCmd(mods) and key == .s and buf.file != null) {
            buf.stripTrailingSpaces();

            // Adjust cursor in case it was on the trimmed whitespace
            buf.recalculateLines();
            for (self.cursors.items) |*cursor| cursor.pos = buf.getPosFromLineCol(cursor.line, cursor.col);

            buf.saveToDisk() catch unreachable; // TODO: handle
        }
    }

    fn processKeyForCursor(self: *Editor, buf: *Buffer, key: glfw.Key, mods: glfw.Mods, cursor: *Cursor, tmp_allocator: Allocator) void {
        const TAB_SIZE = 4;
        const old_cursor = cursor.state();
        const single_cursor = self.cursors.items.len == 1; // some actions are only for single cursor

        // Cursor movements
        {
            const line = buf.getLine(cursor.line);
            const move_by: usize = if (u.modsCmd(mods)) 5 else 1;

            switch (key) {
                .left, .right => {
                    if (mods.shift or !cursor.hasSelection()) {
                        if (key == .left) cursor.pos -|= move_by else cursor.pos += move_by;
                    } else if (cursor.getSelectionRange()) |selection| {
                        cursor.pos = if (key == .left) selection.start else selection.end;
                        cursor.selection_start = null;
                    }
                },
                .up, .down, .page_up, .page_down => {
                    if (!mods.alt) {
                        // Move cursor to new line
                        const new_line = switch (key) {
                            .up => cursor.line -| move_by,
                            .down => cursor.line + move_by,
                            .page_up => cursor.line -| self.lines_per_screen,
                            .page_down => cursor.line + self.lines_per_screen,
                            else => unreachable,
                        };
                        const target_line = buf.getLine(new_line);
                        const wanted_pos = cursor.col_wanted orelse cursor.col;
                        const new_line_pos = u.min(wanted_pos, target_line.len());
                        cursor.col_wanted = if (new_line_pos < wanted_pos) wanted_pos else null; // reset or remember wanted position
                        cursor.pos = target_line.start + new_line_pos;
                    } else if (u.modsOnlyAlt(mods)) {
                        const new_line = switch (key) {
                            .up => cursor.line -| 5,
                            .down => cursor.line + 5,
                            .page_up => cursor.line -| self.lines_per_screen,
                            .page_down => cursor.line + self.lines_per_screen,
                            else => unreachable,
                        };
                        // Move viewport
                        if (new_line < cursor.line) {
                            self.scroll.line -|= (cursor.line - new_line);
                        } else {
                            self.scroll.line += (new_line - cursor.line);
                        }
                    }
                },
                .home => {
                    if (cursor.pos != line.text_start) {
                        cursor.pos = line.text_start;
                    } else {
                        cursor.pos = line.start;
                    }
                },
                .end => {
                    cursor.pos = line.end;
                },
                .escape => {
                    // Remove selection
                    cursor.selection_start = null;
                },
                else => {},
            }

            // Start new selection or remove selection
            if (old_cursor.pos != cursor.pos) {
                if (mods.shift) {
                    if (!cursor.hasSelection()) cursor.selection_start = old_cursor.pos; // new selection
                } else {
                    cursor.selection_start = null;
                }
                self.highlights.clearRetainingCapacity();
            }
        }

        // Insertions/deletions of sorts
        if (key == .delete) {
            if (cursor.getSelectionRange()) |selection| {
                cursor.pos = selection.start;
                buf.deleteRange(selection.start, selection.end);
            } else {
                buf.deleteRange(cursor.pos, cursor.pos + 1);
            }
        }
        if (key == .backspace) {
            if (cursor.getSelectionRange()) |selection| {
                cursor.pos = selection.start;
                buf.deleteRange(selection.start, selection.end);
            } else {
                // Check if we can delete spaces to the previous tabstop
                var to_prev_tabstop = cursor.col % TAB_SIZE;
                if (to_prev_tabstop == 0 and cursor.col > 0) to_prev_tabstop = TAB_SIZE;
                var all_spaces: bool = false;
                if (to_prev_tabstop > 0) {
                    for (buf.chars.items[cursor.pos - to_prev_tabstop .. cursor.pos]) |char| {
                        if (char != ' ') break;
                    } else {
                        all_spaces = true;
                    }
                }
                const spaces_to_remove = if (all_spaces) to_prev_tabstop else 1;
                cursor.pos -|= spaces_to_remove;
                buf.deleteRange(cursor.pos, old_cursor.pos);
            }
        }
        if (key == .tab) {
            const SPACES = [1]Char{' '} ** TAB_SIZE;

            if (cursor.getSelectionRange()) |selection| {
                const range = buf.expandRangeToWholeLines(selection.start, selection.end, false);
                const lines = buf.lines.items[buf.getLineColFromPos(selection.start).line .. buf.getLineColFromPos(selection.end).line + 1];

                var new_chars = ArrayList(Char).init(tmp_allocator);
                new_chars.ensureTotalCapacity(range.len() + lines.len * TAB_SIZE) catch u.oom();

                self.keep_selection = true;

                if (!mods.shift) {
                    // Indent selected lines
                    for (lines) |line| {
                        new_chars.appendSliceAssumeCapacity(&SPACES);
                        new_chars.appendSliceAssumeCapacity(buf.chars.items[line.start..line.end]);
                        if (line.end != range.end) new_chars.appendAssumeCapacity('\n');
                    }

                    // Adjust selection
                    const spaces_inserted = lines.len * TAB_SIZE;
                    if (cursor.pos == selection.start) {
                        cursor.pos += TAB_SIZE;
                        cursor.selection_start.? += spaces_inserted;
                    } else {
                        cursor.selection_start.? += TAB_SIZE;
                        cursor.pos += spaces_inserted;
                    }

                    buf.replaceRange(range.start, range.end, new_chars.items);
                } else {
                    // Un-indent selected lines
                    var spaces_removed: usize = 0;
                    for (lines) |line| {
                        const spaces_to_remove = u.min(TAB_SIZE, line.lenWhitespace());
                        spaces_removed += spaces_to_remove;
                        new_chars.appendSliceAssumeCapacity(buf.chars.items[line.start + spaces_to_remove .. line.end]);
                        if (line.end != range.end) new_chars.appendAssumeCapacity('\n');
                    }

                    // Adjust selection
                    const first_line = lines[0];
                    const last_line = lines[lines.len - 1];
                    const sel_start_adjust = u.min3(TAB_SIZE, first_line.lenWhitespace(), selection.start - first_line.start);
                    const sel_end_adjust = spaces_removed -| u.min(last_line.text_start -| selection.end, TAB_SIZE);
                    if (cursor.pos == selection.start) {
                        cursor.pos -= sel_start_adjust;
                        cursor.selection_start.? -|= sel_end_adjust;
                    } else {
                        cursor.selection_start.? -|= sel_start_adjust;
                        cursor.pos -|= sel_end_adjust;
                    }

                    buf.replaceRange(range.start, range.end, new_chars.items);
                }
            } else {
                if (!mods.shift) {
                    // Insert spaces
                    const to_next_tabstop = TAB_SIZE - cursor.col % TAB_SIZE;
                    cursor.pos += to_next_tabstop;
                    buf.insertSlice(old_cursor.pos, SPACES[0..to_next_tabstop]);
                } else {
                    // Un-indent current line
                    const line = buf.getLine(cursor.line);
                    const spaces_to_remove = u.min(TAB_SIZE, line.lenWhitespace());
                    cursor.pos -|= u.min(cursor.pos - line.start, spaces_to_remove);
                    buf.deleteRange(line.start, line.start + spaces_to_remove);
                }
            }
        }
        if (key == .enter) {
            const line = buf.getLine(cursor.line);
            var indent = line.lenWhitespace();
            var char_buf: [1024]Char = undefined;
            std.mem.set(Char, char_buf[0 .. indent + 1], ' '); // if buffer is too small, we safely crash here

            if (u.modsCmd(mods) and mods.shift) {
                // Insert line above
                char_buf[indent] = '\n';
                cursor.pos = line.start + indent;
                buf.insertSlice(line.start, char_buf[0 .. indent + 1]);
            } else if (u.modsCmd(mods)) {
                // Insert line below
                if (buf.getLineOrNull(cursor.line + 1)) |next_line| {
                    char_buf[indent] = '\n';
                    cursor.pos = next_line.start + indent;
                    buf.insertSlice(next_line.start, char_buf[0 .. indent + 1]);
                }
            } else if (cursor.getSelectionRange()) |selection| {
                // Replace selection with a newline
                cursor.pos = selection.start + 1;
                buf.replaceRange(selection.start, selection.end, &[_]Char{'\n'});
            } else if (cursor.col <= indent) {
                // Don't add too much indentation
                indent = cursor.col;
                char_buf[indent] = '\n';
                cursor.pos += 1 + indent;
                buf.insertSlice(line.start, char_buf[0 .. indent + 1]);
            } else {
                // Break the line normally
                char_buf[0] = '\n';
                cursor.pos += 1 + indent;
                buf.insertSlice(old_cursor.pos, char_buf[0 .. indent + 1]);
            }
        }

        // Duplicate lines
        if (u.modsCmd(mods) and mods.shift and key == .d) {
            const range = if (cursor.getSelectionRange()) |selection|
                buf.expandRangeToWholeLines(selection.start, selection.end, false)
            else
                buf.expandRangeToWholeLines(cursor.pos, cursor.pos, false);

            // Move selection forward
            cursor.pos += range.len() + 1;
            if (cursor.selection_start != null) cursor.selection_start.? += range.len() + 1;
            self.keep_selection = true;

            // Make sure we won't reallocate when copying
            buf.chars.ensureTotalCapacity(buf.numChars() + range.len()) catch u.oom();
            buf.insertSlice(range.start, buf.chars.items[range.start..range.end]);
            buf.insertChar(range.end, '\n');
        }

        // Swap line or selection
        if (single_cursor and u.modsOnlyAltShift(mods) and (key == .up or key == .down)) {
            var range = if (cursor.getSelectionRange()) |selection|
                buf.expandRangeToWholeLines(selection.start, selection.end, false)
            else
                buf.expandRangeToWholeLines(cursor.pos, cursor.pos, false);

            const line_first = buf.getLineColFromPos(range.start).line;
            const line_last = buf.getLineColFromPos(range.end).line;

            if (key == .up and line_first > 0) {
                // Move line(s) up
                const target = buf.getLine(line_first - 1).start;
                cursor.pos = target + (cursor.pos - range.start);
                if (cursor.selection_start) |sel_start| {
                    cursor.selection_start = target + (sel_start - range.start);
                    self.keep_selection = true;
                }
                // TODO: should we have it here? buf.newEditGroup();
                buf.moveRange(range, target);
                buf.insertChar(target + range.len(), '\n');
                buf.deleteChar(range.end);
            } else if (key == .down and line_last < buf.numLines() -| 1) {
                // Move line(s) down
                const target_line = buf.getLine(line_last + 1);
                cursor.pos += target_line.len() + 1;
                if (cursor.selection_start) |sel_start| {
                    cursor.selection_start = sel_start + target_line.len() + 1;
                    self.keep_selection = true;
                }
                // TODO: should we have it here? buf.newEditGroup();
                buf.insertChar(target_line.end, '\n');
                buf.moveRange(range, target_line.end + 1);
                buf.deleteChar(range.start);
            }
        }

        // Cmd + key
        if (u.modsOnlyCmd(mods)) {
            switch (key) {
                .a => {
                    // Select all
                    cursor.selection_start = 0;
                    cursor.pos = buf.numChars();
                },
                .c, .x => {
                    // Copy / cut
                    if (cursor.getSelectionRange()) |s| {
                        if (single_cursor) {
                            // Copy to global clipboard
                            copyToClipboard(buf.chars.items[s.start..s.end], tmp_allocator);
                        } else {
                            // Copy to individual clipboard
                            cursor.copyToClipboard(buf.chars.items[s.start..s.end]);
                        }
                        if (key == .x) {
                            cursor.pos = s.start;
                            buf.deleteRange(s.start, s.end);
                        }
                    }
                },
                .v => {
                    // Paste
                    var paste_data: []const Char = undefined;
                    if (single_cursor) {
                        paste_data = getClipboardString(tmp_allocator);
                    } else {
                        const has_individual_data = for (self.cursors.items) |c| {
                            if (c.clipboard.items.len > 0) break true;
                        } else false;
                        paste_data = if (has_individual_data) cursor.clipboard.items else getClipboardString(tmp_allocator);
                    }
                    if (paste_data.len > 0) {
                        if (cursor.getSelectionRange()) |s| {
                            cursor.pos = s.start + paste_data.len;
                            buf.replaceRange(s.start, s.end, paste_data);
                        } else {
                            cursor.pos += paste_data.len;
                            buf.insertSlice(old_cursor.pos, paste_data);
                        }
                    }
                },
                .l => {
                    // Select line
                    const range = if (cursor.getSelectionRange()) |selection|
                        buf.expandRangeToWholeLines(selection.start, selection.end, true)
                    else
                        buf.expandRangeToWholeLines(cursor.pos, cursor.pos, true);
                    cursor.selection_start = range.start;
                    cursor.pos = range.end;
                },
                .d => {
                    if (!cursor.hasSelection()) {
                        if (buf.selectWord(cursor.pos)) |range| {
                            cursor.selection_start = range.start;
                            cursor.pos = range.end;
                        }
                    }
                },
                else => {},
            }
        }

        // Keep or reset col_wanted
        switch (key) {
            .up, .down, .page_up, .page_down => {}, // keep on vertical movements
            else => if (cursor.pos != old_cursor.pos) {
                cursor.col_wanted = null;
            },
        }
    }

    fn replaceCursors(self: *Editor, cursors: []const Buffer.CursorState, buf: *const Buffer) void {
        if (cursors.len == 0) return; // the first undo doesn't have any remembered cursors

        for (self.cursors.items) |cursor| cursor.deinit();
        self.cursors.clearRetainingCapacity();
        self.cursors.ensureUnusedCapacity(cursors.len) catch u.oom();
        for (cursors) |cursor| {
            const line_col = buf.getLineColFromPos(cursor.pos);
            self.cursors.appendAssumeCapacity(Cursor{
                .pos = cursor.pos,
                .selection_start = cursor.selection_start,
                .line = line_col.line,
                .col = line_col.col,
                .clipboard = ArrayList(Char).init(self.allocator),
            });
        }
        if (self.main_cursor_index >= self.cursors.items.len) self.main_cursor_index = self.cursors.items.len - 1;
        self.keep_selection = true;
    }

    fn moveViewportToLineCol(self: *Editor, line_col: LineCol, centered: bool) void {
        const line = line_col.line;
        const col = line_col.col;

        var top = self.scroll.line;
        var left = self.scroll.col;

        if (centered) {
            // Set the desired scroll coordinates and let the code below adjust it
            top = line -| self.lines_per_screen / 2;
            left= 0;
        }

        // Allowed cursor positions within viewport
        const line_min = top + SCROLL_PADDING;
        const line_max = top + self.lines_per_screen -| (SCROLL_PADDING + 2);
        const col_min = left + SCROLL_PADDING;
        const col_max = left + self.cols_per_screen -| SCROLL_PADDING;

        // Detect if cursor is outside viewport
        if (line < line_min) {
            top = line -| SCROLL_PADDING;
        } else if (line > line_max) {
            top = line + SCROLL_PADDING + 2 -| self.lines_per_screen;
        }
        if (col < col_min) {
            left -|= (col_min - col);
        } else if (col > col_max) {
            left += (col -| col_max);
        }

        self.scroll.line = top;
        self.scroll.col = left;
    }

    fn selectedText(self: *Editor, buf: *const Buffer) ?[]const Char {
        const text = if (self.mainCursor().getSelectionRange()) |s| buf.chars.items[s.start..s.end] else return null;
        for (self.cursors.items) |cursor| {
            if (cursor.getSelectionRange()) |s| {
                if (!std.mem.eql(Char, text, buf.chars.items[s.start..s.end])) return null;
            } else {
                return null;
            }
        }
        return text;
    }

    fn drawSelection(ui: *Ui, buf: *const Buffer, top_left: Vec2, start: LineCol, end: LineCol, color: style.Color, line_min: usize, col_min: usize, col_max: usize) void {
        const char_size = ui.screen.font.charSize();

        var line: usize = u.max(start.line, line_min);
        while (line <= end.line) : (line += 1) {
            const start_col = if (line == start.line) start.col -| col_min else 0;
            var end_col = if (line == end.line) end.col else buf.getLine(line).len() + 1;
            if (end_col > col_max + 1) end_col = col_max + 1;
            end_col -|= col_min;

            if (start_col < end_col) {
                const r = Rect{
                    .x = top_left.x + @intToFloat(f32, start_col) * char_size.x,
                    .y = top_left.y + @intToFloat(f32, line - line_min) * char_size.y - 2 * ui.screen.scale,
                    .w = @intToFloat(f32, end_col - start_col) * char_size.x,
                    .h = char_size.y,
                };
                ui.drawSolidRect(r, color);
            }
        }
    }
};
