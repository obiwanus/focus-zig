const std = @import("std");
const vk = @import("vulkan");
const u = @import("utils.zig");

const Allocator = std.mem.Allocator;
const VulkanContext = @import("vulkan/context.zig").VulkanContext;

const MAX_VERTEX_COUNT = 100000;

pub const Ui = struct {
    vertices: std.ArrayList(Vertex), // TODO: use a primitive buffer instead
    indices: std.ArrayList(u32),

    vertex_buffer: vk.Buffer,
    vertex_buffer_memory: vk.DeviceMemory,
    index_buffer: vk.Buffer,
    index_buffer_memory: vk.DeviceMemory,

    pub const Vertex = extern struct {
        pos: u.Vec2,
        color: u.Color,

        pub const binding_description = vk.VertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .input_rate = .vertex,
        };

        pub const attribute_description = [_]vk.VertexInputAttributeDescription{
            .{
                .binding = 0,
                .location = 0,
                .format = .r32g32_sfloat,
                .offset = @offsetOf(Vertex, "pos"),
            },
            .{
                .binding = 0,
                .location = 1,
                .format = .r32g32b32a32_sfloat,
                .offset = @offsetOf(Vertex, "color"),
            },
        };
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

    pub fn reset(self: *Ui) void {
        self.vertices.shrinkRetainingCapacity(0);
        self.indices.shrinkRetainingCapacity(0);
    }

    pub fn indexCount(self: Ui) u32 {
        return @intCast(u32, self.indices.items.len);
    }

    pub fn drawRect(self: *Ui, x: usize, y: usize, width: usize, height: usize, color: u.Color) void {
        // Current vertex index
        const v = @intCast(u32, self.vertices.items.len);

        const l = @intToFloat(f32, x);
        const t = @intToFloat(f32, y);
        const w = @intToFloat(f32, width);
        const h = @intToFloat(f32, height);

        // Rect vertices in clockwise order, starting from top left
        const vertices = [_]Vertex{
            Vertex{ .pos = u.Vec2{ .x = l, .y = t }, .color = color },
            Vertex{ .pos = u.Vec2{ .x = l + w, .y = t }, .color = color },
            Vertex{ .pos = u.Vec2{ .x = l + w, .y = t + h }, .color = color },
            Vertex{ .pos = u.Vec2{ .x = l, .y = t + h }, .color = color },
        };
        self.vertices.appendSlice(&vertices) catch u.oom();

        // Indices: 0, 2, 1, 0, 1, 2
        const indices = [_]u32{ v, v + 2, v + 1, v, v + 1, v + 2 };
        self.indices.appendSlice(&indices) catch u.oom();
    }
};
