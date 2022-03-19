pub const Codepoint = u21;

pub const Vec2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const TextColor = enum(u8) {
    default = 0,
    comment,
    @"type",
    function,
    punctuation,
    string,
    number,
    keyword,
};

pub const Color = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,
};
