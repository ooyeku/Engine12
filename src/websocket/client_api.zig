const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const net = std.net;

const protocol = @import("protocol.zig");
const handshake = @import("handshake.zig");
const security = @import("security.zig");
const message = @import("message.zig");

/// Standalone WebSocket client for connecting to WebSocket servers
/// This can be used independently from the Engine12 framework
pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    socket: ?posix.socket_t,
    config: ClientConfig,
    state: State,
    frame_parser: protocol.FrameParser,
    frame_encoder: protocol.FrameEncoder,
    message_assembler: message.MessageAssembler,
    rate_limiter: security.RateLimiter,
    validator: security.FrameValidator,
    last_pong_time: i64,
    ping_failures: u8,
    read_buffer: []u8,

    const Self = @This();

    pub const State = enum {
        disconnected,
        connecting,
        connected,
        closing,
        closed,
    };

    pub const ClientConfig = struct {
        /// Server host
        host: []const u8 = "127.0.0.1",
        /// Server port
        port: u16 = 80,
        /// Request path
        path: []const u8 = "/",
        /// Origin header value
        origin: ?[]const u8 = null,
        /// Subprotocol to request
        protocol: ?[]const u8 = null,
        /// Security configuration
        security: security.SecurityConfig = .{},
        /// Read buffer size
        buffer_size: usize = 65536,
        /// Auto-respond to pings
        auto_pong: bool = true,
        /// Auto-reconnect on disconnect
        auto_reconnect: bool = false,
        /// Reconnect delay in ms
        reconnect_delay_ms: u32 = 1000,
        /// Maximum reconnect attempts
        max_reconnect_attempts: u32 = 5,
    };

    pub fn init(allocator: std.mem.Allocator, config: ClientConfig) !Self {
        const buffer = try allocator.alloc(u8, config.buffer_size);
        errdefer allocator.free(buffer);

        return Self{
            .allocator = allocator,
            .socket = null,
            .config = config,
            .state = .disconnected,
            .frame_parser = protocol.FrameParser.init(allocator, config.security.max_frame_size),
            .frame_encoder = protocol.FrameEncoder.init(allocator),
            .message_assembler = message.MessageAssembler.init(allocator, config.security),
            .rate_limiter = security.RateLimiter.init(config.security),
            .validator = security.FrameValidator.init(config.security),
            .last_pong_time = 0,
            .ping_failures = 0,
            .read_buffer = buffer,
        };
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();
        self.frame_parser.deinit();
        self.message_assembler.deinit();
        self.allocator.free(self.read_buffer);
    }

    /// Connect to the WebSocket server
    pub fn connect(self: *Self) !void {
        if (self.state != .disconnected) {
            return error.AlreadyConnected;
        }

        self.state = .connecting;
        errdefer self.state = .disconnected;

        // Resolve address
        const address = try net.Address.parseIp4(self.config.host, self.config.port);

        // Create socket
        const socket = try posix.socket(
            address.any.family,
            posix.SOCK.STREAM,
            posix.IPPROTO.TCP,
        );
        errdefer closeSocket(socket);

        // Set timeouts
        try setSocketTimeouts(socket, self.config.security.handshake_timeout_ms, self.config.security.handshake_timeout_ms);

        // Connect
        try posix.connect(socket, &address.any, address.getOsSockLen());

        // Perform handshake
        try self.performHandshake(socket);

        self.socket = socket;
        self.state = .connected;
        self.last_pong_time = std.time.milliTimestamp();
    }

    fn performHandshake(self: *Self, socket: posix.socket_t) !void {
        // Generate random key
        var key_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&key_bytes);

        var key_buf: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_buf, &key_bytes);
        const key = key_buf[0..24];

        // Build handshake request
        var request = std.ArrayListUnmanaged(u8){};
        defer request.deinit(self.allocator);

        try request.appendSlice(self.allocator, "GET ");
        try request.appendSlice(self.allocator, self.config.path);
        try request.appendSlice(self.allocator, " HTTP/1.1\r\n");

        try request.appendSlice(self.allocator, "Host: ");
        try request.appendSlice(self.allocator, self.config.host);
        try request.appendSlice(self.allocator, "\r\n");

        try request.appendSlice(self.allocator, "Upgrade: websocket\r\n");
        try request.appendSlice(self.allocator, "Connection: Upgrade\r\n");

        try request.appendSlice(self.allocator, "Sec-WebSocket-Key: ");
        try request.appendSlice(self.allocator, key);
        try request.appendSlice(self.allocator, "\r\n");

        try request.appendSlice(self.allocator, "Sec-WebSocket-Version: 13\r\n");

        if (self.config.origin) |origin| {
            try request.appendSlice(self.allocator, "Origin: ");
            try request.appendSlice(self.allocator, origin);
            try request.appendSlice(self.allocator, "\r\n");
        }

        if (self.config.protocol) |proto| {
            try request.appendSlice(self.allocator, "Sec-WebSocket-Protocol: ");
            try request.appendSlice(self.allocator, proto);
            try request.appendSlice(self.allocator, "\r\n");
        }

        try request.appendSlice(self.allocator, "\r\n");

        // Send request
        _ = try posix.send(socket, request.items, 0);

        // Read response
        var response_buf: [4096]u8 = undefined;
        var total_read: usize = 0;

        while (total_read < response_buf.len) {
            const bytes = posix.recv(socket, response_buf[total_read..], 0) catch |err| {
                return err;
            };
            if (bytes == 0) return error.ConnectionClosed;
            total_read += bytes;

            if (std.mem.indexOf(u8, response_buf[0..total_read], "\r\n\r\n") != null) {
                break;
            }
        }

        // Verify response
        const response = response_buf[0..total_read];

        // Check status line
        if (!std.mem.startsWith(u8, response, "HTTP/1.1 101")) {
            return error.HandshakeFailed;
        }

        // Verify accept key
        const expected_accept = try handshake.generateAcceptKey(self.allocator, key);
        defer self.allocator.free(expected_accept);

        if (std.mem.indexOf(u8, response, expected_accept) == null) {
            return error.InvalidAcceptKey;
        }
    }

    /// Disconnect from the server
    pub fn disconnect(self: *Self) void {
        if (self.socket) |socket| {
            closeSocket(socket);
            self.socket = null;
        }
        self.state = .disconnected;
        self.frame_parser.reset();
        self.message_assembler.reset();
        self.validator.reset();
    }

    /// Send a text message
    pub fn sendText(self: *Self, text: []const u8) !void {
        try self.sendFrame(.text, text);
    }

    /// Send a binary message
    pub fn sendBinary(self: *Self, data: []const u8) !void {
        try self.sendFrame(.binary, data);
    }

    /// Send a ping
    pub fn sendPing(self: *Self, data: []const u8) !void {
        try self.sendFrame(.ping, data);
    }

    /// Send a close frame and close connection
    pub fn close(self: *Self, code: protocol.CloseCode, reason: []const u8) !void {
        if (self.state != .connected) {
            return;
        }

        self.state = .closing;

        // Generate mask key
        var mask_key: [4]u8 = undefined;
        std.crypto.random.bytes(&mask_key);

        // Build close payload
        const code_u16 = @intFromEnum(code);
        const payload_len = 2 + reason.len;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);

        payload[0] = @intCast((code_u16 >> 8) & 0xFF);
        payload[1] = @intCast(code_u16 & 0xFF);
        if (reason.len > 0) {
            @memcpy(payload[2..], reason);
        }

        const frame = try self.frame_encoder.encodeWithMask(.close, payload, true, mask_key);
        defer self.frame_encoder.free(frame);

        if (self.socket) |socket| {
            _ = posix.send(socket, frame, 0) catch {};
        }

        self.state = .closed;
        self.disconnect();
    }

    fn sendFrame(self: *Self, opcode: protocol.Opcode, payload: []const u8) !void {
        if (self.state != .connected) {
            return error.NotConnected;
        }

        // Check rate limit
        if (!self.rate_limiter.allowFrame(payload.len)) {
            return error.RateLimited;
        }

        // Generate mask key (client frames must be masked)
        var mask_key: [4]u8 = undefined;
        std.crypto.random.bytes(&mask_key);

        const frame = try self.frame_encoder.encodeWithMask(opcode, payload, true, mask_key);
        defer self.frame_encoder.free(frame);

        const socket = self.socket orelse return error.NotConnected;
        _ = try posix.send(socket, frame, 0);
    }

    /// Receive the next message (blocking)
    pub fn receive(self: *Self) !?message.Message {
        if (self.state != .connected) {
            return null;
        }

        const socket = self.socket orelse return null;

        while (true) {
            // Try to parse existing data
            const frame = self.frame_parser.parse() catch |err| {
                self.disconnect();
                return err;
            };

            if (frame) |f| {
                defer self.frame_parser.freeFrame(f);

                // Handle control frames
                if (f.header.opcode.isControl()) {
                    try self.handleControlFrame(&f);
                    continue;
                }

                // Assemble message
                if (try self.message_assembler.processFrame(&f)) |msg| {
                    return msg;
                }

                continue;
            }

            // Read more data
            const bytes = posix.recv(socket, self.read_buffer, 0) catch |err| {
                self.disconnect();
                return err;
            };

            if (bytes == 0) {
                self.disconnect();
                return null;
            }

            try self.frame_parser.feed(self.read_buffer[0..bytes]);
        }
    }

    fn handleControlFrame(self: *Self, frame: *const protocol.Frame) !void {
        switch (frame.header.opcode) {
            .ping => {
                if (self.config.auto_pong) {
                    try self.sendPong(frame.payload);
                }
            },
            .pong => {
                self.last_pong_time = std.time.milliTimestamp();
                self.ping_failures = 0;
            },
            .close => {
                const close_info = frame.getCloseInfo();
                try self.close(close_info.code, close_info.reason);
            },
            else => {},
        }
    }

    fn sendPong(self: *Self, data: []const u8) !void {
        var mask_key: [4]u8 = undefined;
        std.crypto.random.bytes(&mask_key);

        const frame = try self.frame_encoder.encodeWithMask(.pong, data, true, mask_key);
        defer self.frame_encoder.free(frame);

        if (self.socket) |socket| {
            _ = try posix.send(socket, frame, 0);
        }
    }

    /// Check if connected
    pub fn isConnected(self: *const Self) bool {
        return self.state == .connected;
    }

    /// Get current state
    pub fn getState(self: *const Self) State {
        return self.state;
    }

    /// Free a received message
    pub fn freeMessage(self: *Self, msg: *const message.Message) void {
        self.message_assembler.freeMessage(msg);
    }
};

/// Builder for creating WebSocket clients with fluent API
pub const ClientBuilder = struct {
    config: WebSocketClient.ClientConfig,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .config = .{},
        };
    }

    pub fn host(self: *Self, h: []const u8) *Self {
        self.config.host = h;
        return self;
    }

    pub fn port(self: *Self, p: u16) *Self {
        self.config.port = p;
        return self;
    }

    pub fn path(self: *Self, p: []const u8) *Self {
        self.config.path = p;
        return self;
    }

    pub fn origin(self: *Self, o: []const u8) *Self {
        self.config.origin = o;
        return self;
    }

    pub fn protocol(self: *Self, p: []const u8) *Self {
        self.config.protocol = p;
        return self;
    }

    pub fn maxFrameSize(self: *Self, size: usize) *Self {
        self.config.security.max_frame_size = size;
        return self;
    }

    pub fn maxMessageSize(self: *Self, size: usize) *Self {
        self.config.security.max_message_size = size;
        return self;
    }

    pub fn autoPong(self: *Self, enabled: bool) *Self {
        self.config.auto_pong = enabled;
        return self;
    }

    pub fn autoReconnect(self: *Self, enabled: bool) *Self {
        self.config.auto_reconnect = enabled;
        return self;
    }

    pub fn bufferSize(self: *Self, size: usize) *Self {
        self.config.buffer_size = size;
        return self;
    }

    pub fn build(self: *Self) !WebSocketClient {
        return WebSocketClient.init(self.allocator, self.config);
    }
};

// Helper functions
fn closeSocket(socket: posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ws2_32.closesocket(socket);
    } else {
        posix.close(socket);
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

// ============================================================================
// Tests
// ============================================================================

test "ClientBuilder basic configuration" {
    const allocator = std.testing.allocator;

    var builder = ClientBuilder.init(allocator);
    _ = builder
        .host("localhost")
        .port(8080)
        .path("/ws")
        .autoPong(true);

    try std.testing.expectEqualStrings("localhost", builder.config.host);
    try std.testing.expectEqual(@as(u16, 8080), builder.config.port);
    try std.testing.expectEqualStrings("/ws", builder.config.path);
    try std.testing.expect(builder.config.auto_pong);
}

test "WebSocketClient init and deinit" {
    const allocator = std.testing.allocator;

    var client = try WebSocketClient.init(allocator, .{
        .host = "localhost",
        .port = 8080,
    });
    defer client.deinit();

    try std.testing.expect(!client.isConnected());
    try std.testing.expectEqual(WebSocketClient.State.disconnected, client.getState());
}

// ============================================================================
// Additional comprehensive tests
// ============================================================================

test "ClientBuilder full configuration" {
    const allocator = std.testing.allocator;

    var builder = ClientBuilder.init(allocator);
    _ = builder
        .host("example.com")
        .port(443)
        .path("/websocket")
        .origin("https://example.com")
        .protocol("chat")
        .maxFrameSize(1024 * 1024)
        .maxMessageSize(4 * 1024 * 1024)
        .autoPong(false)
        .autoReconnect(true)
        .bufferSize(32768);

    try std.testing.expectEqualStrings("example.com", builder.config.host);
    try std.testing.expectEqual(@as(u16, 443), builder.config.port);
    try std.testing.expectEqualStrings("/websocket", builder.config.path);
    try std.testing.expectEqualStrings("https://example.com", builder.config.origin.?);
    try std.testing.expectEqualStrings("chat", builder.config.protocol.?);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), builder.config.security.max_frame_size);
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), builder.config.security.max_message_size);
    try std.testing.expect(!builder.config.auto_pong);
    try std.testing.expect(builder.config.auto_reconnect);
    try std.testing.expectEqual(@as(usize, 32768), builder.config.buffer_size);
}

test "ClientBuilder can build client" {
    const allocator = std.testing.allocator;

    var builder = ClientBuilder.init(allocator);
    _ = builder.host("localhost").port(9000);

    var client = try builder.build();
    defer client.deinit();

    try std.testing.expectEqual(WebSocketClient.State.disconnected, client.getState());
}

test "ClientConfig default values" {
    const config = WebSocketClient.ClientConfig{};

    try std.testing.expectEqualStrings("127.0.0.1", config.host);
    try std.testing.expectEqual(@as(u16, 80), config.port);
    try std.testing.expectEqualStrings("/", config.path);
    try std.testing.expect(config.origin == null);
    try std.testing.expect(config.protocol == null);
    try std.testing.expectEqual(@as(usize, 65536), config.buffer_size);
    try std.testing.expect(config.auto_pong);
    try std.testing.expect(!config.auto_reconnect);
    try std.testing.expectEqual(@as(u32, 1000), config.reconnect_delay_ms);
    try std.testing.expectEqual(@as(u32, 5), config.max_reconnect_attempts);
}

test "WebSocketClient State enum" {
    try std.testing.expect(WebSocketClient.State.disconnected != WebSocketClient.State.connecting);
    try std.testing.expect(WebSocketClient.State.connecting != WebSocketClient.State.connected);
    try std.testing.expect(WebSocketClient.State.connected != WebSocketClient.State.closing);
    try std.testing.expect(WebSocketClient.State.closing != WebSocketClient.State.closed);
}

test "WebSocketClient initial state" {
    const allocator = std.testing.allocator;

    var client = try WebSocketClient.init(allocator, .{});
    defer client.deinit();

    try std.testing.expectEqual(WebSocketClient.State.disconnected, client.state);
    try std.testing.expect(client.socket == null);
    try std.testing.expectEqual(@as(i64, 0), client.last_pong_time);
    try std.testing.expectEqual(@as(u8, 0), client.ping_failures);
}

test "WebSocketClient disconnect from disconnected state" {
    const allocator = std.testing.allocator;

    var client = try WebSocketClient.init(allocator, .{});
    defer client.deinit();

    // Disconnect from already disconnected state should be safe
    client.disconnect();
    try std.testing.expectEqual(WebSocketClient.State.disconnected, client.getState());
}

test "WebSocketClient isConnected" {
    const allocator = std.testing.allocator;

    var client = try WebSocketClient.init(allocator, .{});
    defer client.deinit();

    try std.testing.expect(!client.isConnected());

    // Simulate connected state (without actual connection)
    client.state = .connected;
    try std.testing.expect(client.isConnected());

    client.state = .closing;
    try std.testing.expect(!client.isConnected());

    client.state = .closed;
    try std.testing.expect(!client.isConnected());
}

test "ClientBuilder chaining returns same instance" {
    const allocator = std.testing.allocator;

    var builder = ClientBuilder.init(allocator);

    const ptr1 = builder.host("a");
    const ptr2 = ptr1.port(1);
    const ptr3 = ptr2.path("/");

    // All should be same instance
    try std.testing.expect(ptr1 == ptr2);
    try std.testing.expect(ptr2 == ptr3);
}

test "WebSocketClient with custom buffer size" {
    const allocator = std.testing.allocator;

    var client = try WebSocketClient.init(allocator, .{
        .buffer_size = 1024,
    });
    defer client.deinit();

    try std.testing.expectEqual(@as(usize, 1024), client.read_buffer.len);
}

test "WebSocketClient with security config" {
    const allocator = std.testing.allocator;

    var client = try WebSocketClient.init(allocator, .{
        .security = .{
            .max_frame_size = 100,
            .max_message_size = 500,
            .require_masking = false,
        },
    });
    defer client.deinit();

    try std.testing.expectEqual(@as(usize, 100), client.config.security.max_frame_size);
    try std.testing.expectEqual(@as(usize, 500), client.config.security.max_message_size);
    try std.testing.expect(!client.config.security.require_masking);
}
