const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");

const focus = @import("../focus.zig");
const u = focus.utils;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;

const Self = @This();

root: Dir,
current_dir: ?*Dir = null,
filter_text: ArrayList(u.Char),
memory_arena: ArenaAllocator,

const delimiter = if (builtin.os.tag == .windows) "\\" else "/";

pub fn init(allocator: Allocator) !Self {
    var arena = ArenaAllocator.init(std.heap.page_allocator);
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
        // NOTE: there seems to be a bug in zig or something but
        // we can't currently use the arena allocator for the filter text,
        // it crashes when trying to append
        .filter_text = ArrayList(u.Char).init(allocator),
        .memory_arena = arena,
    };
}

pub fn deinit(self: *Self) void {
    self.root.deinit();
    self.memory_arena.deinit();
    self.filter_text.deinit();
}

pub fn getCurrentDirMut(self: *Self) *Dir {
    if (self.current_dir) |current_dir| return current_dir;
    return &self.root;
}

pub fn getCurrentDir(self: Self) *const Dir {
    if (self.current_dir) |current_dir| return current_dir;
    return &self.root;
}

pub fn keyPress(self: *Self, key: glfw.Key, mods: glfw.Mods, tmp_allocator: Allocator) void {
    _ = mods;
    var dir = self.getCurrentDirMut();
    switch (key) {
        .up => {
            dir.selected -|= 1;
        },
        .down => {
            dir.selected += 1;
            const num_entries = dir.filteredEntries(self.filter_text.items, tmp_allocator).len;
            if (dir.selected >= num_entries) {
                dir.selected = num_entries -| 1;
            }
        },
        .enter => {
            // const entry = dir.selectedEntry();
            // switch (entry) {
            //     .dir => |d| {
            //         u.print("Open dir: {s}\n", .{d.name.items});
            //     },
            //     .file => |f| {
            //         u.print("Open file: {s}\n", .{f.name.items});
            //     },
            // }
        },
        .backspace => {
            if (self.filter_text.items.len > 0) {
                _ = self.filter_text.pop();
            } else {
                // TODO: go back one directory
            }
        },
        else => {},
    }
}

pub fn charEntered(self: *Self, char: u.Char) void {
    self.filter_text.append(char) catch u.oom();
    self.getCurrentDirMut().selected = 0;
}

pub const Entry = union(enum) {
    dir: *const Dir,
    file: *const File,

    pub fn getName(self: Entry) []const u8 {
        return switch (self) {
            .dir => |d| d.name.items,
            .file => |f| f.name.items,
        };
    }
};

// Filesystem tree node
pub const Dir = struct {
    name: ArrayList(u8),
    dirs: ArrayList(Dir),
    files: ArrayList(File),
    selected: usize,

    pub fn init(allocator: Allocator, name_slice: []const u8) Dir {
        var name = ArrayList(u8).init(allocator);
        name.appendSlice(name_slice) catch u.oom();
        return Dir{
            .name = name,
            .dirs = ArrayList(Dir).init(allocator),
            .files = ArrayList(File).init(allocator),
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

    pub fn getEntry(self: Dir, i: usize) ?Entry {
        const total_entries = self.dirs.items.len + self.files.items.len;
        if (i >= total_entries) return null;
        if (i < self.dirs.items.len) {
            return Entry{ .dir = &self.dirs.items[i] };
        } else {
            return Entry{ .file = &self.files.items[i - self.dirs.items.len] };
        }
    }

    /// Don't store them anywhere
    pub fn filteredEntries(self: Dir, filter_text: []const u.Char, tmp_allocator: Allocator) []Entry {
        var entries = std.ArrayList(Entry).init(tmp_allocator);
        var dir_iterator = FilteredEntriesIterator{
            .dir = &self,
            .filter_text = filter_text,
            .tmp_allocator = tmp_allocator,
        };
        while (dir_iterator.next()) |entry| {
            entries.append(entry) catch u.oom();
        }
        return entries.toOwnedSlice();
    }
};

pub const FilteredEntriesIterator = struct {
    dir: *const Dir,
    filter_text: []const u.Char,
    tmp_allocator: Allocator,
    i: usize = 0,

    pub fn next(self: *FilteredEntriesIterator) ?Entry {
        const entry = self.dir.getEntry(self.i) orelse return null;
        self.i += 1;
        if (self.matchesFuzzyFilter(entry)) {
            return entry;
        } else {
            return self.next();
        }
    }

    fn matchesFuzzyFilter(self: *FilteredEntriesIterator, entry: Entry) bool {
        const name = u.bytesToChars(entry.getName(), self.tmp_allocator) catch @panic("file name contains invalid utf8");
        var pos: usize = 0;
        for (self.filter_text) |char, i| {
            if (std.mem.indexOfPos(u.Char, name, pos, self.filter_text[i .. i + 1])) |index| {
                pos = index + 1;
            } else {
                // Try switching case for latin letters
                const lowercase = 'a' <= char and char <= 'z';
                const uppercase = 'A' <= char and char <= 'Z';
                if (!lowercase and !uppercase) return false; // not latin. give up

                const new_char = if (lowercase)
                    'A' + (char - 'a')
                else
                    'a' + (char - 'A');

                // Try again
                const needle = [_]u.Char{new_char};
                if (std.mem.indexOfPos(u.Char, name, pos, &needle)) |index| {
                    pos = index + 1;
                } else {
                    return false;
                }
            }
        }

        // var i: usize = 0;
        // while (i < self.filter_text.len) : (i += 1) {
        //     if (std.mem.indexOfPos(u.Char, name, pos, self.filter_text[i .. i + 1])) |index| {
        //         pos = index + 1;
        //     } else {
        //         return false;
        //     }
        // }
        return true;
    }
};

pub const File = struct {
    name: ArrayList(u8), // for displaying
    path: ArrayList(u8), // for opening

    pub fn init(allocator: Allocator, name_slice: []const u8, path_slice: []const u8) File {
        var name = ArrayList(u8).init(allocator);
        var path = ArrayList(u8).init(allocator);
        name.appendSlice(name_slice) catch u.oom();
        path.appendSlice(path_slice) catch u.oom();
        return File{
            .name = name,
            .path = path,
        };
    }
};
