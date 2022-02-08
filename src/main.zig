const std = @import("std");
const builtin = @import("builtin");

const glfw = @import("glfw");
const vk = @import("vulkan");
const resources = @import("resources");
const stbi = @import("stbi");

const fonts = @import("fonts.zig");

const Allocator = std.mem.Allocator;
const VulkanContext = @import("vulkan/context.zig").VulkanContext;
const Swapchain = @import("vulkan/swapchain.zig").Swapchain;

var GPA = std.heap.GeneralPurposeAllocator(.{ .never_unmap = false }){};

const APP_NAME = "Focus";

var text_start: Vec2 = .{ .x = 50, .y = 50 };

pub fn main() !void {
    // Static arena lives until the end of the program
    var static_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer static_arena.deinit();
    var static_allocator = static_arena.allocator();

    // General-purpose allocator for things that live for more than 1 frame
    // but need to be freed before the end of the program
    const gpa = if (builtin.mode == .Debug) GPA.allocator() else std.heap.c_allocator;

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

    window.setKeyCallback(processKeyEvent);

    const size = try window.getSize();
    var extent = vk.Extent2D{
        .width = size.width,
        .height = size.height,
    };

    const vc = try VulkanContext.init(static_allocator, APP_NAME, window);
    defer vc.deinit();

    var swapchain = try Swapchain.init(&vc, static_allocator, extent);
    defer swapchain.deinit();

    const pool = try vc.vkd.createCommandPool(vc.dev, &.{
        .flags = .{},
        .queue_family_index = vc.graphics_queue.family,
    }, null);
    defer vc.vkd.destroyCommandPool(vc.dev, pool, null);

    // TMP pack fonts into a texture
    const font = try fonts.getPackedFont(gpa, "fonts/consola.ttf", 16);
    const texture_image = try createFontTextureImage(&vc, font.pixels, font.atlas_width, font.atlas_height, pool);
    defer texture_image.deinit(&vc);

    std.debug.print("{any}", .{extent});

    var current_text_start = Vec2{ .x = 50, .y = 50 };
    var vertices = try get_vertices_tmp(font, current_text_start, gpa);

    const texture_image_view = try createTextureImageView(&vc, texture_image.image, .r8g8b8a8_srgb);
    defer vc.vkd.destroyImageView(vc.dev, texture_image_view, null);
    const texture_sampler = try vc.vkd.createSampler(vc.dev, &.{
        .flags = .{},
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .mip_lod_bias = 0,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = 1,
        .compare_enable = vk.FALSE,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = vk.FALSE,
    }, null);
    defer vc.vkd.destroySampler(vc.dev, texture_sampler, null);

    const descriptor_set_layout_bindings = [_]vk.DescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
            .p_immutable_samplers = null,
        },
    };
    const descriptor_set_layout = try vc.vkd.createDescriptorSetLayout(vc.dev, &.{
        .flags = .{},
        .binding_count = descriptor_set_layout_bindings.len,
        .p_bindings = &descriptor_set_layout_bindings,
    }, null);
    defer vc.vkd.destroyDescriptorSetLayout(vc.dev, descriptor_set_layout, null);

    const descriptor_pool_sizes = [_]vk.DescriptorPoolSize{
        .{
            .@"type" = .combined_image_sampler,
            .descriptor_count = 1,
        },
    };
    // NOTE: we'll create only one set per layout
    const set_layouts = [_]vk.DescriptorSetLayout{
        descriptor_set_layout,
    };
    const descriptor_pool = try vc.vkd.createDescriptorPool(vc.dev, &.{
        .flags = .{},
        .max_sets = set_layouts.len,
        .pool_size_count = descriptor_pool_sizes.len,
        .p_pool_sizes = &descriptor_pool_sizes,
    }, null);
    defer vc.vkd.destroyDescriptorPool(vc.dev, descriptor_pool, null);

    var descriptor_sets: [set_layouts.len]vk.DescriptorSet = undefined;
    try vc.vkd.allocateDescriptorSets(vc.dev, &.{
        .descriptor_pool = descriptor_pool,
        .descriptor_set_count = set_layouts.len,
        .p_set_layouts = &set_layouts,
    }, &descriptor_sets);

    std.debug.assert(descriptor_sets.len == 1); // only one for now
    const descriptor_set = descriptor_sets[0];
    const image_info = [_]vk.DescriptorImageInfo{
        .{
            .sampler = texture_sampler,
            .image_view = texture_image_view,
            .image_layout = .shader_read_only_optimal,
        },
    };
    const descriptor_writes = [_]vk.WriteDescriptorSet{
        .{
            .dst_set = descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = &image_info,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
    };
    vc.vkd.updateDescriptorSets(vc.dev, descriptor_writes.len, &descriptor_writes, 0, undefined);

    const pipeline_layout = try vc.vkd.createPipelineLayout(vc.dev, &.{
        .flags = .{},
        .set_layout_count = set_layouts.len,
        .p_set_layouts = &set_layouts,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    }, null);
    defer vc.vkd.destroyPipelineLayout(vc.dev, pipeline_layout, null);

    const render_pass = try createRenderPass(&vc, swapchain.surface_format.format);
    defer vc.vkd.destroyRenderPass(vc.dev, render_pass, null);

    var pipeline = try createPipeline(&vc, pipeline_layout, render_pass);
    defer vc.vkd.destroyPipeline(vc.dev, pipeline, null);

    var framebuffers = try createFramebuffers(&vc, gpa, render_pass, swapchain);
    defer destroyFramebuffers(&vc, gpa, framebuffers);

    const buffer = try vc.vkd.createBuffer(vc.dev, &.{
        .flags = .{},
        .size = @sizeOf(Vertex) * vertices.len,
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

    try uploadVertices(&vc, vertices, pool, buffer);

    var cmdbufs = try createCommandBuffers(
        &vc,
        pool,
        gpa,
        buffer,
        swapchain.extent,
        render_pass,
        pipeline,
        framebuffers,
        descriptor_sets[0..1],
        pipeline_layout,
        vertices.len,
    );
    defer destroyCommandBuffers(&vc, pool, gpa, cmdbufs);

    while (!window.shouldClose()) {
        const cmdbuf = cmdbufs[swapchain.image_index];

        if (text_start.y != current_text_start.y) {
            current_text_start = text_start;
            gpa.free(vertices);
            vertices = try get_vertices_tmp(font, current_text_start, gpa);
            try uploadVertices(&vc, vertices, pool, buffer);
        }

        const state = swapchain.present(cmdbuf) catch |err| switch (err) {
            error.OutOfDateKHR => Swapchain.PresentState.suboptimal,
            else => |narrow| return narrow,
        };

        if (state == .suboptimal) {
            const new_size = try window.getSize();
            extent.width = new_size.width;
            extent.height = new_size.height;
            try swapchain.recreate(extent);

            destroyFramebuffers(&vc, gpa, framebuffers);
            framebuffers = try createFramebuffers(&vc, gpa, render_pass, swapchain);

            destroyCommandBuffers(&vc, pool, gpa, cmdbufs);
            cmdbufs = try createCommandBuffers(
                &vc,
                pool,
                gpa,
                buffer,
                swapchain.extent,
                render_pass,
                pipeline,
                framebuffers,
                descriptor_sets[0..1],
                pipeline_layout,
                vertices.len,
            );
        }

        try glfw.waitEvents();
    }

    try swapchain.waitForAllFences();
    try vc.vkd.queueWaitIdle(vc.graphics_queue.handle);
}

const VulkanImage = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,

    fn deinit(self: VulkanImage, vc: *const VulkanContext) void {
        vc.vkd.freeMemory(vc.dev, self.memory, null);
        vc.vkd.destroyImage(vc.dev, self.image, null);
    }
};

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

fn createFontTextureImage(vc: *const VulkanContext, pixels: []u8, width: u32, height: u32, pool: vk.CommandPool) !VulkanImage {
    // Create a staging buffer
    const staging_buffer = try vc.vkd.createBuffer(vc.dev, &.{
        .flags = .{},
        .size = pixels.len,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    }, null);
    defer vc.vkd.destroyBuffer(vc.dev, staging_buffer, null);
    const staging_mem_reqs = vc.vkd.getBufferMemoryRequirements(vc.dev, staging_buffer);
    const staging_memory = try vc.allocate(staging_mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer vc.vkd.freeMemory(vc.dev, staging_memory, null);
    try vc.vkd.bindBufferMemory(vc.dev, staging_buffer, staging_memory, 0);

    const data = try vc.vkd.mapMemory(vc.dev, staging_memory, 0, vk.WHOLE_SIZE, .{});
    defer vc.vkd.unmapMemory(vc.dev, staging_memory);

    const image_data_dst = @ptrCast([*]u8, data)[0..pixels.len];
    std.mem.copy(u8, image_data_dst, pixels);

    // Create an image
    const image_extent = vk.Extent3D{ // has to be separate, triggers segmentation fault otherwise
        .width = @intCast(u32, width),
        .height = @intCast(u32, height),
        .depth = 1,
    };
    const texture_image = try vc.vkd.createImage(vc.dev, &.{
        .flags = .{},
        .image_type = .@"2d",
        .format = .r8g8b8a8_srgb,
        .extent = image_extent,
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .initial_layout = .@"undefined",
    }, null);
    errdefer vc.vkd.destroyImage(vc.dev, texture_image, null);

    const mem_reqs = vc.vkd.getImageMemoryRequirements(vc.dev, texture_image);
    const memory = try vc.allocate(mem_reqs, .{ .device_local_bit = true });
    errdefer vc.vkd.freeMemory(vc.dev, memory, null);
    try vc.vkd.bindImageMemory(vc.dev, texture_image, memory, 0);

    // Copy buffer data to image
    try transitionImageLayout(vc, pool, texture_image, .r8g8b8a8_srgb, .@"undefined", .transfer_dst_optimal);
    try copyBufferToImage(vc, pool, staging_buffer, texture_image, width, height);
    try transitionImageLayout(vc, pool, texture_image, .r8g8b8a8_srgb, .transfer_dst_optimal, .shader_read_only_optimal);

    return VulkanImage{
        .image = texture_image,
        .memory = memory,
    };
}

fn createTextureImage(vc: *const VulkanContext, filename: [:0]const u8, pool: vk.CommandPool) !VulkanImage {
    const texture = try stbi.load(filename, .rgb_alpha);
    defer texture.free();

    // Create a staging buffer
    const staging_buffer = try vc.vkd.createBuffer(vc.dev, &.{
        .flags = .{},
        .size = texture.num_bytes(),
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    }, null);
    defer vc.vkd.destroyBuffer(vc.dev, staging_buffer, null);
    const staging_mem_reqs = vc.vkd.getBufferMemoryRequirements(vc.dev, staging_buffer);
    const staging_memory = try vc.allocate(staging_mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer vc.vkd.freeMemory(vc.dev, staging_memory, null);
    try vc.vkd.bindBufferMemory(vc.dev, staging_buffer, staging_memory, 0);

    const data = try vc.vkd.mapMemory(vc.dev, staging_memory, 0, vk.WHOLE_SIZE, .{});
    defer vc.vkd.unmapMemory(vc.dev, staging_memory);

    const image_data_dst = @ptrCast([*]u8, data)[0..texture.pixels.len];
    std.mem.copy(u8, image_data_dst, texture.pixels);

    // Create an image
    const image_extent = vk.Extent3D{ // has to be separate, triggers segmentation fault otherwise
        .width = texture.width,
        .height = texture.height,
        .depth = 1,
    };
    const texture_image = try vc.vkd.createImage(vc.dev, &.{
        .flags = .{},
        .image_type = .@"2d",
        .format = .r8g8b8a8_srgb,
        .extent = image_extent,
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .initial_layout = .@"undefined",
    }, null);
    errdefer vc.vkd.destroyImage(vc.dev, texture_image, null);

    const mem_reqs = vc.vkd.getImageMemoryRequirements(vc.dev, texture_image);
    const memory = try vc.allocate(mem_reqs, .{ .device_local_bit = true });
    errdefer vc.vkd.freeMemory(vc.dev, memory, null);
    try vc.vkd.bindImageMemory(vc.dev, texture_image, memory, 0);

    // Copy buffer data to image
    try transitionImageLayout(vc, pool, texture_image, .r8g8b8a8_srgb, .@"undefined", .transfer_dst_optimal);
    try copyBufferToImage(vc, pool, staging_buffer, texture_image, texture.width, texture.height);
    try transitionImageLayout(vc, pool, texture_image, .r8g8b8a8_srgb, .transfer_dst_optimal, .shader_read_only_optimal);

    return VulkanImage{
        .image = texture_image,
        .memory = memory,
    };
}

pub fn createTextureImageView(vc: *const VulkanContext, image: vk.Image, format: vk.Format) !vk.ImageView {
    const components = vk.ComponentMapping{
        .r = .identity,
        .g = .identity,
        .b = .identity,
        .a = .identity,
    };
    const subresource_range = vk.ImageSubresourceRange{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
    const image_view = try vc.vkd.createImageView(vc.dev, &.{
        .flags = .{},
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .components = components,
        .subresource_range = subresource_range,
    }, null);

    return image_view;
}

const Vertex = struct {
    pos: [2]f32,
    tex_coord: [2]f32,

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
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "tex_coord"),
        },
    };
};

const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,
};

const Quad = struct {
    p0: Vec2,
    p1: Vec2,
    st0: Vec2,
    st1: Vec2,

    pub fn getVertices(self: Quad) [6]Vertex {
        const v0 = Vertex{ .pos = .{ self.p0.x, self.p0.y }, .tex_coord = .{ self.st0.x, self.st0.y } };
        const v1 = Vertex{ .pos = .{ self.p1.x, self.p0.y }, .tex_coord = .{ self.st1.x, self.st0.y } };
        const v2 = Vertex{ .pos = .{ self.p1.x, self.p1.y }, .tex_coord = .{ self.st1.x, self.st1.y } };
        const v3 = Vertex{ .pos = .{ self.p0.x, self.p1.y }, .tex_coord = .{ self.st0.x, self.st1.y } };
        return .{ v0, v1, v2, v0, v2, v3 };
    }
};

fn createRenderPass(vc: *const VulkanContext, attachment_format: vk.Format) !vk.RenderPass {
    const color_attachment = vk.AttachmentDescription{
        .flags = .{},
        .format = attachment_format,
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

fn uploadVertices(vc: *const VulkanContext, vertices: []const Vertex, pool: vk.CommandPool, buffer: vk.Buffer) !void {
    const staging_buffer = try vc.vkd.createBuffer(vc.dev, &.{
        .flags = .{},
        .size = @sizeOf(Vertex) * vertices.len,
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

    try copyBuffer(vc, pool, buffer, staging_buffer, @sizeOf(Vertex) * vertices.len);
}

fn copyBuffer(vc: *const VulkanContext, pool: vk.CommandPool, dst: vk.Buffer, src: vk.Buffer, size: vk.DeviceSize) !void {
    const cmdbuf = try SingleTimeCommandBuffer.create_and_begin(vc, pool);

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    vc.vkd.cmdCopyBuffer(cmdbuf.buf, src, dst, 1, @ptrCast([*]const vk.BufferCopy, &region));

    try cmdbuf.submit_and_free();
}

fn transitionImageLayout(vc: *const VulkanContext, pool: vk.CommandPool, image: vk.Image, format: vk.Format, old: vk.ImageLayout, new: vk.ImageLayout) !void {
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

fn copyBufferToImage(vc: *const VulkanContext, pool: vk.CommandPool, buffer: vk.Buffer, image: vk.Image, width: u32, height: u32) !void {
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

fn createCommandBuffers(
    vc: *const VulkanContext,
    pool: vk.CommandPool,
    allocator: Allocator,
    buffer: vk.Buffer,
    extent: vk.Extent2D,
    render_pass: vk.RenderPass,
    pipeline: vk.Pipeline,
    framebuffers: []vk.Framebuffer,
    descriptor_sets: []vk.DescriptorSet,
    pipeline_layout: vk.PipelineLayout,
    vertex_count: usize,
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
        vc.vkd.cmdBindDescriptorSets(cmdbuf, .graphics, pipeline_layout, 0, @intCast(u32, descriptor_sets.len), descriptor_sets.ptr, 0, undefined);
        vc.vkd.cmdDraw(cmdbuf, @intCast(u32, vertex_count), 1, 0, 0);

        vc.vkd.cmdEndRenderPass(cmdbuf);
        try vc.vkd.endCommandBuffer(cmdbuf);
    }

    return cmdbufs;
}

fn destroyCommandBuffers(vc: *const VulkanContext, pool: vk.CommandPool, allocator: Allocator, cmdbufs: []vk.CommandBuffer) void {
    vc.vkd.freeCommandBuffers(vc.dev, pool, @truncate(u32, cmdbufs.len), cmdbufs.ptr);
    allocator.free(cmdbufs);
}

fn get_vertices_tmp(font: fonts.Font, start: Vec2, allocator: Allocator) ![]Vertex {
    const text = @embedFile("main.zig");
    var quads = std.ArrayList(Quad).init(allocator);
    defer quads.deinit();
    var pos = Vec2{ .x = start.x, .y = start.y };
    for (text) |char| {
        const q = font.getQuad(char, pos.x, pos.y);
        try quads.append(Quad{
            .p0 = .{ .x = q.x0, .y = q.y0 },
            .p1 = .{ .x = q.x1, .y = q.y1 },
            .st0 = .{ .x = q.s0, .y = q.t0 },
            .st1 = .{ .x = q.s1, .y = q.t1 },
        });
        pos.x += font.getXAdvance(char); // TODO: make this constant for fixed-width fonts
        if (char == '\n') {
            pos.x = start.x;
            pos.y += 23;
        }
    }
    var vertices = std.ArrayList(Vertex).init(allocator);
    for (quads.items) |quad| {
        for (quad.getVertices()) |vertex| {
            try vertices.append(vertex);
        }
    }

    return vertices.toOwnedSlice();
}

fn processKeyEvent(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = window;

    if (action == .press or action == .repeat) {
        if (key == .up) {
            text_start.y -= 10;
        } else if (key == .down) {
            text_start.y += 10;
        }
    }

    std.debug.print("Key: {any}, scancode: {any}, action: {any}, mods: {any}\n", .{ key, scancode, action, mods });
}
