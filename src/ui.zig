const std = @import("std");
const vk = @import("vulkan");
const u = @import("utils.zig");
const vu = @import("vulkan/utils.zig");
const style = @import("style.zig");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Font = @import("fonts.zig").Font;
const VulkanContext = @import("vulkan/context.zig").VulkanContext;
const Editor = @import("editor.zig").Editor;
const TextColor = style.TextColor;
const Color = style.Color;
const Vec2 = u.Vec2;
const Rect = u.Rect;

// Probably temporary - this is just to preallocate buffers on the GPU
// and not worry about more sophisticated allocation strategies
const MAX_VERTEX_COUNT = 100000;

// Margins in pixels for scale = 1.0
const MARGIN_VERTICAL = 15;
const MARGIN_HORIZONTAL = 30;

pub const Screen = struct {
    size: vk.Extent2D,
    scale: f32,
    font: Font,

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
        assert(self.vertices.items.len < MAX_VERTEX_COUNT);
        assert(self.indices.items.len < MAX_VERTEX_COUNT * 2);
        // Copy drawing data to GPU buffers
        try vu.uploadDataToBuffer(vc, Vertex, self.vertices.items, pool, self.vertex_buffer);
        try vu.uploadDataToBuffer(vc, u32, self.indices.items, pool, self.index_buffer);
    }

    pub fn indexCount(self: Ui) u32 {
        return @intCast(u32, self.indices.items.len);
    }

    pub fn drawEditors(self: *Ui, editor1: Editor, editor2: Editor, active_editor: *const Editor) Rect {
        // Figure out where to draw editors
        const margin_h = MARGIN_HORIZONTAL * self.screen.scale;
        const margin_v = MARGIN_VERTICAL * self.screen.scale;
        const editor_width = (@intToFloat(f32, self.screen.size.width) - 3 * margin_h) / 2;
        const editor_height = @intToFloat(f32, self.screen.size.height) - 2 * margin_v;

        const rect1 = Rect{
            .x = margin_h,
            .y = margin_v,
            .w = editor_width,
            .h = editor_height,
        };
        const rect2 = Rect{
            .x = margin_h + editor_width + margin_h,
            .y = margin_v,
            .w = editor_width,
            .h = editor_height,
        };

        // Draw editors in the corresponding rects
        self.drawEditor(editor1, rect1, active_editor == &editor1);
        self.drawEditor(editor2, rect2, active_editor == &editor2);

        // Return editor dimensions so we can adjust their internal data
        // (assuming the two rects have the same dimensions)
        return rect1;
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

        self.drawText(chars, colors, top_left, col_min, col_max);

        // Draw cursor
        const size = Vec2{ .x = font.xadvance, .y = font.letter_height };
        const advance = Vec2{ .x = font.xadvance, .y = font.line_height };
        const padding = Vec2{ .x = 0, .y = 4 };
        const cursor_offset = Vec2{
            .x = @intToFloat(f32, editor.cursor.col),
            .y = @intToFloat(f32, editor.cursor.line -| line_min),
        };
        const cursor_rect = Rect{
            .x = rect.x - offset.x + cursor_offset.x * advance.x - padding.x,
            .y = rect.y - offset.y + cursor_offset.y * advance.y - padding.y,
            .w = size.x + 2 * padding.x,
            .h = size.y + 2 * padding.y,
        };
        const color = if (is_active) style.Colors.CURSOR_ACTIVE else style.Colors.CURSOR_INACTIVE;
        self.drawSolidRect(cursor_rect, color);
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
            style.Colors.BACKGROUND_LIGHT,
        );
        var buf: [10]u8 = undefined;
        _ = std.fmt.bufPrint(buf[0..], "{d:10}", .{frame_number}) catch unreachable;
        var chars: [10]u.Codepoint = undefined;
        var colors: [10]TextColor = undefined;
        for (buf) |char, i| {
            chars[i] = char;
            colors[i] = .keyword;
        }
        // TODO: write a more convenient method for drawing debug stuff
        self.drawText(chars[0..], colors[0..], Vec2{ .x = screen_x - margin - padding - width, .y = margin + padding }, 0, 10);
    }

    // ----------------------------------------------------------------------------------------------------------------

    pub fn drawSolidRect(self: *Ui, r: Rect, color: Color) void {
        // Current vertex index
        const v = @intCast(u32, self.vertices.items.len);

        // Rect vertices in clockwise order, starting from top left
        const vertices = [_]Vertex{
            .{ .color = color, .vertex_type = .solid, .texcoord = undefined, .pos = .{ .x = r.x, .y = r.y } },
            .{ .color = color, .vertex_type = .solid, .texcoord = undefined, .pos = .{ .x = r.x + r.w, .y = r.y } },
            .{ .color = color, .vertex_type = .solid, .texcoord = undefined, .pos = .{ .x = r.x + r.w, .y = r.y + r.h } },
            .{ .color = color, .vertex_type = .solid, .texcoord = undefined, .pos = .{ .x = r.x, .y = r.y + r.h } },
        };
        self.vertices.appendSlice(&vertices) catch u.oom();

        // Indices: 0, 2, 3, 0, 1, 2
        const indices = [_]u32{ v, v + 2, v + 3, v, v + 1, v + 2 };
        self.indices.appendSlice(&indices) catch u.oom();
    }

    fn drawText(self: *Ui, chars: []u.Codepoint, colors: []TextColor, top_left: Vec2, col_min: usize, col_max: usize) void {
        const font = self.screen.font;
        var pos = Vec2{ .x = top_left.x, .y = top_left.y + font.baseline };
        var col: usize = 0;

        // Current vertex index
        var v = @intCast(u32, self.vertices.items.len);

        for (chars) |char, i| {
            if (char != ' ' and char != '\n' and col_min <= col and col <= col_max) {
                const q = font.getQuad(char, pos.x, pos.y);
                const color = style.Colors.PALETTE[@intCast(usize, @enumToInt(colors[i]))];

                // Quad vertices in clockwise order, starting from top left
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

                v += 4;
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
};
