const std = @import("std");
const builtin = @import("builtin");

const glfw = @import("glfw");
const vk = @import("vulkan");

const u = @import("utils.zig");
const vu = @import("vulkan/utils.zig");
const pipeline = @import("vulkan/pipeline.zig");
const style = @import("style.zig");
const ui_mod = @import("ui.zig");

const Allocator = std.mem.Allocator;
const VulkanContext = @import("vulkan/context.zig").VulkanContext;
const Font = @import("fonts.zig").Font;
const Swapchain = @import("vulkan/swapchain.zig").Swapchain;
const UiPipeline = pipeline.UiPipeline;
const Ui = ui_mod.Ui;
const Screen = ui_mod.Screen;
const Editor = @import("editor.zig").Editor;

var GPA = std.heap.GeneralPurposeAllocator(.{ .never_unmap = false }){};

const APP_NAME = "Focus";
const FONT_NAME = "fonts/FiraCode-Retina.ttf";
const FONT_SIZE = 18; // for scale = 1.0

var g_events: std.ArrayList(Event) = undefined;

const EditorLayout = enum {
    none,
    single,
    side_by_side,
};

pub const OpenFileDialog = struct {
    entries: std.ArrayList(Entry),
    selected: usize = 0,

    const Entry = struct {
        path: []u.Codepoint,
        name: []u.Codepoint,
        kind: Kind,
    };

    const Kind = enum {
        file,
        directory,
    };

    pub fn init(allocator: Allocator) !OpenFileDialog {
        var entries = std.ArrayList(Entry).init(allocator);
        var dir = try std.fs.cwd().openDir("src", .{ .iterate = true });
        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            const kind = switch (entry.kind) {
                .Directory => Kind.directory,
                .File => Kind.file,
                else => continue,
            };
            entries.append(Entry{
                // TODO: Need to find an idiomatic way to handle this leak
                // (e.g. have a memory arena for the strings so we can free them at once)
                .path = try u.bytesToCodepoints(entry.path, allocator),
                .name = try u.bytesToCodepoints(entry.basename, allocator),
                .kind = kind,
            }) catch u.oom();
        }

        return OpenFileDialog{
            .entries = entries,
        };
    }

    pub fn deinit(self: *OpenFileDialog) void {
        self.entries.deinit();
    }
};

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
    u.assert(content_scale.x_scale == content_scale.y_scale);
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

    g_events = std.ArrayList(Event).init(gpa);
    window.setKeyCallback(newKeyEvent);
    window.setCharCallback(newCharEvent);
    window.setSizeCallback(newWindowSizeEvent);

    var ui = try Ui.init(gpa, &vc);
    defer ui.deinit(&vc);

    var active_animation = false;
    var active_editor: *Editor = &editor1;
    g_events.append(.redraw_requested) catch u.oom();

    var frame_number: usize = 0;
    const app_start_ms = std.time.nanoTimestamp();
    var clock_ms: f64 = 0;

    var layout_mode: EditorLayout = .side_by_side;
    // var layout_mode: EditorLayout = .single;

    var open_file_dialog: ?OpenFileDialog = null;

    while (!window.shouldClose()) {
        frame_number += 1;

        // Ask the swapchain for the next image
        const is_optimal = swapchain.acquireNextImage();
        if (!is_optimal) {
            // Recreate swapchain if necessary
            const new_size = try window.getFramebufferSize();
            screen.size.width = new_size.width;
            screen.size.height = new_size.height;

            try swapchain.recreate(screen.size);
            if (!swapchain.acquireNextImage()) {
                return error.SwapchainRecreationFailure;
            }

            // Make sure the font is updated if screen scale has changed
            const new_scale = try window.getContentScale();
            u.assert(new_scale.x_scale == new_scale.y_scale);
            if (screen.scale != new_scale.x_scale) {
                screen.scale = new_scale.x_scale;
                screen.font.deinit(&vc);
                screen.font = try Font.init(&vc, gpa, FONT_NAME, FONT_SIZE * new_scale.x_scale, main_cmd_pool);
                ui_pipeline.updateFontTextureDescriptor(&vc, screen.font.atlas_texture.view);
            }

            vu.destroyFramebuffers(&vc, gpa, framebuffers);
            framebuffers = try createFramebuffers(&vc, gpa, render_pass, swapchain);

            g_events.append(.redraw_requested) catch u.oom();
        }

        // Check if we have events and immediately continue
        try glfw.pollEvents();

        // Otherwise sleep until something happens
        while (g_events.items.len == 0 and !active_animation and !window.shouldClose()) {
            try glfw.waitEvents();
        }

        // Monotonically increasing clock for animations
        clock_ms = @intToFloat(f64, std.time.nanoTimestamp() - app_start_ms) / 1_000_000;

        // Process events
        for (g_events.items) |event| {
            switch (event) {
                .char_entered => |char| {
                    active_editor.typeChar(char);
                },
                .key_pressed => |kp| {
                    active_editor.keyPress(kp.key, kp.mods);
                },
                .command => |command| {
                    switch (command) {
                        .switch_to_left => active_editor = &editor1,
                        .switch_to_right => active_editor = &editor2, // TODO: editor2 doesn't always exist
                        .toggle_open_file_dialog => {
                            if (open_file_dialog) |*dialog| {
                                dialog.deinit();
                                open_file_dialog = null;
                            } else {
                                open_file_dialog = try OpenFileDialog.init(gpa);
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
        g_events.shrinkRetainingCapacity(0);

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

        const margin_h = 30 * screen.scale;
        const margin_v = 15 * screen.scale;

        switch (layout_mode) {
            .none => {
                // Layout rects to prepare for drawing
                var area = screen.getRect();
                const footer_rect = area.splitBottom(screen.font.line_height + 4, 0);
                ui.drawSolidRect(footer_rect, style.colors.BACKGROUND_BRIGHT);
            },
            .single => {
                // Layout rects to prepare for drawing
                var area = screen.getRect();
                const footer_rect = area.splitBottom(screen.font.line_height + 4, 0);
                const editor1_rect = area.shrink(margin_h, margin_v, margin_h, 0);

                // Retain info about dimensions
                active_editor.lines_per_screen = @floatToInt(usize, editor1_rect.h / screen.font.line_height);
                active_editor.cols_per_screen = @floatToInt(usize, editor1_rect.w / screen.font.xadvance);

                // Update internal data if necessary
                if (editor1.dirty) editor1.syncInternalData();
                active_editor.updateCursor();
                active_editor.moveViewportToCursor(screen.font); // depends on lines_per_screen etc
                active_animation = active_editor.animateScrolling(clock_ms);

                ui.drawEditor(editor1, editor1_rect, true);

                ui.drawSolidRectWithShadow(footer_rect, style.colors.BACKGROUND_BRIGHT, 5);
            },
            .side_by_side => {
                // Layout rects to prepare for drawing
                var area = screen.getRect();
                const footer_rect = area.splitBottom(screen.font.line_height + 4, 0);
                area = area.shrink(margin_h, margin_v, margin_h, 0);
                const editor1_rect = area.splitLeft(area.w / 2, margin_h).shrink(0, 0, margin_h, 0);
                const editor2_rect = area;

                // Retain info about dimensions
                active_editor.lines_per_screen = @floatToInt(usize, editor1_rect.h / screen.font.line_height);
                active_editor.cols_per_screen = @floatToInt(usize, editor1_rect.w / screen.font.xadvance);

                // Update internal data if necessary
                if (editor1.dirty) editor1.syncInternalData();
                if (editor2.dirty) editor2.syncInternalData();
                active_editor.updateCursor();
                active_editor.moveViewportToCursor(screen.font); // depends on lines_per_screen etc
                active_animation = active_editor.animateScrolling(clock_ms);

                ui.drawEditor(editor1, editor1_rect, active_editor == &editor1);
                ui.drawEditor(editor2, editor2_rect, active_editor == &editor2);

                ui.drawSolidRectWithShadow(footer_rect, style.colors.BACKGROUND_BRIGHT, 5);
                const screen_rect = screen.getRect();
                const splitter_rect = screen_rect.shrink(screen_rect.w / 2 - 1, 0, screen_rect.w / 2 - 1, 0);
                ui.drawSolidRect(splitter_rect, style.colors.BACKGROUND_BRIGHT);
            },
        }

        if (open_file_dialog) |dialog| {
            ui.drawOpenFileDialog(dialog);
        }

        ui.drawDebugPanel(frame_number);
        try ui.endFrame(&vc, main_cmd_pool);

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
                .color = .{ .float_32 = style.colors.BACKGROUND.asArray() },
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

            // Draw everything
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
        try swapchain.waitUntilLastFrameIsRendered();
    }

    // Wait for GPU to finish all work before cleaning up
    try vc.vkd.queueWaitIdle(vc.graphics_queue.handle);
}

pub const Event = union(enum) {
    key_pressed: KeyPress,
    char_entered: u.Codepoint,
    window_resized: WindowResize,
    command: Command,
    redraw_requested: void,

    pub const WindowResize = struct {
        width: i32,
        height: i32,
    };
    pub const KeyPress = struct {
        key: glfw.Key,
        mods: glfw.Mods,
    };
    pub const Command = enum {
        switch_to_left,
        switch_to_right,
        close_current,
        toggle_open_file_dialog,
    };
};

fn newKeyEvent(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = window;
    _ = scancode;
    if (action == .press or action == .repeat) {
        if (mods.control and mods.alt) {
            if (key == .left) {
                g_events.append(Event{ .command = .switch_to_left }) catch u.oom();
                return;
            }
            if (key == .right) {
                g_events.append(Event{ .command = .switch_to_right }) catch u.oom();
                return;
            }
        }
        if (mods.control and key == .p) {
            g_events.append(Event{ .command = .toggle_open_file_dialog }) catch u.oom();
            return;
        }
        g_events.append(Event{ .key_pressed = .{ .key = key, .mods = mods } }) catch u.oom();
    }
}

fn newCharEvent(window: glfw.Window, codepoint: u.Codepoint) void {
    _ = window;
    g_events.append(Event{ .char_entered = codepoint }) catch u.oom();
}

fn newWindowSizeEvent(window: glfw.Window, width: i32, height: i32) void {
    _ = window;
    g_events.append(Event{ .window_resized = .{ .width = width, .height = height } }) catch u.oom();
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
