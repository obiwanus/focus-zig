const std = @import("std");

const focus = @import("focus.zig");
const u = focus.utils;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Zls = @This();

allocator: Allocator,
process: *std.ChildProcess = undefined,
listener: std.Thread = undefined,

pub fn init(allocator: Allocator) Zls {
    return Zls{
        .allocator = allocator,
    };
}

pub fn start(self: *Zls) !void {
    var process = try std.ChildProcess.init(&[_][]const u8{"zls"}, self.allocator);
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;
    try process.spawn();
    self.process = process;

    self.listener = try std.Thread.spawn(.{}, listen, .{self});
    self.listener.setName("ZLS listener") catch |e| u.println("Unable to set thread name: {}", .{e});

    try self.sendInitRequest();
}

pub fn shutdown(self: *Zls) void {
    self.sendShutdownRequest() catch |e| u.println("Error sending shutdown request to zls: {}", .{e});
    // self.process.stdin.?.close();
    // self.process.stdout.?.close();
    // TODO: wait for the process with a small timeout?
    self.listener.join();
}

fn listen(self: *Zls) void {
    var arena = ArenaAllocator.init(self.allocator);
    var allocator = arena.allocator();
    defer arena.deinit();

    const reader = self.process.stdout.?.reader();

    while (true) {
        const msg = readMessageAlloc(reader, allocator) catch |e| {
            if (e == error.EndOfStream) {
                u.println("Zls: end of stream. Stopping listener...", .{});
            } else {
                u.println("Error reading message from zls: {}", .{e});
            }
            break;
        };

        u.println("==== ZLS message ===========================", .{});
        u.println("{s}\n", .{msg});

        // Reset arena
        arena.deinit();
        arena.state = .{};
    }
}

//pub fn notifyFileOpened(self: Zls, path: []const u8) !void {}

fn sendInitRequest(self: *Zls) !void {
    var arena = ArenaAllocator.init(self.allocator);
    var allocator = arena.allocator();
    defer arena.deinit();
    const content =
        \\{
        \\  "jsonrpc": "2.0", 
        \\  "id": "init", 
        \\  "method": "initialize",
        \\  "params": {
        \\    "capabilities": {
        \\      "workspace": null, 
        \\      "textDocument": null, 
        \\      "offsetEncoding": ["utf-8"]
        \\    }, 
        \\    "workspaceFolders": null
        \\  }
        \\}
    ;
    const request = std.fmt.allocPrint(allocator, "Content-Length: {}\r\n\r\n{s}", .{ content.len, content }) catch u.oom();
    try self.process.stdin.?.writer().writeAll(request);
}

fn sendShutdownRequest(self: *Zls) !void {
    var arena = ArenaAllocator.init(self.allocator);
    var allocator = arena.allocator();
    defer arena.deinit();
    const content =
        \\{
        \\  "jsonrpc": "2.0", 
        \\  "id": "init", 
        \\  "method": "shutdown", 
        \\  "params": {}
        \\}
    ;
    const request = std.fmt.allocPrint(allocator, "Content-Length: {}\r\n\r\n{s}", .{ content.len, content }) catch u.oom();
    try self.process.stdin.?.writer().writeAll(request);
}

fn readMessageAlloc(reader: anytype, tmp_allocator: Allocator) ![]const u8 {
    const header = try reader.readUntilDelimiterAlloc(tmp_allocator, '\n', 0x100);
    u.assert(header[header.len - 1] == '\r');
    const header_name = "Content-Length: ";
    u.assert(std.mem.eql(u8, header[0..header_name.len], header_name));
    const header_value = header[header_name.len .. header.len - 1];
    const content_length = std.fmt.parseInt(usize, header_value, 10) catch u.panic("Invalid zls response content size: '{s}'", .{header_value});

    const buf = tmp_allocator.alloc(u8, content_length + 2) catch u.oom();
    try reader.readNoEof(buf);
    u.assert(buf[0] == '\r' and buf[1] == '\n');
    return buf[2..]; // we don't care about freeing it so we take a slice
}
