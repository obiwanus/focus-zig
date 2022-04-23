const std = @import("std");
const builtin = @import("builtin");

const glfw = @import("glfw");
const vk = @import("vulkan");

const u = @import("utils.zig");
const vu = @import("vulkan/utils.zig");
const pipeline = @import("vulkan/pipeline.zig");

const Allocator = std.mem.Allocator;
const VulkanContext = @import("vulkan/context.zig").VulkanContext;
const Font = @import("fonts.zig").Font;
const Swapchain = @import("vulkan/swapchain.zig").Swapchain;
const UiPipeline = pipeline.UiPipeline;
const Ui = @import("ui.zig").Ui;
const Screen = @import("ui.zig").Screen;
const Editor = @import("editor.zig").Editor;

const print = std.debug.print;
const assert = std.debug.assert;

var GPA = std.heap.GeneralPurposeAllocator(.{ .never_unmap = false }){};

const APP_NAME = "Focus";
const FONT_NAME = "fonts/FiraCode-Retina.ttf";
const FONT_SIZE = 18; // for scale = 1.0
const TAB_SIZE = 4;

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
        // .maximized = false,
        // .decorated = false,  // NOTE: there's a bug which causes the window to be bigger than the monitor
        //                      // (or causes it to report a bigger size than it actually is)
        .scale_to_monitor = true,
        .srgb_capable = true,
    });

    // Choose the biggest monitor and get its position
    const monitors = try glfw.Monitor.getAll(gpa);
    const monitor: glfw.Monitor = x: {
        var biggest: ?glfw.Monitor = null;
        var max_pixels: u32 = 0;
        for (monitors) |m| {
            const video_mode = try m.getVideoMode();
            const num_pixels = video_mode.getWidth() * video_mode.getHeight();
            if (num_pixels > max_pixels) {
                max_pixels = num_pixels;
                biggest = m;
            }
        }
        break :x biggest.?;
    };
    const monitor_pos = try monitor.getPosInt();

    // Move window to the biggest monitor and maximise
    try window.setPosInt(monitor_pos.x, monitor_pos.y);
    try window.maximize();
    defer window.destroy();

    const vc = try VulkanContext.init(static_allocator, APP_NAME, window);
    defer vc.deinit();

    const main_cmd_pool = try vc.vkd.createCommandPool(vc.dev, &.{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = vc.graphics_queue.family,
    }, null);
    defer vc.vkd.destroyCommandPool(vc.dev, main_cmd_pool, null);

    var screen: Screen = undefined;
    screen.size = x: {
        const size = try window.getFramebufferSize();
        break :x vk.Extent2D{
            .width = size.width,
            .height = size.height,
        };
    };
    const content_scale = try window.getContentScale();
    assert(content_scale.x_scale == content_scale.y_scale);
    screen.scale = content_scale.x_scale;
    screen.font = try Font.init(&vc, gpa, FONT_NAME, FONT_SIZE * screen.scale, main_cmd_pool);
    defer screen.font.deinit(&vc);

    var editor1 = try Editor.init(gpa, "main.zig");
    defer editor1.deinit();
    var editor2 = try Editor.init(gpa, "ui.zig");
    defer editor2.deinit();

    var swapchain = try Swapchain.init(&vc, static_allocator, screen.size);
    defer swapchain.deinit();

    // We have only one render pass
    const render_pass = try createRenderPass(&vc, swapchain.surface_format.format);
    defer vc.vkd.destroyRenderPass(vc.dev, render_pass, null);

    // NOTE: not sure if we can avoid converting from screen to clip coordinates manually in the shaders
    var uniform_buffer = try vu.UniformBuffer.init(&vc, screen.size);
    defer uniform_buffer.deinit(&vc);
    try uniform_buffer.copyToGPU(&vc);

    // UI pipeline
    var ui_pipeline = try UiPipeline.init(&vc, render_pass, uniform_buffer.descriptor_set_layout);
    ui_pipeline.updateFontTextureDescriptor(&vc, screen.font.atlas_texture.view);
    defer ui_pipeline.deinit(&vc);

    var framebuffers = try createFramebuffers(&vc, gpa, render_pass, swapchain);
    defer vu.destroyFramebuffers(&vc, gpa, framebuffers);

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
    window.setSizeCallback(processWindowSizeEvent);

    var ui = try Ui.init(gpa, &vc);
    defer ui.deinit(&vc);

    var text_changed = true;
    var view_changed = false;

    while (!window.shouldClose()) {
        // Ask the swapchain for the next image
        const is_optimal = swapchain.acquire_next_image();
        if (!is_optimal) {
            // Recreate swapchain if necessary
            const new_size = try window.getFramebufferSize();
            screen.size.width = new_size.width;
            screen.size.height = new_size.height;

            try swapchain.recreate(screen.size);
            if (!swapchain.acquire_next_image()) {
                return error.SwapchainRecreationFailure;
            }

            // Make sure the font is updated if screen scale has changed
            const new_scale = try window.getContentScale();
            assert(new_scale.x_scale == new_scale.y_scale);
            if (screen.scale != new_scale.x_scale) {
                screen.scale = new_scale.x_scale;
                screen.font.deinit(&vc);
                screen.font = try Font.init(&vc, gpa, FONT_NAME, FONT_SIZE * new_scale.x_scale, main_cmd_pool);
                ui_pipeline.updateFontTextureDescriptor(&vc, screen.font.atlas_texture.view);
            }

            vu.destroyFramebuffers(&vc, gpa, framebuffers);
            framebuffers = try createFramebuffers(&vc, gpa, render_pass, swapchain);

            view_changed = true;
        }

        // Wait for input
        // TODO: do not redraw on events we don't care about (e.g. mousemove)
        try glfw.waitEvents();

        // Update view or text
        if (view_changed or text_changed) {
            view_changed = false;
            if (text_changed) {
                text_changed = false;

                try editor1.recalculateLines();
                try editor1.recalculateBytes();
                try editor1.highlightCode();

                try editor2.recalculateLines();
                try editor2.recalculateBytes();
                try editor2.highlightCode();
            }

            // Update uniform buffer
            // NOTE: no need to update every frame right now, but we're still doing it
            // because it'll be easier to add stuff here if we need to
            uniform_buffer.data.screen_size = u.Vec2{
                .x = @intToFloat(f32, screen.size.width),
                .y = @intToFloat(f32, screen.size.height),
            };
            try uniform_buffer.copyToGPU(&vc);

            // Draw UI
            ui.startFrame(screen);

            // TODO: support no editor, 1 editor, 2 editors
            ui.drawEditors(editor1, editor2);

            try ui.endFrame(&vc, main_cmd_pool);
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
                .width = @intToFloat(f32, screen.size.width),
                .height = @intToFloat(f32, screen.size.height),
                .min_depth = 0,
                .max_depth = 1,
            };
            vc.vkd.cmdSetViewport(main_cmd_buf, 0, 1, @ptrCast([*]const vk.Viewport, &viewport));

            const scissor = vk.Rect2D{
                .offset = .{
                    .x = 0,
                    .y = 0,
                },
                .extent = .{
                    .width = screen.size.width,
                    .height = screen.size.height,
                },
            };
            vc.vkd.cmdSetScissor(main_cmd_buf, 0, 1, @ptrCast([*]const vk.Rect2D, &scissor));

            const clear = vk.ClearValue{
                .color = .{ .float_32 = .{ 0.086, 0.133, 0.165, 1 } },
            };
            const render_area = vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = screen.size,
            };
            vc.vkd.cmdBeginRenderPass(main_cmd_buf, &.{
                .render_pass = render_pass,
                .framebuffer = framebuffer,
                .render_area = render_area,
                .clear_value_count = 1,
                .p_clear_values = @ptrCast([*]const vk.ClearValue, &clear),
            }, .@"inline");

            // Draw UI
            vc.vkd.cmdBindPipeline(main_cmd_buf, .graphics, ui_pipeline.handle);
            const ui_descriptors = [_]vk.DescriptorSet{
                uniform_buffer.descriptor_set, // 0 = uniform buffer
                ui_pipeline.descriptor_set, // 1 = atlas texture
            };
            vc.vkd.cmdBindDescriptorSets(
                main_cmd_buf,
                .graphics,
                ui_pipeline.layout,
                0,
                ui_descriptors.len,
                &ui_descriptors,
                0,
                undefined,
            );
            vc.vkd.cmdBindVertexBuffers(main_cmd_buf, 0, 1, @ptrCast([*]const vk.Buffer, &ui.vertex_buffer), &[_]vk.DeviceSize{0});
            vc.vkd.cmdBindIndexBuffer(main_cmd_buf, ui.index_buffer, 0, .uint32);
            vc.vkd.cmdDrawIndexed(main_cmd_buf, ui.indexCount(), 1, 0, 0, 0);

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

const TextBuffer = struct {
    bytes: std.ArrayList(u8),
    chars: std.ArrayList(u.Codepoint), // unicode codepoints
    colors: std.ArrayList(u.TextColor), // color for every char
    lines: std.ArrayList(usize),
    cursor: Cursor,
    viewport: Viewport,

    text_changed: bool = false,
    view_changed: bool = false,

    const Cursor = struct {
        pos: usize = 0,
        line: usize = 0, // from the beginning of buffer
        col: usize = 0, // actual column
        col_wanted: ?usize = null, // where the cursor wants to be
    };

    const Viewport = struct {
        top: usize = 0, // in lines
        left: usize = 0, // in colums
    };

    pub fn init(allocator: Allocator, comptime file_name: []const u8) !TextBuffer {
        const initial = @embedFile(file_name);
        var bytes = std.ArrayList(u8).init(allocator);
        try bytes.appendSlice(initial);

        // For simplicity we assume that a codepoint equals a character (though it's not true).
        // If we ever encounter multi-codepoint characters, we can revisit this
        var chars = std.ArrayList(u.Codepoint).init(allocator);
        try chars.ensureTotalCapacity(bytes.items.len);
        const utf8_view = try std.unicode.Utf8View.init(bytes.items);
        var codepoints = utf8_view.iterator();
        while (codepoints.nextCodepoint()) |codepoint| {
            try chars.append(codepoint);
        }

        var colors = std.ArrayList(u.TextColor).init(allocator);
        try colors.ensureTotalCapacity(chars.items.len);

        var lines = std.ArrayList(usize).init(allocator);
        try lines.append(0); // first line is always at the buffer start

        return TextBuffer{
            .bytes = bytes,
            .chars = chars,
            .colors = colors,
            .lines = lines,
            .cursor = Cursor{},
            .viewport = Viewport{},
        };
    }

    pub fn deinit(self: TextBuffer) void {
        self.lines.deinit();
        self.bytes.deinit();
        self.chars.deinit();
    }

    pub fn recalculateLines(self: *TextBuffer) !void {
        self.lines.shrinkRetainingCapacity(1);
        for (self.chars.items) |char, i| {
            if (char == '\n') {
                try self.lines.append(i + 1);
            }
        }
        try self.lines.append(self.chars.items.len);
    }

    pub fn recalculateBytes(self: *TextBuffer) !void {
        try self.bytes.ensureTotalCapacity(self.chars.items.len * 4); // enough to store 4-byte chars
        self.bytes.expandToCapacity();
        var cursor: usize = 0;
        for (self.chars.items) |char| {
            const num_bytes = try std.unicode.utf8Encode(char, self.bytes.items[cursor..]);
            cursor += @intCast(usize, num_bytes);
        }
        self.bytes.shrinkRetainingCapacity(cursor);
        try self.bytes.append(0); // so we can pass it to tokenizer
    }

    pub fn highlightCode(self: *TextBuffer) !void {
        // Have the color array ready
        try self.colors.ensureTotalCapacity(self.chars.items.len);
        self.colors.expandToCapacity();
        var colors = self.colors.items;
        std.mem.set(u.TextColor, colors, .comment);

        // NOTE: we're tokenizing the whole source file. At least for zig this can be optimised,
        // but we're not doing it just yet
        const source_bytes = self.bytes.items[0 .. self.bytes.items.len - 1 :0]; // has to be null-terminated
        var tokenizer = std.zig.Tokenizer.init(source_bytes);
        while (true) {
            var token = tokenizer.next();
            const token_color: u.TextColor = switch (token.tag) {
                .eof => break,
                .invalid => .@"error",
                .string_literal, .multiline_string_literal_line, .char_literal => .string,
                .builtin => .function,
                .identifier => u.TextColor.getForIdentifier(self.chars.items[token.loc.start..token.loc.end], self.chars.items[token.loc.end]),
                .integer_literal, .float_literal => .value,
                .doc_comment, .container_doc_comment => .comment,
                .keyword_addrspace, .keyword_align, .keyword_allowzero, .keyword_and, .keyword_anyframe, .keyword_anytype, .keyword_asm, .keyword_async, .keyword_await, .keyword_break, .keyword_callconv, .keyword_catch, .keyword_comptime, .keyword_const, .keyword_continue, .keyword_defer, .keyword_else, .keyword_enum, .keyword_errdefer, .keyword_error, .keyword_export, .keyword_extern, .keyword_fn, .keyword_for, .keyword_if, .keyword_inline, .keyword_noalias, .keyword_noinline, .keyword_nosuspend, .keyword_opaque, .keyword_or, .keyword_orelse, .keyword_packed, .keyword_pub, .keyword_resume, .keyword_return, .keyword_linksection, .keyword_struct, .keyword_suspend, .keyword_switch, .keyword_test, .keyword_threadlocal, .keyword_try, .keyword_union, .keyword_unreachable, .keyword_usingnamespace, .keyword_var, .keyword_volatile, .keyword_while => .keyword,
                .bang, .pipe, .pipe_pipe, .pipe_equal, .equal, .equal_equal, .equal_angle_bracket_right, .bang_equal, .l_paren, .r_paren, .semicolon, .percent, .percent_equal, .l_brace, .r_brace, .l_bracket, .r_bracket, .period, .period_asterisk, .ellipsis2, .ellipsis3, .caret, .caret_equal, .plus, .plus_plus, .plus_equal, .plus_percent, .plus_percent_equal, .plus_pipe, .plus_pipe_equal, .minus, .minus_equal, .minus_percent, .minus_percent_equal, .minus_pipe, .minus_pipe_equal, .asterisk, .asterisk_equal, .asterisk_asterisk, .asterisk_percent, .asterisk_percent_equal, .asterisk_pipe, .asterisk_pipe_equal, .arrow, .colon, .slash, .slash_equal, .comma, .ampersand, .ampersand_equal, .question_mark, .angle_bracket_left, .angle_bracket_left_equal, .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_left_equal, .angle_bracket_angle_bracket_left_pipe, .angle_bracket_angle_bracket_left_pipe_equal, .angle_bracket_right, .angle_bracket_right_equal, .angle_bracket_angle_bracket_right, .angle_bracket_angle_bracket_right_equal, .tilde => .punctuation,
                else => .default,
            };
            std.mem.set(u.TextColor, colors[token.loc.start..token.loc.end], token_color);
        }
    }
};

fn processKeyEvent(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = window;
    _ = scancode;
    _ = mods;
    _ = key;
    _ = action;
}

fn processCharEvent(window: glfw.Window, codepoint: u.Codepoint) void {
    _ = window;
    _ = codepoint;
    // g_buf.chars.insert(g_buf.cursor.pos, codepoint) catch unreachable;
    // g_buf.cursor.pos += 1;
    // g_buf.cursor.col_wanted = null;
    // g_buf.text_changed = true;
}

fn processWindowSizeEvent(window: glfw.Window, width: i32, height: i32) void {
    _ = window;
    _ = width;
    _ = height;
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
