const std = @import("std");
const builtin = @import("builtin");

const glfw = @import("glfw");

const Allocator = std.mem.Allocator;

pub const Char = u21;

pub const assert = std.debug.assert;
pub const print = std.debug.print;

pub fn println(comptime fmt: []const u8, args: anytype) void {
    print(fmt ++ "\n", args);
}

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

    pub fn topLeft(self: Rect) Vec2 {
        return Vec2{ .x = self.x, .y = self.y };
    }

    pub fn r(self: Rect) f32 {
        return self.x + self.w;
    }

    pub fn b(self: Rect) f32 {
        return self.y + self.h;
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

pub fn bytesToChars(bytes: []const u8, allocator: Allocator) ![]Char {
    var chars = std.ArrayList(Char).init(allocator);
    const utf8_view = try std.unicode.Utf8View.init(bytes);
    var iterator = utf8_view.iterator();
    while (iterator.nextCodepoint()) |char| {
        chars.append(char) catch oom();
    }
    return chars.toOwnedSlice();
}

pub fn charsToBytes(chars: []const Char, allocator: Allocator) ![]u8 {
    var bytes = std.ArrayList(u8).init(allocator);
    bytes.ensureTotalCapacity(chars.len * 4) catch oom();
    bytes.expandToCapacity();
    var total_bytes: usize = 0;
    for (chars) |char| {
        const num_bytes = try std.unicode.utf8Encode(char, bytes.items[total_bytes..]);
        total_bytes += num_bytes;
    }
    bytes.shrinkRetainingCapacity(total_bytes);
    return bytes.toOwnedSlice();
}

pub fn readEntireFile(file_path: []const u8, allocator: Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile(file_path, .{ .read = true });
    defer file.close();

    const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10 Mb
    const result = file.reader().readAllAlloc(allocator, MAX_FILE_SIZE) catch |e| switch (e) {
        error.StreamTooLong => return e,
        else => oom(), // we want to die on OOM but we want to know if the error is different
    };
    return result;
}

pub fn writeEntireFile(file_path: []const u8, buffer: []const u8) !void {
    const file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(buffer);
}

pub fn modsOnlyCtrl(m: glfw.Mods) bool {
    return m.control and !(m.shift or m.alt or m.super);
}

pub fn oom() noreturn {
    @panic("Out of memory");
}

pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    @panic(msg);
}

pub fn pathChunksIterator(path: []const u8) std.mem.SplitIterator(u8) {
    const delimiter = if (builtin.os.tag == .windows) "\\" else "/";
    return std.mem.split(u8, path, delimiter);
}

pub fn isWordChar(char: Char) bool {
    return switch (char) {
        '0'...'9', 'A'...'Z', 'a'...'z', '_' => true,
        'А'...'Я', 'а'...'я' => true,
        else => false,
    };
}
