const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const handler = @import("handler.zig");
const connection = @import("connection.zig");
const server = @import("server.zig");
const protocol = @import("protocol.zig");
const room = @import("room.zig");

/// Entry for a registered WebSocket server
pub const WebSocketServerEntry = struct {
    path: []const u8,
    port: u16,
    handler: handler.WebSocketHandler,
    server_instance: ?*server.Server = null,
    thread: ?std.Thread = null,
};

/// Manages multiple WebSocket servers for Engine12
pub const WebSocketManager = struct {
    /// List of registered servers
    servers: std.ArrayListUnmanaged(WebSocketServerEntry),

    /// Active connections registry
    connections: std.StringHashMap(*connection.WebSocketConnection),
    connections_mutex: std.Thread.Mutex = .{},

    /// Allocator
    allocator: std.mem.Allocator,

    /// Base port for WebSocket servers
    base_port: u16 = 9000,

    /// Next available port
    next_port: u16 = 9000,

    /// Running state
    is_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !WebSocketManager {
        return WebSocketManager{
            .servers = .{},
            .connections = std.StringHashMap(*connection.WebSocketConnection).init(allocator),
            .allocator = allocator,
            .base_port = 9000,
            .next_port = 9000,
        };
    }

    /// Register a WebSocket server for a path
    pub fn registerServer(
        self: *WebSocketManager,
        path: []const u8,
        handler_fn: handler.WebSocketHandler,
    ) !void {
        const port = self.next_port;
        self.next_port += 1;

        try self.servers.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .port = port,
            .handler = handler_fn,
            .server_instance = null,
            .thread = null,
        });
    }

    /// Start all registered WebSocket servers
    pub fn start(self: *WebSocketManager) !void {
        if (self.is_running.swap(true, .monotonic)) {
            return; // Already running
        }

        for (self.servers.items, 0..) |*entry, idx| {
            // Create app data for this handler
            const app_data = try self.allocator.create(handler.AppData);
            app_data.* = .{
                .handler = entry.handler,
                .allocator = self.allocator,
                .path = entry.path,
                .manager = self,
            };

            // Create native WebSocket server
            const ws_server = try self.allocator.create(server.Server);
            ws_server.* = server.Server.init(self.allocator, .{
                .address = "127.0.0.1",
                .port = entry.port,
                .max_connections = 1024,
                .max_payload_size = 16 * 1024 * 1024,
                .read_timeout_ms = 30000,
                .write_timeout_ms = 30000,
                .handshake_timeout_ms = 3000,
            }, createCallbacks(app_data));

            entry.server_instance = ws_server;

            // Start the server in listening mode
            ws_server.start() catch |err| {
                std.debug.print("[WebSocket] Failed to start server on port {d}: {}\n", .{ entry.port, err });
                self.allocator.destroy(ws_server);
                entry.server_instance = null;
                continue;
            };

            // Spawn a thread to run the server accept loop
            const thread_ctx = try self.allocator.create(ServerThreadContext);
            thread_ctx.* = .{
                .server = ws_server,
                .app_data = app_data,
                .manager = self,
                .entry_idx = idx,
            };

            const thread = std.Thread.spawn(.{}, serverThreadFn, .{thread_ctx}) catch |err| {
                std.debug.print("[WebSocket] Failed to spawn server thread: {}\n", .{err});
                ws_server.stop();
                ws_server.deinit();
                self.allocator.destroy(ws_server);
                self.allocator.destroy(app_data);
                self.allocator.destroy(thread_ctx);
                entry.server_instance = null;
                continue;
            };

            entry.thread = thread;
        }
    }

    /// Stop all WebSocket servers
    pub fn stop(self: *WebSocketManager) void {
        self.is_running.store(false, .monotonic);

        // Stop all servers first
        for (self.servers.items) |*entry| {
            if (entry.server_instance) |ws_server| {
                ws_server.stop();
            }
        }

        // Wait for threads to finish (they will clean up app_data and thread_ctx via defer)
        for (self.servers.items) |*entry| {
            if (entry.thread) |thread| {
                thread.join();
            }
        }

        // Clean up server resources (app_data is already cleaned by thread defer)
        for (self.servers.items) |entry| {
            self.allocator.free(entry.path);
            if (entry.server_instance) |ws_server| {
                ws_server.deinit();
                self.allocator.destroy(ws_server);
            }
        }
        self.servers.deinit(self.allocator);

        // Clean up connections
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.cleanup();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit();
    }

    /// Register a connection
    pub fn registerConnection(
        self: *WebSocketManager,
        conn_id: []const u8,
        conn: *connection.WebSocketConnection,
    ) !void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        try self.connections.put(conn_id, conn);
    }

    /// Remove a connection
    pub fn removeConnection(self: *WebSocketManager, conn_id: []const u8) void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        _ = self.connections.remove(conn_id);
    }

    /// Get a connection by ID
    pub fn getConnection(
        self: *WebSocketManager,
        conn_id: []const u8,
    ) ?*connection.WebSocketConnection {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        return self.connections.get(conn_id);
    }

    /// Broadcast to all connections
    pub fn broadcast(self: *WebSocketManager, message: []const u8) void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.sendText(message) catch {};
        }
    }

    /// Get the number of active connections
    pub fn connectionCount(self: *WebSocketManager) usize {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();
        return self.connections.count();
    }
};

const ServerThreadContext = struct {
    server: *server.Server,
    app_data: *handler.AppData,
    manager: *WebSocketManager,
    entry_idx: usize,
};

fn serverThreadFn(ctx: *ServerThreadContext) void {
    defer ctx.manager.allocator.destroy(ctx.app_data);
    defer ctx.manager.allocator.destroy(ctx);

    // Run the server's accept loop
    runServerLoop(ctx.server, ctx.app_data, ctx.manager);
}

fn runServerLoop(ws_server: *server.Server, app_data: *handler.AppData, manager: *WebSocketManager) void {
    const listener = ws_server.listener orelse return;

    while (ws_server.is_running.load(.monotonic) and manager.is_running.load(.monotonic)) {
        var client_address: std.net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(std.net.Address);

        const client_socket = posix.accept(
            listener,
            &client_address.any,
            &client_address_len,
            0,
        ) catch |err| {
            if (!ws_server.is_running.load(.monotonic)) break;
            std.debug.print("[WebSocket] Accept error: {}\n", .{err});
            continue;
        };

        // Spawn a thread to handle this client
        const client_ctx = manager.allocator.create(ClientContext) catch {
            closeSocket(client_socket);
            continue;
        };
        client_ctx.* = .{
            .socket = client_socket,
            .address = client_address,
            .app_data = app_data,
            .manager = manager,
            .config = ws_server.config,
        };

        var thread = std.Thread.spawn(.{}, handleClientThread, .{client_ctx}) catch {
            manager.allocator.destroy(client_ctx);
            closeSocket(client_socket);
            continue;
        };
        thread.detach();
    }
}

const ClientContext = struct {
    socket: posix.socket_t,
    address: std.net.Address,
    app_data: *handler.AppData,
    manager: *WebSocketManager,
    config: server.ServerConfig,
};

fn handleClientThread(ctx: *ClientContext) void {
    defer ctx.manager.allocator.destroy(ctx);
    handleClient(ctx);
}

fn handleClient(ctx: *ClientContext) void {
    const socket = ctx.socket;
    defer closeSocket(socket);

    const allocator = ctx.app_data.allocator;
    const handshake_mod = @import("handshake.zig");

    // Set socket timeouts
    setSocketTimeouts(socket, ctx.config.handshake_timeout_ms, ctx.config.write_timeout_ms) catch return;

    // Read handshake request
    var buffer: [4096]u8 = undefined;
    var total_read: usize = 0;

    while (total_read < buffer.len) {
        const bytes_read = posix.recv(socket, buffer[total_read..], 0) catch return;
        if (bytes_read == 0) return;
        total_read += bytes_read;

        if (std.mem.indexOf(u8, buffer[0..total_read], "\r\n\r\n") != null) {
            break;
        }
    }

    // Parse handshake
    var request = handshake_mod.parseHandshakeRequest(allocator, buffer[0..total_read]) catch |err| {
        const response = handshake_mod.generateBadRequestResponse(allocator, @errorName(err)) catch return;
        defer allocator.free(response);
        _ = posix.send(socket, response, 0) catch {};
        return;
    };

    // Validate handshake
    handshake_mod.validateHandshake(&request) catch |err| {
        defer request.deinit(allocator);
        const response = switch (err) {
            handshake_mod.HandshakeError.UnsupportedWebSocketVersion => handshake_mod.generateUpgradeRequiredResponse(allocator) catch return,
            else => handshake_mod.generateBadRequestResponse(allocator, @errorName(err)) catch return,
        };
        defer allocator.free(response);
        _ = posix.send(socket, response, 0) catch {};
        return;
    };

    // Generate and send response
    const client_key = request.sec_websocket_key.?;
    const response = handshake_mod.generateHandshakeResponse(allocator, client_key, request.sec_websocket_protocol) catch {
        request.deinit(allocator);
        return;
    };
    defer allocator.free(response);

    _ = posix.send(socket, response, 0) catch {
        request.deinit(allocator);
        return;
    };

    // Create native client
    var native_client = server.Client.init(
        allocator,
        socket,
        ctx.address,
        request.path,
        request.headers,
        ctx.config.max_payload_size,
    ) catch {
        request.deinit(allocator);
        return;
    };

    // Free request fields we didn't transfer
    if (request.host) |h| allocator.free(h);
    if (request.upgrade) |u| allocator.free(u);
    if (request.connection) |c| allocator.free(c);
    if (request.sec_websocket_key) |k| allocator.free(k);
    if (request.sec_websocket_version) |v| allocator.free(v);
    if (request.sec_websocket_protocol) |p| allocator.free(p);
    if (request.sec_websocket_extensions) |e| allocator.free(e);
    if (request.origin) |o| allocator.free(o);
    allocator.free(request.path);
    // Headers ownership transferred to native_client

    // Create Engine12 connection wrapper
    const engine12_conn = handler.createEngine12Connection(
        allocator,
        &native_client,
        ctx.app_data.path,
    ) catch {
        native_client.deinit();
        return;
    };

    // Register connection
    ctx.manager.registerConnection(engine12_conn.id, engine12_conn) catch {
        engine12_conn.cleanup();
        allocator.destroy(engine12_conn);
        native_client.deinit();
        return;
    };

    defer {
        ctx.manager.removeConnection(engine12_conn.id);
        engine12_conn.cleanup();
        allocator.destroy(engine12_conn);
        native_client.deinit();
    }

    // Set normal timeouts for message handling
    setSocketTimeouts(socket, ctx.config.read_timeout_ms, ctx.config.write_timeout_ms) catch return;

    // Call the Engine12 handler (on_open equivalent)
    ctx.app_data.handler(engine12_conn);

    // Main message loop
    var read_buffer: [65536]u8 = undefined;
    while (native_client.isOpen() and ctx.manager.is_running.load(.monotonic)) {
        const frame = native_client.readFrame(&read_buffer) catch {
            break;
        };

        if (frame) |f| {
            defer native_client.freeFrame(f);

            switch (f.header.opcode) {
                .text, .binary => {
                    // Messages are handled by the application via callbacks or other means
                    // For Engine12, message handling is typically done through rooms/broadcast
                },
                .ping => {
                    // Pong is sent automatically by native client
                },
                .pong => {
                    // Acknowledge received
                },
                .close => {
                    // Echo close and exit
                    const close_info = f.getCloseInfo();
                    native_client.close(close_info.code, close_info.reason) catch {};
                    return;
                },
                .continuation => {
                    // Fragmented message handling
                },
            }
        } else {
            // Connection closed
            break;
        }
    }
}

fn closeSocket(socket: posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.closesocket(socket);
    } else {
        // Use system call directly to avoid unreachable on BADF
        // Socket may already be closed, so we silently ignore BADF errors
        switch (posix.errno(posix.system.close(socket))) {
            .SUCCESS => {},
            .BADF => {}, // Socket already closed, ignore
            .INTR => {}, // Interrupted, but still successful
            else => |err| {
                std.debug.print("[WebSocket] Error closing socket: {}\n", .{err});
            },
        }
    }
}

fn setSocketTimeouts(socket: posix.socket_t, read_timeout_ms: u32, write_timeout_ms: u32) !void {
    if (builtin.os.tag == .windows) {
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(read_timeout_ms));
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(write_timeout_ms));
    } else {
        const read_timeout = posix.timeval{
            .sec = @intCast(read_timeout_ms / 1000),
            .usec = @intCast((read_timeout_ms % 1000) * 1000),
        };
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(read_timeout));

        const write_timeout = posix.timeval{
            .sec = @intCast(write_timeout_ms / 1000),
            .usec = @intCast((write_timeout_ms % 1000) * 1000),
        };
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(write_timeout));
    }
}

fn createCallbacks(app_data: *handler.AppData) server.Callbacks {
    _ = app_data;
    // The callbacks are minimal since we handle everything in the manager's loop
    return server.Callbacks{
        .on_open = null,
        .on_text = null,
        .on_binary = null,
        .on_close = null,
        .on_error = null,
        .on_ping = null,
        .on_pong = null,
        .context = null,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "WebSocketManager init and deinit" {
    const allocator = std.testing.allocator;

    var manager = try WebSocketManager.init(allocator);
    manager.stop();
}

test "WebSocketManager register server" {
    const allocator = std.testing.allocator;

    var manager = try WebSocketManager.init(allocator);
    defer manager.stop();

    const dummy_handler: handler.WebSocketHandler = struct {
        fn h(_: *connection.WebSocketConnection) void {}
    }.h;

    try manager.registerServer("/ws/test", dummy_handler);

    try std.testing.expectEqual(@as(usize, 1), manager.servers.items.len);
    try std.testing.expectEqual(@as(u16, 9000), manager.servers.items[0].port);
}
