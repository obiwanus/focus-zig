const std = @import("std");
const builtin = @import("builtin");

const focus = @import("../focus.zig");
const u = focus.utils;

const Allocator = std.mem.Allocator;

const Self = @This();

root: Dir,
current_dir: ?*Dir = null,

memory_arena: std.heap.ArenaAllocator,

const delimiter = if (builtin.os.tag == .windows) "\\" else "/";

// Filesystem tree node
pub const Dir = struct {
    name: std.ArrayList(u8),
    dirs: std.ArrayList(Dir),
    files: std.ArrayList(File),
    selected: usize,

    pub const Entry = union(enum) {
        dir: *Dir,
        file: *File,
    };

    pub fn init(allocator: Allocator, name_slice: []const u8) Dir {
        var name = std.ArrayList(u8).init(allocator);
        name.appendSlice(name_slice) catch u.oom();
        return Dir{
            .name = name,
            .dirs = std.ArrayList(Dir).init(allocator),
            .files = std.ArrayList(File).init(allocator),
            .selected = 0,
        };
    }

    pub fn deinit(self: *Dir) void {
        for (self.dirs.items) |*dir| {
            dir.deinit();
        }
        self.files.deinit();
    }

    pub fn printTree(self: Dir, level: usize) void {
        const indent = " " ** 100;
        u.print("{s}[{s}]\n", .{ indent[0 .. 4 * level], self.name.items });
        for (self.dirs.items) |dir| {
            dir.printTree(level + 1);
        }
        for (self.files.items) |f| {
            u.print("{s} {s} \n", .{ indent[0 .. 4 * (level + 1)], f.name.items });
        }
    }

    pub fn insertFileIntoTree(self: *Dir, path: []const u8, path_chunks: []const []const u8, allocator: Allocator) void {
        if (path_chunks.len >= 2) {
            // <dir_name>\...
            const dir_name = path_chunks[0];

            // Insert dir into list if doesn't exist
            var dir = for (self.dirs.items) |d| {
                if (std.mem.eql(u8, d.name.items, dir_name)) {
                    break d;
                }
            } else blk: {
                var new_dir = Dir.init(allocator, dir_name);
                self.dirs.append(new_dir) catch u.oom();
                break :blk new_dir;
            };

            // Insert the rest into the dir
            dir.insertFileIntoTree(path, path_chunks[1..], allocator);
        } else if (path_chunks.len == 1) {
            // <file_name>
            const file_name = path_chunks[0];
            const file = File.init(allocator, file_name, path);
            self.files.append(file) catch u.oom();
        } else unreachable;
    }

    pub fn totalEntries(self: Dir) usize {
        return self.dirs.items.len + self.files.items.len;
    }

    pub fn selectedEntry(self: *Dir) Entry {
        if (self.selected < self.dirs.items.len) {
            return Entry{ .dir = &self.dirs.items[self.selected] };
        }
        u.assert(self.selected < self.totalEntries());
        return Entry{ .file = &self.files.items[self.selected - self.dirs.items.len] };
    }
};

pub const File = struct {
    name: std.ArrayList(u8), // for displaying
    path: std.ArrayList(u8), // for opening

    pub fn init(allocator: Allocator, name_slice: []const u8, path_slice: []const u8) File {
        var name = std.ArrayList(u8).init(allocator);
        var path = std.ArrayList(u8).init(allocator);
        name.appendSlice(name_slice) catch u.oom();
        path.appendSlice(path_slice) catch u.oom();
        return File{
            .name = name,
            .path = path,
        };
    }
};

pub fn init(allocator: Allocator) !Self {
    var arena = std.heap.ArenaAllocator.init(allocator);
    var arena_allocator = arena.allocator();

    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var root = Dir.init(arena_allocator, ".");
    const folders_to_ignore = [_][]const u8{
        ".git",
        "zig-cache",
        "zig-out",
    };

    // Go through all the files and subfolders and build a tree
    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .File => {
                // Split path into chunks
                var iter = std.mem.split(u8, entry.path, delimiter);
                var path_chunks: [50][]const u8 = undefined; // (surely 50 should be enough)
                var i: usize = 0;
                while (iter.next()) |chunk| {
                    path_chunks[i] = chunk;
                    i += 1;
                }
                u.assert(i < 50);
                const ignore = for (folders_to_ignore) |folder| {
                    if (std.mem.eql(u8, folder, path_chunks[0])) break true;
                } else false;
                if (ignore) continue;

                root.insertFileIntoTree(entry.path, path_chunks[0..i], arena_allocator);
            },
            else => continue, // ignore everything else
        }
    }

    return Self{
        .root = root,
        .current_dir = null,
        .memory_arena = arena,
    };
}

pub fn deinit(self: *Self) void {
    self.root.deinit();
    self.memory_arena.deinit();
}

pub fn getCurrentDir(self: *Self) *Dir {
    if (self.current_dir) |current_dir| return current_dir;
    return &self.root;
}
