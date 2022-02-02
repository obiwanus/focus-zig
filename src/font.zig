const std = @import("std");
const stbtt = @import("stbtt");

const Allocator = std.mem.Allocator;

pub fn pack_fonts_into_texture(allocator: Allocator, filename: []const u8, width: usize, height: usize) ![]u8 {
    var pixels_tmp = try allocator.alloc(u8, width * height);
    var pixels = try allocator.alloc(u8, width * height * 4); // 4 channels

    const font_data = try read_entire_file(filename, allocator);
    defer allocator.free(font_data);

    var pack_context = try stbtt.packBegin(pixels_tmp, width, height, 0, 1, null);
    defer stbtt.packEnd(&pack_context);

    const packed_chars = try stbtt.packFontRange(&pack_context, font_data, 30, 32, 32 * 3, allocator);
    _ = packed_chars;

    for (pixels_tmp) |pixel, i| {
        pixels[i * 4] = pixel;
        pixels[i * 4 + 1] = pixel;
        pixels[i * 4 + 2] = pixel;
        pixels[i * 4 + 3] = 255;
    }

    return pixels;
}

fn read_entire_file(filename: []const u8, allocator: Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile(filename, .{ .read = true });
    defer file.close();

    return file.reader().readAllAlloc(allocator, 10 * 1024 * 1024); // max 10 Mb
}
