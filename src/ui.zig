const std = @import("std");
const vk = @import("vulkan");

const focus = @import("focus.zig");
const u = focus.utils;
const vu = focus.vulkan.utils;
const style = focus.style;

const Allocator = std.mem.Allocator;
const Font = focus.fonts.Font;
const VulkanContext = focus.vulkan.context.VulkanContext;
const Editor = focus.editor.Editor;
const TextColor = style.TextColor;
const Color = style.Color;
const Vec2 = u.Vec2;
const Rect = u.Rect;
const OpenFileDialog = focus.dialogs.OpenFile;

// Probably temporary - this is just to preallocate buffers on the GPU
// and not worry about more sophisticated allocation strategies
const MAX_VERTEX_COUNT = 100000;

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

    pub fn drawEditor(self: *Ui, editor: Editor, rect: Rect, is_active: bool) void {
        const font = self.screen.font;

        // How many lines/cols fit inside the rect
        const total_lines = @floatToInt(usize, rect.h / font.line_height);
        const total_cols = @floatToInt(usize, rect.w / font.xadvance);

        // First and last visible lines
        // TODO: check how it behaves when scale changes
        const line_min = @floatToInt(usize, editor.scroll.y / font.line_height) -| 1;
        var line_max = line_min + total_lines + 3;
        if (line_max >= editor.lines.items.len) {
            line_max = editor.lines.items.len - 1;
        }
        const col_min = @floatToInt(usize, editor.scroll.x / font.xadvance);
        const col_max = col_min + total_cols;

        // Offset from canonical position (for smooth scrolling)
        const offset = Vec2{
            .x = editor.scroll.x - @intToFloat(f32, col_min) * font.xadvance,
            .y = editor.scroll.y - @intToFloat(f32, line_min) * font.line_height,
        };

        const start_char = editor.lines.items[line_min];
        const end_char = editor.lines.items[line_max];

        const chars = editor.chars.items[start_char..end_char];
        const colors = editor.colors.items[start_char..end_char];
        const top_left = Vec2{ .x = rect.x - offset.x, .y = rect.y - offset.y };

        // Draw cursor first
        const size = Vec2{ .x = font.xadvance, .y = font.letter_height };
        const advance = Vec2{ .x = font.xadvance, .y = font.line_height };
        const padding = Vec2{ .x = 0, .y = 4 };
        const cursor_offset = Vec2{
            .x = @intToFloat(f32, editor.cursor.col),
            .y = @intToFloat(f32, editor.cursor.line -| line_min),
        };
        const highlight_rect = Rect{
            .x = rect.x - 4,
            .y = rect.y - offset.y + cursor_offset.y * advance.y - padding.y,
            .w = rect.w + 8,
            .h = size.y + 2 * padding.y,
        };
        self.drawSolidRect(highlight_rect, style.colors.BACKGROUND_HIGHLIGHT);
        const cursor_rect = Rect{
            .x = rect.x - offset.x + cursor_offset.x * advance.x - padding.x,
            .y = rect.y - offset.y + cursor_offset.y * advance.y - padding.y,
            .w = size.x + 2 * padding.x,
            .h = size.y + 2 * padding.y,
        };
        const color = if (is_active) style.colors.CURSOR_ACTIVE else style.colors.CURSOR_INACTIVE;
        self.drawSolidRect(cursor_rect, color);

        // Then draw text on top
        self.drawText(chars, colors, top_left, col_min, col_max);
    }

    pub fn drawOpenFileDialog(self: *Ui, dialog: *OpenFileDialog, tmp_allocator: Allocator) void {
        var dir = dialog.getCurrentDir();
        const scale = self.screen.scale;
        const font = self.screen.font;

        const min_width = 500 * scale;
        const max_width = 1500 * scale;
        const max_height = 800 * scale;

        const screen = self.screen.getRect();
        const width = std.math.clamp(screen.w / 4, min_width, max_width);
        var dialog_rect = Rect{ .x = (screen.w - width) / 2, .y = 100, .w = width, .h = max_height };

        // Determine the height of the dialog box
        const margin = 10 * scale;
        const padding = 5 * scale;
        const input_rect_height = font.line_height + 2 * padding + 2 * margin + 2;
        const entry_height = font.line_height + 2 * padding;
        const max_entries = @floatToInt(usize, dialog_rect.h / entry_height);

        const filtered_entries = dir.filteredEntries(dialog.filter_text.items, tmp_allocator);
        const num_entries = std.math.clamp(1, filtered_entries.len, max_entries);

        const actual_height = entry_height * @intToFloat(f32, num_entries) + input_rect_height;
        dialog_rect.h = actual_height;

        // Draw background
        self.drawSolidRectWithShadow(
            dialog_rect,
            style.colors.BACKGROUND_LIGHT,
            10,
        );

        const adjust_y = 2 * scale; // to align text within boxes

        // Draw input box
        var input_rect = dialog_rect.splitTop(input_rect_height, 0).shrinkEvenly(margin);
        self.drawSolidRect(input_rect, style.colors.BACKGROUND_DARK);
        input_rect = input_rect.shrinkEvenly(1);
        self.drawSolidRect(input_rect, style.colors.BACKGROUND);
        input_rect = input_rect.shrinkEvenly(padding);
        self.drawLabel(dialog.filter_text.items, .{ .x = input_rect.x, .y = input_rect.y + adjust_y }, style.colors.DEFAULT);
        const cursor_rect = Rect{
            .x = input_rect.x + @intToFloat(f32, dialog.filter_text.items.len) * font.xadvance,
            .y = input_rect.y,
            .w = font.xadvance,
            .h = font.line_height,
        };
        self.drawSolidRect(cursor_rect, style.colors.CURSOR_ACTIVE);

        // Draw entries
        for (filtered_entries) |entry, i| {
            const r = Rect{
                .x = dialog_rect.x,
                .y = dialog_rect.y + @intToFloat(f32, i) * entry_height,
                .w = dialog_rect.w,
                .h = entry_height,
            };
            if (i == dir.selected) {
                self.drawSolidRect(r, style.colors.BACKGROUND_BRIGHT);
            }
            const name = u.bytesToChars(entry.getName(), tmp_allocator) catch unreachable;
            self.drawLabel(
                name,
                Vec2{ .x = r.x + margin + padding, .y = r.y + padding + adjust_y },
                style.colors.PUNCTUATION,
            );
        }

        // Draw placeholder if no entries are present
        if (filtered_entries.len == 0) {
            dialog_rect = dialog_rect.shrink(margin + padding, padding, 0, padding);
            const placeholder = u.bytesToChars("...", tmp_allocator) catch unreachable;
            self.drawLabel(placeholder, .{ .x = dialog_rect.x, .y = dialog_rect.y + adjust_y }, style.colors.COMMENT);
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

    pub fn drawSolidRectWithShadow(self: *Ui, r: Rect, color: Color, shadow_size: f32) void {
        const size = shadow_size * self.screen.scale;
        const dark = Color{ .r = 0, .g = 0, .b = 0, .a = 0.2 };
        const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const pi = std.math.pi;

        // Draw main shadows
        self.drawRect(Rect{ .x = r.x, .y = r.y - size, .w = r.w, .h = size }, transparent, transparent, dark, dark); // top
        self.drawRect(Rect{ .x = r.x, .y = r.y + r.h, .w = r.w, .h = size }, dark, dark, transparent, transparent); // bottom
        self.drawRect(Rect{ .x = r.x - size, .y = r.y, .w = size, .h = r.h }, transparent, dark, dark, transparent); // left
        self.drawRect(Rect{ .x = r.x + r.w, .y = r.y, .w = size, .h = r.h }, dark, transparent, transparent, dark); // right

        // Draw corners
        self.drawCircularShadow(.{ .x = r.x + r.w, .y = r.y }, size, pi / 2.0, pi, dark);
        self.drawCircularShadow(.{ .x = r.x, .y = r.y }, size, pi, 3 * pi / 2.0, dark);
        self.drawCircularShadow(.{ .x = r.x, .y = r.y + r.h }, size, 3 * pi / 2.0, 2.0 * pi, dark);
        self.drawCircularShadow(.{ .x = r.x + r.w, .y = r.y + r.h }, size, 0, pi / 2.0, dark);

        self.drawSolidRect(r, color);
    }

    fn drawCircularShadow(self: *Ui, center: Vec2, radius: f32, start_angle: f32, end_angle: f32, dark: Color) void {
        const v = @intCast(u32, self.vertices.items.len);
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

    fn drawText(self: *Ui, chars: []u.Char, colors: []TextColor, top_left: Vec2, col_min: usize, col_max: usize) void {
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

    fn drawLabel(self: *Ui, chars: []u.Char, top_left: Vec2, color: Color) void {
        const font = self.screen.font;
        var pos = Vec2{ .x = top_left.x, .y = top_left.y + font.baseline };
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
