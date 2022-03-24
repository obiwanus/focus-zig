const std = @import("std");
const vk = @import("vulkan");
const resources = @import("resources");

const u = @import("../utils.zig");
const vu = @import("utils.zig");

const VulkanContext = @import("context.zig").VulkanContext;
const Vec2 = u.Vec2;
const TextColor = u.TextColor;
const Color = u.Color;

const assert = std.debug.assert;

pub const TextPipeline = struct {
    texture_sampler: vk.Sampler,
    descriptor_pool: vk.DescriptorPool,
    descriptor_set_layout: vk.DescriptorSetLayout,
    descriptor_set: vk.DescriptorSet,
    layout: vk.PipelineLayout,
    handle: vk.Pipeline,

    pub fn init(vc: *const VulkanContext, render_pass: vk.RenderPass, ubo_set_layout: vk.DescriptorSetLayout) !TextPipeline {
        // Sampler for the texture
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
        errdefer vc.vkd.destroySampler(vc.dev, texture_sampler, null);

        const descriptor_pool = x: {
            const pool_sizes = [_]vk.DescriptorPoolSize{
                .{
                    .@"type" = .combined_image_sampler,
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
        errdefer vc.vkd.destroyDescriptorSetLayout(vc.dev, descriptor_set_layout, null);

        // Allocate descriptor sets
        var descriptor_set: vk.DescriptorSet = undefined;
        try vc.vkd.allocateDescriptorSets(vc.dev, &.{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &descriptor_set_layout),
        }, @ptrCast([*]vk.DescriptorSet, &descriptor_set));

        const set_layouts = [_]vk.DescriptorSetLayout{
            ubo_set_layout,
            descriptor_set_layout, // for the atlas texture
        };

        // Pipeline layout
        const pipeline_layout = try vc.vkd.createPipelineLayout(vc.dev, &.{
            .flags = .{},
            .set_layout_count = set_layouts.len,
            .p_set_layouts = &set_layouts,
            .push_constant_range_count = 0,
            .p_push_constant_ranges = undefined,
        }, null);
        errdefer vc.vkd.destroyPipelineLayout(vc.dev, pipeline_layout, null);

        // Create the pipeline itself
        const pipeline_handle = x: {
            const vert_module = try vc.vkd.createShaderModule(vc.dev, &.{
                .flags = .{},
                .code_size = resources.text_vert.len,
                .p_code = @ptrCast([*]const u32, resources.text_vert),
            }, null);
            defer vc.vkd.destroyShaderModule(vc.dev, vert_module, null);

            const frag_module = try vc.vkd.createShaderModule(vc.dev, &.{
                .flags = .{},
                .code_size = resources.text_frag.len,
                .p_code = @ptrCast([*]const u32, resources.text_frag),
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
                .p_vertex_binding_descriptions = @ptrCast([*]const vk.VertexInputBindingDescription, &TexturedQuad.Vertex.binding_description),
                .vertex_attribute_description_count = TexturedQuad.Vertex.attribute_description.len,
                .p_vertex_attribute_descriptions = &TexturedQuad.Vertex.attribute_description,
            };

            const piasci = vk.PipelineInputAssemblyStateCreateInfo{
                .flags = .{},
                .topology = .triangle_list,
                .primitive_restart_enable = vk.FALSE,
            };

            const pvsci = vk.PipelineViewportStateCreateInfo{
                .flags = .{},
                .viewport_count = 1,
                .p_viewports = undefined, // set when recording command buffer with cmdSetViewport
                .scissor_count = 1,
                .p_scissors = undefined, // set when recording command buffer with cmdSetScissor
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
                .blend_enable = vk.TRUE,
                .src_color_blend_factor = .one,
                .dst_color_blend_factor = .one_minus_src_alpha,
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
                .layout = pipeline_layout,
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

            break :x pipeline;
        };

        return TextPipeline{
            .texture_sampler = texture_sampler,
            .descriptor_pool = descriptor_pool,
            .descriptor_set_layout = descriptor_set_layout,
            .descriptor_set = descriptor_set,
            .layout = pipeline_layout,
            .handle = pipeline_handle,
        };
    }

    pub fn updateFontTextureDescriptor(self: TextPipeline, vc: *const VulkanContext, texture_image_view: vk.ImageView) void {
        // NOTE: not sure if this is the intended way to pass textures to pipelines
        // Maybe it would make sense to create all descriptors beforehand and then
        // copy them around somehow?
        // Still, even if so, we don't have a texture image until we generate one for the font anyway.
        const image_info = [_]vk.DescriptorImageInfo{
            .{
                .sampler = self.texture_sampler,
                .image_view = texture_image_view,
                .image_layout = .shader_read_only_optimal,
            },
        };
        const descriptor_writes = [_]vk.WriteDescriptorSet{
            .{
                .dst_set = self.descriptor_set,
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
    }

    pub fn deinit(self: TextPipeline, vc: *const VulkanContext) void {
        vc.vkd.destroySampler(vc.dev, self.texture_sampler, null);
        vc.vkd.destroyDescriptorSetLayout(vc.dev, self.descriptor_set_layout, null);
        vc.vkd.destroyDescriptorPool(vc.dev, self.descriptor_pool, null);
        vc.vkd.destroyPipelineLayout(vc.dev, self.layout, null);
        vc.vkd.destroyPipeline(vc.dev, self.handle, null);
    }
};

pub const CursorPipeline = struct {
    layout: vk.PipelineLayout,
    handle: vk.Pipeline,

    pub fn init(vc: *const VulkanContext, render_pass: vk.RenderPass, ubo_set_layout: vk.DescriptorSetLayout) !CursorPipeline {
        const push_constant_ranges = [_]vk.PushConstantRange{.{
            .stage_flags = .{ .vertex_bit = true },
            .offset = 0,
            .size = @sizeOf(Vec2),
        }};

        // Pipeline layout
        const pipeline_layout = try vc.vkd.createPipelineLayout(vc.dev, &.{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &ubo_set_layout),
            .push_constant_range_count = push_constant_ranges.len,
            .p_push_constant_ranges = &push_constant_ranges,
        }, null);
        errdefer vc.vkd.destroyPipelineLayout(vc.dev, pipeline_layout, null);

        // Create the pipeline itself
        const pipeline_handle = x: {
            const vert_module = try vc.vkd.createShaderModule(vc.dev, &.{
                .flags = .{},
                .code_size = resources.cursor_vert.len,
                .p_code = @ptrCast([*]const u32, resources.cursor_vert),
            }, null);
            defer vc.vkd.destroyShaderModule(vc.dev, vert_module, null);

            const frag_module = try vc.vkd.createShaderModule(vc.dev, &.{
                .flags = .{},
                .code_size = resources.cursor_frag.len,
                .p_code = @ptrCast([*]const u32, resources.cursor_frag),
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

            // Everything is hard-coded in vertex shader
            const pvisci = vk.PipelineVertexInputStateCreateInfo{
                .flags = .{},
                .vertex_binding_description_count = 0,
                .p_vertex_binding_descriptions = undefined,
                .vertex_attribute_description_count = 0,
                .p_vertex_attribute_descriptions = undefined,
            };

            const piasci = vk.PipelineInputAssemblyStateCreateInfo{
                .flags = .{},
                .topology = .triangle_list,
                .primitive_restart_enable = vk.FALSE,
            };

            const pvsci = vk.PipelineViewportStateCreateInfo{
                .flags = .{},
                .viewport_count = 1,
                .p_viewports = undefined, // set when recording command buffer with cmdSetViewport
                .scissor_count = 1,
                .p_scissors = undefined, // set when recording command buffer with cmdSetScissor
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
                .blend_enable = vk.TRUE,
                .src_color_blend_factor = .one,
                .dst_color_blend_factor = .one,
                .color_blend_op = .subtract,
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
                .layout = pipeline_layout,
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

            break :x pipeline;
        };

        return CursorPipeline{
            .layout = pipeline_layout,
            .handle = pipeline_handle,
        };
    }

    pub fn deinit(self: CursorPipeline, vc: *const VulkanContext) void {
        vc.vkd.destroyPipelineLayout(vc.dev, self.layout, null);
        vc.vkd.destroyPipeline(vc.dev, self.handle, null);
    }
};

pub const SolidPipeline = struct {
    layout: vk.PipelineLayout,
    handle: vk.Pipeline,

    pub fn init(vc: *const VulkanContext, render_pass: vk.RenderPass, ubo_set_layout: vk.DescriptorSetLayout) !SolidPipeline {
        // Pipeline layout
        const pipeline_layout = try vc.vkd.createPipelineLayout(vc.dev, &.{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast([*]const vk.DescriptorSetLayout, &ubo_set_layout),
            .push_constant_range_count = 0,
            .p_push_constant_ranges = undefined,
        }, null);
        errdefer vc.vkd.destroyPipelineLayout(vc.dev, pipeline_layout, null);

        // Create the pipeline itself
        const pipeline_handle = x: {
            const vert_module = try vc.vkd.createShaderModule(vc.dev, &.{
                .flags = .{},
                .code_size = resources.solid_vert.len,
                .p_code = @ptrCast([*]const u32, resources.solid_vert),
            }, null);
            defer vc.vkd.destroyShaderModule(vc.dev, vert_module, null);

            const frag_module = try vc.vkd.createShaderModule(vc.dev, &.{
                .flags = .{},
                .code_size = resources.solid_frag.len,
                .p_code = @ptrCast([*]const u32, resources.solid_frag),
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
                .p_vertex_binding_descriptions = @ptrCast([*]const vk.VertexInputBindingDescription, &SolidQuad.Vertex.binding_description),
                .vertex_attribute_description_count = SolidQuad.Vertex.attribute_description.len,
                .p_vertex_attribute_descriptions = &SolidQuad.Vertex.attribute_description,
            };

            const piasci = vk.PipelineInputAssemblyStateCreateInfo{
                .flags = .{},
                .topology = .triangle_list,
                .primitive_restart_enable = vk.FALSE,
            };

            const pvsci = vk.PipelineViewportStateCreateInfo{
                .flags = .{},
                .viewport_count = 1,
                .p_viewports = undefined, // set when recording command buffer with cmdSetViewport
                .scissor_count = 1,
                .p_scissors = undefined, // set when recording command buffer with cmdSetScissor
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
                .dst_color_blend_factor = .one,
                .color_blend_op = .subtract,
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
                .layout = pipeline_layout,
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

            break :x pipeline;
        };

        return SolidPipeline{
            .layout = pipeline_layout,
            .handle = pipeline_handle,
        };
    }

    pub fn deinit(self: SolidPipeline, vc: *const VulkanContext) void {
        vc.vkd.destroyPipelineLayout(vc.dev, self.layout, null);
        vc.vkd.destroyPipeline(vc.dev, self.handle, null);
    }
};

pub const TexturedQuad = struct {
    p0: Vec2,
    p1: Vec2,
    st0: Vec2,
    st1: Vec2,
    color: TextColor,

    pub const Vertex = extern struct {
        pos: [2]f32,
        tex_coord: [2]f32,
        color: TextColor,

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
            .{
                .binding = 0,
                .location = 2,
                .format = .r8_uint,
                .offset = @offsetOf(Vertex, "color"),
            },
        };
    };

    pub fn getVertices(self: TexturedQuad) [6]Vertex {
        const v0 = Vertex{ .pos = .{ self.p0.x, self.p0.y }, .tex_coord = .{ self.st0.x, self.st0.y }, .color = self.color };
        const v1 = Vertex{ .pos = .{ self.p1.x, self.p0.y }, .tex_coord = .{ self.st1.x, self.st0.y }, .color = self.color };
        const v2 = Vertex{ .pos = .{ self.p1.x, self.p1.y }, .tex_coord = .{ self.st1.x, self.st1.y }, .color = self.color };
        const v3 = Vertex{ .pos = .{ self.p0.x, self.p1.y }, .tex_coord = .{ self.st0.x, self.st1.y }, .color = self.color };
        return .{ v0, v1, v2, v0, v2, v3 };
    }
};

pub const SolidQuad = struct {
    p0: Vec2,
    p1: Vec2,
    color: Color,

    pub const Vertex = extern struct {
        pos: [2]f32,
        color: [4]f32,

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
                .format = .r32g32b32a32_sfloat,
                .offset = @offsetOf(Vertex, "color"),
            },
        };
    };

    pub fn getVertices(self: SolidQuad) [6]Vertex {
        const color = .{ self.color.r, self.color.g, self.color.b, self.color.a };
        const v0 = Vertex{ .pos = .{ self.p0.x, self.p0.y }, .color = color };
        const v1 = Vertex{ .pos = .{ self.p1.x, self.p0.y }, .color = color };
        const v2 = Vertex{ .pos = .{ self.p1.x, self.p1.y }, .color = color };
        const v3 = Vertex{ .pos = .{ self.p0.x, self.p1.y }, .color = color };
        return .{ v0, v1, v2, v0, v2, v3 };
    }
};
