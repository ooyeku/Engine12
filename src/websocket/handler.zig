const std = @import("std");
const connection = @import("connection.zig");
const WebSocketConnection = connection.WebSocketConnection;
const server = @import("server.zig");
const protocol = @import("protocol.zig");
const websocket_mod = @import("module.zig");

/// Handler function type for Engine12 WebSocket connections
pub const WebSocketHandler = *const fn (*WebSocketConnection) void;

/// Application data passed to the native WebSocket server
pub const AppData = struct {
    handler: WebSocketHandler,
    allocator: std.mem.Allocator,
    path: []const u8,
    manager: ?*@import("manager.zig").WebSocketManager = null,
};

/// Create a server callbacks structure for a given handler
pub fn createServerCallbacks(app_data: *AppData) server.Callbacks {
    return server.Callbacks{
        .on_open = onOpen,
        .on_text = onText,
        .on_binary = onBinary,
        .on_close = onClose,
        .on_error = onError,
        .on_ping = null, // Pong is sent automatically
        .on_pong = null,
        .context = app_data,
    };
}

/// Create an Engine12 connection wrapper from a native client
pub fn createEngine12Connection(
    allocator: std.mem.Allocator,
    client: *server.Client,
    path: []const u8,
) !*WebSocketConnection {
    // Generate unique connection ID
    const timestamp = std.time.milliTimestamp();
    const random = @as(u64, @intCast(std.time.nanoTimestamp())) % 1000000;
    const conn_id = try std.fmt.allocPrint(allocator, "ws_{d}_{d}", .{ timestamp, random });
    errdefer allocator.free(conn_id);

    // Copy path
    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);

    // Copy headers from client
    var headers_copy = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = headers_copy.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        headers_copy.deinit();
    }

    var it = client.headers.iterator();
    while (it.next()) |entry| {
        const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key_copy);
        const value_copy = try allocator.dupe(u8, entry.value_ptr.*);
        errdefer allocator.free(value_copy);
        try headers_copy.put(key_copy, value_copy);
    }

    // Create connection
    const engine12_conn = try allocator.create(WebSocketConnection);
    errdefer allocator.destroy(engine12_conn);

    engine12_conn.* = WebSocketConnection{
        .client = client,
        .id = conn_id,
        .path = path_copy,
        .headers = headers_copy,
        .is_open = std.atomic.Value(bool).init(true),
        .context = std.StringHashMap([]const u8).init(allocator),
        .allocator = allocator,
        .on_close = null,
        .cleaned_up = std.atomic.Value(bool).init(false),
    };

    // Store the Engine12 connection pointer in the client's user_data
    client.user_data = engine12_conn;

    return engine12_conn;
}

/// Get the Engine12 connection from a native client
fn getEngine12Connection(client: *server.Client) ?*WebSocketConnection {
    if (client.user_data) |ptr| {
        return @as(*WebSocketConnection, @ptrCast(@alignCast(ptr)));
    }
    return null;
}

/// Callback for new connections
fn onOpen(client: *server.Client) void {
    // Get app data from somewhere - we need to pass it through
    // For now, we'll handle this in the manager
    _ = client;
}

/// Callback for text messages
fn onText(client: *server.Client, data: []const u8) void {
    _ = client;
    _ = data;
    // Message handling is done in the manager's message loop
}

/// Callback for binary messages
fn onBinary(client: *server.Client, data: []const u8) void {
    _ = client;
    _ = data;
    // Message handling is done in the manager's message loop
}

/// Callback for connection close
fn onClose(client: *server.Client, code: protocol.CloseCode, reason: []const u8) void {
    _ = code;
    _ = reason;

    if (getEngine12Connection(client)) |conn| {
        conn.is_open.store(false, .monotonic);

        // Clean up room membership if set
        var room_ptr: ?*websocket_mod.room.WebSocketRoom = null;
        if (conn.get("hot_reload_room")) |room_ptr_str| {
            const room_ptr_str_copy = conn.allocator.dupe(u8, room_ptr_str) catch null;
            defer if (room_ptr_str_copy) |str| conn.allocator.free(str);

            if (room_ptr_str_copy) |str| {
                const room_ptr_int = std.fmt.parseInt(usize, str, 10) catch 0;
                if (room_ptr_int != 0) {
                    room_ptr = @as(*websocket_mod.room.WebSocketRoom, @ptrFromInt(room_ptr_int));
                }
            }
        }

        conn.cleanup();

        if (room_ptr) |room| {
            room.leave(conn);
        }

        conn.allocator.destroy(conn);
    }
}

/// Callback for errors
fn onError(client: *server.Client, err: anyerror) void {
    _ = client;
    std.debug.print("[WebSocket] Error: {}\n", .{err});
}

// ============================================================================
// Tests
// ============================================================================

test "AppData creation" {
    const allocator = std.testing.allocator;

    const dummy_handler: WebSocketHandler = struct {
        fn handler(_: *WebSocketConnection) void {}
    }.handler;

    const app_data = AppData{
        .handler = dummy_handler,
        .allocator = allocator,
        .path = "/ws/test",
        .manager = null,
    };

    try std.testing.expectEqualStrings("/ws/test", app_data.path);
}
