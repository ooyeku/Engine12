const std = @import("std");
const json = @import("../json.zig");
const protocol = @import("protocol.zig");
const server = @import("server.zig");

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

/// WebSocket connection wrapper for Engine12
/// Uses native WebSocket implementation instead of external dependency
pub const WebSocketConnection = struct {
    /// Native WebSocket client
    client: *server.Client,

    /// Unique connection ID
    id: []const u8,

    /// Request path
    path: []const u8,

    /// Request headers (copy for Engine12 API compatibility)
    headers: std.StringHashMap([]const u8),

    /// Connection state flag
    is_open: std.atomic.Value(bool),

    /// Custom context for storing user data
    context: std.StringHashMap([]const u8),

    /// Allocator for this connection
    allocator: std.mem.Allocator,

    /// Cleanup flag to prevent double cleanup
    cleaned_up: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Send a text message
    pub fn sendText(self: *WebSocketConnection, text: []const u8) !void {
        if (!self.is_open.load(.monotonic)) {
            return error.ConnectionClosed;
        }

        try self.client.sendText(text);
    }

    /// Send a binary message
    pub fn sendBinary(self: *WebSocketConnection, data: []const u8) !void {
        if (!self.is_open.load(.monotonic)) {
            return error.ConnectionClosed;
        }

        try self.client.sendBinary(data);
    }

    /// Send a JSON-serialized message
    pub fn sendJson(self: *WebSocketConnection, comptime T: type, value: T) !void {
        const json_str = try json.Json.serialize(T, value, self.allocator);
        defer self.allocator.free(json_str);
        try self.sendText(json_str);
    }

    /// Close the connection
    pub fn close(self: *WebSocketConnection, code: ?u16, reason: ?[]const u8) !void {
        self.is_open.store(false, .monotonic);

        const close_code = if (code) |c|
            protocol.CloseCode.fromU16(c)
        else
            protocol.CloseCode.normal;

        const close_reason = reason orelse "";

        try self.client.close(close_code, close_reason);
    }

    /// Get a context value by key
    pub fn get(self: *const WebSocketConnection, key: []const u8) ?[]const u8 {
        return self.context.get(key);
    }

    /// Set a context value
    pub fn set(self: *WebSocketConnection, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.context.put(key_copy, value_copy);
    }

    /// Queue a message for later sending
    pub fn queueMessage(self: *WebSocketConnection, queue: *MessageQueue, topic: []const u8, data: []const u8) !void {
        _ = self;
        try queue.push(topic, data);
    }

    /// Drain and send all queued messages
    pub fn drainQueue(self: *WebSocketConnection, queue: *MessageQueue) void {
        while (queue.pop()) |msg| {
            defer msg.deinit(self.allocator);
            self.sendText(msg.data) catch |err| {
                std.debug.print("[WebSocket] Failed to send queued message: {}\n", .{err});
            };
        }
    }

    /// Get a header value from the original request
    pub fn getHeader(self: *const WebSocketConnection, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    /// Check if connection is open
    pub fn isOpen(self: *const WebSocketConnection) bool {
        return self.is_open.load(.monotonic);
    }

    /// Cleanup connection resources
    pub fn cleanup(self: *WebSocketConnection) void {
        const already_cleaned = self.cleaned_up.swap(true, .monotonic);
        if (already_cleaned) {
            return; // Already cleaned up
        }

        // Clean up context
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

        // Clean up headers
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

        // Free id and path
        self.allocator.free(self.id);
        self.allocator.free(self.path);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ThreadSafeContext basic operations" {
    const allocator = std.testing.allocator;

    var ctx = ThreadSafeContext.init(allocator);
    defer ctx.deinit();

    try ctx.setThreadSafe("key1", "value1");
    try std.testing.expectEqualStrings("value1", ctx.getThreadSafe("key1").?);

    ctx.removeThreadSafe("key1");
    try std.testing.expect(ctx.getThreadSafe("key1") == null);
}

test "MessageQueue push and pop" {
    const allocator = std.testing.allocator;

    var queue = MessageQueue.init(allocator);
    defer queue.deinit();

    try queue.push("topic1", "data1");
    try queue.push("topic2", "data2");

    try std.testing.expectEqual(@as(usize, 2), queue.len());

    const msg1 = queue.pop();
    try std.testing.expect(msg1 != null);
    if (msg1) |m| {
        defer m.deinit(allocator);
        try std.testing.expectEqualStrings("topic1", m.topic);
        try std.testing.expectEqualStrings("data1", m.data);
    }

    const msg2 = queue.pop();
    try std.testing.expect(msg2 != null);
    if (msg2) |m| {
        defer m.deinit(allocator);
        try std.testing.expectEqualStrings("topic2", m.topic);
        try std.testing.expectEqualStrings("data2", m.data);
    }

    try std.testing.expect(queue.pop() == null);
}

test "MessageQueue max size" {
    const allocator = std.testing.allocator;

    var queue = MessageQueue.initWithMaxSize(allocator, 2);
    defer queue.deinit();

    try queue.push("topic1", "data1");
    try queue.push("topic2", "data2");
    try std.testing.expectError(error.QueueFull, queue.push("topic3", "data3"));
}

test "MessageQueue clear" {
    const allocator = std.testing.allocator;

    var queue = MessageQueue.init(allocator);
    defer queue.deinit();

    try queue.push("topic1", "data1");
    try queue.push("topic2", "data2");

    queue.clear();
    try std.testing.expect(queue.isEmpty());
}
