const std = @import("std");
const vk = @import("vulkan");

const focus = @import("../focus.zig");
const u = focus.utils;

const Allocator = std.mem.Allocator;
const VulkanContext = focus.vulkan.context.VulkanContext;
const Vec2 = u.Vec2;

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

    pub fn submit_and_free(self: SingleTimeCommandBuffer, queue: vk.Queue) !void {
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

pub fn transitionImageLayout(vc: *const VulkanContext, pool: vk.CommandPool, image: vk.Image, old: vk.ImageLayout, new: vk.ImageLayout) !void {
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

    try cmdbuf.submit_and_free(vc.graphics_queue.handle);
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

    try cmdbuf.submit_and_free(vc.graphics_queue.handle);
}

pub fn copyBuffer(vc: *const VulkanContext, pool: vk.CommandPool, dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize) !void {
    const cmdbuf = try SingleTimeCommandBuffer.create_and_begin(vc, pool);

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    vc.vkd.cmdCopyBuffer(cmdbuf.buf, src, dst, 1, @ptrCast([*]const vk.BufferCopy, &region));

    try cmdbuf.submit_and_free(vc.graphics_queue.handle);
}

pub const UniformBuffer = struct {
    data: Data,

    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    descriptor_pool: vk.DescriptorPool,
    descriptor_set: vk.DescriptorSet,
    descriptor_set_layout: vk.DescriptorSetLayout,

    const Data = extern struct {
        screen_size: Vec2,
        // used to be more data
    };

    pub fn init(vc: *const VulkanContext, extent: vk.Extent2D) !UniformBuffer {
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

        // This descriptor pool will be used just for the uniform buffer descriptor
        // TODO: most likely this is not how it's intended to be used, but should do for our case
        const descriptor_pool = x: {
            const pool_sizes = [_]vk.DescriptorPoolSize{
                .{
                    .@"type" = .uniform_buffer,
                    .descriptor_count = 1,
                },
            };
            break :x try vc.vkd.createDescriptorPool(vc.dev, &.{
                .flags = .{},
                .max_sets = 1,
                .pool_size_count = pool_sizes.len,
                .p_pool_sizes = &pool_sizes,
            }, null);
        };
        errdefer vc.vkd.destroyDescriptorPool(vc.dev, descriptor_pool, null);

        // Descriptor set layout
        const descriptor_set_layout_bindings = [_]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptor_type = .uniform_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .vertex_bit = true },
                .p_immutable_samplers = null,
            },
        };
        const descriptor_set_layout = try vc.vkd.createDescriptorSetLayout(vc.dev, &.{
            .flags = .{},
            .binding_count = descriptor_set_layout_bindings.len,
            .p_bindings = &descriptor_set_layout_bindings,
        }, null);
        errdefer vc.vkd.destroyDescriptorSetLayout(vc.dev, descriptor_set_layout, null);

        // Allocate descriptor sets
        var descriptor_set: vk.DescriptorSet = undefined;
        try vc.vkd.allocateDescriptorSets(vc.dev, &.{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &descriptor_set_layout),
        }, @ptrCast([*]vk.DescriptorSet, &descriptor_set));

        // Set the uniform buffer to the appropriate descriptor
        {
            const buffer_info = vk.DescriptorBufferInfo{
                .buffer = buffer,
                .offset = 0,
                .range = @sizeOf(Data), // Can probably use vk.WHOLE_SIZE?
            };
            const descriptor_writes = [_]vk.WriteDescriptorSet{
                .{
                    .dst_set = descriptor_set,
                    .dst_binding = 0,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .uniform_buffer,
                    .p_image_info = undefined,
                    .p_buffer_info = @ptrCast([*]const vk.DescriptorBufferInfo, &buffer_info),
                    .p_texel_buffer_view = undefined,
                },
            };
            vc.vkd.updateDescriptorSets(vc.dev, descriptor_writes.len, &descriptor_writes, 0, undefined);
        }

        return UniformBuffer{
            .data = Data{
                .screen_size = screen_size,
            },
            .buffer = buffer,
            .memory = memory,
            .descriptor_pool = descriptor_pool,
            .descriptor_set = descriptor_set,
            .descriptor_set_layout = descriptor_set_layout,
        };
    }

    pub fn copyToGPU(self: UniformBuffer, vc: *const VulkanContext) !void {
        const mapped_data = try vc.vkd.mapMemory(vc.dev, self.memory, 0, vk.WHOLE_SIZE, .{});
        defer vc.vkd.unmapMemory(vc.dev, self.memory);
        const data = @ptrCast(*Data, @alignCast(@alignOf(Data), mapped_data));
        data.* = self.data;
    }

    pub fn deinit(self: UniformBuffer, vc: *const VulkanContext) void {
        vc.vkd.destroyBuffer(vc.dev, self.buffer, null);
        vc.vkd.freeMemory(vc.dev, self.memory, null);
        vc.vkd.destroyDescriptorSetLayout(vc.dev, self.descriptor_set_layout, null);
        vc.vkd.destroyDescriptorPool(vc.dev, self.descriptor_pool, null);
    }
};

pub fn destroyFramebuffers(vc: *const VulkanContext, allocator: Allocator, framebuffers: []const vk.Framebuffer) void {
    for (framebuffers) |fb| vc.vkd.destroyFramebuffer(vc.dev, fb, null);
    allocator.free(framebuffers);
}

pub fn uploadDataToBuffer(vc: *const VulkanContext, comptime Data: type, src_array: []const Data, pool: vk.CommandPool, buffer: vk.Buffer) !void {
    if (src_array.len == 0) {
        return;
    }
    const buffer_size = @sizeOf(Data) * src_array.len;
    const staging_buffer = try vc.vkd.createBuffer(vc.dev, &.{
        .flags = .{},
        .size = buffer_size,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    }, null);
    defer vc.vkd.destroyBuffer(vc.dev, staging_buffer, null);
    const mem_reqs = vc.vkd.getBufferMemoryRequirements(vc.dev, staging_buffer);
    const staging_memory = try vc.allocate(mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer vc.vkd.freeMemory(vc.dev, staging_memory, null);
    try vc.vkd.bindBufferMemory(vc.dev, staging_buffer, staging_memory, 0);

    {
        const data = try vc.vkd.mapMemory(vc.dev, staging_memory, 0, vk.WHOLE_SIZE, .{});
        defer vc.vkd.unmapMemory(vc.dev, staging_memory);

        const gpu_vertices = @ptrCast([*]Data, @alignCast(@alignOf(Data), data));
        std.mem.copy(Data, gpu_vertices[0..src_array.len], src_array);
    }

    try copyBuffer(vc, pool, buffer, staging_buffer, buffer_size);
}
