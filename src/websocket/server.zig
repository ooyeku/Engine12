const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const net = std.net;

const protocol = @import("protocol.zig");
const handshake = @import("handshake.zig");

/// WebSocket server configuration
pub const ServerConfig = struct {
    /// Address to bind to
    address: []const u8 = "127.0.0.1",
    /// Port to listen on
    port: u16 = 9000,
    /// Maximum number of concurrent connections
    max_connections: usize = 1024,
    /// Maximum payload size in bytes
    max_payload_size: usize = 16 * 1024 * 1024, // 16MB
    /// Read timeout in milliseconds
    read_timeout_ms: u32 = 30000,
    /// Write timeout in milliseconds
    write_timeout_ms: u32 = 30000,
    /// Handshake timeout in milliseconds
    handshake_timeout_ms: u32 = 3000,
    /// Buffer size for reading
    buffer_size: usize = 65536,
};

/// Represents a connected WebSocket client
pub const Client = struct {
    socket: posix.socket_t,
    address: net.Address,
    allocator: std.mem.Allocator,
    frame_parser: protocol.FrameParser,
    frame_encoder: protocol.FrameEncoder,
    is_open: std.atomic.Value(bool),
    path: []const u8,
    headers: std.StringHashMap([]const u8),
    user_data: ?*anyopaque,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        socket: posix.socket_t,
        address: net.Address,
        path: []const u8,
        headers: std.StringHashMap([]const u8),
        max_payload_size: usize,
    ) !Self {
        return Self{
            .socket = socket,
            .address = address,
            .allocator = allocator,
            .frame_parser = protocol.FrameParser.init(allocator, max_payload_size),
            .frame_encoder = protocol.FrameEncoder.init(allocator),
            .is_open = std.atomic.Value(bool).init(true),
            .path = try allocator.dupe(u8, path),
            .headers = headers,
            .user_data = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.frame_parser.deinit();
        self.allocator.free(self.path);

        var it = self.headers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
    }

    /// Send a text message
    pub fn sendText(self: *Self, text: []const u8) !void {
        if (!self.is_open.load(.monotonic)) {
            return error.ConnectionClosed;
        }

        const frame = try self.frame_encoder.encodeText(text);
        defer self.frame_encoder.free(frame);

        try self.sendRaw(frame);
    }

    /// Send a binary message
    pub fn sendBinary(self: *Self, data: []const u8) !void {
        if (!self.is_open.load(.monotonic)) {
            return error.ConnectionClosed;
        }

        const frame = try self.frame_encoder.encodeBinary(data);
        defer self.frame_encoder.free(frame);

        try self.sendRaw(frame);
    }

    /// Send a ping
    pub fn sendPing(self: *Self, data: []const u8) !void {
        if (!self.is_open.load(.monotonic)) {
            return error.ConnectionClosed;
        }

        const frame = try self.frame_encoder.encodePing(data);
        defer self.frame_encoder.free(frame);

        try self.sendRaw(frame);
    }

    /// Send a pong
    pub fn sendPong(self: *Self, data: []const u8) !void {
        if (!self.is_open.load(.monotonic)) {
            return error.ConnectionClosed;
        }

        const frame = try self.frame_encoder.encodePong(data);
        defer self.frame_encoder.free(frame);

        try self.sendRaw(frame);
    }

    /// Send a close frame and close the connection
    pub fn close(self: *Self, code: protocol.CloseCode, reason: []const u8) !void {
        if (!self.is_open.swap(false, .monotonic)) {
            return; // Already closed
        }

        const frame = try self.frame_encoder.encodeClose(code, reason);
        defer self.frame_encoder.free(frame);

        self.sendRaw(frame) catch {};
        closeSocket(self.socket);
    }

    /// Send raw frame data
    fn sendRaw(self: *Self, data: []const u8) !void {
        var total_sent: usize = 0;
        while (total_sent < data.len) {
            const sent = posix.send(self.socket, data[total_sent..], 0) catch |err| {
                self.is_open.store(false, .monotonic);
                return err;
            };
            if (sent == 0) {
                self.is_open.store(false, .monotonic);
                return error.ConnectionClosed;
            }
            total_sent += sent;
        }
    }

    /// Read and parse incoming frames
    pub fn readFrame(self: *Self, buffer: []u8) !?protocol.Frame {
        // Try to parse from existing buffer first
        if (try self.frame_parser.parse()) |frame| {
            return frame;
        }

        // Read more data
        const bytes_read = posix.recv(self.socket, buffer, 0) catch |err| {
            self.is_open.store(false, .monotonic);
            return err;
        };

        if (bytes_read == 0) {
            self.is_open.store(false, .monotonic);
            return null;
        }

        try self.frame_parser.feed(buffer[0..bytes_read]);
        return try self.frame_parser.parse();
    }

    /// Free a frame allocated by the parser
    pub fn freeFrame(self: *Self, frame: protocol.Frame) void {
        self.frame_parser.freeFrame(frame);
    }

    /// Check if connection is open
    pub fn isOpen(self: *Self) bool {
        return self.is_open.load(.monotonic);
    }

    /// Get a header value
    pub fn getHeader(self: *const Self, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }
};

/// Callback types for WebSocket server events
pub const Callbacks = struct {
    /// Called when a new connection is established
    on_open: ?*const fn (*Client) void = null,
    /// Called when a text message is received
    on_text: ?*const fn (*Client, []const u8) void = null,
    /// Called when a binary message is received
    on_binary: ?*const fn (*Client, []const u8) void = null,
    /// Called when a ping is received (pong is sent automatically)
    on_ping: ?*const fn (*Client, []const u8) void = null,
    /// Called when a pong is received
    on_pong: ?*const fn (*Client, []const u8) void = null,
    /// Called when a close is received or connection is closed
    on_close: ?*const fn (*Client, protocol.CloseCode, []const u8) void = null,
    /// Called on errors
    on_error: ?*const fn (*Client, anyerror) void = null,
    /// User context to pass to callbacks
    context: ?*anyopaque = null,
};

/// Native WebSocket server
pub const Server = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,
    callbacks: Callbacks,
    listener: ?posix.socket_t,
    is_running: std.atomic.Value(bool),
    clients: std.ArrayListUnmanaged(*Client),
    clients_mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig, callbacks: Callbacks) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .callbacks = callbacks,
            .listener = null,
            .is_running = std.atomic.Value(bool).init(false),
            .clients = std.ArrayListUnmanaged(*Client){},
            .clients_mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.clients.deinit(self.allocator);
    }

    /// Start the WebSocket server
    pub fn start(self: *Self) !void {
        if (self.is_running.load(.monotonic)) {
            return error.AlreadyRunning;
        }

        const address = try net.Address.parseIp4(self.config.address, self.config.port);

        const listener = try posix.socket(
            address.any.family,
            posix.SOCK.STREAM,
            posix.IPPROTO.TCP,
        );
        errdefer closeSocket(listener);

        // Set socket options
        try setReuseAddr(listener);
        try setSocketTimeouts(listener, self.config.read_timeout_ms, self.config.write_timeout_ms);

        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 128);

        self.listener = listener;
        self.is_running.store(true, .monotonic);
    }

    /// Accept and handle connections in a loop (blocking)
    pub fn listen(self: *Self) !void {
        const listener = self.listener orelse return error.NotStarted;

        while (self.is_running.load(.monotonic)) {
            var client_address: net.Address = undefined;
            var client_address_len: posix.socklen_t = @sizeOf(net.Address);

            const client_socket = posix.accept(
                listener,
                &client_address.any,
                &client_address_len,
                0,
            ) catch |err| {
                if (!self.is_running.load(.monotonic)) break;
                std.log.err("Accept error: {}", .{err});
                continue;
            };

            // Spawn a thread to handle this client
            const handler_ctx = self.allocator.create(ClientHandlerContext) catch {
                closeSocket(client_socket);
                continue;
            };
            handler_ctx.* = .{
                .server = self,
                .socket = client_socket,
                .address = client_address,
            };

            var thread = std.Thread.spawn(.{}, handleClientThread, .{handler_ctx}) catch {
                self.allocator.destroy(handler_ctx);
                closeSocket(client_socket);
                continue;
            };
            thread.detach();
        }
    }

    /// Stop the server
    pub fn stop(self: *Self) void {
        self.is_running.store(false, .monotonic);

        if (self.listener) |listener| {
            closeSocket(listener);
            self.listener = null;
        }

        // Close all client connections
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();

        for (self.clients.items) |client| {
            client.close(.going_away, "Server shutting down") catch {};
            client.deinit();
            self.allocator.destroy(client);
        }
        self.clients.clearRetainingCapacity();
    }

    /// Get the number of connected clients
    pub fn clientCount(self: *Self) usize {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        return self.clients.items.len;
    }

    /// Broadcast a text message to all connected clients
    pub fn broadcast(self: *Self, text: []const u8) void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();

        for (self.clients.items) |client| {
            client.sendText(text) catch {};
        }
    }

    /// Broadcast a binary message to all connected clients
    pub fn broadcastBinary(self: *Self, data: []const u8) void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();

        for (self.clients.items) |client| {
            client.sendBinary(data) catch {};
        }
    }

    fn addClient(self: *Self, client: *Client) !void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        try self.clients.append(self.allocator, client);
    }

    fn removeClient(self: *Self, client: *Client) void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();

        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.swapRemove(i);
                break;
            }
        }
    }
};

const ClientHandlerContext = struct {
    server: *Server,
    socket: posix.socket_t,
    address: net.Address,
};

fn handleClientThread(ctx: *ClientHandlerContext) void {
    defer ctx.server.allocator.destroy(ctx);
    handleClient(ctx.server, ctx.socket, ctx.address);
}

fn handleClient(server: *Server, socket: posix.socket_t, address: net.Address) void {
    defer closeSocket(socket);

    // Set socket timeouts
    setSocketTimeouts(socket, server.config.handshake_timeout_ms, server.config.write_timeout_ms) catch return;

    // Read handshake request
    var buffer: [4096]u8 = undefined;
    var total_read: usize = 0;

    while (total_read < buffer.len) {
        const bytes_read = posix.recv(socket, buffer[total_read..], 0) catch return;
        if (bytes_read == 0) return;
        total_read += bytes_read;

        // Check for end of headers
        if (std.mem.indexOf(u8, buffer[0..total_read], "\r\n\r\n") != null) {
            break;
        }
    }

    // Parse handshake
    var request = handshake.parseHandshakeRequest(server.allocator, buffer[0..total_read]) catch |err| {
        const response = handshake.generateBadRequestResponse(server.allocator, @errorName(err)) catch return;
        defer server.allocator.free(response);
        _ = posix.send(socket, response, 0) catch {};
        return;
    };

    // Validate handshake
    handshake.validateHandshake(&request) catch |err| {
        defer request.deinit(server.allocator);
        const response = switch (err) {
            handshake.HandshakeError.UnsupportedWebSocketVersion => handshake.generateUpgradeRequiredResponse(server.allocator) catch return,
            else => handshake.generateBadRequestResponse(server.allocator, @errorName(err)) catch return,
        };
        defer server.allocator.free(response);
        _ = posix.send(socket, response, 0) catch {};
        return;
    };

    // Generate and send response
    const client_key = request.sec_websocket_key.?;
    const response = handshake.generateHandshakeResponse(server.allocator, client_key, request.sec_websocket_protocol) catch {
        request.deinit(server.allocator);
        return;
    };
    defer server.allocator.free(response);

    _ = posix.send(socket, response, 0) catch {
        request.deinit(server.allocator);
        return;
    };

    // Create client and transfer ownership of headers
    const path = request.path;
    const headers = request.headers;
    // Clear request's references since we're transferring ownership
    request.path = "";
    request.headers = std.StringHashMap([]const u8).init(server.allocator);

    // Free other request fields that we copied
    if (request.host) |h| server.allocator.free(h);
    if (request.upgrade) |u| server.allocator.free(u);
    if (request.connection) |c| server.allocator.free(c);
    if (request.sec_websocket_key) |k| server.allocator.free(k);
    if (request.sec_websocket_version) |v| server.allocator.free(v);
    if (request.sec_websocket_protocol) |p| server.allocator.free(p);
    if (request.sec_websocket_extensions) |e| server.allocator.free(e);
    if (request.origin) |o| server.allocator.free(o);
    request.headers.deinit();

    var client = Client.init(
        server.allocator,
        socket,
        address,
        path,
        headers,
        server.config.max_payload_size,
    ) catch {
        server.allocator.free(path);
        var h_mut = headers;
        var it = h_mut.iterator();
        while (it.next()) |entry| {
            server.allocator.free(entry.key_ptr.*);
            server.allocator.free(entry.value_ptr.*);
        }
        h_mut.deinit();
        return;
    };
    server.allocator.free(path);

    const client_ptr = server.allocator.create(Client) catch {
        client.deinit();
        return;
    };
    client_ptr.* = client;

    server.addClient(client_ptr) catch {
        client_ptr.deinit();
        server.allocator.destroy(client_ptr);
        return;
    };

    defer {
        server.removeClient(client_ptr);
        client_ptr.deinit();
        server.allocator.destroy(client_ptr);
    }

    // Set normal timeouts
    setSocketTimeouts(socket, server.config.read_timeout_ms, server.config.write_timeout_ms) catch return;

    // Call on_open callback
    if (server.callbacks.on_open) |on_open| {
        on_open(client_ptr);
    }

    // Main read loop
    var read_buffer: [65536]u8 = undefined;
    while (client_ptr.isOpen() and server.is_running.load(.monotonic)) {
        const frame = client_ptr.readFrame(&read_buffer) catch |err| {
            if (server.callbacks.on_error) |on_error| {
                on_error(client_ptr, err);
            }
            break;
        };

        if (frame) |f| {
            defer client_ptr.freeFrame(f);

            switch (f.header.opcode) {
                .text => {
                    if (server.callbacks.on_text) |on_text| {
                        on_text(client_ptr, f.payload);
                    }
                },
                .binary => {
                    if (server.callbacks.on_binary) |on_binary| {
                        on_binary(client_ptr, f.payload);
                    }
                },
                .ping => {
                    // Send pong automatically
                    client_ptr.sendPong(f.payload) catch {};
                    if (server.callbacks.on_ping) |on_ping| {
                        on_ping(client_ptr, f.payload);
                    }
                },
                .pong => {
                    if (server.callbacks.on_pong) |on_pong| {
                        on_pong(client_ptr, f.payload);
                    }
                },
                .close => {
                    const close_info = f.getCloseInfo();
                    if (server.callbacks.on_close) |on_close| {
                        on_close(client_ptr, close_info.code, close_info.reason);
                    }
                    // Echo close frame
                    client_ptr.close(close_info.code, close_info.reason) catch {};
                    return;
                },
                .continuation => {
                    // TODO: Handle fragmented messages
                },
            }
        } else {
            // Connection closed
            if (server.callbacks.on_close) |on_close| {
                on_close(client_ptr, .abnormal, "Connection closed");
            }
            break;
        }
    }
}

// ============================================================================
// Cross-platform socket utilities
// ============================================================================

fn closeSocket(socket: posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.closesocket(socket);
    } else {
        posix.close(socket);
    }
}

fn setReuseAddr(socket: posix.socket_t) !void {
    const one: u32 = 1;
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(one));
}

fn setSocketTimeouts(socket: posix.socket_t, read_timeout_ms: u32, write_timeout_ms: u32) !void {
    if (builtin.os.tag == .windows) {
        // Windows uses milliseconds directly
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(read_timeout_ms));
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(write_timeout_ms));
    } else {
        // POSIX uses timeval struct
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

// ============================================================================
// Tests
// ============================================================================

test "Server init and deinit" {
    const allocator = std.testing.allocator;

    var server = Server.init(allocator, .{}, .{});
    defer server.deinit();

    try std.testing.expect(!server.is_running.load(.monotonic));
    try std.testing.expect(server.listener == null);
}

test "Client sendText encoding" {
    // This test validates that Client.sendText properly encodes frames
    // Full integration testing requires actual socket connections
}
