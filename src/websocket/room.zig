const std = @import("std");
const connection = @import("connection.zig");
const WebSocketConnection = connection.WebSocketConnection;

pub const WebSocketRoom = struct {
    name: []const u8,

    connections: std.ArrayListUnmanaged(*WebSocketConnection),

    mutex: std.Thread.Mutex = .{},

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !WebSocketRoom {
        return WebSocketRoom{
            .name = try allocator.dupe(u8, name),
            .connections = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WebSocketRoom) void {
        self.allocator.free(self.name);
        self.connections.deinit(self.allocator);
    }

    pub fn broadcast(self: *WebSocketRoom, message: []const u8) !void {
        const message_copy = try self.allocator.dupe(u8, message);
        defer self.allocator.free(message_copy);

        var connections_copy = std.ArrayListUnmanaged(*connection.WebSocketConnection){};
        defer connections_copy.deinit(self.allocator);

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.connections.items) |conn| {
                connections_copy.append(self.allocator, conn) catch continue;
            }
        }

        for (connections_copy.items) |conn| {
            if (!conn.is_open.load(.monotonic)) {
                continue;
            }

            conn.sendText(message_copy) catch |err| {
                std.debug.print("[WebSocketRoom] Error sending message to connection: {}\n", .{err});
                continue;
            };
        }

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            var i: usize = 0;
            while (i < self.connections.items.len) {
                const conn = self.connections.items[i];
                if (safeIsOpen(conn)) {
                    i += 1;
                } else {
                    _ = self.connections.swapRemove(i);
                }
            }
        }
    }

    fn safeIsOpen(conn: *connection.WebSocketConnection) bool {
        return conn.is_open.load(.monotonic);
    }

    pub fn broadcastBinary(self: *WebSocketRoom, data: []const u8) !void {
        const data_copy = try self.allocator.dupe(u8, data);
        defer self.allocator.free(data_copy);

        var connections_copy = std.ArrayListUnmanaged(*connection.WebSocketConnection){};
        defer connections_copy.deinit(self.allocator);

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.connections.items) |conn| {
                connections_copy.append(self.allocator, conn) catch continue;
            }
        }

        for (connections_copy.items) |conn| {
            if (safeIsOpen(conn)) {
                conn.sendBinary(data_copy) catch |err| {
                    std.debug.print("[WebSocketRoom] Error sending binary to connection: {}\n", .{err});
                    continue;
                };
            }
        }

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            var i: usize = 0;
            while (i < self.connections.items.len) {
                const conn = self.connections.items[i];
                if (safeIsOpen(conn)) {
                    i += 1;
                } else {
                    _ = self.connections.swapRemove(i);
                }
            }
        }
    }

    pub fn broadcastJson(self: *WebSocketRoom, comptime T: type, value: T) !void {
        const json = @import("../data/json.zig");
        const json_str = try json.Json.serialize(T, value, self.allocator);
        defer self.allocator.free(json_str);

        try self.broadcast(json_str);
    }

    pub fn join(self: *WebSocketRoom, conn: *WebSocketConnection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |existing| {
            if (existing == conn) {
                return; // Already in room
            }
        }

        try self.connections.append(self.allocator, conn);
    }

    pub fn leave(self: *WebSocketRoom, conn: *WebSocketConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items, 0..) |c, i| {
            if (c == conn) {
                _ = self.connections.swapRemove(i);
                break;
            }
        }
    }

    pub fn count(self: *WebSocketRoom) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.connections.items.len;
    }

    pub fn isEmpty(self: *WebSocketRoom) bool {
        return self.count() == 0;
    }
};
