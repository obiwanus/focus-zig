const std = @import("std");

const Allocator = std.mem.Allocator;

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

    pub fn copy(self: Rect) Rect {
        return self;
    }

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

    pub fn shrinkEvenly(self: Rect, margin: f32) Rect {
        return self.shrink(margin, margin, margin, margin);
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

pub fn bytesToCodepoints(bytes: []const u8, allocator: Allocator) ![]Codepoint {
    var codepoints = std.ArrayList(Codepoint).init(allocator);
    const utf8_view = try std.unicode.Utf8View.init(bytes);
    var iterator = utf8_view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        try codepoints.append(codepoint);
    }
    return codepoints.toOwnedSlice();
}

pub fn oom() noreturn {
    @panic("Out of memory");
}
