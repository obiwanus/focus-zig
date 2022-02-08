const std = @import("std");
const stbtt = @import("stbtt");

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

// TODO: calculate dynamically based on oversampling and font size
const ATLAS_WIDTH = 2048;
const ATLAS_HEIGHT = 2048;
const OVERSAMPLING = 8;

const FIRST_CHAR = 32;

pub const Font = struct {
    pixels: []u8,
    chars: []stbtt.PackedChar,
    atlas_width: u32,
    atlas_height: u32,

    // TODO: support unicode
    pub fn getQuad(self: Font, char: u8, x: f32, y: f32) stbtt.AlignedQuad {
        const char_index = self.getCharIndex(char);
        const quad = stbtt.getPackedQuad(
            self.chars.ptr,
            @intCast(c_int, self.atlas_width),
            @intCast(c_int, self.atlas_height),
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

pub fn getPackedFont(allocator: Allocator, filename: []const u8, size: f32) !Font {
    var pixels_tmp = try allocator.alloc(u8, ATLAS_WIDTH * ATLAS_HEIGHT);
    var pixels = try allocator.alloc(u8, ATLAS_WIDTH * ATLAS_HEIGHT * 4); // 4 channels

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
