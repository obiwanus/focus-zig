const std = @import("std");
const builtin = @import("builtin");

const glfw = @import("glfw");
const vk = @import("vulkan");
const stbi = @import("stbi");

const vu = @import("vulkan/utils.zig");

const Allocator = std.mem.Allocator;
const VulkanContext = @import("vulkan/context.zig").VulkanContext;
const Font = @import("fonts.zig").Font;
const Swapchain = @import("vulkan/swapchain.zig").Swapchain;
const TextPipeline = @import("vulkan/pipeline.zig").TextPipeline;
const TexturedQuad = @import("vulkan/pipeline.zig").TexturedQuad;
const CursorPipeline = @import("vulkan/pipeline.zig").CursorPipeline;
const Vec2 = @import("math.zig").Vec2;

const print = std.debug.print;
const assert = std.debug.assert;

var GPA = std.heap.GeneralPurposeAllocator(.{ .never_unmap = false }){};

const APP_NAME = "Focus";
const FONT_NAME = "fonts/consola.ttf";
const FONT_SIZE = 16; // for scale = 1.0
const MAX_VERTEX_COUNT = 100000;

// NOTE: this buffer is global temporary. We don't want it to be global eventually
var g_buf: TextBuffer = undefined;
var g_screen: Screen = undefined;

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
    });
    defer window.destroy();

    const vc = try VulkanContext.init(static_allocator, APP_NAME, window);
    defer vc.deinit();

    const main_cmd_pool = try vc.vkd.createCommandPool(vc.dev, &.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = vc.graphics_queue.family,
    }, null);
    defer vc.vkd.destroyCommandPool(vc.dev, main_cmd_pool, null);

    // Initialise global context
    g_screen.size = x: {
        const size = try window.getFramebufferSize();
        break :x vk.Extent2D{
            .width = size.width,
            .height = size.height,
        };
    };
    g_screen.scale = try window.getContentScale();
    g_screen.font = try Font.init(&vc, gpa, FONT_NAME, FONT_SIZE, main_cmd_pool);
    defer g_screen.font.deinit(&vc);
    g_screen.total_lines = @floatToInt(usize, @intToFloat(f32, g_screen.size.height) / g_screen.font.line_height);

    g_buf = try TextBuffer.init(gpa, "main.zig");
    defer g_buf.deinit();
    g_buf.text_changed = true; // trigger initial update
    g_buf.text_vertices = std.ArrayList(TexturedQuad.Vertex).init(gpa);

    var swapchain = try Swapchain.init(&vc, static_allocator, g_screen.size);
    defer swapchain.deinit();

    // We have only one render pass
    const render_pass = try createRenderPass(&vc, swapchain.surface_format.format);
    defer vc.vkd.destroyRenderPass(vc.dev, render_pass, null);

    // Uniform buffer - shared between pipelines
    var uniform_buffer = try vu.UniformBuffer.init(
        &vc,
        g_screen.size,
        .{ .x = 30, .y = 15 },
        .{ .x = g_screen.font.xadvance, .y = g_screen.font.letter_height },
        .{ .x = g_screen.font.xadvance, .y = g_screen.font.line_height },
    );
    defer uniform_buffer.deinit(&vc);
    try uniform_buffer.sendToGPU(&vc);

    // Pipeline for rendering text
    var text_pipeline = try TextPipeline.init(&vc, render_pass, uniform_buffer);
    text_pipeline.updateFontTextureDescriptor(&vc, g_screen.font.atlas_texture.view);
    defer text_pipeline.deinit(&vc);

    // Pipeline for colored quads (such as cursor or panels)
    var cursor_pipeline = try CursorPipeline.init(&vc, render_pass, uniform_buffer);
    defer cursor_pipeline.deinit(&vc);

    var framebuffers = try createFramebuffers(&vc, gpa, render_pass, swapchain);
    defer destroyFramebuffers(&vc, gpa, framebuffers);

    const text_vertex_buffer = try vc.vkd.createBuffer(vc.dev, &.{
        .flags = .{},
        .size = @sizeOf(TexturedQuad.Vertex) * MAX_VERTEX_COUNT,
        .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    }, null);
    defer vc.vkd.destroyBuffer(vc.dev, text_vertex_buffer, null);
    const mem_reqs = vc.vkd.getBufferMemoryRequirements(vc.dev, text_vertex_buffer);
    const memory = try vc.allocate(mem_reqs, .{ .device_local_bit = true });
    defer vc.vkd.freeMemory(vc.dev, memory, null);
    try vc.vkd.bindBufferMemory(vc.dev, text_vertex_buffer, memory, 0);

    // This is the only command buffer we'll use for drawing.
    // It will be reset and re-recorded every frame
    const main_cmd_buf = x: {
        var cmdbuf: vk.CommandBuffer = undefined;
        try vc.vkd.allocateCommandBuffers(vc.dev, &.{
            .command_pool = main_cmd_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast([*]vk.CommandBuffer, &cmdbuf));
        break :x cmdbuf;
    };
    defer vc.vkd.freeCommandBuffers(vc.dev, main_cmd_pool, 1, @ptrCast([*]const vk.CommandBuffer, &main_cmd_buf));

    window.setKeyCallback(processKeyEvent);
    window.setCharCallback(processCharEvent);

    while (!window.shouldClose()) {
        // Ask the swapchain for the next image
        const is_optimal = swapchain.acquire_next_image();
        if (!is_optimal) {
            // Recreate swapchain if necessary
            const new_size = try window.getFramebufferSize();
            g_screen.size.width = new_size.width;
            g_screen.size.height = new_size.height;
            g_screen.total_lines = @floatToInt(usize, @intToFloat(f32, g_screen.size.height) / g_screen.font.line_height);
            try swapchain.recreate(g_screen.size);
            if (!swapchain.acquire_next_image()) {
                return error.SwapchainRecreationFailure;
            }

            // Make sure the font is updated
            const new_scale = try window.getContentScale();
            if (g_screen.scaleChanged(new_scale)) {
                g_screen.scale = new_scale;
                g_screen.font.deinit(&vc);
                g_screen.font = try Font.init(&vc, gpa, FONT_NAME, FONT_SIZE * new_scale.x_scale, main_cmd_pool);
                text_pipeline.updateFontTextureDescriptor(&vc, g_screen.font.atlas_texture.view);
            }

            uniform_buffer.data.screen_size = Vec2{
                .x = @intToFloat(f32, new_size.width),
                .y = @intToFloat(f32, new_size.height),
            };
            uniform_buffer.data.cursor_size = Vec2{
                .x = g_screen.font.xadvance,
                .y = g_screen.font.letter_height,
            };
            uniform_buffer.data.cursor_advance = Vec2{
                .x = g_screen.font.xadvance,
                .y = g_screen.font.line_height,
            };
            try uniform_buffer.sendToGPU(&vc);

            destroyFramebuffers(&vc, gpa, framebuffers);
            framebuffers = try createFramebuffers(&vc, gpa, render_pass, swapchain);

            g_buf.view_changed = true;
        }

        // Wait for input
        try glfw.waitEvents();

        // Update view or text
        if (g_buf.view_changed or g_buf.text_changed) {
            g_buf.view_changed = false;
            if (g_buf.text_changed) {
                g_buf.text_changed = false;
                // TODO: do it from cursor? - only applicable if the change was made by the cursor
                try g_buf.recalculateLines();
            }
            g_buf.updateCursor();
            try g_buf.updateVisibleVertices(g_screen.font);
            try uploadVertices(&vc, g_buf.text_vertices.items, main_cmd_pool, text_vertex_buffer);
        }

        // Record the main command buffer
        {
            // Framebuffers were created to match swapchain images,
            // and we record a command buffer for the correct framebuffer each frame
            const framebuffer = framebuffers[swapchain.image_index];

            try vc.vkd.resetCommandBuffer(main_cmd_buf, .{});
            try vc.vkd.beginCommandBuffer(main_cmd_buf, &.{
                .flags = .{ .one_time_submit_bit = true },
                .p_inheritance_info = null,
            });

            const viewport = vk.Viewport{
                .x = 0,
                .y = 0,
                .width = @intToFloat(f32, g_screen.size.width),
                .height = @intToFloat(f32, g_screen.size.height),
                .min_depth = 0,
                .max_depth = 1,
            };
            vc.vkd.cmdSetViewport(main_cmd_buf, 0, 1, @ptrCast([*]const vk.Viewport, &viewport));

            const scissor = vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = g_screen.size,
            };
            vc.vkd.cmdSetScissor(main_cmd_buf, 0, 1, @ptrCast([*]const vk.Rect2D, &scissor));

            const clear = vk.ClearValue{
                .color = .{ .float_32 = .{ 2.0 / 255.0, 4.0 / 255.0, 6.0 / 255.0, 1 } },
            };
            const render_area = vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = g_screen.size,
            };
            vc.vkd.cmdBeginRenderPass(main_cmd_buf, &.{
                .render_pass = render_pass,
                .framebuffer = framebuffer,
                .render_area = render_area,
                .clear_value_count = 1,
                .p_clear_values = @ptrCast([*]const vk.ClearValue, &clear),
            }, .@"inline");

            // Draw text
            vc.vkd.cmdBindPipeline(main_cmd_buf, .graphics, text_pipeline.handle);
            const offset = [_]vk.DeviceSize{0};
            vc.vkd.cmdBindVertexBuffers(main_cmd_buf, 0, 1, @ptrCast([*]const vk.Buffer, &text_vertex_buffer), &offset);
            vc.vkd.cmdBindDescriptorSets(
                main_cmd_buf,
                .graphics,
                text_pipeline.layout,
                0,
                1,
                @ptrCast([*]const vk.DescriptorSet, &text_pipeline.descriptor_set),
                0,
                undefined,
            );
            vc.vkd.cmdDraw(main_cmd_buf, @intCast(u32, g_buf.text_vertices.items.len), 1, 0, 0);

            // Draw cursor
            vc.vkd.cmdBindPipeline(main_cmd_buf, .graphics, cursor_pipeline.handle);
            const cursor_offset = Vec2{ .x = @intToFloat(f32, g_buf.cursor.col), .y = @intToFloat(f32, g_buf.cursor.line - g_buf.viewport_top_line) };
            vc.vkd.cmdPushConstants(main_cmd_buf, cursor_pipeline.layout, .{ .vertex_bit = true }, 0, @sizeOf(Vec2), &cursor_offset);
            vc.vkd.cmdBindDescriptorSets(
                main_cmd_buf,
                .graphics,
                cursor_pipeline.layout,
                0,
                1,
                @ptrCast([*]const vk.DescriptorSet, &cursor_pipeline.descriptor_set),
                0,
                undefined,
            );
            vc.vkd.cmdDraw(main_cmd_buf, 4, 1, 0, 0);

            vc.vkd.cmdEndRenderPass(main_cmd_buf);
            try vc.vkd.endCommandBuffer(main_cmd_buf);
        }

        // Submit the command buffer to start rendering
        const wait_stage = [_]vk.PipelineStageFlags{.{ .top_of_pipe_bit = true }};
        try vc.vkd.queueSubmit(vc.graphics_queue.handle, 1, &[_]vk.SubmitInfo{.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &swapchain.image_acquired_semaphore),
            .p_wait_dst_stage_mask = &wait_stage,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast([*]const vk.CommandBuffer, &main_cmd_buf),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast([*]const vk.Semaphore, &swapchain.render_finished_semaphore),
        }}, swapchain.render_finished_fence);

        // Present the rendered frame when ready
        _ = try vc.vkd.queuePresentKHR(vc.present_queue.handle, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast([*]const vk.Semaphore, &swapchain.render_finished_semaphore),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast([*]const vk.SwapchainKHR, &swapchain.handle),
            .p_image_indices = @ptrCast([*]const u32, &swapchain.image_index),
            .p_results = null,
        });

        // Make sure the rendering is finished
        try swapchain.wait_until_last_frame_is_rendered();
    }

    // Wait for GPU to finish all work before cleaning up
    try vc.vkd.queueWaitIdle(vc.graphics_queue.handle);
}

const Screen = struct {
    size: vk.Extent2D,
    scale: glfw.Window.ContentScale,
    font: Font,
    total_lines: usize, // how many fit vertically for the current font

    pub fn scaleChanged(self: Screen, new_scale: glfw.Window.ContentScale) bool {
        assert(new_scale.x_scale == new_scale.y_scale);
        return self.scale.x_scale != new_scale.x_scale;
    }
};

const TextBuffer = struct {
    bytes: std.ArrayList(u8),
    // TODO: unicode
    lines: std.ArrayList(usize),
    cursor: Cursor,

    text_vertices: std.ArrayList(TexturedQuad.Vertex),
    text_quads: std.ArrayList(TexturedQuad),

    viewport_top_line: usize = 0, // line from which viewport starts
    text_changed: bool = false,
    view_changed: bool = false,

    const Cursor = struct {
        pos: usize = 0,
        line: usize = 0, // from the beginning of buffer
        col: usize = 0, // actual column
        col_wanted: ?usize = null, // where the cursor wants to be
    };

    pub fn init(allocator: Allocator, comptime file_name: []const u8) !TextBuffer {
        const initial = @embedFile(file_name);
        var bytes = std.ArrayList(u8).init(allocator);
        try bytes.appendSlice(initial);

        var lines = std.ArrayList(usize).init(allocator);
        try lines.append(0); // first line is always at the buffer start

        var text_vertices = std.ArrayList(TexturedQuad.Vertex).init(allocator);
        var text_quads = std.ArrayList(TexturedQuad).init(allocator);

        return TextBuffer{
            .bytes = bytes,
            .lines = lines,
            .cursor = Cursor{},
            .text_vertices = text_vertices,
            .text_quads = text_quads,
        };
    }

    pub fn deinit(self: TextBuffer) void {
        self.lines.deinit();
        self.bytes.deinit();
    }

    pub fn recalculateLines(self: *TextBuffer) !void {
        self.lines.shrinkRetainingCapacity(1);
        for (self.bytes.items) |char, i| {
            if (char == '\n') {
                try self.lines.append(i + 1);
            }
        }
        try self.lines.append(self.bytes.items.len);
    }

    /// Recalculates cursor line/column coordinates from buffer position
    pub fn updateCursor(self: *TextBuffer) void {
        self.cursor.line = for (self.lines.items) |line_start, line| {
            if (self.cursor.pos < line_start) {
                break line - 1;
            } else if (self.cursor.pos == line_start) {
                break line; // for one-line files
            }
        } else self.lines.items.len;
        self.cursor.col = self.cursor.pos - self.lines.items[self.cursor.line];

        // Detect if cursor is outside vertical viewport
        if (self.cursor.line < self.viewport_top_line) {
            self.viewport_top_line = self.cursor.line;
        } else if (self.cursor.line > self.viewport_top_line + g_screen.total_lines - 1) {
            self.viewport_top_line = self.cursor.line - g_screen.total_lines + 1;
        }
    }

    /// Updates the inner vertex array based on current viewport and buffer contents
    pub fn updateVisibleVertices(self: *TextBuffer, font: Font) !void {
        var bottom_line = self.viewport_top_line + g_screen.total_lines;
        if (bottom_line > self.lines.items.len - 1) {
            bottom_line = self.lines.items.len - 1;
        }
        const start_pos = self.lines.items[self.viewport_top_line];
        const end_pos = self.lines.items[bottom_line];
        const visible_chars = self.bytes.items[start_pos..end_pos];

        // Rebuild text vertices
        {
            self.text_vertices.shrinkRetainingCapacity(0);
            self.text_quads.shrinkRetainingCapacity(0);

            const start = Vec2{ .x = 0, .y = font.baseline }; // will be repositioned by the shader
            var pos = Vec2{ .x = start.x, .y = start.y };
            // Get quads
            for (visible_chars) |char| {
                if (char != ' ' and char != '\n') {
                    const q = font.getQuad(char, pos.x, pos.y);
                    try self.text_quads.append(TexturedQuad{
                        .p0 = .{ .x = q.x0, .y = q.y0 },
                        .p1 = .{ .x = q.x1, .y = q.y1 },
                        .st0 = .{ .x = q.s0, .y = q.t0 },
                        .st1 = .{ .x = q.s1, .y = q.t1 },
                    });
                }
                pos.x += font.xadvance;
                if (char == '\n') {
                    pos.x = start.x;
                    pos.y += font.line_height;
                }
            }
            // Get vertices
            for (self.text_quads.items) |quad| {
                // Convert them to unit coordinates on the fly
                // NOTE: not sure if we should do it in the shader instead
                for (quad.getVertices()) |vertex| {
                    try self.text_vertices.append(vertex);
                }
            }

            assert(self.text_vertices.items.len < MAX_VERTEX_COUNT);
        }
    }
};

// Directly modifies globals (tmp)
fn moveCursorToTargetLine(line: usize) void {
    const target_line = if (line > g_buf.lines.items.len - 2)
        g_buf.lines.items.len - 2
    else
        line;
    const chars_on_target_line = g_buf.lines.items[target_line + 1] - g_buf.lines.items[target_line] -| 1;
    const wanted_pos = if (g_buf.cursor.col_wanted) |wanted|
        wanted
    else
        g_buf.cursor.col;
    const new_line_pos = std.math.min(wanted_pos, chars_on_target_line);
    g_buf.cursor.col_wanted = if (new_line_pos < wanted_pos) wanted_pos else null; // reset or remember wanted position
    g_buf.cursor.pos = g_buf.lines.items[target_line] + new_line_pos;
    g_buf.view_changed = true;
}

fn processKeyEvent(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = window;
    _ = scancode;
    _ = mods;

    if (action == .press or action == .repeat) {
        switch (key) {
            .left => if (g_buf.cursor.pos > 0) {
                g_buf.cursor.pos -= 1;
                g_buf.cursor.col_wanted = null;
                g_buf.view_changed = true;
            },
            .right => if (g_buf.cursor.pos < g_buf.bytes.items.len - 1) {
                g_buf.cursor.pos += 1;
                g_buf.cursor.col_wanted = null;
                g_buf.view_changed = true;
            },
            .up => {
                const offset: usize = if (mods.control) 5 else 1;
                moveCursorToTargetLine(g_buf.cursor.line -| offset);
            },
            .down => {
                const offset: usize = if (mods.control) 5 else 1;
                moveCursorToTargetLine(g_buf.cursor.line + offset);
            },
            .page_up => {
                moveCursorToTargetLine(g_buf.cursor.line -| (g_screen.total_lines - 1));
            },
            .page_down => {
                moveCursorToTargetLine(g_buf.cursor.line + (g_screen.total_lines - 1));
            },
            .home => {
                g_buf.cursor.pos = g_buf.lines.items[g_buf.cursor.line];
                g_buf.cursor.col_wanted = null;
                g_buf.view_changed = true;
            },
            .end => {
                g_buf.cursor.pos = g_buf.lines.items[g_buf.cursor.line + 1] - 1;
                g_buf.cursor.col_wanted = std.math.maxInt(usize);
                g_buf.view_changed = true;
            },
            .tab => {
                g_buf.bytes.insertSlice(g_buf.cursor.pos, "    ") catch unreachable;
                g_buf.cursor.pos += 4;
                g_buf.cursor.col_wanted = null;
                g_buf.text_changed = true;
            },
            .enter => {
                if (mods.control and mods.shift) {
                    // Insert line above
                    g_buf.cursor.pos = g_buf.lines.items[g_buf.cursor.line];
                    g_buf.bytes.insert(g_buf.cursor.pos, '\n') catch unreachable;
                } else if (mods.control) {
                    // Insert line below
                    g_buf.cursor.pos = g_buf.lines.items[g_buf.cursor.line + 1];
                    g_buf.bytes.insert(g_buf.cursor.pos, '\n') catch unreachable;
                } else {
                    // Break the line normally
                    g_buf.bytes.insert(g_buf.cursor.pos, '\n') catch unreachable;
                    g_buf.cursor.pos += 1;
                }
                g_buf.cursor.col_wanted = null;
                g_buf.text_changed = true;
            },
            .backspace => if (g_buf.cursor.pos > 0) {
                g_buf.cursor.pos -= 1;
                _ = g_buf.bytes.orderedRemove(g_buf.cursor.pos);
                g_buf.cursor.col_wanted = null;
                g_buf.text_changed = true;
            },
            .delete => if (g_buf.bytes.items.len > 1 and g_buf.cursor.pos < g_buf.bytes.items.len - 1) {
                _ = g_buf.bytes.orderedRemove(g_buf.cursor.pos);
                g_buf.cursor.col_wanted = null;
                g_buf.text_changed = true;
            },
            else => {},
        }
        g_buf.viewport_top_line = std.math.clamp(g_buf.viewport_top_line, 0, g_buf.lines.items.len -| 2);
    }
}

fn processCharEvent(window: glfw.Window, codepoint: u21) void {
    _ = window;
    const code = @truncate(u8, codepoint);
    g_buf.bytes.insert(g_buf.cursor.pos, code) catch unreachable;
    g_buf.cursor.pos += 1;
    g_buf.cursor.col_wanted = null;
    g_buf.text_changed = true;
}

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

fn uploadVertices(vc: *const VulkanContext, vertices: []const TexturedQuad.Vertex, pool: vk.CommandPool, buffer: vk.Buffer) !void {
    if (vertices.len == 0) {
        return;
    }
    const buffer_size = @sizeOf(TexturedQuad.Vertex) * vertices.len;
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

        const gpu_vertices = @ptrCast([*]TexturedQuad.Vertex, @alignCast(@alignOf(TexturedQuad.Vertex), data));
        std.mem.copy(TexturedQuad.Vertex, gpu_vertices[0..vertices.len], vertices);
    }

    try vu.copyBuffer(vc, pool, buffer, staging_buffer, buffer_size);
}
