const std = @import("std");
const vk = @import("vulkan");
const u = @import("utils.zig");
const vu = @import("vulkan/utils.zig");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Font = @import("fonts.zig").Font;
const VulkanContext = @import("vulkan/context.zig").VulkanContext;

const MAX_VERTEX_COUNT = 100000;

pub const Ui = struct {
    vertices: std.ArrayList(Vertex),
    indices: std.ArrayList(u32),

    vertex_buffer: vk.Buffer,
    vertex_buffer_memory: vk.DeviceMemory,
    index_buffer: vk.Buffer,
    index_buffer_memory: vk.DeviceMemory,

    const VertexType = enum(u32) {
        solid = 0,
        textured = 1,
        // yeah, the waste!
    };

    // #MEMORY: fat vertex. TODO: use a primitive buffer instead
    pub const Vertex = extern struct {
        color: u.Color,
        pos: u.Vec2,
        texcoord: u.Vec2,
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

    pub fn start_frame(self: *Ui) void {
        // Reset drawing data
        self.vertices.shrinkRetainingCapacity(0);
        self.indices.shrinkRetainingCapacity(0);
    }

    pub fn end_frame(self: Ui, vc: *const VulkanContext, pool: vk.CommandPool) !void {
        assert(self.vertices.items.len < MAX_VERTEX_COUNT);
        assert(self.indices.items.len < MAX_VERTEX_COUNT * 2);
        // Copy drawing data to GPU buffers
        try vu.uploadDataToBuffer(vc, Vertex, self.vertices.items, pool, self.vertex_buffer);
        try vu.uploadDataToBuffer(vc, u32, self.indices.items, pool, self.index_buffer);
    }

    pub fn indexCount(self: Ui) u32 {
        return @intCast(u32, self.indices.items.len);
    }

    pub fn drawSolidRect(self: *Ui, x: f32, y: f32, w: f32, h: f32, color: u.Color) void {
        // Current vertex index
        const v = @intCast(u32, self.vertices.items.len);

        // Rect vertices in clockwise order, starting from top left
        const vertices = [_]Vertex{
            Vertex{ .color = color, .vertex_type = .solid, .texcoord = undefined, .pos = u.Vec2{ .x = x, .y = y } },
            Vertex{ .color = color, .vertex_type = .solid, .texcoord = undefined, .pos = u.Vec2{ .x = x + w, .y = y } },
            Vertex{ .color = color, .vertex_type = .solid, .texcoord = undefined, .pos = u.Vec2{ .x = x + w, .y = y + h } },
            Vertex{ .color = color, .vertex_type = .solid, .texcoord = undefined, .pos = u.Vec2{ .x = x, .y = y + h } },
        };
        self.vertices.appendSlice(&vertices) catch u.oom();

        // Indices: 0, 2, 3, 0, 1, 2
        const indices = [_]u32{ v, v + 2, v + 3, v, v + 1, v + 2 };
        self.indices.appendSlice(&indices) catch u.oom();
    }

    pub fn drawLetter(self: *Ui, char: u.Codepoint, font: Font, x: usize, y: usize, width: usize, height: usize, color: u.Color) void {
        // Current vertex index
        const v = @intCast(u32, self.vertices.items.len);

        const l = @intToFloat(f32, x);
        const t = @intToFloat(f32, y);

        const q = font.getQuad(char, l, t);
        const scale = 1.0; // @intToFloat(f32, width) / font.xadvance;
        const w = (q.x1 - q.x0) * scale;
        const h = (q.y1 - q.y0) * scale;
        _ = width;
        _ = height;

        // const w = @intToFloat(f32, width);
        // const h = @intToFloat(f32, height);

        // Rect vertices in clockwise order, starting from top left
        const vertices = [_]Vertex{
            Vertex{ .color = color, .vertex_type = .textured, .texcoord = u.Vec2{ .x = q.s0, .y = q.t0 }, .pos = u.Vec2{ .x = l, .y = t } },
            Vertex{ .color = color, .vertex_type = .textured, .texcoord = u.Vec2{ .x = q.s1, .y = q.t0 }, .pos = u.Vec2{ .x = l + w, .y = t } },
            Vertex{ .color = color, .vertex_type = .textured, .texcoord = u.Vec2{ .x = q.s1, .y = q.t1 }, .pos = u.Vec2{ .x = l + w, .y = t + h } },
            Vertex{ .color = color, .vertex_type = .textured, .texcoord = u.Vec2{ .x = q.s0, .y = q.t1 }, .pos = u.Vec2{ .x = l, .y = t + h } },
        };
        self.vertices.appendSlice(&vertices) catch u.oom();

        // Indices: 0, 2, 3, 0, 1, 2
        const indices = [_]u32{ v, v + 2, v + 3, v, v + 1, v + 2 };
        self.indices.appendSlice(&indices) catch u.oom();
    }
};
