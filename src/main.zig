const std = @import("std");
const builtin = @import("builtin");

const glfw = @import("glfw");
const vk = @import("vulkan");
const stbi = @import("stbi");

const focus = @import("focus.zig");
const u = focus.utils;
const vu = focus.vulkan.utils;
const pipeline = focus.vulkan.pipeline;
const style = focus.style;

const Allocator = std.mem.Allocator;
const VulkanContext = focus.vulkan.context.VulkanContext;
const Font = focus.fonts.Font;
const Swapchain = focus.vulkan.swapchain.Swapchain;
const UiPipeline = pipeline.UiPipeline;
const Ui = focus.ui.Ui;
const Screen = focus.ui.Screen;
const Editors = focus.Editors;
const OpenFileDialog = focus.dialogs.OpenFile;
const Zls = focus.Zls;

const windows = std.os.windows;
pub extern "user32" fn GetConsoleWindow() callconv(windows.WINAPI) windows.HWND;

var GPA = std.heap.GeneralPurposeAllocator(.{ .never_unmap = false }){};

const APP_NAME = if (focus.DEBUG_MODE) "Focus (debug)" else "Focus";
const FONT_NAME = "../fonts/FiraCode-Retina.ttf"; // relative to "src"
const FONT_SIZE = 18; // for scale = 1.0

var g_events: std.ArrayList(Event) = undefined;

pub fn main() !void {
    // Hide the console window (we have to run as a console app, at least for now)
    if (builtin.os.tag == .windows) {
        _ = windows.user32.showWindow(GetConsoleWindow(), windows.user32.SW_HIDE);
    }

    // Static arena lives until the end of the program
    var static_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer static_arena.deinit();
    var static_allocator = static_arena.allocator();

    // General-purpose allocator for things that live for more than 1 frame
    // but need to be freed before the end of the program
    const gpa = if (focus.DEBUG_MODE) GPA.allocator() else std.heap.c_allocator;

    try glfw.init(.{});
    defer glfw.terminate();

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

    // Create window
    var window_visible = false;
    const window = try glfw.Window.create(1000, 1000, APP_NAME, null, null, .{
        .client_api = .no_api,
        .focused = true,
        .focus_on_show = true,
        .visible = window_visible,
        // .maximized = false,
        // .decorated = false,  // NOTE: there's a bug which causes the window to be bigger than the monitor
        //                      // (or causes it to report a bigger size than it actually is)
        .scale_to_monitor = true,
        .srgb_capable = true,
    });

    // Move window to the biggest monitor and maximise
    try window.setPosInt(monitor_pos.x, monitor_pos.y);
    try window.setSizeLimits(.{ .width = 400, .height = 400 }, .{ .width = null, .height = null });

    defer window.destroy();

    // Set window icon
    const window_icon_img_data = @embedFile("../images/focus.png");
    const window_icon = stbi.load(.{ .buffer = window_icon_img_data }, .rgb_alpha) catch u.panic("Couldn't load window icon", .{});
    defer window_icon.free();
    window.setIcon(static_allocator, &[_]glfw.Image{.{
        .width = window_icon.width,
        .height = window_icon.height,
        .pixels = window_icon.pixels,
        .owned = true,
    }}) catch u.panic("Couldn't set window icon", .{});

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
    window.setFocusCallback(windowFocusChanged);

    // Init UI
    var ui = try Ui.init(gpa, &vc);
    defer ui.deinit(&vc);

    // Init the zig language server
    var zls = Zls.init(gpa);
    zls.start() catch @panic("Couldn't start the Zig language server");
    defer zls.shutdown();

    // Init editor manager
    var editors = Editors.init(gpa, &zls);
    defer editors.deinit();

    g_events.append(.redraw_requested) catch u.oom();

    var frame_number: usize = 0;
    const app_start_ms = std.time.nanoTimestamp();
    var clock_ms: f64 = 0;
    var last_redraw_ms: f64 = 0;

    var open_file_dialog: ?OpenFileDialog = null;

    while (!window.shouldClose()) {
        var frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer frame_arena.deinit();
        var frame_allocator = frame_arena.allocator();

        frame_number += 1;

        // Ask the swapchain for the next image
        const is_optimal = swapchain.acquireNextImage();
        if (!is_optimal) {
            // Recreate swapchain if necessary
            var new_size = try window.getFramebufferSize();
            while (new_size.width == 0 or new_size.height == 0) {
                // Window is minimised. Pause until it's back
                try glfw.waitEvents();
                new_size = try window.getFramebufferSize();
            }

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

        // Monotonically increasing clock for animations
        clock_ms = @intToFloat(f64, std.time.nanoTimestamp() - app_start_ms) / 1_000_000;

        // Otherwise sleep until something happens
        while (g_events.items.len == 0 and !window.shouldClose()) {
            try glfw.waitEventsTimeout(0.5);
            clock_ms = @intToFloat(f64, std.time.nanoTimestamp() - app_start_ms) / 1_000_000;

            // Always update at least once in 0.5 seconds
            const redraw = true; // set to false for printf debugging
            if (focus.RELEASE_MODE and !redraw) @compileError("Auto-redraw should be enabled for release");
            if (redraw and clock_ms - last_redraw_ms >= 500) break;
        }
        last_redraw_ms = clock_ms;

        // Process events
        if (open_file_dialog) |*dialog| {
            // All events go to the dialog
            for (g_events.items) |event| {
                switch (event) {
                    .char_entered => |char| {
                        dialog.charEntered(char);
                    },
                    .key_pressed => |kp| {
                        if (kp.key == .escape or (kp.mods.control and kp.key == .p)) {
                            // Close dialog
                            dialog.deinit();
                            open_file_dialog = null;
                        } else {
                            const action = dialog.keyPress(kp.key, kp.mods, frame_allocator);
                            if (action) |a| {
                                switch (a) {
                                    .open_file => |of| editors.openFile(of.path, of.on_the_side),
                                    // no more actions yet
                                }
                                // On any action close the dialog
                                dialog.deinit();
                                open_file_dialog = null;
                            }
                        }
                    },
                    else => {},
                }
            }
        } else {
            // Normal editor mode
            for (g_events.items) |event| {
                switch (event) {
                    .char_entered => |char| {
                        editors.charEntered(char, clock_ms);
                    },
                    .focus_changed => |focused| {
                        editors.focused = focused;
                    },
                    .key_pressed => |kp| {
                        if (u.modsOnlyCmd(kp.mods) and kp.key == .p) {
                            open_file_dialog = try OpenFileDialog.init(gpa);
                            if (editors.getActiveEditorFilePath()) |path| {
                                // Open files relavitely to the currently active buffer
                                open_file_dialog.?.navigateToDir(path);
                            }
                            continue;
                        }
                        editors.keyPress(kp.key, kp.mods, frame_allocator, clock_ms);
                    },
                    else => {},
                }
            }
        }
        g_events.clearRetainingCapacity();

        // Update uniform buffer
        // NOTE: no need to update every frame right now, but we're still doing it
        // because it'll be easier to add stuff here if we need to
        uniform_buffer.data.screen_size = u.Vec2{
            .x = @intToFloat(f32, screen.size.width),
            .y = @intToFloat(f32, screen.size.height),
        };
        try uniform_buffer.copyToGPU(&vc);

        // Draw UI
        {
            ui.startFrame(screen);

            const need_redraw = editors.updateAndDrawAll(&ui, clock_ms, frame_allocator);
            if (need_redraw) g_events.append(.redraw_requested) catch u.oom();

            if (open_file_dialog) |*dialog| {
                ui.drawOpenFileDialog(dialog, frame_allocator);
            }

            // ui.drawDebugPanel(frame_number);

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

        if (!window_visible) {
            try window.maximize();
            try window.show();
            window_visible = true;
        }

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
    char_entered: u.Char,
    focus_changed: bool,
    window_resized: WindowResize,
    redraw_requested: void,

    pub const WindowResize = struct {
        width: i32,
        height: i32,
    };
    pub const KeyPress = struct {
        key: glfw.Key,
        mods: glfw.Mods,
    };
};

fn newKeyEvent(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
    _ = window;
    _ = scancode;
    if ((action == .press or action == .repeat) and !isCharEvent(key, mods)) {
        g_events.append(Event{ .key_pressed = .{ .key = key, .mods = mods } }) catch u.oom();
    }
}

fn isCharEvent(key: glfw.Key, mods: glfw.Mods) bool {
    if (mods.control or mods.super or mods.alt) return false;
    switch (key) {
        .space, .apostrophe, .comma, .minus, .period, .slash, .zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine, .semicolon, .equal, .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z, .left_bracket, .backslash, .right_bracket, .grave_accent, .world_1, .world_2 => return true,
        else => return false,
    }
}

fn newCharEvent(window: glfw.Window, char: u.Char) void {
    _ = window;
    g_events.append(Event{ .char_entered = char }) catch u.oom();
}

fn newWindowSizeEvent(window: glfw.Window, width: i32, height: i32) void {
    _ = window;
    g_events.append(Event{ .window_resized = .{ .width = width, .height = height } }) catch u.oom();
}

fn windowFocusChanged(window: glfw.Window, focused: bool) void {
    _ = window;
    g_events.append(Event{ .focus_changed = focused }) catch u.oom();
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
