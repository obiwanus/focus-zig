const std = @import("std");
const vk = @import("vulkan");

const Vec2 = @import("../math.zig").Vec2;
const VulkanContext = @import("context.zig").VulkanContext;

pub const SingleTimeCommandBuffer = struct {
    vc: *const VulkanContext,
    pool: vk.CommandPool,
    buf: vk.CommandBuffer,

    pub fn create_and_begin(vc: *const VulkanContext, pool: vk.CommandPool) !SingleTimeCommandBuffer {
        var self: SingleTimeCommandBuffer = undefined;
        self.vc = vc;
        self.pool = pool;
        self.buf = x: {
            var buf: vk.CommandBuffer = undefined;
            try vc.vkd.allocateCommandBuffers(vc.dev, &.{
                .command_pool = pool,
                .level = .primary,
                .command_buffer_count = 1,
            }, @ptrCast([*]vk.CommandBuffer, &buf));
            errdefer vc.vkd.freeCommandBuffers(vc.dev, pool, 1, @ptrCast([*]const vk.CommandBuffer, &buf));
            break :x buf;
        };

        try vc.vkd.beginCommandBuffer(self.buf, &.{
            .flags = .{ .one_time_submit_bit = true },
            .p_inheritance_info = null,
        });

        return self;
    }

    pub fn free(self: SingleTimeCommandBuffer) !void {
        self.vc.vkd.freeCommandBuffers(self.vc.dev, self.pool, 1, @ptrCast([*]const vk.CommandBuffer, &self.buf));
    }

    pub fn submit_and_free(self: SingleTimeCommandBuffer) !void {
        // TODO: should we accept the queue as a parameter?
        const queue = self.vc.graphics_queue.handle;
        try self.vc.vkd.endCommandBuffer(self.buf);
        const si = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &self.buf),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        };
        try self.vc.vkd.queueSubmit(queue, 1, @ptrCast([*]const vk.SubmitInfo, &si), .null_handle);
        try self.vc.vkd.queueWaitIdle(queue);
        try self.free();
    }
};

pub fn transitionImageLayout(vc: *const VulkanContext, pool: vk.CommandPool, image: vk.Image, format: vk.Format, old: vk.ImageLayout, new: vk.ImageLayout) !void {
    _ = format; // ignoring for now

    const subresource_range = vk.ImageSubresourceRange{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
    var src_access_mask: vk.AccessFlags = undefined;
    var dst_access_mask: vk.AccessFlags = undefined;
    var src_stage_mask: vk.PipelineStageFlags = undefined;
    var dst_stage_mask: vk.PipelineStageFlags = undefined;
    if (old == .@"undefined" and new == .transfer_dst_optimal) {
        src_access_mask = .{};
        dst_access_mask = .{ .transfer_write_bit = true };
        src_stage_mask = .{ .top_of_pipe_bit = true };
        dst_stage_mask = .{ .transfer_bit = true };
    } else if (old == .transfer_dst_optimal and new == .shader_read_only_optimal) {
        src_access_mask = .{ .transfer_write_bit = true };
        dst_access_mask = .{ .shader_read_bit = true };
        src_stage_mask = .{ .transfer_bit = true };
        dst_stage_mask = .{ .fragment_shader_bit = true };
    } else {
        unreachable;
    }

    const image_barrier = vk.ImageMemoryBarrier{
        .src_access_mask = src_access_mask,
        .dst_access_mask = dst_access_mask,
        .old_layout = old,
        .new_layout = new,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = subresource_range,
    };

    const cmdbuf = try SingleTimeCommandBuffer.create_and_begin(vc, pool);

    vc.vkd.cmdPipelineBarrier(
        cmdbuf.buf,
        src_stage_mask,
        dst_stage_mask,
        .{},
        0,
        undefined,
        0,
        undefined,
        1,
        @ptrCast([*]const vk.ImageMemoryBarrier, &image_barrier),
    );

    try cmdbuf.submit_and_free();
}

pub fn copyBufferToImage(vc: *const VulkanContext, pool: vk.CommandPool, buffer: vk.Buffer, image: vk.Image, width: u32, height: u32) !void {
    const cmdbuf = try SingleTimeCommandBuffer.create_and_begin(vc, pool);

    const region = x: {
        const subresource = vk.ImageSubresourceLayers{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        };
        const offset = vk.Offset3D{
            .x = 0,
            .y = 0,
            .z = 0,
        };
        const extent = vk.Extent3D{
            .width = width,
            .height = height,
            .depth = 1,
        };
        break :x vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = subresource,
            .image_offset = offset,
            .image_extent = extent,
        };
    };

    vc.vkd.cmdCopyBufferToImage(
        cmdbuf.buf,
        buffer,
        image,
        .transfer_dst_optimal,
        1,
        @ptrCast([*]const vk.BufferImageCopy, &region),
    );

    try cmdbuf.submit_and_free();
}

pub fn copyBuffer(vc: *const VulkanContext, pool: vk.CommandPool, dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize) !void {
    const cmdbuf = try SingleTimeCommandBuffer.create_and_begin(vc, pool);

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    vc.vkd.cmdCopyBuffer(cmdbuf.buf, src, dst, 1, @ptrCast([*]const vk.BufferCopy, &region));

    try cmdbuf.submit_and_free();
}

pub const UniformBuffer = struct {
    data: Data,
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,

    const Data = extern struct {
        screen_size: Vec2,
        panel_topleft: Vec2,
        cursor_size: Vec2,
        cursor_advance: Vec2,
    };

    pub fn init(vc: *const VulkanContext, extent: vk.Extent2D, panel_topleft: Vec2, cursor_size: Vec2, cursor_advance: Vec2) !UniformBuffer {
        const buffer = try vc.vkd.createBuffer(vc.dev, &.{
            .flags = .{},
            .size = @sizeOf(UniformBuffer.Data),
            .usage = .{ .uniform_buffer_bit = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
        }, null);
        errdefer vc.vkd.destroyBuffer(vc.dev, buffer, null);
        const mem_reqs = vc.vkd.getBufferMemoryRequirements(vc.dev, buffer);
        const memory = try vc.allocate(mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
        try vc.vkd.bindBufferMemory(vc.dev, buffer, memory, 0);

        const screen_size = Vec2{
            .x = @intToFloat(f32, extent.width),
            .y = @intToFloat(f32, extent.height),
        };

        return UniformBuffer{
            .data = Data{
                .screen_size = screen_size,
                .panel_topleft = panel_topleft,
                .cursor_size = cursor_size,
                .cursor_advance = cursor_advance,
            },
            .buffer = buffer,
            .memory = memory,
        };
    }

    pub fn sendToGPU(self: UniformBuffer, vc: *const VulkanContext) !void {
        const mapped_data = try vc.vkd.mapMemory(vc.dev, self.memory, 0, vk.WHOLE_SIZE, .{});
        defer vc.vkd.unmapMemory(vc.dev, self.memory);
        const data = @ptrCast(*Data, @alignCast(@alignOf(Data), mapped_data));
        data.* = self.data;
    }

    pub fn deinit(self: UniformBuffer, vc: *const VulkanContext) void {
        vc.vkd.destroyBuffer(vc.dev, self.buffer, null);
        vc.vkd.freeMemory(vc.dev, self.memory, null);
    }
};
