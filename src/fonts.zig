const std = @import("std");
const stbtt = @import("stbtt");

const Allocator = std.mem.Allocator;

// TODO: calculate dynamically based on oversampling and font size
const ATLAS_WIDTH = 2048;
const ATLAS_HEIGHT = 2048;
const OVERSAMPLING = 8;

pub const Font = struct {
    pixels: []u8,
    chars: []stbtt.PackedChar,
    atlas_width: u32,
    atlas_height: u32,
};

pub fn getPackedFont(allocator: Allocator, filename: []const u8, size: f32) !Font {
    var pixels_tmp = try allocator.alloc(u8, ATLAS_WIDTH * ATLAS_HEIGHT);
    var pixels = try allocator.alloc(u8, ATLAS_WIDTH * ATLAS_HEIGHT * 4); // 4 channels

    const font_data = try readEntireFile(filename, allocator);
    defer allocator.free(font_data);

    var pack_context = try stbtt.packBegin(pixels_tmp, ATLAS_WIDTH, ATLAS_HEIGHT, 0, 5, null);
    defer stbtt.packEnd(&pack_context);
    stbtt.packSetOversampling(&pack_context, OVERSAMPLING, OVERSAMPLING);

    const chars = try stbtt.packFontRange(&pack_context, font_data, size, 32, 32 * 3, allocator);

    // TODO: stop doing this
    for (pixels_tmp) |pixel, i| {
        pixels[i * 4 + 0] = pixel;
        pixels[i * 4 + 1] = pixel;
        pixels[i * 4 + 2] = pixel;
        pixels[i * 4 + 3] = 255;
    }

    return Font{
        .pixels = pixels,
        .chars = chars,
        .atlas_width = ATLAS_WIDTH,
        .atlas_height = ATLAS_HEIGHT,
    };
}

fn readEntireFile(filename: []const u8, allocator: Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile(filename, .{ .read = true });
    defer file.close();

    return file.reader().readAllAlloc(allocator, 10 * 1024 * 1024); // max 10 Mb
}
