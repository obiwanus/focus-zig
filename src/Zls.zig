const std = @import("std");

const focus = @import("focus.zig");
const u = focus.utils;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const Char = u.Char;
const LineCol = u.LineCol;

const Zls = @This();

allocator: Allocator,
process: *std.ChildProcess = undefined,
listener: std.Thread = undefined,
listener_stderr: std.Thread = undefined,
action_queue: ActionQueue,

const OpenDocument = struct {
    textDocument: struct {
        uri: []const u8,
        text: []const u8,
    },
};

pub const Position = struct {
    line: i64,
    character: i64,

    fn fromLineCol(line_col: LineCol) Position {
        return .{ .line = @intCast(i64, line_col.line), .character = @intCast(i64, line_col.col) };
    }

    fn toLineCol(self: Position) LineCol {
        return .{ .line = @intCast(usize, self.line), .col = @intCast(usize, self.character) };
    }
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

const TextDocument = struct {
    uri: []const u8,
};

const GoToDefinitionRequest = struct {
    textDocument: TextDocument,
    position: Position,
};

const ResponseId = union(enum) {
    string: []const u8,
    number: usize,
};

const MessageType = enum {
    log_message,
    definition,
    definition_other,
    unknown,
};

const DefinitionResponse = struct {
    result: struct {
        uri: []const u8,
        range: Range,
    },
};

const ActionQueue = struct {
    queue: ArrayList(Action),
    mutex: std.Thread.Mutex,

    const Action = union(enum) {
        jump_to_file: struct {
            uri: []const u8,
            line_col: LineCol,
            other: bool,
        },
    };

    fn init(allocator: Allocator) ActionQueue {
        return .{
            .queue = ArrayList(Action).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    fn deinit(self: ActionQueue) void {
        // A potential leak which we don't care about because it's at shutdown
        self.queue.deinit();
    }

    fn addToFront(self: *ActionQueue, item: Action) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.queue.append(item) catch u.oom();
    }

    pub fn maybePopFromBack(self: *ActionQueue) ?Action {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }
};

pub fn init(allocator: Allocator) Zls {
    return Zls{
        .allocator = allocator,
        .action_queue = ActionQueue.init(allocator),
    };
}

pub fn start(self: *Zls) !void {
    var process = try std.ChildProcess.init(&[_][]const u8{"C:\\Users\\ivan\\Projects\\zls\\zig-out\\bin\\zls.exe"}, self.allocator);
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;
    try process.spawn();
    self.process = process;

    self.listener = try std.Thread.spawn(.{}, listen, .{self});
    self.listener.setName("ZLS listener") catch |e| u.println("Unable to set thread name: {}", .{e});

    self.listener_stderr = try std.Thread.spawn(.{}, listen_stderr, .{self});
    self.listener_stderr.setName("ZLS listener_stderr") catch |e| u.println("Unable to set thread name: {}", .{e});

    try self.sendInitRequest();
}

pub fn shutdown(self: *Zls) void {
    self.sendShutdownRequest() catch |e| u.println("Error sending shutdown request to zls: {}", .{e});
    // self.process.stdin.?.close();
    // self.process.stdout.?.close();
    // TODO: wait for the process with a small timeout?
    self.listener.join();
    self.listener_stderr.join();

    self.action_queue.deinit();
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

        self.processMessage(msg, allocator);

        // Reset arena
        arena.deinit();
        arena.state = .{};
    }
}

fn processMessage(self: *Zls, msg: []const u8, tmp_allocator: Allocator) void {
    u.println("==== ZLS message ===========================", .{});
    u.println("{s}\n", .{msg});

    const msg_type = getMessageType(msg, tmp_allocator);
    switch (msg_type) {
        .definition, .definition_other => {
            const response = parseJsonAs(DefinitionResponse, msg, tmp_allocator) catch |e| {
                u.println("Can't parse message as DefinitionResponse: {}", .{e});
                return;
            };
            self.action_queue.addToFront(.{
                .jump_to_file = .{
                    .uri = self.allocator.dupe(u8, response.result.uri) catch u.oom(),
                    .line_col = response.result.range.start.toLineCol(),
                    .other = msg_type == .definition_other,
                },
            });
        },
        else => {},
    }
}

fn parseJsonAs(comptime result_type: type, json: []const u8, allocator: Allocator) !result_type {
    return std.json.parse(
        result_type,
        &std.json.TokenStream.init(json),
        .{
            .allocator = allocator,
            .ignore_unknown_fields = true,
        },
    );
}

fn getMessageType(msg: []const u8, tmp_allocator: Allocator) MessageType {
    const message = parseJsonAs(struct { id: ?ResponseId = null, method: ?[]const u8 = null }, msg, tmp_allocator) catch |e| {
        u.println("Error parsing message: {}", .{e});
        return .unknown;
    };

    if (message.id) |id| {
        switch (id) {
            .string => |str| {
                if (std.mem.eql(u8, str, "definition")) return .definition;
                if (std.mem.eql(u8, str, "definition_other")) return .definition_other;
            },
            else => {},
        }
    }
    return .unknown;
}

fn listen_stderr(self: *Zls) void {
    var arena = ArenaAllocator.init(self.allocator);
    var allocator = arena.allocator();
    defer arena.deinit();

    const output = self.process.stderr.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024) catch unreachable;

    u.println("==== ZLS stderr ===========================", .{});
    u.println("{s}\n", .{output});
}

pub fn notifyBufferOpened(self: Zls, buffer_id: usize, uri: []const u8, chars: []const Char) !void {
    var arena = ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    const open_document = OpenDocument{
        .textDocument = .{
            .uri = uri,
            .text = u.charsToBytes(chars, allocator) catch unreachable,
        },
    };

    const content_template =
        \\{{
        \\  "jsonrpc": "2.0",
        \\  "id": {},
        \\  "method": "textDocument/didOpen",
        \\  "params": {s}
        \\}}
    ;

    var params = std.ArrayList(u8).init(allocator);
    try std.json.stringify(open_document, .{}, params.writer());

    const content = std.fmt.allocPrint(allocator, content_template, .{ buffer_id, params.items }) catch u.oom();
    u.println("OpenDocumentRequest: ===============\n{s}\n", .{content});
    const request = std.fmt.allocPrint(allocator, "Content-Length: {}\r\n\r\n{s}", .{ content.len, content }) catch u.oom();
    try self.process.stdin.?.writer().writeAll(request);
}

pub fn goToDefinition(self: Zls, uri: []const u8, line_col: LineCol, other: bool) !void {
    var arena = ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    const request_id = if (other) "definition_other" else "definition";

    const content_template =
        \\{{
        \\  "jsonrpc": "2.0",
        \\  "id": "{s}",
        \\  "method": "textDocument/definition",
        \\  "params": {s}
        \\}}
    ;

    const request_params = GoToDefinitionRequest{
        .textDocument = .{ .uri = uri },
        .position = Position.fromLineCol(line_col),
    };
    var params = std.ArrayList(u8).init(allocator);
    try std.json.stringify(request_params, .{}, params.writer());

    const content = std.fmt.allocPrint(allocator, content_template, .{ request_id, params.items }) catch u.oom();
    u.println("GoToDefinitionRequest: ===============\n{s}\n", .{content});
    const request = std.fmt.allocPrint(allocator, "Content-Length: {}\r\n\r\n{s}", .{ content.len, content }) catch u.oom();
    try self.process.stdin.?.writer().writeAll(request);
}

fn sendInitRequest(self: *Zls) !void {
    var arena = ArenaAllocator.init(self.allocator);
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
        \\      "offsetEncoding": ["utf-32"]
        \\    },
        \\    "workspaceFolders": null
        \\  }
        \\}
    ;
    const request = std.fmt.allocPrint(arena.allocator(), "Content-Length: {}\r\n\r\n{s}", .{ content.len, content }) catch u.oom();
    try self.process.stdin.?.writer().writeAll(request);
}

fn sendShutdownRequest(self: *Zls) !void {
    var arena = ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const content =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": "init",
        \\  "method": "shutdown",
        \\  "params": {}
        \\}
    ;
    const request = std.fmt.allocPrint(arena.allocator(), "Content-Length: {}\r\n\r\n{s}", .{ content.len, content }) catch u.oom();
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
