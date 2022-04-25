const std = @import("std");
pub const Codepoint = u21;

pub const assert = std.debug.assert;
pub const print = std.debug.print;

pub const Vec2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn shrink(self: Rect, left: f32, top: f32, right: f32, bottom: f32) Rect {
        assert(self.w >= left + right);
        assert(self.h >= top + bottom);
        return Rect{
            .x = self.x + left,
            .y = self.y + top,
            .w = self.w - right - left,
            .h = self.h - bottom - top,
        };
    }

    pub fn splitLeft(self: *Rect, w: f32, margin: f32) Rect {
        assert(self.w >= w);
        const split = Rect{ .x = self.x, .y = self.y, .w = w, .h = self.h };
        self.x += w + margin;
        self.w -= w + margin;
        return split;
    }

    pub fn splitRight(self: *Rect, w: f32, margin: f32) Rect {
        assert(self.w >= w);
        const split = Rect{ .x = self.x + self.w - w, .y = self.y, .w = w, .h = self.h };
        self.w -= w + margin;
        return split;
    }

    pub fn splitBottom(self: *Rect, h: f32, margin: f32) Rect {
        assert(self.h >= h);
        const split = Rect{ .x = self.x, .y = self.y + self.h - h, .w = self.w, .h = h };
        self.h -= h + margin;
        return split;
    }

    pub fn splitTop(self: *Rect, h: f32, margin: f32) Rect {
        assert(self.h >= h);
        const split = Rect{ .x = self.x, .y = self.y, .w = self.w, .h = h };
        self.y += h + margin;
        self.h -= h + margin;
        return split;
    }
};

const TYPE_KEYWORDS = [_][]const u8{ "bool", "usize", "type" };
const VALUE_KEYWORDS = [_][]const u8{ "true", "false", "undefined", "null" };

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

    pub fn getForIdentifier(ident: []Codepoint, next_char: Codepoint) TextColor {
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
        if (next_char == '(') return .function;
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

pub const Color = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,
};

pub fn oom() noreturn {
    @panic("Out of memory");
}
