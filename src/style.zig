const std = @import("std");

const focus = @import("focus.zig");
const Char = focus.utils.Char;

pub const Color = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,

    pub fn asArray(self: Color) [4]f32 {
        return .{ self.r, self.g, self.b, self.a };
    }
};

pub const colors = struct {
    pub const BACKGROUND = Color{ .r = 0.086, .g = 0.133, .b = 0.165, .a = 1.0 };
    pub const BACKGROUND_DARK = Color{ .r = 0.065, .g = 0.101, .b = 0.125, .a = 1.0 };
    pub const BACKGROUND_HIGHLIGHT = Color{ .r = 0.097, .g = 0.15, .b = 0.185, .a = 1.0 };
    pub const BACKGROUND_LIGHT = Color{ .r = 0.102, .g = 0.158, .b = 0.195, .a = 1.0 };
    pub const BACKGROUND_BRIGHT = Color{ .r = 0.131, .g = 0.202, .b = 0.25, .a = 1.0 };
    pub const CURSOR_ACTIVE = Color{ .r = 0.2, .g = 0.8, .b = 0.8, .a = 0.6 };
    pub const CURSOR_INACTIVE = Color{ .r = 0.2, .g = 0.239, .b = 0.267, .a = 1.0 };
    pub const SELECTION_ACTIVE = Color{ .r = 0.11, .g = 0.267, .b = 0.29, .a = 1.0 };
    pub const SELECTION_INACTIVE = Color{ .r = 0.11, .g = 0.267, .b = 0.29, .a = 0.5 };
    pub const SEARCH_RESULT_ACTIVE = Color{ .r = 0.559, .g = 0.469, .b = 0.184, .a = 1.0 };
    pub const SEARCH_RESULT_INACTIVE = Color{ .r = 0.322, .g = 0.302, .b = 0.173, .a = 1.0 };
    pub const SCROLLBAR = Color{ .r = 0.065, .g = 0.101, .b = 0.125, .a = 0.5 };

    // Code
    pub const DEFAULT = Color{ .r = 0.81, .g = 0.77, .b = 0.66, .a = 1.0 };
    pub const COMMENT = Color{ .r = 0.52, .g = 0.56, .b = 0.54, .a = 1.0 };
    pub const TYPE = Color{ .r = 0.51, .g = 0.67, .b = 0.64, .a = 1.0 };
    pub const FUNCTION = Color{ .r = 0.67, .g = 0.74, .b = 0.49, .a = 1.0 };
    pub const PUNCTUATION = Color{ .r = 0.65, .g = 0.69, .b = 0.76, .a = 1.0 };
    pub const STRING = Color{ .r = 0.85, .g = 0.68, .b = 0.33, .a = 1.0 };
    pub const VALUE = Color{ .r = 0.84, .g = 0.60, .b = 0.71, .a = 1.0 };
    pub const HIGHLIGHT = Color{ .r = 0.85, .g = 0.61, .b = 0.46, .a = 1.0 };
    pub const ERROR = Color{ .r = 1.00, .g = 0.00, .b = 0.00, .a = 1.0 };
    pub const KEYWORD = Color{ .r = 0.902, .g = 0.493, .b = 0.457, .a = 1.0 };

    // Special
    pub const SHADOW_DARK = Color{ .r = 0, .g = 0, .b = 0, .a = 0.2 };
    pub const SHADOW_TRANSPARENT = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    // pub const SHADOW_DARK = Color{ .r = 0.057, .g = 0.089, .b = 0.11, .a = 0.2 };
    // pub const SHADOW_TRANSPARENT = Color{ .r = 0.057, .g = 0.089, .b = 0.11, .a = 0 };
    pub const WARNING = Color{ .r = 0.85, .g = 0.68, .b = 0.33, .a = 1.0 };

    pub const PALETTE = [_]Color{
        // Order must match TextColor
        DEFAULT,
        COMMENT,
        TYPE,
        FUNCTION,
        PUNCTUATION,
        STRING,
        VALUE,
        HIGHLIGHT,
        ERROR,
        KEYWORD,
    };
};

pub const TextColor = enum(u8) {
    default = 0,
    comment,
    @"type",
    function,
    punctuation,
    string,
    value,
    highlight,
    @"error",
    keyword,

    const TYPE_KEYWORDS = [_][]const u8{ "bool", "usize", "isize", "type" };
    const VALUE_KEYWORDS = [_][]const u8{ "true", "false", "undefined", "null" };

    pub fn getForIdentifier(ident: []Char, next_char: ?Char) TextColor {
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
        if (next_char != null and next_char.? == '(') return .function;
        if ((ident[0] == 'u' or ident[0] == 'i' or ident[0] == 'f') and ident.len > 1 and ident.len <= 4) {
            const only_digits = for (ident[1..]) |c| {
                switch (c) {
                    '0'...'9' => continue,
                    else => break false,
                }
            } else true;
            if (only_digits) return .@"type";
        }
        if (ident.len <= 10) {
            var buf: [10]u8 = undefined;
            for (ident) |c, i| {
                buf[i] = @truncate(u8, c);
            }
            for (TYPE_KEYWORDS) |keyword| {
                if (std.mem.eql(u8, keyword, buf[0..keyword.len])) return .@"type";
            }
            for (VALUE_KEYWORDS) |keyword| {
                if (std.mem.eql(u8, keyword, buf[0..keyword.len])) return .value;
            }
        }

        return .default;
    }
};
