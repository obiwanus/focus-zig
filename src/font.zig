const std = @import("std");
const stbtt = @import("stbtt");

const Allocator = std.mem.Allocator;

pub const Font = struct {
    pixels: []u8,
    chars: []stbtt.PackedChar,
};

pub fn getPackedFont(allocator: Allocator, filename: []const u8, width: usize, height: usize) !Font {
    var pixels_tmp = try allocator.alloc(u8, width * height);
    var pixels = try allocator.alloc(u8, width * height * 4); // 4 channels

    const font_data = try readEntireFile(filename, allocator);
    defer allocator.free(font_data);

    var pack_context = try stbtt.packBegin(pixels_tmp, width, height, 0, 1, null);
    defer stbtt.packEnd(&pack_context);
    stbtt.packSetOversampling(&pack_context, 4, 4);

    const chars = try stbtt.packFontRange(&pack_context, font_data, 70, 32, 32 * 3, allocator);

    for (pixels_tmp) |pixel, i| {
        pixels[i * 4] = pixel;
        pixels[i * 4 + 1] = pixel;
        pixels[i * 4 + 2] = pixel;
        pixels[i * 4 + 3] = 255;
    }

    return Font{
        .pixels = pixels,
        .chars = chars,
    };
}

fn readEntireFile(filename: []const u8, allocator: Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile(filename, .{ .read = true });
    defer file.close();

    return file.reader().readAllAlloc(allocator, 10 * 1024 * 1024); // max 10 Mb
}
