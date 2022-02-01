const assert = @import("std").debug.assert;

pub const ReqComp = enum(c_int) {
    default = 0, // only used for desired_channels

    grey = 1,
    grey_alpha = 2,
    rgb = 3,
    rgb_alpha = 4,
};

pub const Image = struct {
    width: u32,
    height: u32,
    channels: u32,
    pixels: []u8,

    pub fn free(self: Image) void {
        stbi_image_free(self.pixels.ptr);
    }

    pub fn num_bytes(self: Image) usize {
        return self.pixels.len * @sizeOf(@TypeOf(self.pixels[0]));
    }
};

extern fn stbi_load(filename: [*c]const u8, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int, req_comp: ReqComp) [*c]u8;
extern fn stbi_image_free(pixels: ?*anyopaque) void;

pub fn load(filename: [:0]const u8, req_comp: ReqComp) !Image {
    var x: c_int = undefined;
    var y: c_int = undefined;
    var comp: c_int = undefined;

    const pixels: ?[*]u8 = stbi_load(filename, &x, &y, &comp, req_comp);
    if (pixels == null) {
        return error.ImageLoadError;
    }

    const channels = if (req_comp != .default)
        @enumToInt(req_comp)
    else
        comp;

    const size = @intCast(usize, x * y * channels);
    assert(size > 0);

    return Image{
        .width = @intCast(u32, x),
        .height = @intCast(u32, y),
        .channels = @intCast(u32, channels),
        .pixels = pixels.?[0..size],
    };
}
