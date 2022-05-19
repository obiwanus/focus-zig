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
const Buffer = focus.Buffer;
const Font = focus.fonts.Font;
const TextColor = focus.style.TextColor;
const Ui = focus.ui.Ui;

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

const Editors = @This();
const BUFFER_REFRESH_TIMEOUT_MS = 500;
const UNDO_GROUP_TIMEOUT_MS = 500;

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

pub fn updateAndDrawAll(self: *Editors, ui: *Ui, clock_ms: f64, tmp_allocator: Allocator) void {
    // Reload buffers from disk and check for conflicts
    if (clock_ms - self.last_update_from_disk_ms > BUFFER_REFRESH_TIMEOUT_MS) {
        for (self.open_buffers.items) |*buf| buf.refreshFromDisk(self.allocator);
        self.last_update_from_disk_ms = clock_ms;
    }

    // Always try to update all open buffers
    for (self.open_buffers.items) |*buf, buf_id| {
        if (clock_ms - buf.last_edit_ms >= UNDO_GROUP_TIMEOUT_MS) {

            // if (buf.undos.items.len != buf.last_undo_len) {
            //     u.println("= Buffer ====================================================================================", .{});
            //     u.printChars(buf.chars.items);
            //     u.println("", .{});
            //     u.println("= Undos =====================================================================================", .{});
            //     for (buf.undos.items) |edit_group| {
            //         for (edit_group.edits) |edit| {
            //             switch (edit) {
            //                 .Insert => |e| {
            //                     u.print("- Insert at pos {}: '", .{e.pos});
            //                     u.printChars(e.new_chars);
            //                     u.println("'", .{});
            //                 },
            //                 .Delete => |e| {
            //                     u.print("- Delete [{}..{}]: '", .{ e.range.start, e.range.start + e.old_chars.len });
            //                     u.printChars(e.old_chars);
            //                     u.println("'", .{});
            //                 },
            //                 .Replace => |e| {
            //                     u.print("- Replace '", .{});
            //                     u.printChars(e.old_chars);
            //                     u.print("' with '", .{});
            //                     u.printChars(e.new_chars);
            //                     u.println("'", .{});
            //                 },
            //             }
            //         }
            //         u.println("-------------------------------------------", .{});
            //     }
            //     u.println("\n", .{});
            //     buf.last_undo_len = buf.undos.items.len;
            // }

            buf.putCurrentEditsIntoUndoGroup();
        }
        if (buf.dirty) {
            buf.syncInternalData();
            buf.dirty = false;

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
    const new_editor = Editor.init(buffer, self.allocator);
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
    clipboard: ArrayList(Char),

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

    fn state(self: Cursor) Buffer.CursorState {
        // Used to save in undos/redos
        return .{ .pos = self.pos, .selection_start = self.selection_start };
    }

    fn copyToClipboard(self: *Cursor, chars: []const Char) void {
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

        const search_str = self.text.items;

        // Search from the beginning
        var pos: usize = 0;
        var i: usize = 0;
        var selected_found = false;
        while (std.mem.indexOfPos(Char, buf.chars.items, pos, search_str)) |found| : (i += 1) {
            self.results.append(found) catch u.oom();
            if (found >= cursor_pos and !selected_found) {
                self.result_selected = i;
                selected_found = true;
            }
            pos = found + search_str.len;
            if (pos >= buf.chars.items.len) break;
        }
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
    buffer: usize,

    // Updated every time we draw UI (because that's when we know the layout and therefore size)
    lines_per_screen: usize = 60,
    cols_per_screen: usize = 120,
    cursor: Cursor,
    scroll: Vec2 = Vec2{}, // how many px we have scrolled to the left and to the top
    scroll_animation: ?ScrollAnimation = null,
    search_box: SearchBox,

    fn init(buffer: usize, allocator: Allocator) Editor {
        return .{
            .buffer = buffer,
            .cursor = Cursor.init(allocator),
            .search_box = SearchBox.init(allocator),
        };
    }

    fn deinit(self: Editor) void {
        self.cursor.deinit();
        self.search_box.deinit();
    }

    fn updateAndDraw(self: *Editor, buf: *Buffer, ui: *Ui, rect: Rect, clock_ms: f64, is_active: bool, tmp_allocator: Allocator) void {
        const scale = ui.screen.scale;
        const char_size = ui.screen.font.charSize();
        const margin = Vec2{ .x = 30 * scale, .y = 15 * scale };
        const cursor_active = is_active and !self.search_box.open;

        var area = rect.copy();
        var footer_rect = area.splitBottom(char_size.y + 2 * 4 * scale, 0);
        area = area.shrink(margin.x, margin.y, margin.x, 0);

        // Retain info about size - we only know it now
        self.lines_per_screen = @floatToInt(usize, area.h / char_size.y);
        self.cols_per_screen = @floatToInt(usize, area.w / char_size.x);

        // Update cursor line, col and pos
        {
            if (self.cursor.pos > buf.numChars()) self.cursor.pos = buf.numChars();
            const cursor = buf.getLineColFromPos(self.cursor.pos);
            self.cursor.line = cursor.line;
            self.cursor.col = cursor.col;
        }

        if (self.search_box.getCurrentResultPos()) |pos| {
            self.moveViewportToPos(buf, pos, char_size); // depends on lines_per_screen etc
        } else {
            self.moveViewportToPos(buf, self.cursor.pos, char_size); // depends on lines_per_screen etc
        }

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

            // Draw search selections
            if (self.search_box.getVisibleResults(start_char, end_char)) |results| {
                const selected_result = self.search_box.results.items[self.search_box.result_selected];
                const word_len = self.search_box.text.items.len;

                for (results) |start_pos| {
                    // Draw selection
                    const color = if (start_pos == selected_result) style.colors.SEARCH_RESULT_ACTIVE else style.colors.SEARCH_RESULT_INACTIVE;
                    const start = buf.getLineColFromPos(start_pos);
                    const end = buf.getLineColFromPos(start_pos + word_len);

                    var line: usize = start.line;
                    while (line <= end.line) : (line += 1) {
                        const start_col = if (line == start.line) start.col -| col_min else 0;
                        var end_col = if (line == end.line) end.col else buf.getLine(line).len() + 1;
                        if (end_col > col_max + 1) end_col = col_max + 1;
                        end_col -|= col_min;

                        if (start_col < end_col) {
                            const r = Rect{
                                .x = top_left.x + @intToFloat(f32, start_col) * char_size.x,
                                .y = top_left.y + @intToFloat(f32, line -| line_min) * char_size.y - adjust_y,
                                .w = @intToFloat(f32, end_col - start_col) * char_size.x,
                                .h = char_size.y,
                            };
                            ui.drawSolidRect(r, color);
                        }
                    }
                }
            }

            // Draw cursor selections
            if (self.cursor.getSelectionRange()) |s| {
                const color = if (cursor_active) style.colors.SELECTION_ACTIVE else style.colors.SELECTION_INACTIVE;
                const start = buf.getLineColFromPos(s.start);
                const end = buf.getLineColFromPos(s.end);

                var line: usize = start.line;
                while (line <= end.line) : (line += 1) {
                    const start_col = if (line == start.line) start.col -| col_min else 0;
                    var end_col = if (line == end.line) end.col else buf.getLine(line).len() + 1;
                    if (end_col > col_max + 1) end_col = col_max + 1;
                    end_col -|= col_min;

                    if (start_col < end_col) {
                        const r = Rect{
                            .x = top_left.x + @intToFloat(f32, start_col) * char_size.x,
                            .y = top_left.y + @intToFloat(f32, line -| line_min) * char_size.y - adjust_y,
                            .w = @intToFloat(f32, end_col - start_col) * char_size.x,
                            .h = char_size.y,
                        };
                        ui.drawSolidRect(r, color);
                    }
                }
            }

            // Then draw cursor
            const cursor_rect = Rect{
                .x = top_left.x + @intToFloat(f32, cursor_col) * char_size.x,
                .y = top_left.y + @intToFloat(f32, cursor_line) * char_size.y - adjust_y,
                .w = char_size.x,
                .h = char_size.y,
            };
            const cursor_color = if (cursor_active) style.colors.CURSOR_ACTIVE else style.colors.CURSOR_INACTIVE;
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
    }

    fn typeChar(self: *Editor, char: Char, buf: *Buffer, clock_ms: f64) void {
        const old_cursor = self.cursor.state();
        var cursor = &self.cursor;

        // Type into search box
        if (self.search_box.open) {
            if (self.search_box.text_selected) {
                self.search_box.text.clearRetainingCapacity();
                self.search_box.text_selected = false;
            }
            self.search_box.text.append(char) catch u.oom();
            self.search_box.search(buf, cursor.pos);
            return;
        }

        // Or type into the editor
        if (cursor.getSelectionRange()) |selection| {
            cursor.pos = selection.start + 1;
            buf.replaceRange(selection.start, selection.end, &[_]Char{char}, old_cursor, cursor.state());
        } else {
            cursor.pos += 1;
            buf.insertChar(old_cursor.pos, char, old_cursor, cursor.state());
        }
        cursor.col_wanted = null;
        buf.dirty = true;
        buf.modified = true;
        buf.last_edit_ms = clock_ms;
    }

    fn keyPress(self: *Editor, buf: *Buffer, key: glfw.Key, mods: glfw.Mods, tmp_allocator: Allocator, clock_ms: f64) void {
        const old_cursor = self.cursor.state();
        var cursor = &self.cursor;

        // Process search box
        var search_box = &self.search_box;
        if (search_box.open) {
            switch (key) {
                .escape => {
                    if (search_box.getCurrentResultPos()) |pos| {
                        cursor.pos = pos;
                        cursor.selection_start = pos - search_box.text.items.len;
                    }
                    search_box.open = false;
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
                    if (mods.shift) search_box.prevResult() else search_box.nextResult();
                },
                .up => search_box.prevResult(),
                .down => search_box.nextResult(),
                .left, .right => search_box.text_selected = false,
                else => {},
            }
            return;
        }
        if (u.modsOnlyCmd(mods) and key == .f) {
            search_box.open = true;
            search_box.text_selected = true;
            search_box.search(buf, cursor.pos);
            return;
        }

        // Insertions/deletions of sorts
        const TAB_SIZE = 4;
        buf.dirty = true;
        switch (key) {
            .delete => {
                if (cursor.getSelectionRange()) |selection| {
                    cursor.pos = selection.start;
                    buf.deleteRange(selection.start, selection.end, old_cursor, cursor.state());
                } else {
                    buf.deleteRange(cursor.pos, cursor.pos + 1, old_cursor, cursor.state());
                }
            },
            .backspace => {
                if (cursor.getSelectionRange()) |selection| {
                    cursor.pos = selection.start;
                    buf.deleteRange(selection.start, selection.end, old_cursor, cursor.state());
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
                    buf.deleteRange(cursor.pos, old_cursor.pos, old_cursor, cursor.state());
                }
            },
            .tab => {
                const SPACES = [1]Char{' '} ** TAB_SIZE;

                if (cursor.getSelectionRange()) |selection| {
                    const range = buf.expandRangeToWholeLines(selection.start, selection.end);
                    const lines = buf.lines.items[buf.getLineColFromPos(selection.start).line .. buf.getLineColFromPos(selection.end).line + 1];

                    var new_chars = ArrayList(Char).init(tmp_allocator);
                    new_chars.ensureTotalCapacity(range.len() + lines.len * TAB_SIZE) catch u.oom();

                    cursor.keep_selection = true;

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

                        buf.replaceRange(range.start, range.end, new_chars.items, old_cursor, cursor.state());
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

                        buf.replaceRange(range.start, range.end, new_chars.items, old_cursor, cursor.state());
                    }
                } else {
                    if (!mods.shift) {
                        // Insert spaces
                        const to_next_tabstop = TAB_SIZE - cursor.col % TAB_SIZE;
                        cursor.pos += to_next_tabstop;
                        buf.insertSlice(old_cursor.pos, SPACES[0..to_next_tabstop], old_cursor, cursor.state());
                    } else {
                        // Un-indent current line
                        const line = buf.getLine(cursor.line);
                        const spaces_to_remove = u.min(TAB_SIZE, line.lenWhitespace());
                        cursor.pos -|= u.min(cursor.pos - line.start, spaces_to_remove);
                        buf.deleteRange(line.start, line.start + spaces_to_remove, old_cursor, cursor.state());
                    }
                }
            },
            .enter => {
                const line = buf.getLine(cursor.line);
                var indent = line.lenWhitespace();
                var char_buf: [1024]Char = undefined;
                std.mem.set(Char, char_buf[0 .. indent + 1], ' '); // if buffer is too small, we safely crash here

                if (u.modsCmd(mods) and mods.shift) {
                    // Insert line above
                    char_buf[indent] = '\n';
                    cursor.pos = line.start + indent;
                    buf.insertSlice(line.start, char_buf[0 .. indent + 1], old_cursor, cursor.state());
                } else if (u.modsCmd(mods)) {
                    // Insert line below
                    if (buf.getLineOrNull(cursor.line + 1)) |next_line| {
                        char_buf[indent] = '\n';
                        cursor.pos = next_line.start + indent;
                        buf.insertSlice(next_line.start, char_buf[0 .. indent + 1], old_cursor, cursor.state());
                    }
                } else if (cursor.getSelectionRange()) |selection| {
                    // Replace selection with a newline
                    cursor.pos = selection.start + 1;
                    buf.replaceRange(selection.start, selection.end, &[_]Char{'\n'}, old_cursor, cursor.state());
                } else if (cursor.col <= indent) {
                    // Don't add too much indentation
                    indent = cursor.col;
                    char_buf[indent] = '\n';
                    cursor.pos += 1 + indent;
                    buf.insertSlice(line.start, char_buf[0 .. indent + 1], old_cursor, cursor.state());
                } else {
                    // Break the line normally
                    char_buf[0] = '\n';
                    cursor.pos += 1 + indent;
                    buf.insertSlice(old_cursor.pos, char_buf[0 .. indent + 1], old_cursor, cursor.state());
                }
            },
            else => {
                buf.dirty = false; // nothing needs to be done
            },
        }

        if (u.modsCmd(mods) and mods.shift and key == .d) {
            // Duplicate lines
            const range = if (cursor.getSelectionRange()) |selection|
                buf.expandRangeToWholeLines(selection.start, selection.end)
            else
                buf.expandRangeToWholeLines(cursor.pos, cursor.pos);

            // Move selection forward
            cursor.pos += range.len() + 1;
            if (cursor.selection_start != null) cursor.selection_start.? += range.len() + 1;
            cursor.keep_selection = true;

            // Make sure we won't reallocate when copying
            buf.chars.ensureTotalCapacity(buf.numChars() + range.len()) catch u.oom();
            buf.insertSlice(range.start, buf.chars.items[range.start..range.end], old_cursor, cursor.state());
            buf.insertChar(range.end, '\n', old_cursor, cursor.state());

            buf.dirty = true;
        }

        const line = buf.getLine(cursor.line);
        const move_by: usize = if (u.modsCmd(mods)) 5 else 1;

        // Cursor movements
        switch (key) {
            .left => {
                cursor.pos -|= move_by;
                if (u.modsCmd(mods) and cursor.pos < line.start) cursor.pos = line.start;
            },
            .right => {
                cursor.pos += move_by;
                if (u.modsCmd(mods) and cursor.pos > line.end) cursor.pos = line.end;
                if (cursor.pos > buf.numChars()) cursor.pos = buf.numChars();
            },
            .up => {
                self.moveCursorToLine(cursor.line -| move_by, buf);
            },
            .down => {
                self.moveCursorToLine(cursor.line + move_by, buf);
            },
            .page_up => {
                self.moveCursorToLine(cursor.line -| self.lines_per_screen, buf);
            },
            .page_down => {
                self.moveCursorToLine(cursor.line + self.lines_per_screen, buf);
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
        if (old_cursor.pos != cursor.pos and !cursor.keep_selection) {
            if (mods.shift) {
                if (cursor.selection_start == null) {
                    // Start new selection
                    cursor.selection_start = old_cursor.pos;
                }
            } else {
                cursor.selection_start = null;
            }
        }

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
                        cursor.copyToClipboard(buf.chars.items[s.start..s.end]);
                        if (key == .x) {
                            cursor.pos = s.start;
                            buf.deleteRange(s.start, s.end, old_cursor, cursor.state());
                            buf.dirty = true;
                        }
                    }
                },
                .v => {
                    // Paste
                    if (cursor.clipboard.items.len > 0) {
                        const paste_data = cursor.clipboard.items;
                        if (cursor.getSelectionRange()) |s| {
                            cursor.pos = s.start + paste_data.len;
                            buf.replaceRange(s.start, s.end, paste_data, old_cursor, cursor.state());
                        } else {
                            cursor.pos += paste_data.len;
                            buf.insertSlice(old_cursor.pos, paste_data, old_cursor, cursor.state());
                        }
                        buf.dirty = true;
                    }
                },
                .l => {
                    // Select line
                    const range = if (cursor.getSelectionRange()) |selection|
                        buf.expandRangeToWholeLines(selection.start, selection.end)
                    else
                        buf.expandRangeToWholeLines(cursor.pos, cursor.pos);
                    cursor.selection_start = range.start;
                    cursor.pos = range.end;
                },
                .d => {
                    // TODO:
                    // - When single cursor has a selection, create more cursors
                    // - When more than one cursor:
                    //     - select words under each
                    //     - do nothing else
                    if (buf.selectWord(cursor.pos)) |range| {
                        cursor.selection_start = range.start;
                        cursor.pos = range.end;
                    }
                },
                .z => {
                    if (buf.undo()) |cursor_state| {
                        cursor.pos = cursor_state.pos;
                        cursor.selection_start = cursor_state.selection_start;
                        cursor.keep_selection = true;
                        buf.dirty = true;
                    }
                },
                else => {},
            }
        }

        if (u.modsCmd(mods) and mods.shift and key == .z) {
            if (buf.redo()) |cursor_state| {
                cursor.pos = cursor_state.pos;
                cursor.selection_start = cursor_state.selection_start;
                cursor.keep_selection = true;
                buf.dirty = true;
            }
        }

        if (buf.dirty) {
            buf.modified = true;
            buf.last_edit_ms = clock_ms;
        }

        // Keep or reset col_wanted
        switch (key) {
            .up, .down, .page_up, .page_down => {}, // keep on vertical movements
            else => if (cursor.pos != old_cursor.pos) {
                cursor.col_wanted = null;
            },
        }

        // Save to disk
        if (u.modsCmd(mods) and key == .s and buf.file != null) {
            buf.stripTrailingSpaces();

            // Adjust cursor in case it was on the trimmed whitespace
            buf.recalculateLines();
            cursor.pos = buf.getPosFromLineCol(cursor.line, cursor.col);

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

    fn moveViewportToPos(self: *Editor, buf: *const Buffer, pos: usize, char_size: Vec2) void {
        const lc = buf.getLineColFromPos(pos);
        const line = lc.line;
        const col = lc.col;

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
        if (line < line_min) {
            viewport_top = line -| padding;
        } else if (line > line_max) {
            viewport_top = line + padding + 1 -| self.lines_per_screen;
        }
        if (col < col_min) {
            viewport_left -|= (col_min - col);
        } else if (col > col_max) {
            viewport_left += (col -| col_max);
        }

        self.scroll.y = @intToFloat(f32, viewport_top) * char_size.y;
        self.scroll.x = @intToFloat(f32, viewport_left) * char_size.x;
    }
};
