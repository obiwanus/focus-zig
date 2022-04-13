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
const Vec2 = u.Vec2;
const Ui = @import("ui.zig").Ui;

const print = std.debug.print;
const assert = std.debug.assert;

var GPA = std.heap.GeneralPurposeAllocator(.{ .never_unmap = false }){};

const APP_NAME = "Focus";
const FONT_NAME = "fonts/FiraCode-Retina.ttf";
const FONT_SIZE = 18; // for scale = 1.0
const TAB_SIZE = 4;
const MAX_VERTEX_COUNT = 100000;

// Distance from edges to where text starts
const TEXT_MARGIN = Margin{
    .left = 30,
    .top = 15,
    .right = 30,
    .bottom = 15,
};

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

    // Choose the biggest monitor
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

    const window = try glfw.Window.create(1000, 1000, APP_NAME, null, null, .{
        .client_api = .no_api,
        .focused = true,
        // .maximized = false,
        // .decorated = false,  // NOTE: there's a bug which causes the window to be bigger than the monitor
        //                      // (or causes it to report a bigger size than it actually is)
        .scale_to_monitor = true,
        .srgb_capable = true,
    });
    // // An attempt to remove window title on windows (didn't work)
    // if (builtin.os.tag == .windows) {
    //     // Remove window decorations
    //     const native = glfw.Native(.{ .win32 = true });
    //     const hwnd = native.getWin32Window(window);
    //     _ = try std.os.windows.user32.setWindowLongA(hwnd, std.os.windows.user32.GWL_STYLE, 0);
    // }
    const monitor_pos = try monitor.getPosInt();
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

    // Initialise global context
    g_screen.size = x: {
        const size = try window.getFramebufferSize();
        break :x vk.Extent2D{
            .width = size.width,
            .height = size.height,
        };
    };
    const content_scale = try window.getContentScale();
    assert(content_scale.x_scale == content_scale.y_scale);
    g_screen.scale = content_scale.x_scale;
    g_screen.font = try Font.init(&vc, gpa, FONT_NAME, FONT_SIZE * g_screen.scale, main_cmd_pool);
    defer g_screen.font.deinit(&vc);

    {
        const working_area_width = g_screen.size.width - TEXT_MARGIN.left - TEXT_MARGIN.right;
        const working_area_height = g_screen.size.height - TEXT_MARGIN.top - TEXT_MARGIN.bottom;
        g_screen.total_cols = @floatToInt(usize, @intToFloat(f32, working_area_width) / g_screen.font.xadvance);
        g_screen.total_lines = @floatToInt(usize, @intToFloat(f32, working_area_height) / g_screen.font.line_height);
    }

    g_buf = try TextBuffer.init(gpa, "main.zig");
    defer g_buf.deinit();
    g_buf.text_changed = true; // trigger initial update

    var swapchain = try Swapchain.init(&vc, static_allocator, g_screen.size);
    defer swapchain.deinit();

    // We have only one render pass
    const render_pass = try createRenderPass(&vc, swapchain.surface_format.format);
    defer vc.vkd.destroyRenderPass(vc.dev, render_pass, null);

    // Uniform buffer - shared between pipelines
    var uniform_buffer = try vu.UniformBuffer.init(&vc, g_screen.size);
    defer uniform_buffer.deinit(&vc);
    try uniform_buffer.copyToGPU(&vc);

    // UI pipeline
    var ui_pipeline = try UiPipeline.init(&vc, render_pass, uniform_buffer.descriptor_set_layout);
    ui_pipeline.updateFontTextureDescriptor(&vc, g_screen.font.atlas_texture.view);
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

    while (!window.shouldClose()) {
        // Ask the swapchain for the next image
        const is_optimal = swapchain.acquire_next_image();
        if (!is_optimal) {
            // Recreate swapchain if necessary
            const new_size = try window.getFramebufferSize();
            g_screen.size.width = new_size.width;
            g_screen.size.height = new_size.height;

            try swapchain.recreate(g_screen.size);
            if (!swapchain.acquire_next_image()) {
                return error.SwapchainRecreationFailure;
            }

            // Make sure the font is updated
            const new_scale = try window.getContentScale();
            if (g_screen.scaleChanged(new_scale)) {
                g_screen.scale = new_scale.x_scale;
                g_screen.font.deinit(&vc);
                g_screen.font = try Font.init(&vc, gpa, FONT_NAME, FONT_SIZE * new_scale.x_scale, main_cmd_pool);
                ui_pipeline.updateFontTextureDescriptor(&vc, g_screen.font.atlas_texture.view);
            }

            const working_area_width = g_screen.size.width - TEXT_MARGIN.left - TEXT_MARGIN.right;
            const working_area_height = g_screen.size.height - TEXT_MARGIN.top - TEXT_MARGIN.bottom;
            g_screen.total_cols = @floatToInt(usize, @intToFloat(f32, working_area_width) / g_screen.font.xadvance);
            g_screen.total_lines = @floatToInt(usize, @intToFloat(f32, working_area_height) / g_screen.font.line_height);

            vu.destroyFramebuffers(&vc, gpa, framebuffers);
            framebuffers = try createFramebuffers(&vc, gpa, render_pass, swapchain);

            g_buf.view_changed = true;
        }

        // Wait for input
        // TODO: do not process events we don't care about
        try glfw.waitEvents();

        // Update view or text
        if (g_buf.view_changed or g_buf.text_changed) {
            g_buf.view_changed = false;
            if (g_buf.text_changed) {
                g_buf.text_changed = false;
                // TODO: do it from cursor? - only applicable if the change was made by the cursor
                try g_buf.recalculateLines();
                try g_buf.recalculateBytes();
                try g_buf.highlightCode();
            }
            g_buf.updateCursorAndViewport();

            // Update uniform buffer
            uniform_buffer.data.screen_size = Vec2{
                .x = @intToFloat(f32, g_screen.size.width),
                .y = @intToFloat(f32, g_screen.size.height),
            };
            try uniform_buffer.copyToGPU(&vc);

            // Draw UI
            ui.start_frame();
            // ui.drawSolidRect(100, 100, 300, 300, u.Color{ .r = 1, .g = 1, .b = 0, .a = 0.5 });
            // ui.drawSolidRect(400, 100, 200, 500, u.Color{ .r = 0, .g = 1, .b = 1, .a = 1 });
            // ui.drawLetter('a', g_screen.font, 600, 200, 1000, 600, u.Color{ .r = 1, .g = 1, .b = 0, .a = 1 });

            // Draw text
            {
                // Get visible char range
                var bottom_line = g_buf.viewport.top + g_screen.total_lines;
                if (bottom_line > g_buf.lines.items.len - 1) {
                    bottom_line = g_buf.lines.items.len - 1;
                }
                const start_char = g_buf.lines.items[g_buf.viewport.top];
                const end_char = g_buf.lines.items[bottom_line];

                const chars = g_buf.chars.items[start_char..end_char];
                const colors = g_buf.colors.items[start_char..end_char];
                const col_min = g_buf.viewport.left;
                const col_max = g_buf.viewport.left + g_screen.total_cols;
                const top_left = Vec2{ .x = TEXT_MARGIN.left, .y = TEXT_MARGIN.top };

                ui.drawText(chars, colors, g_screen.font, top_left, col_min, col_max);
            }

            // Draw cursor
            {
                const offset = Vec2{
                    .x = @intToFloat(f32, g_buf.cursor.col),
                    .y = @intToFloat(f32, g_buf.cursor.line - g_buf.viewport.top),
                };
                const size = Vec2{ .x = g_screen.font.xadvance, .y = g_screen.font.letter_height };
                const advance = Vec2{ .x = g_screen.font.xadvance, .y = g_screen.font.line_height };
                const padding = Vec2{ .x = 0, .y = 4.0 };

                const x = @intToFloat(f32, TEXT_MARGIN.left) + offset.x * advance.x - padding.x;
                const y = @intToFloat(f32, TEXT_MARGIN.top) + offset.y * advance.y - padding.y;
                const w = size.x + 2.0 * padding.x;
                const h = size.y + 2.0 * padding.y;

                ui.drawSolidRect(x, y, w, h, u.Color{ .r = 1, .g = 1, .b = 0.2, .a = 0.8 });
            }

            try ui.end_frame(&vc, main_cmd_pool);
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

            // const scissor = vk.Rect2D{
            //     .offset = .{
            //         .x = TEXT_MARGIN.left,
            //         .y = 5, // we don't want to cut the cursor off
            //     },
            //     .extent = .{
            //         .width = g_screen.size.width -| (TEXT_MARGIN.left + TEXT_MARGIN.right),
            //         .height = g_screen.size.height -| 10,
            //     },
            // };
            const scissor = vk.Rect2D{
                .offset = .{
                    .x = 0,
                    .y = 0,
                },
                .extent = .{
                    .width = g_screen.size.width,
                    .height = g_screen.size.height,
                },
            };
            vc.vkd.cmdSetScissor(main_cmd_buf, 0, 1, @ptrCast([*]const vk.Rect2D, &scissor));

            const clear = vk.ClearValue{
                .color = .{ .float_32 = .{ 0.086, 0.133, 0.165, 1 } },
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

const Margin = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

const Screen = struct {
    size: vk.Extent2D,
    scale: f32,
    font: Font,
    total_lines: usize,
    total_cols: usize,

    pub fn scaleChanged(self: Screen, new_scale: glfw.Window.ContentScale) bool {
        assert(new_scale.x_scale == new_scale.y_scale);
        return self.scale != new_scale.x_scale;
    }
};

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

    /// Recalculates cursor line/column coordinates from buffer position
    pub fn updateCursorAndViewport(self: *TextBuffer) void {
        self.cursor.line = for (self.lines.items) |line_start, line| {
            if (self.cursor.pos < line_start) {
                break line - 1;
            } else if (self.cursor.pos == line_start) {
                break line; // for one-line files
            }
        } else self.lines.items.len;
        self.cursor.col = self.cursor.pos - self.lines.items[self.cursor.line];

        // TODO: make a viewport method

        // Allowed cursor positions within viewport
        const padding = 4;
        const line_min = self.viewport.top + padding;
        const line_max = self.viewport.top + g_screen.total_lines - padding - 1;
        const col_min = self.viewport.left + padding;
        const col_max = self.viewport.left + g_screen.total_cols - padding - 1;

        // Detect if cursor is outside viewport
        if (self.cursor.line < line_min) {
            self.viewport.top = self.cursor.line -| padding;
        } else if (self.cursor.line > line_max) {
            self.viewport.top = self.cursor.line + padding + 1 - g_screen.total_lines;
        }
        if (self.cursor.col < col_min) {
            self.viewport.left -|= (col_min - self.cursor.col);
        } else if (self.cursor.col > col_max) {
            self.viewport.left += (self.cursor.col - col_max);
        }
    }

    pub fn getCurrentLineIndent(self: TextBuffer) usize {
        var indent: usize = 0;
        var cursor: usize = self.lines.items[self.cursor.line];
        while (self.chars.items[cursor] == ' ') {
            indent += 1;
            cursor += 1;
        }
        return indent;
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
            .right => if (g_buf.cursor.pos < g_buf.chars.items.len - 1) {
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
                const SPACES = [1]u.Codepoint{' '} ** TAB_SIZE;
                const to_next_tabstop = TAB_SIZE - g_buf.cursor.col % TAB_SIZE;
                g_buf.chars.insertSlice(g_buf.cursor.pos, SPACES[0..to_next_tabstop]) catch unreachable;
                g_buf.cursor.pos += to_next_tabstop;
                g_buf.cursor.col_wanted = null;
                g_buf.text_changed = true;
            },
            .enter => {
                var indent = g_buf.getCurrentLineIndent();
                var buf: [1024]u.Codepoint = undefined;
                if (mods.control and mods.shift) {
                    // Insert line above
                    std.mem.set(u.Codepoint, buf[0..indent], ' ');
                    buf[indent] = '\n';
                    g_buf.cursor.pos = g_buf.lines.items[g_buf.cursor.line];
                    g_buf.chars.insertSlice(g_buf.cursor.pos, buf[0 .. indent + 1]) catch unreachable;
                    g_buf.cursor.pos += indent;
                } else if (mods.control) {
                    // Insert line below
                    std.mem.set(u.Codepoint, buf[0..indent], ' ');
                    buf[indent] = '\n';
                    g_buf.cursor.pos = g_buf.lines.items[g_buf.cursor.line + 1];
                    g_buf.chars.insertSlice(g_buf.cursor.pos, buf[0 .. indent + 1]) catch unreachable;
                    g_buf.cursor.pos += indent;
                } else {
                    // Break the line normally
                    const prev_char = g_buf.chars.items[g_buf.cursor.pos -| 1];
                    const next_char = g_buf.chars.items[g_buf.cursor.pos]; // TODO: fix when near the end
                    if (prev_char == '{' and next_char == '\n') {
                        indent += TAB_SIZE;
                    }
                    buf[0] = '\n';
                    std.mem.set(u.Codepoint, buf[1 .. indent + 1], ' ');
                    g_buf.chars.insertSlice(g_buf.cursor.pos, buf[0 .. indent + 1]) catch unreachable;
                    g_buf.cursor.pos += 1 + indent;
                    if (prev_char == '{' and next_char == '\n') {
                        // Insert a closing brace
                        indent -= TAB_SIZE;
                        g_buf.chars.insertSlice(g_buf.cursor.pos, buf[0 .. indent + 1]) catch unreachable;
                        g_buf.chars.insert(g_buf.cursor.pos + indent + 1, '}') catch unreachable;
                    }
                }
                g_buf.cursor.col_wanted = null;
                g_buf.text_changed = true;
            },
            .backspace => if (g_buf.cursor.pos > 0) {
                const to_prev_tabstop = x: {
                    var spaces = g_buf.cursor.col % TAB_SIZE;
                    if (spaces == 0 and g_buf.cursor.col > 0) spaces = 4;
                    break :x spaces;
                };
                // Check if we can delete spaces to the previous tabstop
                var all_spaces: bool = false;
                if (to_prev_tabstop > 0) {
                    const pos = g_buf.cursor.pos;
                    all_spaces = for (g_buf.chars.items[(pos - to_prev_tabstop)..pos]) |char| {
                        if (char != ' ') break false;
                    } else true;
                    if (all_spaces) {
                        // Delete all spaces
                        g_buf.cursor.pos -= to_prev_tabstop;
                        const EMPTY_ARRAY = [_]u.Codepoint{};
                        g_buf.chars.replaceRange(g_buf.cursor.pos, to_prev_tabstop, EMPTY_ARRAY[0..]) catch unreachable;
                    }
                }
                if (!all_spaces) {
                    // Just delete 1 char
                    g_buf.cursor.pos -= 1;
                    _ = g_buf.chars.orderedRemove(g_buf.cursor.pos);
                }
                g_buf.cursor.col_wanted = null;
                g_buf.text_changed = true;
            },
            .delete => if (g_buf.chars.items.len > 1 and g_buf.cursor.pos < g_buf.chars.items.len - 1) {
                _ = g_buf.chars.orderedRemove(g_buf.cursor.pos);
                g_buf.cursor.col_wanted = null;
                g_buf.text_changed = true;
            },
            else => {},
        }
        g_buf.viewport.top = std.math.clamp(g_buf.viewport.top, 0, g_buf.lines.items.len -| 2);
    }
}

fn processCharEvent(window: glfw.Window, codepoint: u.Codepoint) void {
    _ = window;
    g_buf.chars.insert(g_buf.cursor.pos, codepoint) catch unreachable;
    g_buf.cursor.pos += 1;
    g_buf.cursor.col_wanted = null;
    g_buf.text_changed = true;
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
