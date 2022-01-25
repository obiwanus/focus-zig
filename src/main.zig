const std = @import("std");

const glfw = @import("glfw");
const vk = @import("vulkan");
const resources = @import("resources");
const stbtt = @import("stbtt");

const Allocator = std.mem.Allocator;
const VulkanContext = @import("vulkan/context.zig").VulkanContext;
const Swapchain = @import("vulkan/swapchain.zig").Swapchain;

const APP_NAME = "Focus";

pub fn main() !void {
    try glfw.init(.{});
    defer glfw.terminate();

    const window = try glfw.Window.create(1000, 1000, APP_NAME, null, null, .{
        .client_api = .no_api,
        .focused = true,
        .maximized = true,
        .scale_to_monitor = true,
        .srgb_capable = true,
    });
    defer window.destroy();

    const size = try window.getSize();
    var extent = vk.Extent2D{
        .width = size.width,
        .height = size.height,
    };

    _ = stbtt.initFont(null, null, 0);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    const vc = try VulkanContext.init(allocator, APP_NAME, window);
    defer vc.deinit();

    var swapchain = try Swapchain.init(&vc, allocator, extent);
    defer swapchain.deinit();

    const pipeline_layout = try vc.vkd.createPipelineLayout(vc.dev, &.{
        .flags = .{},
        .set_layout_count = 0,
        .p_set_layouts = undefined,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    }, null);
    defer vc.vkd.destroyPipelineLayout(vc.dev, pipeline_layout, null);

    const render_pass = try createRenderPass(&vc, swapchain);
    defer vc.vkd.destroyRenderPass(vc.dev, render_pass, null);

    var pipeline = try createPipeline(&vc, pipeline_layout, render_pass);
    defer vc.vkd.destroyPipeline(vc.dev, pipeline, null);

    var framebuffers = try createFramebuffers(&vc, allocator, render_pass, swapchain);
    defer destroyFramebuffers(&vc, allocator, framebuffers);

    const pool = try vc.vkd.createCommandPool(vc.dev, &.{
        .flags = .{},
        .queue_family_index = vc.graphics_queue.family,
    }, null);
    defer vc.vkd.destroyCommandPool(vc.dev, pool, null);

    const buffer = try vc.vkd.createBuffer(vc.dev, &.{
        .flags = .{},
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    }, null);
    defer vc.vkd.destroyBuffer(vc.dev, buffer, null);
    const mem_reqs = vc.vkd.getBufferMemoryRequirements(vc.dev, buffer);
    const memory = try vc.allocate(mem_reqs, .{ .device_local_bit = true });
    defer vc.vkd.freeMemory(vc.dev, memory, null);
    try vc.vkd.bindBufferMemory(vc.dev, buffer, memory, 0);

    try uploadVertices(&vc, pool, buffer);

    var cmdbufs = try createCommandBuffers(
        &vc,
        pool,
        allocator,
        buffer,
        swapchain.extent,
        render_pass,
        pipeline,
        framebuffers,
    );
    defer destroyCommandBuffers(&vc, pool, allocator, cmdbufs);

    while (!window.shouldClose()) {
        const cmdbuf = cmdbufs[swapchain.image_index];

        const state = swapchain.present(cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        if (state == .suboptimal) {
            const new_size = try window.getSize();
            extent.width = new_size.width;
            extent.height = new_size.height;
            try swapchain.recreate(extent);

            destroyFramebuffers(&vc, allocator, framebuffers);
            framebuffers = try createFramebuffers(&vc, allocator, render_pass, swapchain);

            destroyCommandBuffers(&vc, pool, allocator, cmdbufs);
            cmdbufs = try createCommandBuffers(
                &vc,
                pool,
                allocator,
                buffer,
                swapchain.extent,
                render_pass,
                pipeline,
                framebuffers,
            );
        }

        try glfw.pollEvents();
    }

    try swapchain.waitForAllFences();
}

const Vertex = struct {
    pos: [2]f32,
    color: [3]f32,

    const binding_description = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    const attribute_description = [_]vk.VertexInputAttributeDescription{
        .{
            .binding = 0,
            .location = 0,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "pos"),
        },
        .{
            .binding = 0,
            .location = 1,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "color"),
        },
    };
};

const vertices = [_]Vertex{
    .{ .pos = .{ 0, -0.5 }, .color = .{ 1, 0, 0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0, 1, 0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0, 0, 1 } },
};

fn createRenderPass(vc: *const VulkanContext, swapchain: Swapchain) !vk.RenderPass {
    const color_attachment = vk.AttachmentDescription{
        .flags = .{},
        .format = swapchain.surface_format.format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .@"undefined",
        .final_layout = .present_src_khr,
    };

    const color_attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    const subpass = vk.SubpassDescription{
        .flags = .{},
        .pipeline_bind_point = .graphics,
        .input_attachment_count = 0,
        .p_input_attachments = undefined,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast([*]const vk.AttachmentReference, &color_attachment_ref),
        .p_resolve_attachments = null,
        .p_depth_stencil_attachment = null,
        .preserve_attachment_count = 0,
        .p_preserve_attachments = undefined,
    };

    return vc.vkd.createRenderPass(vc.dev, &.{
        .flags = .{},
        .attachment_count = 1,
        .p_attachments = @ptrCast([*]const vk.AttachmentDescription, &color_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast([*]const vk.SubpassDescription, &subpass),
        .dependency_count = 0,
        .p_dependencies = undefined,
    }, null);
}

fn createPipeline(vc: *const VulkanContext, layout: vk.PipelineLayout, render_pass: vk.RenderPass) !vk.Pipeline {
    const vert_module = try vc.vkd.createShaderModule(vc.dev, &.{
        .flags = .{},
        .code_size = resources.triangle_vert.len,
        .p_code = @ptrCast([*]const u32, resources.triangle_vert),
    }, null);
    defer vc.vkd.destroyShaderModule(vc.dev, vert_module, null);

    const frag_module = try vc.vkd.createShaderModule(vc.dev, &.{
        .flags = .{},
        .code_size = resources.triangle_frag.len,
        .p_code = @ptrCast([*]const u32, resources.triangle_frag),
    }, null);
    defer vc.vkd.destroyShaderModule(vc.dev, frag_module, null);

    const pssci = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .flags = .{},
            .stage = .{ .vertex_bit = true },
            .module = vert_module,
            .p_name = "main",
            .p_specialization_info = null,
        },
        .{
            .flags = .{},
            .stage = .{ .fragment_bit = true },
            .module = frag_module,
            .p_name = "main",
            .p_specialization_info = null,
        },
    };

    const pvisci = vk.PipelineVertexInputStateCreateInfo{
        .flags = .{},
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @ptrCast([*]const vk.VertexInputBindingDescription, &Vertex.binding_description),
        .vertex_attribute_description_count = Vertex.attribute_description.len,
        .p_vertex_attribute_descriptions = &Vertex.attribute_description,
    };

    const piasci = vk.PipelineInputAssemblyStateCreateInfo{
        .flags = .{},
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };

    const pvsci = vk.PipelineViewportStateCreateInfo{
        .flags = .{},
        .viewport_count = 1,
        .p_viewports = undefined, // set in createCommandBuffers with cmdSetViewport
        .scissor_count = 1,
        .p_scissors = undefined, // set in createCommandBuffers with cmdSetScissor
    };

    const prsci = vk.PipelineRasterizationStateCreateInfo{
        .flags = .{},
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };

    const pmsci = vk.PipelineMultisampleStateCreateInfo{
        .flags = .{},
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = vk.FALSE,
        .min_sample_shading = 1,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    const pcbas = vk.PipelineColorBlendAttachmentState{
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    const pcbsci = vk.PipelineColorBlendStateCreateInfo{
        .flags = .{},
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast([*]const vk.PipelineColorBlendAttachmentState, &pcbas),
        .blend_constants = [_]f32{ 0, 0, 0, 0 },
    };

    const dynstate = [_]vk.DynamicState{ .viewport, .scissor };
    const pdsci = vk.PipelineDynamicStateCreateInfo{
        .flags = .{},
        .dynamic_state_count = dynstate.len,
        .p_dynamic_states = &dynstate,
    };

    const gpci = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .stage_count = 2,
        .p_stages = &pssci,
        .p_vertex_input_state = &pvisci,
        .p_input_assembly_state = &piasci,
        .p_tessellation_state = null,
        .p_viewport_state = &pvsci,
        .p_rasterization_state = &prsci,
        .p_multisample_state = &pmsci,
        .p_depth_stencil_state = null,
        .p_color_blend_state = &pcbsci,
        .p_dynamic_state = &pdsci,
        .layout = layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try vc.vkd.createGraphicsPipelines(
        vc.dev,
        .null_handle,
        1,
        @ptrCast([*]const vk.GraphicsPipelineCreateInfo, &gpci),
        null,
        @ptrCast([*]vk.Pipeline, &pipeline),
    );

    return pipeline;
}

fn createFramebuffers(vc: *const VulkanContext, allocator: Allocator, render_pass: vk.RenderPass, swapchain: Swapchain) ![]vk.Framebuffer {
    const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.swap_images.len);
    errdefer allocator.free(framebuffers);

    var i: usize = 0;
    errdefer for (framebuffers[0..i]) |fb| vc.vkd.destroyFramebuffer(vc.dev, fb, null);

    for (framebuffers) |*fb| {
        fb.* = try vc.vkd.createFramebuffer(vc.dev, &.{
            .flags = .{},
            .render_pass = render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast([*]const vk.ImageView, &swapchain.swap_images[i].view),
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
            .layers = 1,
        }, null);
        i += 1;
    }

    return framebuffers;
}

fn destroyFramebuffers(vc: *const VulkanContext, allocator: Allocator, framebuffers: []const vk.Framebuffer) void {
    for (framebuffers) |fb| vc.vkd.destroyFramebuffer(vc.dev, fb, null);
    allocator.free(framebuffers);
}

fn uploadVertices(vc: *const VulkanContext, pool: vk.CommandPool, buffer: vk.Buffer) !void {
    const staging_buffer = try vc.vkd.createBuffer(vc.dev, &.{
        .flags = .{},
        .size = @sizeOf(@TypeOf(vertices)),
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

        const gpu_vertices = @ptrCast([*]Vertex, @alignCast(@alignOf(Vertex), data));
        for (vertices) |vertex, i| {
            gpu_vertices[i] = vertex;
        }
    }

    try copyBuffer(vc, pool, buffer, staging_buffer, @sizeOf(@TypeOf(vertices)));
}

fn copyBuffer(vc: *const VulkanContext, pool: vk.CommandPool, dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize) !void {
    var cmdbuf: vk.CommandBuffer = undefined;
    try vc.vkd.allocateCommandBuffers(vc.dev, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast([*]vk.CommandBuffer, &cmdbuf));
    defer vc.vkd.freeCommandBuffers(vc.dev, pool, 1, @ptrCast([*]const vk.CommandBuffer, &cmdbuf));

    try vc.vkd.beginCommandBuffer(cmdbuf, &.{
        .flags = .{ .one_time_submit_bit = true },
        .p_inheritance_info = null,
    });

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    vc.vkd.cmdCopyBuffer(cmdbuf, src, dst, 1, @ptrCast([*]const vk.BufferCopy, &region));

    try vc.vkd.endCommandBuffer(cmdbuf);

    const si = vk.SubmitInfo{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &cmdbuf),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    };
    try vc.vkd.queueSubmit(vc.graphics_queue.handle, 1, @ptrCast([*]const vk.SubmitInfo, &si), .null_handle);
    try vc.vkd.queueWaitIdle(vc.graphics_queue.handle);
}

fn createCommandBuffers(
    vc: *const VulkanContext,
    pool: vk.CommandPool,
    allocator: Allocator,
    buffer: vk.Buffer,
    extent: vk.Extent2D,
    render_pass: vk.RenderPass,
    pipeline: vk.Pipeline,
    framebuffers: []vk.Framebuffer,
) ![]vk.CommandBuffer {
    const cmdbufs = try allocator.alloc(vk.CommandBuffer, framebuffers.len);
    errdefer allocator.free(cmdbufs);

    try vc.vkd.allocateCommandBuffers(vc.dev, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = @truncate(u32, cmdbufs.len),
    }, cmdbufs.ptr);
    errdefer vc.vkd.freeCommandBuffers(vc.dev, pool, @truncate(u32, cmdbufs.len), cmdbufs.ptr);

    const clear = vk.ClearValue{
        .color = .{ .float_32 = .{ 0, 0, 0, 1 } },
    };

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @intToFloat(f32, extent.width),
        .height = @intToFloat(f32, extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };

    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    for (cmdbufs) |cmdbuf, i| {
        _ = i;
        try vc.vkd.beginCommandBuffer(cmdbuf, &.{
            .flags = .{},
            .p_inheritance_info = null,
        });

        vc.vkd.cmdSetViewport(cmdbuf, 0, 1, @ptrCast([*]const vk.Viewport, &viewport));
        vc.vkd.cmdSetScissor(cmdbuf, 0, 1, @ptrCast([*]const vk.Rect2D, &scissor));

        // This needs to be a separate definition - see https://github.com/ziglang/zig/issues/7627.
        const render_area = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        };

        vc.vkd.cmdBeginRenderPass(cmdbuf, &.{
            .render_pass = render_pass,
            .framebuffer = framebuffers[i],
            .render_area = render_area,
            .clear_value_count = 1,
            .p_clear_values = @ptrCast([*]const vk.ClearValue, &clear),
        }, .@"inline");

        vc.vkd.cmdBindPipeline(cmdbuf, .graphics, pipeline);
        const offset = [_]vk.DeviceSize{0};
        vc.vkd.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast([*]const vk.Buffer, &buffer), &offset);
        vc.vkd.cmdDraw(cmdbuf, vertices.len, 1, 0, 0);

        vc.vkd.cmdEndRenderPass(cmdbuf);
        try vc.vkd.endCommandBuffer(cmdbuf);
    }

    return cmdbufs;
}

fn destroyCommandBuffers(vc: *const VulkanContext, pool: vk.CommandPool, allocator: Allocator, cmdbufs: []vk.CommandBuffer) void {
    vc.vkd.freeCommandBuffers(vc.dev, pool, @truncate(u32, cmdbufs.len), cmdbufs.ptr);
    allocator.free(cmdbufs);
}
