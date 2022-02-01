const std = @import("std");
const stbtt = @import("stbtt");

const Allocator = std.mem.Allocator;

pub fn pack_fonts_into_texture(allocator: Allocator, filename: []const u8, width: usize, height: usize) !void {
    var pixels = try allocator.alloc(u8, width * height);

    const font_data = try read_entire_file(filename, allocator);
    defer allocator.free(font_data);

    var pack_context = try stbtt.packBegin(pixels, width, height, 0, 1, null);
    defer stbtt.packEnd(&pack_context);
}

fn read_entire_file(filename: []const u8, allocator: Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile(filename, .{ .read = true });
    defer file.close();

    return file.reader().readAllAlloc(allocator, 10 * 1024 * 1024); // max 10 Mb
}
