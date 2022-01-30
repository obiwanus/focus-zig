const assert = @import("std").debug.assert;

pub const ReqComp = enum(c_int) {
    default = 0, // only used for desired_channels

    grey = 1,
    grey_alpha = 2,
    rgb = 3,
    rgb_alpha = 4,
};

pub const Image = struct {
    width: i32,
    height: i32,
    channels: i32,
    pixels: []f32,
};

extern fn stbi_loadf(filename: [*c]const u8, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int, req_comp: ReqComp) [*c]f32;

pub fn load(filename: [:0]const u8, req_comp: ReqComp) !Image {
    var x: c_int = undefined;
    var y: c_int = undefined;
    var comp: c_int = undefined;

    const pixels: ?[*]f32 = stbi_loadf(filename, &x, &y, &comp, req_comp);
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
        .width = x,
        .height = y,
        .channels = channels,
        .pixels = pixels.?[0..size],
    };
}
