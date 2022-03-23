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

    pub fn getForIdentifier(ident: []Codepoint) TextColor {
        if (ident.len == 0) return .default;
        const starts_with_capital_letter = switch (ident[0]) {
            'A'...'Z' => true,
            else => false,
        };
        if (starts_with_capital_letter) {
            if (ident.len == 1) return .@"type";
            for (ident[1..]) |c| {
                // If has lowercase letters, then should be colored as a type
                switch (c) {
                    'a'...'z' => return .@"type",
                    else => continue,
                }
            }
        }
        if (ident[ident.len - 1] == '(') return .function;
        return .default;
    }
};

pub const Color = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,
};
