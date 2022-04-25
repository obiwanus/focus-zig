const std = @import("std");
const vk = @import("vulkan");

const VulkanContext = @import("context.zig").VulkanContext;
const Allocator = std.mem.Allocator;

pub const Swapchain = struct {
    vc: *const VulkanContext,
    allocator: Allocator,

    surface_format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    extent: vk.Extent2D,
    handle: vk.SwapchainKHR,

    swap_images: []SwapImage,
    image_index: u32,

    image_acquired_semaphore: vk.Semaphore,
    render_finished_semaphore: vk.Semaphore,
    render_finished_fence: vk.Fence,

    pub fn init(vc: *const VulkanContext, allocator: Allocator, extent: vk.Extent2D) !Swapchain {
        return initRecycle(vc, allocator, extent, .null_handle);
    }

    pub fn initRecycle(vc: *const VulkanContext, allocator: Allocator, extent: vk.Extent2D, old_handle: vk.SwapchainKHR) !Swapchain {
        const caps = try vc.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(vc.pdev, vc.surface);
        const actual_extent = findActualExtent(caps, extent);
        if (actual_extent.width == 0 or actual_extent.height == 0) {
            return error.InvalidSurfaceDimensions;
        }

        const surface_format = try findSurfaceFormat(vc, allocator);
        const present_mode = try findPresentMode(vc, allocator);

        var image_count = caps.min_image_count + 1;
        if (caps.max_image_count > 0) {
            image_count = std.math.min(image_count, caps.max_image_count);
        }

        const qfi = [_]u32{ vc.graphics_queue.family, vc.present_queue.family };
        const sharing_mode: vk.SharingMode = if (vc.graphics_queue.family != vc.present_queue.family)
            .concurrent
        else
            .exclusive;

        const handle = try vc.vkd.createSwapchainKHR(vc.dev, &.{
            .flags = .{},
            .surface = vc.surface,
            .min_image_count = image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = actual_extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
            .image_sharing_mode = sharing_mode,
            .queue_family_index_count = qfi.len,
            .p_queue_family_indices = &qfi,
            .pre_transform = caps.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = vk.TRUE,
            .old_swapchain = old_handle,
        }, null);
        errdefer vc.vkd.destroySwapchainKHR(vc.dev, handle, null);

        if (old_handle != .null_handle) {
            vc.vkd.destroySwapchainKHR(vc.dev, old_handle, null);
        }

        // Signaled when swapchain has acquired a new image
        const image_acquired_semaphore = try vc.vkd.createSemaphore(vc.dev, &.{ .flags = .{} }, null);
        errdefer vc.vkd.destroySemaphore(vc.dev, image_acquired_semaphore, null);
        // Signaled when the GPU is done rendering last frame
        const render_finished_semaphore = try vc.vkd.createSemaphore(vc.dev, &.{ .flags = .{} }, null);
        errdefer vc.vkd.destroySemaphore(vc.dev, render_finished_semaphore, null);
        const render_finished_fence = try vc.vkd.createFence(vc.dev, &.{ .flags = .{ .signaled_bit = false } }, null);
        errdefer vc.vkd.destroyFence(vc.dev, render_finished_fence, null);

        const swap_images = try initSwapchainImages(vc, handle, surface_format.format, allocator);
        errdefer for (swap_images) |si| si.deinit(vc);

        return Swapchain{
            .vc = vc,
            .allocator = allocator,
            .surface_format = surface_format,
            .present_mode = present_mode,
            .extent = actual_extent,
            .handle = handle,
            .swap_images = swap_images,
            .image_index = undefined, // NOTE: image must be acquired for it to be defined
            .image_acquired_semaphore = image_acquired_semaphore,
            .render_finished_semaphore = render_finished_semaphore,
            .render_finished_fence = render_finished_fence,
        };
    }

    pub fn deinit(self: Swapchain) void {
        self.deinitExceptSwapchain() catch unreachable;
        self.vc.vkd.destroySwapchainKHR(self.vc.dev, self.handle, null);
    }

    fn deinitExceptSwapchain(self: Swapchain) !void {
        // TODO:
        // // Wait until we're not rendering
        // _ = try self.vc.vkd.waitForFences(self.vc.dev, 1, @ptrCast([*]const vk.Fence, &self.render_finished_fence), vk.TRUE, std.math.maxInt(u64));

        for (self.swap_images) |si| si.deinit(self.vc);
        self.vc.vkd.destroySemaphore(self.vc.dev, self.image_acquired_semaphore, null);
        self.vc.vkd.destroySemaphore(self.vc.dev, self.render_finished_semaphore, null);
        self.vc.vkd.destroyFence(self.vc.dev, self.render_finished_fence, null);
    }

    pub fn recreate(self: *Swapchain, new_extent: vk.Extent2D) !void {
        const vc = self.vc;
        const allocator = self.allocator;
        const old_handle = self.handle;
        try self.deinitExceptSwapchain();
        self.* = try initRecycle(vc, allocator, new_extent, old_handle);
    }

    pub fn waitUntilLastFrameIsRendered(self: Swapchain) !void {
        _ = try self.vc.vkd.waitForFences(self.vc.dev, 1, @ptrCast([*]const vk.Fence, &self.render_finished_fence), vk.TRUE, std.math.maxInt(u64));
        try self.vc.vkd.resetFences(self.vc.dev, 1, @ptrCast([*]const vk.Fence, &self.render_finished_fence));
    }

    pub fn acquireNextImage(self: *Swapchain) bool {
        const result = self.vc.vkd.acquireNextImageKHR(
            self.vc.dev,
            self.handle,
            std.math.maxInt(u64),
            self.image_acquired_semaphore,
            .null_handle,
        ) catch |err| switch (err) {
            error.OutOfDateKHR => return false,
            else => unreachable, // TODO: what other errors are possible?
        };
        switch (result.result) {
            .success => {
                self.image_index = result.image_index;
                return true;
            },
            .suboptimal_khr => return false,
            else => unreachable, // TODO: what other results are possible?
        }
    }
};

const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,

    fn init(vc: *const VulkanContext, image: vk.Image, format: vk.Format) !SwapImage {
        const view = try vc.vkd.createImageView(vc.dev, &.{
            .flags = .{},
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        errdefer vc.vkd.destroyImageView(vc.dev, view, null);

        return SwapImage{
            .image = image,
            .view = view,
        };
    }

    fn deinit(self: SwapImage, vc: *const VulkanContext) void {
        vc.vkd.destroyImageView(vc.dev, self.view, null);
    }
};

fn findActualExtent(caps: vk.SurfaceCapabilitiesKHR, extent: vk.Extent2D) vk.Extent2D {
    if (caps.current_extent.width != 0xFFFF_FFFF) {
        return caps.current_extent;
    } else {
        return .{
            .width = std.math.clamp(extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
        };
    }
}

fn findSurfaceFormat(vc: *const VulkanContext, allocator: Allocator) !vk.SurfaceFormatKHR {
    const preferred = vk.SurfaceFormatKHR{
        .format = .b8g8r8a8_unorm,
        .color_space = .srgb_nonlinear_khr,
    };

    var count: u32 = undefined;
    _ = try vc.vki.getPhysicalDeviceSurfaceFormatsKHR(vc.pdev, vc.surface, &count, null);
    const surface_formats = try allocator.alloc(vk.SurfaceFormatKHR, count);
    defer allocator.free(surface_formats);
    _ = try vc.vki.getPhysicalDeviceSurfaceFormatsKHR(vc.pdev, vc.surface, &count, surface_formats.ptr);

    for (surface_formats) |format| {
        if (std.meta.eql(format, preferred)) {
            return preferred;
        }
    }

    return surface_formats[0]; // there must always be at least one supported format
}

fn findPresentMode(vc: *const VulkanContext, allocator: Allocator) !vk.PresentModeKHR {
    var count: u32 = undefined;
    _ = try vc.vki.getPhysicalDeviceSurfacePresentModesKHR(vc.pdev, vc.surface, &count, null);
    const present_modes = try allocator.alloc(vk.PresentModeKHR, count);
    defer allocator.free(present_modes);
    _ = try vc.vki.getPhysicalDeviceSurfacePresentModesKHR(vc.pdev, vc.surface, &count, present_modes.ptr);

    const preferred = [_]vk.PresentModeKHR{
        .mailbox_khr,
        .immediate_khr, // comment out to enable vsync
    };

    for (preferred) |mode| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, mode) != null) {
            return mode;
        }
    }
    return .fifo_khr;
}

fn initSwapchainImages(vc: *const VulkanContext, swapchain: vk.SwapchainKHR, format: vk.Format, allocator: Allocator) ![]SwapImage {
    var count: u32 = undefined;
    _ = try vc.vkd.getSwapchainImagesKHR(vc.dev, swapchain, &count, null);
    const images = try allocator.alloc(vk.Image, count);
    defer allocator.free(images);
    _ = try vc.vkd.getSwapchainImagesKHR(vc.dev, swapchain, &count, images.ptr);

    const swap_images = try allocator.alloc(SwapImage, count);
    errdefer allocator.free(swap_images);

    var i: usize = 0;
    errdefer for (swap_images[0..i]) |si| si.deinit(vc);

    for (images) |image| {
        swap_images[i] = try SwapImage.init(vc, image, format);
        i += 1;
    }

    return swap_images;
}
