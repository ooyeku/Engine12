const std = @import("std");
const ws = @import("websocket");
const json = @import("../json.zig");

pub const ThreadSafeContext = struct {
    mutex: std.Thread.Mutex,
    data: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ThreadSafeContext {
        return ThreadSafeContext{
            .mutex = .{},
            .data = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ThreadSafeContext) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.deinit();
    }

    pub fn getThreadSafe(self: *ThreadSafeContext, key: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.data.get(key);
    }

    pub fn getCopy(self: *ThreadSafeContext, key: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.data.get(key)) |value| {
            return try allocator.dupe(u8, value);
        }
        return null;
    }

    pub fn setThreadSafe(self: *ThreadSafeContext, key: []const u8, value: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.data.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        try self.data.put(key_copy, value_copy);
    }

    pub fn removeThreadSafe(self: *ThreadSafeContext, key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.data.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }
};

pub const MessageQueue = struct {
    pub const Message = struct {
        topic: []const u8,
        data: []const u8,
        timestamp: i64,

        pub fn deinit(self: *const Message, allocator: std.mem.Allocator) void {
            allocator.free(self.topic);
            allocator.free(self.data);
        }
    };

    mutex: std.Thread.Mutex,
    messages: std.ArrayListUnmanaged(Message),
    allocator: std.mem.Allocator,
    max_size: usize,

    pub fn init(allocator: std.mem.Allocator) MessageQueue {
        return initWithMaxSize(allocator, 1024);
    }

    pub fn initWithMaxSize(allocator: std.mem.Allocator, max_size: usize) MessageQueue {
        return MessageQueue{
            .mutex = .{},
            .messages = std.ArrayListUnmanaged(Message){},
            .allocator = allocator,
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *MessageQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.messages.items) |msg| {
            self.allocator.free(msg.topic);
            self.allocator.free(msg.data);
        }
        self.messages.deinit(self.allocator);
    }

    pub fn push(self: *MessageQueue, topic: []const u8, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.messages.items.len >= self.max_size) {
            return error.QueueFull;
        }

        const topic_copy = try self.allocator.dupe(u8, topic);
        errdefer self.allocator.free(topic_copy);
        const data_copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(data_copy);

        try self.messages.append(self.allocator, Message{
            .topic = topic_copy,
            .data = data_copy,
            .timestamp = std.time.milliTimestamp(),
        });
    }

    pub fn pop(self: *MessageQueue) ?Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.messages.items.len == 0) {
            return null;
        }

        const msg = self.messages.orderedRemove(0);
        return msg;
    }

    pub fn isEmpty(self: *MessageQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.messages.items.len == 0;
    }

    pub fn len(self: *MessageQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.messages.items.len;
    }

    pub fn clear(self: *MessageQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.messages.items) |msg| {
            self.allocator.free(msg.topic);
            self.allocator.free(msg.data);
        }
        self.messages.clearRetainingCapacity();
    }
};

pub const WebSocketConnection = struct {
    conn: *ws.Conn,

    id: []const u8,
    path: []const u8,
    headers: std.StringHashMap([]const u8),

    is_open: std.atomic.Value(bool),

    context: std.StringHashMap([]const u8),

    allocator: std.mem.Allocator,

    cleaned_up: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn sendText(self: *WebSocketConnection, text: []const u8) !void {
        if (!self.is_open.load(.monotonic)) {
            return error.ConnectionClosed;
        }

        const mutable = try self.allocator.dupe(u8, text);
        defer self.allocator.free(mutable);

        try self.conn.write(mutable);
    }

    pub fn sendBinary(self: *WebSocketConnection, data: []const u8) !void {
        if (!self.is_open.load(.monotonic)) {
            return error.ConnectionClosed;
        }

        const mutable = try self.allocator.dupe(u8, data);
        defer self.allocator.free(mutable);

        try self.conn.writeBin(mutable);
    }

    pub fn sendJson(self: *WebSocketConnection, comptime T: type, value: T) !void {
        const json_str = try json.Json.serialize(T, value, self.allocator);
        defer self.allocator.free(json_str);
        try self.sendText(json_str);
    }

    pub fn close(self: *WebSocketConnection, code: ?u16, reason: ?[]const u8) !void {
        self.is_open.store(false, .monotonic);

        if (code) |c| {
            const close_reason = reason orelse "";
            try self.conn.close(.{ .code = c, .reason = close_reason });
        } else {
            try self.conn.close(.{});
        }
    }

    pub fn get(self: *const WebSocketConnection, key: []const u8) ?[]const u8 {
        return self.context.get(key);
    }

    pub fn set(self: *WebSocketConnection, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.context.put(key_copy, value_copy);
    }

    pub fn queueMessage(self: *WebSocketConnection, queue: *MessageQueue, topic: []const u8, data: []const u8) !void {
        _ = self;
        try queue.push(topic, data);
    }

    pub fn drainQueue(self: *WebSocketConnection, queue: *MessageQueue) void {
        while (queue.pop()) |msg| {
            defer msg.deinit(self.allocator);
            self.sendText(msg.data) catch |err| {
                std.debug.print("[WebSocket] Failed to send queued message: {}\n", .{err});
            };
        }
    }

    pub fn cleanup(self: *WebSocketConnection) void {
        const already_cleaned = self.cleaned_up.swap(true, .monotonic);
        if (already_cleaned) {
            return; // Already cleaned up
        }

        var context_keys = std.ArrayListUnmanaged([]const u8){};
        defer context_keys.deinit(self.allocator);

        var it = self.context.iterator();
        while (it.next()) |entry| {
            context_keys.append(self.allocator, entry.key_ptr.*) catch continue;
        }

        for (context_keys.items) |key| {
            if (self.context.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
        }
        self.context.deinit();

        var header_keys = std.ArrayListUnmanaged([]const u8){};
        defer header_keys.deinit(self.allocator);

        var header_it = self.headers.iterator();
        while (header_it.next()) |entry| {
            header_keys.append(self.allocator, entry.key_ptr.*) catch continue;
        }

        for (header_keys.items) |key| {
            if (self.headers.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
        }
        self.headers.deinit();

        self.allocator.free(self.id);
        self.allocator.free(self.path);
    }
};
