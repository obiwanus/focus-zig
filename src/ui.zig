const std = @import("std");
const vk = @import("vulkan");

const focus = @import("focus.zig");
const u = focus.utils;
const vu = focus.vulkan.utils;
const style = focus.style;

const Allocator = std.mem.Allocator;
const Font = focus.fonts.Font;
const VulkanContext = focus.vulkan.context.VulkanContext;
const TextColor = style.TextColor;
const Color = style.Color;
const Vec2 = u.Vec2;
const Rect = u.Rect;
const OpenFileDialog = focus.dialogs.OpenFile;

// Probably temporary - this is just to preallocate buffers on the GPU
// and not worry about more sophisticated allocation strategies
const MAX_VERTEX_COUNT = 300000;

pub const Screen = struct {
    size: vk.Extent2D,
    scale: f32,
    font: Font,

    // TODO:
    // font_ui_normal: Font,
    // font_ui_small: Font,

    pub fn getRect(self: Screen) Rect {
        return Rect{
            .x = 0,
            .y = 0,
            .w = @intToFloat(f32, self.size.width),
            .h = @intToFloat(f32, self.size.height),
        };
    }
};

const VertexType = enum(u32) {
    solid = 0,
    textured = 1,
    // yeah, the waste!
};

// #MEMORY: fat vertex. TODO: use a primitive buffer instead
pub const Vertex = extern struct {
    color: Color,
    pos: Vec2,
    texcoord: Vec2,
    vertex_type: VertexType,

    pub const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    pub const attribute_description = [_]vk.VertexInputAttributeDescription{ .{
        .binding = 0,
        .location = 0,
        .format = .r32g32b32a32_sfloat,
        .offset = @offsetOf(Vertex, "color"),
    }, .{
        .binding = 0,
        .location = 1,
        .format = .r32g32_sfloat,
        .offset = @offsetOf(Vertex, "pos"),
    }, .{
        .binding = 0,
        .location = 2,
        .format = .r32g32_sfloat,
        .offset = @offsetOf(Vertex, "texcoord"),
    }, .{
        .binding = 0,
        .location = 3,
        .format = .r8_uint,
        .offset = @offsetOf(Vertex, "vertex_type"),
    } };
};

pub const Ui = struct {
    screen: Screen = undefined,

    vertices: std.ArrayList(Vertex),
    indices: std.ArrayList(u32),

    vertex_buffer: vk.Buffer,
    vertex_buffer_memory: vk.DeviceMemory,
    index_buffer: vk.Buffer,
    index_buffer_memory: vk.DeviceMemory,

    pub fn init(allocator: Allocator, vc: *const VulkanContext) !Ui {
        var self: Ui = undefined;

        self.vertices = std.ArrayList(Vertex).init(allocator);
        self.indices = std.ArrayList(u32).init(allocator);

        // Init vertex buffer
        {
            self.vertex_buffer = try vc.vkd.createBuffer(vc.dev, &.{
                .flags = .{},
                .size = @sizeOf(Vertex) * MAX_VERTEX_COUNT,
                .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
                .sharing_mode = .exclusive,
                .queue_family_index_count = 0,
                .p_queue_family_indices = undefined,
            }, null);
            const mem_reqs = vc.vkd.getBufferMemoryRequirements(vc.dev, self.vertex_buffer);
            self.vertex_buffer_memory = try vc.allocate(mem_reqs, .{ .device_local_bit = true });
            try vc.vkd.bindBufferMemory(vc.dev, self.vertex_buffer, self.vertex_buffer_memory, 0);
        }

        // Init index buffer
        {
            self.index_buffer = try vc.vkd.createBuffer(vc.dev, &.{
                .flags = .{},
                .size = @sizeOf(u32) * MAX_VERTEX_COUNT * 2,
                .usage = .{ .transfer_dst_bit = true, .index_buffer_bit = true },
                .sharing_mode = .exclusive,
                .queue_family_index_count = 0,
                .p_queue_family_indices = undefined,
            }, null);
            const mem_reqs = vc.vkd.getBufferMemoryRequirements(vc.dev, self.index_buffer);
            self.index_buffer_memory = try vc.allocate(mem_reqs, .{ .device_local_bit = true });
            try vc.vkd.bindBufferMemory(vc.dev, self.index_buffer, self.index_buffer_memory, 0);
        }

        return self;
    }

    pub fn deinit(self: Ui, vc: *const VulkanContext) void {
        self.vertices.deinit();
        self.indices.deinit();
        vc.vkd.freeMemory(vc.dev, self.vertex_buffer_memory, null);
        vc.vkd.destroyBuffer(vc.dev, self.vertex_buffer, null);
        vc.vkd.freeMemory(vc.dev, self.index_buffer_memory, null);
        vc.vkd.destroyBuffer(vc.dev, self.index_buffer, null);
    }

    pub fn startFrame(self: *Ui, screen: Screen) void {
        // Reset drawing data
        self.vertices.shrinkRetainingCapacity(0);
        self.indices.shrinkRetainingCapacity(0);

        // Remember screen info for drawing
        self.screen = screen;
    }

    pub fn endFrame(self: Ui, vc: *const VulkanContext, pool: vk.CommandPool) !void {
        u.assert(self.vertices.items.len < MAX_VERTEX_COUNT);
        u.assert(self.indices.items.len < MAX_VERTEX_COUNT * 2);
        // Copy drawing data to GPU buffers
        try vu.uploadDataToBuffer(vc, Vertex, self.vertices.items, pool, self.vertex_buffer);
        try vu.uploadDataToBuffer(vc, u32, self.indices.items, pool, self.index_buffer);
    }

    pub fn indexCount(self: Ui) u32 {
        return @intCast(u32, self.indices.items.len);
    }

    pub fn drawOpenFileDialog(self: *Ui, dialog: *OpenFileDialog, tmp_allocator: Allocator) void {
        var dir = dialog.getCurrentDir();
        const scale = self.screen.scale;
        const font = self.screen.font;

        const screen = self.screen.getRect();
        const dialog_width = std.math.clamp(screen.w / 3, 400.0 * scale, 1500.0 * scale);
        const dialog_height = std.math.clamp(screen.h / 1.5, 200.0 * scale, 800.0 * scale);
        var dialog_rect = Rect{ .x = (screen.w - dialog_width) / 2, .y = 100, .w = dialog_width, .h = dialog_height };

        // Determine the height of the dialog box
        const margin = 10 * scale;
        const padding = 5 * scale;
        const input_rect_height = font.line_height + 2 * padding + 2 * margin + 2;
        const entry_height = font.line_height + 2 * padding;
        const max_entries = @floatToInt(usize, dialog_rect.h / entry_height);

        const filtered_entries = dir.filteredEntries(dialog.filter_text.items, tmp_allocator);
        const num_entries = std.math.clamp(filtered_entries.len, 1, max_entries);

        const actual_height = entry_height * @intToFloat(f32, num_entries) + input_rect_height;
        dialog_rect.h = actual_height;

        // Draw background
        self.drawSolidRectWithShadow(
            dialog_rect,
            style.colors.BACKGROUND_LIGHT,
            10,
        );

        // Draw input box
        {
            var input_rect = dialog_rect.splitTop(input_rect_height, 0).shrinkEvenly(margin);
            self.drawSolidRect(input_rect, style.colors.BACKGROUND_DARK);
            input_rect = input_rect.shrinkEvenly(1);
            self.drawSolidRect(input_rect, style.colors.BACKGROUND);
            input_rect = input_rect.shrinkEvenly(padding);

            // Draw open directories
            const filter_text_min_width = 10 * font.xadvance; // can't go smaller than that
            const dir_list_max_width = input_rect.w - filter_text_min_width;
            var num_dirs: usize = 0;
            var list_width: f32 = 0;
            var dir_list_truncated: bool = false;
            while (num_dirs < dialog.open_dirs.items.len) : (num_dirs += 1) {
                const d = dialog.open_dirs.items[dialog.open_dirs.items.len - 1 - num_dirs]; // iterate backwards
                list_width += padding; // between bubbles
                const dir_width = padding * 2 + @intToFloat(f32, d.name.items.len) * font.xadvance;
                list_width += dir_width;
                if (list_width > dir_list_max_width) {
                    // Pop a dir from the left
                    num_dirs -= 1;
                    list_width -= dir_width;
                    // See if we have room for a "..." bubble
                    if (list_width + 2 * padding + 3 * font.xadvance > dir_list_max_width) {
                        // Pop another one
                        num_dirs -= 1;
                        // NOTE: a couple of corner cases here that we will ignore until they happen
                    }
                    dir_list_truncated = true;
                    break;
                }
            }
            if (dir_list_truncated) {
                // Draw the truncation bubble first
                const w = 3 * font.xadvance + 2 * padding;
                var r = input_rect.splitLeft(w, padding);
                self.drawSolidRect(r, style.colors.SELECTION_INACTIVE);
                const text_rect = r.shrink(padding, 0, padding, 0);
                const name = u.bytesToChars("...", tmp_allocator) catch unreachable;
                self.drawLabel(name, text_rect.topLeft(), style.colors.PUNCTUATION);
            }
            const total_dirs = dialog.open_dirs.items.len;
            for (dialog.open_dirs.items[total_dirs - num_dirs ..]) |d| {
                const w = @intToFloat(f32, d.name.items.len) * font.xadvance + 2 * padding;
                var r = input_rect.splitLeft(w, padding);
                self.drawSolidRect(r, style.colors.SELECTION_INACTIVE);
                const text_rect = r.shrink(padding, 0, padding, 0);
                const name = u.bytesToChars(d.name.items, tmp_allocator) catch unreachable;
                self.drawLabel(name, text_rect.topLeft(), style.colors.PUNCTUATION);
            }

            // Draw filter text
            const filter_text_max_chars = @floatToInt(usize, input_rect.w / font.xadvance) - 1;
            if (dialog.filter_text.items.len > filter_text_max_chars) {
                // Draw truncated version
                self.drawLabel(&[_]u.Char{ '.', '.' }, .{ .x = input_rect.x, .y = input_rect.y }, style.colors.PUNCTUATION);
                self.drawLabel(
                    dialog.filter_text.items[dialog.filter_text.items.len - filter_text_max_chars + 2 ..],
                    .{ .x = input_rect.x + 2 * font.xadvance, .y = input_rect.y },
                    style.colors.PUNCTUATION,
                );
            } else {
                // Draw full version
                self.drawLabel(dialog.filter_text.items, .{ .x = input_rect.x, .y = input_rect.y }, style.colors.PUNCTUATION);
            }

            // Draw cursor
            const cursor_char_pos = @intToFloat(f32, std.math.clamp(dialog.filter_text.items.len, 0, filter_text_max_chars));
            const cursor_rect = Rect{
                .x = input_rect.x + cursor_char_pos * font.xadvance,
                .y = input_rect.y,
                .w = font.xadvance,
                .h = font.line_height,
            };
            self.drawSolidRect(cursor_rect, style.colors.CURSOR_ACTIVE);
        }

        // Draw entries
        var visible_start: usize = 0;
        var visible_end: usize = if (filtered_entries.len > max_entries) max_entries else filtered_entries.len;
        if (dir.selected >= max_entries) {
            visible_start = dir.selected - visible_end + 1;
            visible_end = dir.selected + 1;
        }

        for (filtered_entries[visible_start..visible_end]) |entry, i| {
            const r = Rect{
                .x = dialog_rect.x,
                .y = dialog_rect.y + @intToFloat(f32, i) * entry_height,
                .w = dialog_rect.w,
                .h = entry_height,
            };
            if (visible_start + i == dir.selected) {
                self.drawSolidRect(r, style.colors.BACKGROUND_BRIGHT);
            }
            const name = u.bytesToChars(entry.getName(), tmp_allocator) catch unreachable;
            self.drawLabel(name, .{ .x = r.x + margin + padding, .y = r.y + padding }, style.colors.PUNCTUATION);
        }

        // Draw shadow
        if (dir.selected >= max_entries) {
            const dark = Color{ .r = 0, .g = 0, .b = 0, .a = 0.2 };
            const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
            const r = dialog_rect.splitTop(padding, 0);
            self.drawRect(r, dark, dark, transparent, transparent); // bottom
        }

        // Draw scrollbar
        if (filtered_entries.len >= max_entries) {
            const width = margin;
            const height = dialog_rect.h * @intToFloat(f32, max_entries) / @intToFloat(f32, filtered_entries.len);
            const offset = dialog_rect.h * @intToFloat(f32, visible_start) / @intToFloat(f32, filtered_entries.len);
            const scrollbar = Rect{
                .x = dialog_rect.r() - width,
                .y = dialog_rect.y + offset,
                .w = width,
                .h = height,
            };
            self.drawSolidRect(scrollbar, style.colors.SCROLLBAR);
        }

        // Draw placeholder if no entries are present
        if (filtered_entries.len == 0) {
            const r = dialog_rect.shrink(margin + padding, padding, 0, padding);
            const placeholder = u.bytesToChars("...", tmp_allocator) catch unreachable;
            self.drawLabel(placeholder, .{ .x = r.x, .y = r.y }, style.colors.COMMENT);
        }
    }

    pub fn drawDebugPanel(self: *Ui, frame_number: usize) void {
        const screen_x = @intToFloat(f32, self.screen.size.width);
        const width = 200;
        const height = 100;
        const margin = 20;
        const padding = 10;
        self.drawSolidRect(
            Rect{
                .x = screen_x - margin - 2 * padding - width,
                .y = margin,
                .w = width + 2 * padding,
                .h = height,
            },
            style.colors.BACKGROUND_LIGHT,
        );
        var buf: [10]u8 = undefined;
        _ = std.fmt.bufPrint(buf[0..], "{d:10}", .{frame_number}) catch unreachable;
        var chars: [10]u.Char = undefined;
        for (buf) |char, i| {
            chars[i] = char;
        }
        self.drawLabel(&chars, Vec2{ .x = screen_x - margin - padding - width, .y = margin + padding }, style.colors.KEYWORD);
    }

    // ----------------------------------------------------------------------------------------------------------------

    pub fn drawSolidRect(self: *Ui, r: Rect, color: Color) void {
        self.drawRect(r, color, color, color, color);
    }

    pub fn drawSolidRectWithOpacity(self: *Ui, r: Rect, color: Color, opacity: f32) void {
        var new_color = color;
        new_color.a = opacity;
        self.drawRect(r, new_color, new_color, new_color, new_color);
    }

    pub fn drawSolidRectWithShadow(self: *Ui, r: Rect, color: Color, shadow_size: f32) void {
        const size = shadow_size * self.screen.scale;
        const dark = style.colors.SHADOW_DARK;
        const transparent = style.colors.SHADOW_TRANSPARENT;
        const pi = std.math.pi;

        // Draw main shadows
        self.drawRect(Rect{ .x = r.x, .y = r.y - size, .w = r.w, .h = size }, transparent, transparent, dark, dark); // top
        self.drawRect(Rect{ .x = r.x, .y = r.y + r.h, .w = r.w, .h = size }, dark, dark, transparent, transparent); // bottom
        self.drawRect(Rect{ .x = r.x - size, .y = r.y, .w = size, .h = r.h }, transparent, dark, dark, transparent); // left
        self.drawRect(Rect{ .x = r.x + r.w, .y = r.y, .w = size, .h = r.h }, dark, transparent, transparent, dark); // right

        // Draw corners
        self.drawCircularShadow(.{ .x = r.x + r.w, .y = r.y }, size, pi / 2.0, pi);
        self.drawCircularShadow(.{ .x = r.x, .y = r.y }, size, pi, 3 * pi / 2.0);
        self.drawCircularShadow(.{ .x = r.x, .y = r.y + r.h }, size, 3 * pi / 2.0, 2.0 * pi);
        self.drawCircularShadow(.{ .x = r.x + r.w, .y = r.y + r.h }, size, 0, pi / 2.0);

        self.drawSolidRect(r, color);
    }

    pub fn drawTopShadow(self: *Ui, r: Rect, size: f32) void {
        const dark = style.colors.SHADOW_DARK;
        const transparent = style.colors.SHADOW_TRANSPARENT;
        self.drawRect(Rect{ .x = r.x, .y = r.y - size, .w = r.w, .h = size }, transparent, transparent, dark, dark);
    }

    pub fn drawBottomShadow(self: *Ui, r: Rect, size: f32) void {
        const dark = style.colors.SHADOW_DARK;
        const transparent = style.colors.SHADOW_TRANSPARENT;
        self.drawRect(Rect{ .x = r.x, .y = r.y + r.h, .w = r.w, .h = size }, dark, dark, transparent, transparent);
    }

    pub fn drawRightShadow(self: *Ui, r: Rect, size: f32) void {
        const dark = style.colors.SHADOW_DARK;
        const transparent = style.colors.SHADOW_TRANSPARENT;
        self.drawRect(Rect{ .x = r.x + r.w, .y = r.y, .w = size, .h = r.h }, dark, transparent, transparent, dark);
    }

    pub fn drawCircularShadow(self: *Ui, center: Vec2, radius: f32, start_angle: f32, end_angle: f32) void {
        const v = @intCast(u32, self.vertices.items.len);
        const dark = style.colors.SHADOW_DARK;
        const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

        // Central vertex
        self.vertices.append(Vertex{ .color = dark, .vertex_type = .solid, .texcoord = undefined, .pos = center }) catch u.oom();

        // Get points in a circle
        const num_triangles = 9;
        const step = (end_angle - start_angle) / num_triangles;
        var angle = start_angle;
        var p: usize = 0;
        while (p <= num_triangles) {
            const pos = Vec2{
                .x = center.x + radius * std.math.sin(angle),
                .y = center.y + radius * std.math.cos(angle),
            };
            self.vertices.append(Vertex{ .color = transparent, .vertex_type = .solid, .texcoord = undefined, .pos = pos }) catch u.oom();

            angle += step;
            p += 1;
        }
        var i: u32 = 1;
        while (i <= num_triangles) : (i += 1) {
            const indices = [_]u32{ v, v + i, v + i + 1 };
            self.indices.appendSlice(&indices) catch u.oom();
        }
    }

    /// Queues a rect with colors for each vertex
    fn drawRect(self: *Ui, r: Rect, color0: Color, color1: Color, color2: Color, color3: Color) void {
        // Current vertex index
        const v = @intCast(u32, self.vertices.items.len);

        // Rect vertices in clockwise order, starting from top left
        const vertices = [_]Vertex{
            .{ .color = color0, .vertex_type = .solid, .texcoord = undefined, .pos = .{ .x = r.x, .y = r.y } },
            .{ .color = color1, .vertex_type = .solid, .texcoord = undefined, .pos = .{ .x = r.x + r.w, .y = r.y } },
            .{ .color = color2, .vertex_type = .solid, .texcoord = undefined, .pos = .{ .x = r.x + r.w, .y = r.y + r.h } },
            .{ .color = color3, .vertex_type = .solid, .texcoord = undefined, .pos = .{ .x = r.x, .y = r.y + r.h } },
        };
        self.vertices.appendSlice(&vertices) catch u.oom();

        // Indices: 0, 2, 3, 0, 1, 2
        const indices = [_]u32{ v, v + 2, v + 3, v, v + 1, v + 2 };
        self.indices.appendSlice(&indices) catch u.oom();
    }

    pub fn drawText(self: *Ui, chars: []u.Char, colors: []TextColor, top_left: Vec2, col_min: usize, col_max: usize) void {
        const font = self.screen.font;
        var pos = Vec2{ .x = top_left.x, .y = top_left.y + font.baseline };
        var col: usize = 0;

        for (chars) |char, i| {
            if (char != ' ' and char != '\n' and col_min <= col and col <= col_max) {
                const color = style.colors.PALETTE[@intCast(usize, @enumToInt(colors[i]))];
                self.drawChar(char, pos, font, color);
            }
            if (col_min <= col and col <= col_max) {
                pos.x += font.xadvance;
            }
            col += 1;
            if (char == '\n') {
                pos.x = top_left.x;
                pos.y += font.line_height;
                col = 0;
            }
        }
    }

    pub fn drawLabel(self: *Ui, chars: []const u.Char, top_left: Vec2, color: Color) void {
        const font = self.screen.font;
        var pos = Vec2{ .x = top_left.x, .y = top_left.y + font.baseline + 2 * self.screen.scale };
        for (chars) |char| {
            self.drawChar(char, pos, font, color);
            pos.x += font.xadvance;
        }
    }

    fn drawChar(self: *Ui, char: u.Char, pos: Vec2, font: Font, color: Color) void {
        var v = @intCast(u32, self.vertices.items.len);

        // Quad vertices in clockwise order, starting from top left
        const q = font.getQuad(char, pos.x, pos.y);
        const vertices = [_]Vertex{
            .{ .color = color, .vertex_type = .textured, .texcoord = .{ .x = q.s0, .y = q.t0 }, .pos = .{ .x = q.x0, .y = q.y0 } },
            .{ .color = color, .vertex_type = .textured, .texcoord = .{ .x = q.s1, .y = q.t0 }, .pos = .{ .x = q.x1, .y = q.y0 } },
            .{ .color = color, .vertex_type = .textured, .texcoord = .{ .x = q.s1, .y = q.t1 }, .pos = .{ .x = q.x1, .y = q.y1 } },
            .{ .color = color, .vertex_type = .textured, .texcoord = .{ .x = q.s0, .y = q.t1 }, .pos = .{ .x = q.x0, .y = q.y1 } },
        };
        self.vertices.appendSlice(&vertices) catch u.oom();

        // Indices: 0, 2, 3, 0, 1, 2
        const indices = [_]u32{ v, v + 2, v + 3, v, v + 1, v + 2 };
        self.indices.appendSlice(&indices) catch u.oom();
    }
};
