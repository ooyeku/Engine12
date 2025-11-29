const std = @import("std");
const ws = @import("websocket");
const json = @import("../json.zig");

/// Thread-safe context for sharing state between WebSocket handlers and main thread.
/// Use this when handlers need to access shared data (kernel state, service registries, etc.)
///
/// Threading Model:
/// - WebSocket handlers run on separate worker threads
/// - Shared state must be accessed through ThreadSafeContext to avoid data races
/// - Use getThreadSafe()/setThreadSafe() for mutex-protected access
/// - Use getCopy() to get owned copies that outlive the lock
///
/// Example:
/// ```zig
/// var shared_ctx = ThreadSafeContext.init(allocator);
/// defer shared_ctx.deinit();
///
/// // In handler (runs on worker thread):
/// if (shared_ctx.getThreadSafe("user_count")) |count| {
///     // count is valid only while lock is held
/// }
///
/// // Or get a copy that's safe to use after release:
/// if (try shared_ctx.getCopy("user_count", allocator)) |count| {
///     defer allocator.free(count);
///     // count is an owned copy, safe to use
/// }
/// ```
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

    /// Get a value with mutex protection.
    /// WARNING: The returned slice is only valid while the caller holds no other locks.
    /// For safety across threads, use getCopy() instead.
    pub fn getThreadSafe(self: *ThreadSafeContext, key: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.data.get(key);
    }

    /// Get an owned copy of a value (thread-safe).
    /// Caller owns the returned memory and must free it.
    pub fn getCopy(self: *ThreadSafeContext, key: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.data.get(key)) |value| {
            return try allocator.dupe(u8, value);
        }
        return null;
    }

    /// Set a value with mutex protection.
    /// Both key and value are duplicated internally.
    pub fn setThreadSafe(self: *ThreadSafeContext, key: []const u8, value: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Remove old value if exists
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

    /// Remove a value with mutex protection.
    pub fn removeThreadSafe(self: *ThreadSafeContext, key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.data.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }
};

/// Thread-safe message queue for WebSocket communication.
/// Allows safe message passing between worker threads and main thread.
///
/// Use Cases:
/// - Queue messages from main thread to be sent by WebSocket handler
/// - Collect messages from WebSocket handlers for processing on main thread
/// - Implement pub/sub patterns across threads
///
/// Example:
/// ```zig
/// var queue = MessageQueue.init(allocator);
/// defer queue.deinit();
///
/// // Producer (main thread):
/// try queue.push("update", "{\"count\": 42}");
///
/// // Consumer (worker thread):
/// while (queue.pop()) |msg| {
///     defer msg.deinit(allocator);
///     conn.sendText(msg.data) catch {};
/// }
/// ```
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

    /// Push a message to the queue. Thread-safe.
    /// Returns error.QueueFull if max_size is reached.
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

    /// Pop a message from the queue. Thread-safe.
    /// Returns null if queue is empty.
    /// Caller must call msg.deinit(allocator) when done.
    pub fn pop(self: *MessageQueue) ?Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.messages.items.len == 0) {
            return null;
        }

        // Pop from front (FIFO)
        const msg = self.messages.orderedRemove(0);
        return msg;
    }

    /// Check if queue has messages. Thread-safe.
    pub fn isEmpty(self: *MessageQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.messages.items.len == 0;
    }

    /// Get current queue size. Thread-safe.
    pub fn len(self: *MessageQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.messages.items.len;
    }

    /// Clear all messages. Thread-safe.
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

/// WebSocket connection wrapper for engine12
/// Provides a clean API that wraps websocket.zig's Conn type
///
/// Threading Model:
/// - Each WebSocket connection runs on its own worker thread
/// - The connection's context (get/set) is NOT thread-safe by default
/// - For thread-safe shared state, use ThreadSafeContext
/// - For thread-safe message passing, use MessageQueue
///
/// For real-time features requiring shared state access:
/// ```zig
/// // Create shared context before starting server
/// var shared = ThreadSafeContext.init(allocator);
/// var outbound_queue = MessageQueue.init(allocator);
///
/// // In handler, access shared state safely
/// fn handleMetrics(conn: *WebSocketConnection) void {
///     if (shared.getCopy("metrics", conn.allocator)) |metrics| {
///         defer conn.allocator.free(metrics);
///         conn.sendText(metrics) catch {};
///     } catch {}
/// }
/// ```
pub const WebSocketConnection = struct {
    /// Underlying websocket.zig connection
    conn: *ws.Conn,

    /// Connection metadata
    id: []const u8,
    path: []const u8,
    headers: std.StringHashMap([]const u8),

    /// Connection state
    is_open: std.atomic.Value(bool),

    /// Context storage (like Request.context)
    context: std.StringHashMap([]const u8),

    /// Allocator for this connection
    allocator: std.mem.Allocator,

    /// Flag to prevent double cleanup
    cleaned_up: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Send a text message
    /// websocket.zig expects []u8, not []const u8, so we need to duplicate
    pub fn sendText(self: *WebSocketConnection, text: []const u8) !void {
        if (!self.is_open.load(.monotonic)) {
            return error.ConnectionClosed;
        }

        // websocket.zig expects mutable buffer for masking
        const mutable = try self.allocator.dupe(u8, text);
        defer self.allocator.free(mutable);

        try self.conn.write(mutable);
    }

    /// Send a binary message
    pub fn sendBinary(self: *WebSocketConnection, data: []const u8) !void {
        if (!self.is_open.load(.monotonic)) {
            return error.ConnectionClosed;
        }

        const mutable = try self.allocator.dupe(u8, data);
        defer self.allocator.free(mutable);

        try self.conn.writeBin(mutable);
    }

    /// Send a JSON message (serializes struct to JSON)
    pub fn sendJson(self: *WebSocketConnection, comptime T: type, value: T) !void {
        const json_str = try json.Json.serialize(T, value, self.allocator);
        defer self.allocator.free(json_str);
        try self.sendText(json_str);
    }

    /// Close the connection gracefully
    pub fn close(self: *WebSocketConnection, code: ?u16, reason: ?[]const u8) !void {
        self.is_open.store(false, .monotonic);

        if (code) |c| {
            const close_reason = reason orelse "";
            try self.conn.close(.{ .code = c, .reason = close_reason });
        } else {
            try self.conn.close(.{});
        }
    }

    /// Get value from context
    pub fn get(self: *const WebSocketConnection, key: []const u8) ?[]const u8 {
        return self.context.get(key);
    }

    /// Set value in context
    /// Duplicates both key and value to ensure they persist
    pub fn set(self: *WebSocketConnection, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.context.put(key_copy, value_copy);
    }

    /// Queue a message for thread-safe sending via a MessageQueue.
    /// Use this when sending from a different thread than the WebSocket handler.
    ///
    /// Example:
    /// ```zig
    /// var queue = MessageQueue.init(allocator);
    /// // From main thread:
    /// try conn.queueMessage(&queue, "metrics", metrics_json);
    /// // In handler thread, drain the queue:
    /// conn.drainQueue(&queue);
    /// ```
    pub fn queueMessage(self: *WebSocketConnection, queue: *MessageQueue, topic: []const u8, data: []const u8) !void {
        _ = self;
        try queue.push(topic, data);
    }

    /// Drain messages from a queue and send them.
    /// Call this periodically in the WebSocket handler thread.
    pub fn drainQueue(self: *WebSocketConnection, queue: *MessageQueue) void {
        while (queue.pop()) |msg| {
            defer msg.deinit(self.allocator);
            self.sendText(msg.data) catch |err| {
                // Log error but continue draining
                std.debug.print("[WebSocket] Failed to send queued message: {}\n", .{err});
            };
        }
    }

    /// Cleanup connection resources
    pub fn cleanup(self: *WebSocketConnection) void {
        // Prevent double cleanup
        const already_cleaned = self.cleaned_up.swap(true, .monotonic);
        if (already_cleaned) {
            return; // Already cleaned up
        }

        // Free context entries - collect keys first to avoid iterator invalidation
        var context_keys = std.ArrayListUnmanaged([]const u8){};
        defer context_keys.deinit(self.allocator);

        var it = self.context.iterator();
        while (it.next()) |entry| {
            context_keys.append(self.allocator, entry.key_ptr.*) catch continue;
        }

        // Now free each entry
        for (context_keys.items) |key| {
            if (self.context.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
        }
        self.context.deinit();

        // Free headers - collect keys first
        var header_keys = std.ArrayListUnmanaged([]const u8){};
        defer header_keys.deinit(self.allocator);

        var header_it = self.headers.iterator();
        while (header_it.next()) |entry| {
            header_keys.append(self.allocator, entry.key_ptr.*) catch continue;
        }

        // Now free each entry
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
