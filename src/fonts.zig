const std = @import("std");
const stbtt = @import("stbtt");

const vk = @import("vulkan");
const vu = @import("vulkan/utils.zig");

const Allocator = std.mem.Allocator;
const VulkanContext = @import("vulkan/context.zig").VulkanContext;

const assert = std.debug.assert;

// TODO: calculate dynamically based on oversampling and font size
const ATLAS_WIDTH = 2048;
const ATLAS_HEIGHT = 2048;
const OVERSAMPLING = 8;

const FIRST_CHAR = 32;

pub const Font = struct {
    chars: []stbtt.PackedChar,
    line_height: f32,
    atlas_texture: FontTexture,

    pub fn init(vc: *const VulkanContext, allocator: Allocator, filename: []const u8, size: f32, cmd_pool: vk.CommandPool) !Font {
        var pixels_tmp = try allocator.alloc(u8, ATLAS_WIDTH * ATLAS_HEIGHT);
        defer allocator.free(pixels_tmp);
        var pixels = try allocator.alloc(u8, ATLAS_WIDTH * ATLAS_HEIGHT * 4); // 4 channels
        defer allocator.free(pixels); // after they are uploaded we don't need them

        const font_data = try readEntireFile(filename, allocator);
        defer allocator.free(font_data);

        var pack_context = try stbtt.packBegin(pixels_tmp, ATLAS_WIDTH, ATLAS_HEIGHT, 0, 5, null);
        defer stbtt.packEnd(&pack_context);
        stbtt.packSetOversampling(&pack_context, OVERSAMPLING, OVERSAMPLING);

        const chars = try stbtt.packFontRange(&pack_context, font_data, size, FIRST_CHAR, 32 * 3, allocator);

        // TODO: stop doing this
        for (pixels_tmp) |pixel, i| {
            pixels[i * 4 + 0] = pixel;
            pixels[i * 4 + 1] = pixel;
            pixels[i * 4 + 2] = pixel;
            pixels[i * 4 + 3] = 255;
        }

        const atlas_texture = try createFontTexture(vc, pixels, ATLAS_WIDTH, ATLAS_HEIGHT, cmd_pool);

        return Font{
            .chars = chars,
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            .line_height = 23, // TODO: set based on vertical metrics
            .atlas_texture = atlas_texture,
        };
    }

    pub fn deinit(self: Font, vc: *const VulkanContext) void {
        vc.vkd.freeMemory(vc.dev, self.atlas_texture.memory, null);
        vc.vkd.destroyImageView(vc.dev, self.atlas_texture.view, null);
        vc.vkd.destroyImage(vc.dev, self.atlas_texture.image, null);
    }

    // TODO: support unicode
    pub fn getQuad(self: Font, char: u8, x: f32, y: f32) stbtt.AlignedQuad {
        const char_index = self.getCharIndex(char);
        const quad = stbtt.getPackedQuad(
            self.chars.ptr,
            ATLAS_WIDTH,
            ATLAS_HEIGHT,
            char_index,
            x,
            y,
            false, // align to integer
        );
        return quad;
    }

    fn getCharIndex(self: Font, char: u8) c_int {
        var char_index = @intCast(c_int, char) - FIRST_CHAR;
        if (char_index < 0 or char_index >= self.chars.len) {
            char_index = 0;
        }
        return char_index;
    }

    pub fn getXAdvance(self: Font, char: u8) f32 {
        const char_index = self.getCharIndex(char);
        return self.chars[@intCast(usize, char_index)].xadvance;
    }
};

const FontTexture = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
};

fn readEntireFile(filename: []const u8, allocator: Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile(filename, .{ .read = true });
    defer file.close();

    return file.reader().readAllAlloc(allocator, 10 * 1024 * 1024); // max 10 Mb
}

fn createFontTexture(vc: *const VulkanContext, pixels: []u8, width: u32, height: u32, pool: vk.CommandPool) !FontTexture {
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
    try vu.transitionImageLayout(vc, pool, texture_image, .r8g8b8a8_srgb, .@"undefined", .transfer_dst_optimal);
    try vu.copyBufferToImage(vc, pool, staging_buffer, texture_image, width, height);
    try vu.transitionImageLayout(vc, pool, texture_image, .r8g8b8a8_srgb, .transfer_dst_optimal, .shader_read_only_optimal);

    const image_view = try createImageView(vc, texture_image, .r8g8b8a8_srgb);

    return FontTexture{
        .image = texture_image,
        .memory = memory,
        .view = image_view,
    };
}

pub fn createImageView(vc: *const VulkanContext, image: vk.Image, format: vk.Format) !vk.ImageView {
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
