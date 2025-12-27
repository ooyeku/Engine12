const std = @import("std");
const builtin = @import("builtin");

/// WebSocket GUID as specified in RFC 6455
pub const WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// HTTP header parsing result
pub const HandshakeRequest = struct {
    path: []const u8,
    host: ?[]const u8,
    upgrade: ?[]const u8,
    connection: ?[]const u8,
    sec_websocket_key: ?[]const u8,
    sec_websocket_version: ?[]const u8,
    sec_websocket_protocol: ?[]const u8,
    sec_websocket_extensions: ?[]const u8,
    origin: ?[]const u8,
    headers: std.StringHashMap([]const u8),

    pub fn deinit(self: *HandshakeRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.host) |h| allocator.free(h);
        if (self.upgrade) |u| allocator.free(u);
        if (self.connection) |c| allocator.free(c);
        if (self.sec_websocket_key) |k| allocator.free(k);
        if (self.sec_websocket_version) |v| allocator.free(v);
        if (self.sec_websocket_protocol) |p| allocator.free(p);
        if (self.sec_websocket_extensions) |e| allocator.free(e);
        if (self.origin) |o| allocator.free(o);

        var it = self.headers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
    }
};

/// Handshake validation errors
pub const HandshakeError = error{
    InvalidRequest,
    InvalidMethod,
    MissingUpgradeHeader,
    InvalidUpgradeHeader,
    MissingConnectionHeader,
    InvalidConnectionHeader,
    MissingSecWebSocketKey,
    InvalidSecWebSocketKey,
    MissingSecWebSocketVersion,
    UnsupportedWebSocketVersion,
    OutOfMemory,
    InvalidHeader,
};

/// Parse an HTTP request and extract WebSocket handshake information
pub fn parseHandshakeRequest(allocator: std.mem.Allocator, data: []const u8) HandshakeError!HandshakeRequest {
    var result = HandshakeRequest{
        .path = undefined,
        .host = null,
        .upgrade = null,
        .connection = null,
        .sec_websocket_key = null,
        .sec_websocket_version = null,
        .sec_websocket_protocol = null,
        .sec_websocket_extensions = null,
        .origin = null,
        .headers = std.StringHashMap([]const u8).init(allocator),
    };
    errdefer {
        var it = result.headers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        result.headers.deinit();
    }

    // Find end of headers
    const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse {
        return HandshakeError.InvalidRequest;
    };

    const headers_data = data[0..header_end];
    var lines = std.mem.splitSequence(u8, headers_data, "\r\n");

    // Parse request line
    const request_line = lines.first();
    var request_parts = std.mem.splitScalar(u8, request_line, ' ');

    const method = request_parts.next() orelse return HandshakeError.InvalidRequest;
    if (!std.mem.eql(u8, method, "GET")) {
        return HandshakeError.InvalidMethod;
    }

    const path = request_parts.next() orelse return HandshakeError.InvalidRequest;
    result.path = allocator.dupe(u8, path) catch return HandshakeError.OutOfMemory;

    // Parse headers
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const colon_pos = std.mem.indexOf(u8, line, ":") orelse continue;
        const header_name = std.mem.trim(u8, line[0..colon_pos], " \t");
        const header_value = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");

        // Store in headers map
        const name_copy = allocator.dupe(u8, header_name) catch return HandshakeError.OutOfMemory;
        errdefer allocator.free(name_copy);
        const value_copy = allocator.dupe(u8, header_value) catch return HandshakeError.OutOfMemory;
        errdefer allocator.free(value_copy);

        result.headers.put(name_copy, value_copy) catch return HandshakeError.OutOfMemory;

        // Parse known headers (case-insensitive)
        if (std.ascii.eqlIgnoreCase(header_name, "Host")) {
            result.host = allocator.dupe(u8, header_value) catch return HandshakeError.OutOfMemory;
        } else if (std.ascii.eqlIgnoreCase(header_name, "Upgrade")) {
            result.upgrade = allocator.dupe(u8, header_value) catch return HandshakeError.OutOfMemory;
        } else if (std.ascii.eqlIgnoreCase(header_name, "Connection")) {
            result.connection = allocator.dupe(u8, header_value) catch return HandshakeError.OutOfMemory;
        } else if (std.ascii.eqlIgnoreCase(header_name, "Sec-WebSocket-Key")) {
            result.sec_websocket_key = allocator.dupe(u8, header_value) catch return HandshakeError.OutOfMemory;
        } else if (std.ascii.eqlIgnoreCase(header_name, "Sec-WebSocket-Version")) {
            result.sec_websocket_version = allocator.dupe(u8, header_value) catch return HandshakeError.OutOfMemory;
        } else if (std.ascii.eqlIgnoreCase(header_name, "Sec-WebSocket-Protocol")) {
            result.sec_websocket_protocol = allocator.dupe(u8, header_value) catch return HandshakeError.OutOfMemory;
        } else if (std.ascii.eqlIgnoreCase(header_name, "Sec-WebSocket-Extensions")) {
            result.sec_websocket_extensions = allocator.dupe(u8, header_value) catch return HandshakeError.OutOfMemory;
        } else if (std.ascii.eqlIgnoreCase(header_name, "Origin")) {
            result.origin = allocator.dupe(u8, header_value) catch return HandshakeError.OutOfMemory;
        }
    }

    return result;
}

/// Validate a WebSocket handshake request
pub fn validateHandshake(request: *const HandshakeRequest) HandshakeError!void {
    // Check Upgrade header
    if (request.upgrade) |upgrade| {
        if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) {
            return HandshakeError.InvalidUpgradeHeader;
        }
    } else {
        return HandshakeError.MissingUpgradeHeader;
    }

    // Check Connection header (should contain "Upgrade")
    if (request.connection) |connection| {
        var found_upgrade = false;
        var tokens = std.mem.splitScalar(u8, connection, ',');
        while (tokens.next()) |token| {
            const trimmed = std.mem.trim(u8, token, " \t");
            if (std.ascii.eqlIgnoreCase(trimmed, "upgrade")) {
                found_upgrade = true;
                break;
            }
        }
        if (!found_upgrade) {
            return HandshakeError.InvalidConnectionHeader;
        }
    } else {
        return HandshakeError.MissingConnectionHeader;
    }

    // Check Sec-WebSocket-Key
    if (request.sec_websocket_key) |key| {
        // Key should be 16 bytes base64-encoded (24 characters)
        if (key.len != 24) {
            return HandshakeError.InvalidSecWebSocketKey;
        }
    } else {
        return HandshakeError.MissingSecWebSocketKey;
    }

    // Check Sec-WebSocket-Version
    if (request.sec_websocket_version) |version| {
        if (!std.mem.eql(u8, version, "13")) {
            return HandshakeError.UnsupportedWebSocketVersion;
        }
    } else {
        return HandshakeError.MissingSecWebSocketVersion;
    }
}

/// Generate the Sec-WebSocket-Accept header value
pub fn generateAcceptKey(allocator: std.mem.Allocator, client_key: []const u8) ![]u8 {
    // Concatenate client key with GUID
    const concat_len = client_key.len + WEBSOCKET_GUID.len;
    const concat = try allocator.alloc(u8, concat_len);
    defer allocator.free(concat);

    @memcpy(concat[0..client_key.len], client_key);
    @memcpy(concat[client_key.len..], WEBSOCKET_GUID);

    // SHA-1 hash
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(concat, &hash, .{});

    // Base64 encode
    const base64_len = std.base64.standard.Encoder.calcSize(20);
    const result = try allocator.alloc(u8, base64_len);
    _ = std.base64.standard.Encoder.encode(result, &hash);

    return result;
}

/// Generate a WebSocket handshake response
pub fn generateHandshakeResponse(allocator: std.mem.Allocator, client_key: []const u8, protocol: ?[]const u8) ![]u8 {
    const accept_key = try generateAcceptKey(allocator, client_key);
    defer allocator.free(accept_key);

    var response = std.ArrayListUnmanaged(u8){};
    errdefer response.deinit(allocator);

    try response.appendSlice(allocator, "HTTP/1.1 101 Switching Protocols\r\n");
    try response.appendSlice(allocator, "Upgrade: websocket\r\n");
    try response.appendSlice(allocator, "Connection: Upgrade\r\n");
    try response.appendSlice(allocator, "Sec-WebSocket-Accept: ");
    try response.appendSlice(allocator, accept_key);
    try response.appendSlice(allocator, "\r\n");

    if (protocol) |p| {
        try response.appendSlice(allocator, "Sec-WebSocket-Protocol: ");
        try response.appendSlice(allocator, p);
        try response.appendSlice(allocator, "\r\n");
    }

    try response.appendSlice(allocator, "\r\n");

    return response.toOwnedSlice(allocator);
}

/// Generate a 400 Bad Request response
pub fn generateBadRequestResponse(allocator: std.mem.Allocator, reason: []const u8) ![]u8 {
    var response = std.ArrayListUnmanaged(u8){};
    errdefer response.deinit(allocator);

    const body_template = "Bad Request: {s}";
    const body_len = body_template.len - 3 + reason.len;

    try response.appendSlice(allocator, "HTTP/1.1 400 Bad Request\r\n");
    try response.appendSlice(allocator, "Content-Type: text/plain\r\n");

    // Format Content-Length header
    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "Content-Length: {d}\r\n", .{body_len}) catch return error.OutOfMemory;
    try response.appendSlice(allocator, len_str);

    try response.appendSlice(allocator, "Connection: close\r\n");
    try response.appendSlice(allocator, "\r\n");

    // Format body
    var body_buf: [256]u8 = undefined;
    const body_str = std.fmt.bufPrint(&body_buf, body_template, .{reason}) catch return error.OutOfMemory;
    try response.appendSlice(allocator, body_str);

    return response.toOwnedSlice(allocator);
}

/// Generate a 426 Upgrade Required response
pub fn generateUpgradeRequiredResponse(allocator: std.mem.Allocator) ![]u8 {
    var response = std.ArrayListUnmanaged(u8){};
    errdefer response.deinit(allocator);

    const body = "WebSocket upgrade required. Sec-WebSocket-Version: 13";

    try response.appendSlice(allocator, "HTTP/1.1 426 Upgrade Required\r\n");
    try response.appendSlice(allocator, "Content-Type: text/plain\r\n");

    // Format Content-Length header
    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "Content-Length: {d}\r\n", .{body.len}) catch return error.OutOfMemory;
    try response.appendSlice(allocator, len_str);

    try response.appendSlice(allocator, "Sec-WebSocket-Version: 13\r\n");
    try response.appendSlice(allocator, "Connection: close\r\n");
    try response.appendSlice(allocator, "\r\n");
    try response.appendSlice(allocator, body);

    return response.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "generateAcceptKey" {
    const allocator = std.testing.allocator;

    // Test vector from RFC 6455
    const client_key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept_key = try generateAcceptKey(allocator, client_key);
    defer allocator.free(accept_key);

    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept_key);
}

test "parseHandshakeRequest valid" {
    const allocator = std.testing.allocator;

    const request_data =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "Origin: http://example.com\r\n" ++
        "\r\n";

    var request = try parseHandshakeRequest(allocator, request_data);
    defer request.deinit(allocator);

    try std.testing.expectEqualStrings("/chat", request.path);
    try std.testing.expectEqualStrings("server.example.com", request.host.?);
    try std.testing.expectEqualStrings("websocket", request.upgrade.?);
    try std.testing.expectEqualStrings("Upgrade", request.connection.?);
    try std.testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", request.sec_websocket_key.?);
    try std.testing.expectEqualStrings("13", request.sec_websocket_version.?);
    try std.testing.expectEqualStrings("http://example.com", request.origin.?);
}

test "validateHandshake valid" {
    const allocator = std.testing.allocator;

    const request_data =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";

    var request = try parseHandshakeRequest(allocator, request_data);
    defer request.deinit(allocator);

    try validateHandshake(&request);
}

test "validateHandshake missing upgrade" {
    const allocator = std.testing.allocator;

    const request_data =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";

    var request = try parseHandshakeRequest(allocator, request_data);
    defer request.deinit(allocator);

    try std.testing.expectError(HandshakeError.MissingUpgradeHeader, validateHandshake(&request));
}

test "validateHandshake invalid version" {
    const allocator = std.testing.allocator;

    const request_data =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 8\r\n" ++
        "\r\n";

    var request = try parseHandshakeRequest(allocator, request_data);
    defer request.deinit(allocator);

    try std.testing.expectError(HandshakeError.UnsupportedWebSocketVersion, validateHandshake(&request));
}

test "generateHandshakeResponse" {
    const allocator = std.testing.allocator;

    const response = try generateHandshakeResponse(allocator, "dGhlIHNhbXBsZSBub25jZQ==", null);
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 101 Switching Protocols") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Upgrade: websocket") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Connection: Upgrade") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
}

test "generateHandshakeResponse with protocol" {
    const allocator = std.testing.allocator;

    const response = try generateHandshakeResponse(allocator, "dGhlIHNhbXBsZSBub25jZQ==", "chat");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "Sec-WebSocket-Protocol: chat") != null);
}

test "parseHandshakeRequest POST method rejected" {
    const allocator = std.testing.allocator;

    const request_data =
        "POST /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "\r\n";

    const result = parseHandshakeRequest(allocator, request_data);
    try std.testing.expectError(HandshakeError.InvalidMethod, result);
}

test "validateHandshake connection header with multiple values" {
    const allocator = std.testing.allocator;

    const request_data =
        "GET /chat HTTP/1.1\r\n" ++
        "Host: server.example.com\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: keep-alive, Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "\r\n";

    var request = try parseHandshakeRequest(allocator, request_data);
    defer request.deinit(allocator);

    try validateHandshake(&request);
}
