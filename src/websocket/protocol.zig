const std = @import("std");
const builtin = @import("builtin");

/// WebSocket opcodes as defined in RFC 6455
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    // 0x3-0x7 reserved for non-control frames
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    // 0xB-0xF reserved for control frames

    pub fn isControl(self: Opcode) bool {
        return @intFromEnum(self) >= 0x8;
    }

    pub fn isData(self: Opcode) bool {
        return @intFromEnum(self) <= 0x2;
    }

    pub fn fromU4(value: u4) ?Opcode {
        return switch (value) {
            0x0 => .continuation,
            0x1 => .text,
            0x2 => .binary,
            0x8 => .close,
            0x9 => .ping,
            0xA => .pong,
            else => null,
        };
    }
};

/// WebSocket close codes as defined in RFC 6455
pub const CloseCode = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    // 1004 reserved
    no_status = 1005,
    abnormal = 1006,
    invalid_payload = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    mandatory_extension = 1010,
    internal_error = 1011,
    tls_handshake = 1015,

    pub fn fromU16(value: u16) CloseCode {
        return switch (value) {
            1000 => .normal,
            1001 => .going_away,
            1002 => .protocol_error,
            1003 => .unsupported_data,
            1005 => .no_status,
            1006 => .abnormal,
            1007 => .invalid_payload,
            1008 => .policy_violation,
            1009 => .message_too_big,
            1010 => .mandatory_extension,
            1011 => .internal_error,
            1015 => .tls_handshake,
            else => .protocol_error,
        };
    }
};

/// Represents a parsed WebSocket frame header
pub const FrameHeader = struct {
    fin: bool,
    rsv1: bool,
    rsv2: bool,
    rsv3: bool,
    opcode: Opcode,
    masked: bool,
    payload_len: u64,
    mask_key: ?[4]u8,

    /// Calculate the total header size in bytes
    pub fn headerSize(self: FrameHeader) usize {
        var size: usize = 2; // Base header
        if (self.payload_len > 125) {
            if (self.payload_len <= 65535) {
                size += 2; // 16-bit length
            } else {
                size += 8; // 64-bit length
            }
        }
        if (self.masked) {
            size += 4; // Mask key
        }
        return size;
    }
};

/// Represents a complete WebSocket frame
pub const Frame = struct {
    header: FrameHeader,
    payload: []const u8,

    pub fn isText(self: Frame) bool {
        return self.header.opcode == .text;
    }

    pub fn isBinary(self: Frame) bool {
        return self.header.opcode == .binary;
    }

    pub fn isClose(self: Frame) bool {
        return self.header.opcode == .close;
    }

    pub fn isPing(self: Frame) bool {
        return self.header.opcode == .ping;
    }

    pub fn isPong(self: Frame) bool {
        return self.header.opcode == .pong;
    }

    /// Get close code and reason from a close frame
    pub fn getCloseInfo(self: Frame) struct { code: CloseCode, reason: []const u8 } {
        if (self.payload.len >= 2) {
            const code_value = (@as(u16, self.payload[0]) << 8) | @as(u16, self.payload[1]);
            return .{
                .code = CloseCode.fromU16(code_value),
                .reason = if (self.payload.len > 2) self.payload[2..] else "",
            };
        }
        return .{ .code = .no_status, .reason = "" };
    }
};

/// WebSocket frame parser
pub const FrameParser = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayListUnmanaged(u8),
    max_payload_size: usize,

    pub fn init(allocator: std.mem.Allocator, max_payload_size: usize) FrameParser {
        return FrameParser{
            .allocator = allocator,
            .buffer = std.ArrayListUnmanaged(u8){},
            .max_payload_size = max_payload_size,
        };
    }

    pub fn deinit(self: *FrameParser) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn reset(self: *FrameParser) void {
        self.buffer.clearRetainingCapacity();
    }

    /// Feed data into the parser
    pub fn feed(self: *FrameParser, data: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, data);
    }

    /// Try to parse a complete frame from the buffer
    /// Returns null if more data is needed
    pub fn parse(self: *FrameParser) !?Frame {
        const buf = self.buffer.items;

        if (buf.len < 2) {
            return null; // Need at least 2 bytes for header
        }

        // Parse first byte
        const fin = (buf[0] & 0x80) != 0;
        const rsv1 = (buf[0] & 0x40) != 0;
        const rsv2 = (buf[0] & 0x20) != 0;
        const rsv3 = (buf[0] & 0x10) != 0;
        const opcode_value: u4 = @truncate(buf[0] & 0x0F);

        const opcode = Opcode.fromU4(opcode_value) orelse {
            return error.InvalidOpcode;
        };

        // Check RSV bits (must be 0 unless extension is negotiated)
        if (rsv1 or rsv2 or rsv3) {
            return error.ReservedBitsSet;
        }

        // Parse second byte
        const masked = (buf[1] & 0x80) != 0;
        const len_byte: u7 = @truncate(buf[1] & 0x7F);

        var header_len: usize = 2;
        var payload_len: u64 = undefined;

        if (len_byte <= 125) {
            payload_len = len_byte;
        } else if (len_byte == 126) {
            if (buf.len < 4) return null;
            payload_len = (@as(u64, buf[2]) << 8) | @as(u64, buf[3]);
            header_len = 4;
        } else { // len_byte == 127
            if (buf.len < 10) return null;
            payload_len = (@as(u64, buf[2]) << 56) |
                (@as(u64, buf[3]) << 48) |
                (@as(u64, buf[4]) << 40) |
                (@as(u64, buf[5]) << 32) |
                (@as(u64, buf[6]) << 24) |
                (@as(u64, buf[7]) << 16) |
                (@as(u64, buf[8]) << 8) |
                @as(u64, buf[9]);
            header_len = 10;
        }

        // Validate payload size
        if (payload_len > self.max_payload_size) {
            return error.PayloadTooLarge;
        }

        // Control frames have max payload of 125
        if (opcode.isControl() and payload_len > 125) {
            return error.ControlFrameTooLarge;
        }

        // Control frames must not be fragmented
        if (opcode.isControl() and !fin) {
            return error.ControlFrameFragmented;
        }

        var mask_key: ?[4]u8 = null;
        if (masked) {
            if (buf.len < header_len + 4) return null;
            mask_key = buf[header_len..][0..4].*;
            header_len += 4;
        }

        const total_len = header_len + @as(usize, @intCast(payload_len));
        if (buf.len < total_len) {
            return null; // Need more data
        }

        // Extract and unmask payload
        const payload = try self.allocator.alloc(u8, @intCast(payload_len));
        errdefer self.allocator.free(payload);

        @memcpy(payload, buf[header_len..total_len]);

        if (mask_key) |key| {
            unmaskPayload(payload, key);
        }

        // Remove parsed data from buffer
        const remaining = buf.len - total_len;
        if (remaining > 0) {
            std.mem.copyForwards(u8, buf[0..remaining], buf[total_len..]);
        }
        self.buffer.shrinkRetainingCapacity(remaining);

        return Frame{
            .header = FrameHeader{
                .fin = fin,
                .rsv1 = rsv1,
                .rsv2 = rsv2,
                .rsv3 = rsv3,
                .opcode = opcode,
                .masked = masked,
                .payload_len = payload_len,
                .mask_key = mask_key,
            },
            .payload = payload,
        };
    }

    /// Free a frame's payload
    pub fn freeFrame(self: *FrameParser, frame: Frame) void {
        if (frame.payload.len > 0) {
            self.allocator.free(frame.payload);
        }
    }
};

/// Unmask payload data using the XOR mask key
pub fn unmaskPayload(payload: []u8, mask_key: [4]u8) void {
    for (payload, 0..) |*byte, i| {
        byte.* ^= mask_key[i % 4];
    }
}

/// Mask payload data using the XOR mask key
pub fn maskPayload(payload: []u8, mask_key: [4]u8) void {
    unmaskPayload(payload, mask_key); // XOR is symmetric
}

/// WebSocket frame encoder
pub const FrameEncoder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FrameEncoder {
        return FrameEncoder{ .allocator = allocator };
    }

    /// Encode a frame for sending (server-to-client, so no masking)
    pub fn encode(self: *FrameEncoder, opcode: Opcode, payload: []const u8, fin: bool) ![]u8 {
        return self.encodeWithMask(opcode, payload, fin, null);
    }

    /// Encode a frame with optional masking (client-to-server requires masking)
    pub fn encodeWithMask(self: *FrameEncoder, opcode: Opcode, payload: []const u8, fin: bool, mask_key: ?[4]u8) ![]u8 {
        const masked = mask_key != null;
        var header_len: usize = 2;

        if (payload.len > 125) {
            if (payload.len <= 65535) {
                header_len += 2;
            } else {
                header_len += 8;
            }
        }
        if (masked) {
            header_len += 4;
        }

        const total_len = header_len + payload.len;
        const frame = try self.allocator.alloc(u8, total_len);
        errdefer self.allocator.free(frame);

        // First byte: FIN + RSV + Opcode
        frame[0] = @as(u8, if (fin) 0x80 else 0x00) | @as(u8, @intFromEnum(opcode));

        // Second byte: MASK + Payload length
        var offset: usize = 2;
        if (payload.len <= 125) {
            frame[1] = @as(u8, if (masked) 0x80 else 0x00) | @as(u8, @intCast(payload.len));
        } else if (payload.len <= 65535) {
            frame[1] = @as(u8, if (masked) 0x80 else 0x00) | 126;
            frame[2] = @intCast((payload.len >> 8) & 0xFF);
            frame[3] = @intCast(payload.len & 0xFF);
            offset = 4;
        } else {
            frame[1] = @as(u8, if (masked) 0x80 else 0x00) | 127;
            const len64: u64 = payload.len;
            frame[2] = @intCast((len64 >> 56) & 0xFF);
            frame[3] = @intCast((len64 >> 48) & 0xFF);
            frame[4] = @intCast((len64 >> 40) & 0xFF);
            frame[5] = @intCast((len64 >> 32) & 0xFF);
            frame[6] = @intCast((len64 >> 24) & 0xFF);
            frame[7] = @intCast((len64 >> 16) & 0xFF);
            frame[8] = @intCast((len64 >> 8) & 0xFF);
            frame[9] = @intCast(len64 & 0xFF);
            offset = 10;
        }

        // Mask key (if present)
        if (mask_key) |key| {
            @memcpy(frame[offset .. offset + 4], &key);
            offset += 4;
        }

        // Payload
        @memcpy(frame[offset..], payload);

        // Apply mask if needed
        if (mask_key) |key| {
            maskPayload(frame[offset..], key);
        }

        return frame;
    }

    /// Encode a text frame
    pub fn encodeText(self: *FrameEncoder, text: []const u8) ![]u8 {
        return self.encode(.text, text, true);
    }

    /// Encode a binary frame
    pub fn encodeBinary(self: *FrameEncoder, data: []const u8) ![]u8 {
        return self.encode(.binary, data, true);
    }

    /// Encode a close frame
    pub fn encodeClose(self: *FrameEncoder, code: CloseCode, reason: []const u8) ![]u8 {
        const code_u16 = @intFromEnum(code);
        const payload_len = 2 + reason.len;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);

        payload[0] = @intCast((code_u16 >> 8) & 0xFF);
        payload[1] = @intCast(code_u16 & 0xFF);
        if (reason.len > 0) {
            @memcpy(payload[2..], reason);
        }

        return self.encode(.close, payload, true);
    }

    /// Encode a ping frame
    pub fn encodePing(self: *FrameEncoder, data: []const u8) ![]u8 {
        return self.encode(.ping, data, true);
    }

    /// Encode a pong frame
    pub fn encodePong(self: *FrameEncoder, data: []const u8) ![]u8 {
        return self.encode(.pong, data, true);
    }

    /// Free an encoded frame
    pub fn free(self: *FrameEncoder, frame: []u8) void {
        self.allocator.free(frame);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Opcode.isControl" {
    try std.testing.expect(!Opcode.text.isControl());
    try std.testing.expect(!Opcode.binary.isControl());
    try std.testing.expect(!Opcode.continuation.isControl());
    try std.testing.expect(Opcode.close.isControl());
    try std.testing.expect(Opcode.ping.isControl());
    try std.testing.expect(Opcode.pong.isControl());
}

test "Opcode.isData" {
    try std.testing.expect(Opcode.text.isData());
    try std.testing.expect(Opcode.binary.isData());
    try std.testing.expect(Opcode.continuation.isData());
    try std.testing.expect(!Opcode.close.isData());
    try std.testing.expect(!Opcode.ping.isData());
    try std.testing.expect(!Opcode.pong.isData());
}

test "unmaskPayload" {
    var payload = [_]u8{ 0x7F, 0x9F, 0x4D, 0x51, 0x58 };
    const mask_key = [_]u8{ 0x37, 0xFA, 0x21, 0x3D };

    unmaskPayload(&payload, mask_key);

    // Expected: "Hello" (72, 101, 108, 108, 111)
    try std.testing.expectEqualSlices(u8, "Hello", &payload);
}

test "FrameParser basic text frame" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    // A simple unmasked text frame with "Hello"
    // FIN=1, RSV=0, Opcode=1 (text) -> 0x81
    // Mask=0, Length=5 -> 0x05
    const frame_data = [_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' };
    try parser.feed(&frame_data);

    const frame = try parser.parse();
    try std.testing.expect(frame != null);

    if (frame) |f| {
        defer parser.freeFrame(f);
        try std.testing.expect(f.header.fin);
        try std.testing.expectEqual(Opcode.text, f.header.opcode);
        try std.testing.expect(!f.header.masked);
        try std.testing.expectEqual(@as(u64, 5), f.header.payload_len);
        try std.testing.expectEqualStrings("Hello", f.payload);
    }
}

test "FrameParser masked frame" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    // Masked text frame with "Hello"
    // FIN=1, RSV=0, Opcode=1 (text) -> 0x81
    // Mask=1, Length=5 -> 0x85
    // Mask key: 0x37, 0xFA, 0x21, 0x3D
    // Masked payload: 'H'^0x37, 'e'^0xFA, 'l'^0x21, 'l'^0x3D, 'o'^0x37
    const mask_key = [_]u8{ 0x37, 0xFA, 0x21, 0x3D };
    var masked_payload: [5]u8 = undefined;
    const hello = "Hello";
    for (hello, 0..) |c, i| {
        masked_payload[i] = c ^ mask_key[i % 4];
    }

    var frame_data: [11]u8 = undefined;
    frame_data[0] = 0x81;
    frame_data[1] = 0x85;
    @memcpy(frame_data[2..6], &mask_key);
    @memcpy(frame_data[6..11], &masked_payload);

    try parser.feed(&frame_data);

    const frame = try parser.parse();
    try std.testing.expect(frame != null);

    if (frame) |f| {
        defer parser.freeFrame(f);
        try std.testing.expect(f.header.fin);
        try std.testing.expectEqual(Opcode.text, f.header.opcode);
        try std.testing.expect(f.header.masked);
        try std.testing.expectEqualStrings("Hello", f.payload);
    }
}

test "FrameEncoder encode text" {
    const allocator = std.testing.allocator;
    var encoder = FrameEncoder.init(allocator);

    const frame = try encoder.encodeText("Hello");
    defer encoder.free(frame);

    try std.testing.expectEqual(@as(usize, 7), frame.len);
    try std.testing.expectEqual(@as(u8, 0x81), frame[0]); // FIN=1, Opcode=1
    try std.testing.expectEqual(@as(u8, 0x05), frame[1]); // Mask=0, Length=5
    try std.testing.expectEqualStrings("Hello", frame[2..]);
}

test "FrameEncoder encode close" {
    const allocator = std.testing.allocator;
    var encoder = FrameEncoder.init(allocator);

    const frame = try encoder.encodeClose(.normal, "goodbye");
    defer encoder.free(frame);

    try std.testing.expectEqual(@as(u8, 0x88), frame[0]); // FIN=1, Opcode=8 (close)
    try std.testing.expectEqual(@as(u8, 9), frame[1]); // Mask=0, Length=9 (2 + 7)
    // Close code 1000 = 0x03E8
    try std.testing.expectEqual(@as(u8, 0x03), frame[2]);
    try std.testing.expectEqual(@as(u8, 0xE8), frame[3]);
    try std.testing.expectEqualStrings("goodbye", frame[4..]);
}

test "FrameEncoder encode 16-bit length" {
    const allocator = std.testing.allocator;
    var encoder = FrameEncoder.init(allocator);

    const payload = try allocator.alloc(u8, 200);
    defer allocator.free(payload);
    @memset(payload, 'A');

    const frame = try encoder.encode(.text, payload, true);
    defer encoder.free(frame);

    try std.testing.expectEqual(@as(u8, 0x81), frame[0]); // FIN=1, Opcode=1
    try std.testing.expectEqual(@as(u8, 126), frame[1]); // Extended 16-bit length
    try std.testing.expectEqual(@as(u8, 0), frame[2]); // Length high byte
    try std.testing.expectEqual(@as(u8, 200), frame[3]); // Length low byte
}

test "FrameParser rejects control frame > 125 bytes" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    // Ping frame with 126 byte payload (invalid)
    var frame_data: [4]u8 = undefined;
    frame_data[0] = 0x89; // FIN=1, Opcode=9 (ping)
    frame_data[1] = 126; // Extended length marker
    frame_data[2] = 0;
    frame_data[3] = 130; // 130 bytes

    try parser.feed(&frame_data);

    const result = parser.parse();
    try std.testing.expectError(error.ControlFrameTooLarge, result);
}

test "FrameParser rejects fragmented control frame" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    // Ping frame with FIN=0 (invalid)
    const frame_data = [_]u8{ 0x09, 0x00 }; // FIN=0, Opcode=9 (ping)

    try parser.feed(&frame_data);

    const result = parser.parse();
    try std.testing.expectError(error.ControlFrameFragmented, result);
}

test "Frame.getCloseInfo" {
    const frame = Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .close,
            .masked = false,
            .payload_len = 9,
            .mask_key = null,
        },
        .payload = &[_]u8{ 0x03, 0xE8, 'g', 'o', 'o', 'd', 'b', 'y', 'e' },
    };

    const close_info = frame.getCloseInfo();
    try std.testing.expectEqual(CloseCode.normal, close_info.code);
    try std.testing.expectEqualStrings("goodbye", close_info.reason);
}

// ============================================================================
// Additional comprehensive tests
// ============================================================================

test "Opcode.fromU4 returns null for reserved opcodes" {
    // Reserved non-control opcodes (0x3-0x7)
    try std.testing.expect(Opcode.fromU4(0x3) == null);
    try std.testing.expect(Opcode.fromU4(0x4) == null);
    try std.testing.expect(Opcode.fromU4(0x5) == null);
    try std.testing.expect(Opcode.fromU4(0x6) == null);
    try std.testing.expect(Opcode.fromU4(0x7) == null);

    // Reserved control opcodes (0xB-0xF)
    try std.testing.expect(Opcode.fromU4(0xB) == null);
    try std.testing.expect(Opcode.fromU4(0xC) == null);
    try std.testing.expect(Opcode.fromU4(0xD) == null);
    try std.testing.expect(Opcode.fromU4(0xE) == null);
    try std.testing.expect(Opcode.fromU4(0xF) == null);
}

test "Opcode.fromU4 returns valid opcodes" {
    try std.testing.expectEqual(Opcode.continuation, Opcode.fromU4(0x0).?);
    try std.testing.expectEqual(Opcode.text, Opcode.fromU4(0x1).?);
    try std.testing.expectEqual(Opcode.binary, Opcode.fromU4(0x2).?);
    try std.testing.expectEqual(Opcode.close, Opcode.fromU4(0x8).?);
    try std.testing.expectEqual(Opcode.ping, Opcode.fromU4(0x9).?);
    try std.testing.expectEqual(Opcode.pong, Opcode.fromU4(0xA).?);
}

test "CloseCode.fromU16 handles all defined codes" {
    try std.testing.expectEqual(CloseCode.normal, CloseCode.fromU16(1000));
    try std.testing.expectEqual(CloseCode.going_away, CloseCode.fromU16(1001));
    try std.testing.expectEqual(CloseCode.protocol_error, CloseCode.fromU16(1002));
    try std.testing.expectEqual(CloseCode.unsupported_data, CloseCode.fromU16(1003));
    try std.testing.expectEqual(CloseCode.no_status, CloseCode.fromU16(1005));
    try std.testing.expectEqual(CloseCode.abnormal, CloseCode.fromU16(1006));
    try std.testing.expectEqual(CloseCode.invalid_payload, CloseCode.fromU16(1007));
    try std.testing.expectEqual(CloseCode.policy_violation, CloseCode.fromU16(1008));
    try std.testing.expectEqual(CloseCode.message_too_big, CloseCode.fromU16(1009));
    try std.testing.expectEqual(CloseCode.mandatory_extension, CloseCode.fromU16(1010));
    try std.testing.expectEqual(CloseCode.internal_error, CloseCode.fromU16(1011));
    try std.testing.expectEqual(CloseCode.tls_handshake, CloseCode.fromU16(1015));
}

test "CloseCode.fromU16 returns protocol_error for unknown codes" {
    try std.testing.expectEqual(CloseCode.protocol_error, CloseCode.fromU16(1004)); // Reserved
    try std.testing.expectEqual(CloseCode.protocol_error, CloseCode.fromU16(9999));
    try std.testing.expectEqual(CloseCode.protocol_error, CloseCode.fromU16(0));
}

test "FrameHeader.headerSize calculates correctly" {
    // 2 bytes base + no extended length + no mask
    const header1 = FrameHeader{
        .fin = true,
        .rsv1 = false,
        .rsv2 = false,
        .rsv3 = false,
        .opcode = .text,
        .masked = false,
        .payload_len = 100,
        .mask_key = null,
    };
    try std.testing.expectEqual(@as(usize, 2), header1.headerSize());

    // 2 bytes base + 2 bytes extended (16-bit) + no mask
    const header2 = FrameHeader{
        .fin = true,
        .rsv1 = false,
        .rsv2 = false,
        .rsv3 = false,
        .opcode = .text,
        .masked = false,
        .payload_len = 1000,
        .mask_key = null,
    };
    try std.testing.expectEqual(@as(usize, 4), header2.headerSize());

    // 2 bytes base + 8 bytes extended (64-bit) + no mask
    const header3 = FrameHeader{
        .fin = true,
        .rsv1 = false,
        .rsv2 = false,
        .rsv3 = false,
        .opcode = .text,
        .masked = false,
        .payload_len = 100000,
        .mask_key = null,
    };
    try std.testing.expectEqual(@as(usize, 10), header3.headerSize());

    // 2 bytes base + no extended length + 4 bytes mask
    const header4 = FrameHeader{
        .fin = true,
        .rsv1 = false,
        .rsv2 = false,
        .rsv3 = false,
        .opcode = .text,
        .masked = true,
        .payload_len = 100,
        .mask_key = [_]u8{ 0, 0, 0, 0 },
    };
    try std.testing.expectEqual(@as(usize, 6), header4.headerSize());

    // 2 bytes base + 8 bytes extended (64-bit) + 4 bytes mask
    const header5 = FrameHeader{
        .fin = true,
        .rsv1 = false,
        .rsv2 = false,
        .rsv3 = false,
        .opcode = .text,
        .masked = true,
        .payload_len = 100000,
        .mask_key = [_]u8{ 0, 0, 0, 0 },
    };
    try std.testing.expectEqual(@as(usize, 14), header5.headerSize());
}

test "Frame type helper methods" {
    const text_frame = Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .text,
            .masked = false,
            .payload_len = 0,
            .mask_key = null,
        },
        .payload = "",
    };
    try std.testing.expect(text_frame.isText());
    try std.testing.expect(!text_frame.isBinary());
    try std.testing.expect(!text_frame.isClose());
    try std.testing.expect(!text_frame.isPing());
    try std.testing.expect(!text_frame.isPong());

    const binary_frame = Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .binary,
            .masked = false,
            .payload_len = 0,
            .mask_key = null,
        },
        .payload = "",
    };
    try std.testing.expect(!binary_frame.isText());
    try std.testing.expect(binary_frame.isBinary());

    const ping_frame = Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .ping,
            .masked = false,
            .payload_len = 0,
            .mask_key = null,
        },
        .payload = "",
    };
    try std.testing.expect(ping_frame.isPing());
    try std.testing.expect(!ping_frame.isPong());

    const pong_frame = Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .pong,
            .masked = false,
            .payload_len = 0,
            .mask_key = null,
        },
        .payload = "",
    };
    try std.testing.expect(!pong_frame.isPing());
    try std.testing.expect(pong_frame.isPong());
}

test "Frame.getCloseInfo with empty payload" {
    const frame = Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .close,
            .masked = false,
            .payload_len = 0,
            .mask_key = null,
        },
        .payload = "",
    };

    const close_info = frame.getCloseInfo();
    try std.testing.expectEqual(CloseCode.no_status, close_info.code);
    try std.testing.expectEqualStrings("", close_info.reason);
}

test "Frame.getCloseInfo with code only (no reason)" {
    const frame = Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .close,
            .masked = false,
            .payload_len = 2,
            .mask_key = null,
        },
        .payload = &[_]u8{ 0x03, 0xE9 }, // 1001 (going_away)
    };

    const close_info = frame.getCloseInfo();
    try std.testing.expectEqual(CloseCode.going_away, close_info.code);
    try std.testing.expectEqualStrings("", close_info.reason);
}

test "FrameParser rejects reserved RSV bits" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    // Text frame with RSV1 set (invalid without extension)
    const frame_data = [_]u8{ 0xC1, 0x05, 'H', 'e', 'l', 'l', 'o' }; // RSV1=1

    try parser.feed(&frame_data);

    const result = parser.parse();
    try std.testing.expectError(error.ReservedBitsSet, result);
}

test "FrameParser rejects invalid opcodes" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    // Frame with reserved opcode 0x3
    const frame_data = [_]u8{ 0x83, 0x05, 'H', 'e', 'l', 'l', 'o' };

    try parser.feed(&frame_data);

    const result = parser.parse();
    try std.testing.expectError(error.InvalidOpcode, result);
}

test "FrameParser rejects payload exceeding max size" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 100); // Max 100 bytes
    defer parser.deinit();

    // Frame with 200 byte payload
    var frame_data: [4]u8 = undefined;
    frame_data[0] = 0x81; // FIN=1, Opcode=1 (text)
    frame_data[1] = 126; // Extended length marker
    frame_data[2] = 0;
    frame_data[3] = 200; // 200 bytes

    try parser.feed(&frame_data);

    const result = parser.parse();
    try std.testing.expectError(error.PayloadTooLarge, result);
}

test "FrameParser handles incremental data feeding" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    const frame_data = [_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' };

    // Feed one byte at a time
    for (frame_data[0..6]) |byte| {
        try parser.feed(&[_]u8{byte});
        const result = try parser.parse();
        try std.testing.expect(result == null); // Not complete yet
    }

    // Feed final byte
    try parser.feed(&[_]u8{frame_data[6]});
    const frame = try parser.parse();
    try std.testing.expect(frame != null);

    if (frame) |f| {
        defer parser.freeFrame(f);
        try std.testing.expectEqualStrings("Hello", f.payload);
    }
}

test "FrameParser handles multiple frames in buffer" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    // Two text frames back-to-back
    const frame1 = [_]u8{ 0x81, 0x02, 'H', 'i' };
    const frame2 = [_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' };

    try parser.feed(&frame1);
    try parser.feed(&frame2);

    // Parse first frame
    const f1 = try parser.parse();
    try std.testing.expect(f1 != null);
    if (f1) |f| {
        defer parser.freeFrame(f);
        try std.testing.expectEqualStrings("Hi", f.payload);
    }

    // Parse second frame
    const f2 = try parser.parse();
    try std.testing.expect(f2 != null);
    if (f2) |f| {
        defer parser.freeFrame(f);
        try std.testing.expectEqualStrings("Hello", f.payload);
    }

    // No more frames
    const f3 = try parser.parse();
    try std.testing.expect(f3 == null);
}

test "FrameParser binary frame" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    // Binary frame with non-UTF8 data
    const frame_data = [_]u8{ 0x82, 0x04, 0xFF, 0xFE, 0x00, 0x01 };
    try parser.feed(&frame_data);

    const frame = try parser.parse();
    try std.testing.expect(frame != null);

    if (frame) |f| {
        defer parser.freeFrame(f);
        try std.testing.expectEqual(Opcode.binary, f.header.opcode);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFE, 0x00, 0x01 }, f.payload);
    }
}

test "FrameParser ping frame" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    // Ping frame with payload
    const frame_data = [_]u8{ 0x89, 0x04, 'p', 'i', 'n', 'g' };
    try parser.feed(&frame_data);

    const frame = try parser.parse();
    try std.testing.expect(frame != null);

    if (frame) |f| {
        defer parser.freeFrame(f);
        try std.testing.expect(f.isPing());
        try std.testing.expectEqualStrings("ping", f.payload);
    }
}

test "FrameParser pong frame" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    // Pong frame with payload
    const frame_data = [_]u8{ 0x8A, 0x04, 'p', 'o', 'n', 'g' };
    try parser.feed(&frame_data);

    const frame = try parser.parse();
    try std.testing.expect(frame != null);

    if (frame) |f| {
        defer parser.freeFrame(f);
        try std.testing.expect(f.isPong());
        try std.testing.expectEqualStrings("pong", f.payload);
    }
}

test "FrameParser close frame" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    // Close frame with code 1000 and reason "bye"
    const frame_data = [_]u8{ 0x88, 0x05, 0x03, 0xE8, 'b', 'y', 'e' };
    try parser.feed(&frame_data);

    const frame = try parser.parse();
    try std.testing.expect(frame != null);

    if (frame) |f| {
        defer parser.freeFrame(f);
        try std.testing.expect(f.isClose());
        const info = f.getCloseInfo();
        try std.testing.expectEqual(CloseCode.normal, info.code);
        try std.testing.expectEqualStrings("bye", info.reason);
    }
}

test "FrameParser continuation frame (fragmentation)" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    // First fragment (FIN=0, text)
    const frame1 = [_]u8{ 0x01, 0x03, 'H', 'e', 'l' };
    try parser.feed(&frame1);

    const f1 = try parser.parse();
    try std.testing.expect(f1 != null);
    if (f1) |f| {
        defer parser.freeFrame(f);
        try std.testing.expect(!f.header.fin);
        try std.testing.expectEqual(Opcode.text, f.header.opcode);
        try std.testing.expectEqualStrings("Hel", f.payload);
    }

    // Continuation fragment (FIN=1, continuation)
    const frame2 = [_]u8{ 0x80, 0x02, 'l', 'o' };
    try parser.feed(&frame2);

    const f2 = try parser.parse();
    try std.testing.expect(f2 != null);
    if (f2) |f| {
        defer parser.freeFrame(f);
        try std.testing.expect(f.header.fin);
        try std.testing.expectEqual(Opcode.continuation, f.header.opcode);
        try std.testing.expectEqualStrings("lo", f.payload);
    }
}

test "FrameParser reset clears buffer" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    // Feed partial data
    try parser.feed(&[_]u8{ 0x81, 0x05, 'H' });

    // Reset
    parser.reset();

    // Buffer should be empty, feeding new complete frame should work
    const frame_data = [_]u8{ 0x81, 0x02, 'O', 'K' };
    try parser.feed(&frame_data);

    const frame = try parser.parse();
    try std.testing.expect(frame != null);
    if (frame) |f| {
        defer parser.freeFrame(f);
        try std.testing.expectEqualStrings("OK", f.payload);
    }
}

test "FrameEncoder encode binary" {
    const allocator = std.testing.allocator;
    var encoder = FrameEncoder.init(allocator);

    const data = [_]u8{ 0xFF, 0x00, 0xAB, 0xCD };
    const frame = try encoder.encodeBinary(&data);
    defer encoder.free(frame);

    try std.testing.expectEqual(@as(u8, 0x82), frame[0]); // FIN=1, Opcode=2 (binary)
    try std.testing.expectEqual(@as(u8, 0x04), frame[1]); // Mask=0, Length=4
    try std.testing.expectEqualSlices(u8, &data, frame[2..]);
}

test "FrameEncoder encode ping" {
    const allocator = std.testing.allocator;
    var encoder = FrameEncoder.init(allocator);

    const frame = try encoder.encodePing("test");
    defer encoder.free(frame);

    try std.testing.expectEqual(@as(u8, 0x89), frame[0]); // FIN=1, Opcode=9 (ping)
    try std.testing.expectEqual(@as(u8, 0x04), frame[1]); // Mask=0, Length=4
    try std.testing.expectEqualStrings("test", frame[2..]);
}

test "FrameEncoder encode pong" {
    const allocator = std.testing.allocator;
    var encoder = FrameEncoder.init(allocator);

    const frame = try encoder.encodePong("test");
    defer encoder.free(frame);

    try std.testing.expectEqual(@as(u8, 0x8A), frame[0]); // FIN=1, Opcode=A (pong)
    try std.testing.expectEqual(@as(u8, 0x04), frame[1]); // Mask=0, Length=4
    try std.testing.expectEqualStrings("test", frame[2..]);
}

test "FrameEncoder encode empty payload" {
    const allocator = std.testing.allocator;
    var encoder = FrameEncoder.init(allocator);

    const frame = try encoder.encodeText("");
    defer encoder.free(frame);

    try std.testing.expectEqual(@as(usize, 2), frame.len);
    try std.testing.expectEqual(@as(u8, 0x81), frame[0]); // FIN=1, Opcode=1
    try std.testing.expectEqual(@as(u8, 0x00), frame[1]); // Mask=0, Length=0
}

test "FrameEncoder encode with mask (client-side)" {
    const allocator = std.testing.allocator;
    var encoder = FrameEncoder.init(allocator);

    const mask_key = [_]u8{ 0x37, 0xFA, 0x21, 0x3D };
    const frame = try encoder.encodeWithMask(.text, "Hello", true, mask_key);
    defer encoder.free(frame);

    try std.testing.expectEqual(@as(u8, 0x81), frame[0]); // FIN=1, Opcode=1
    try std.testing.expectEqual(@as(u8, 0x85), frame[1]); // Mask=1, Length=5
    try std.testing.expectEqualSlices(u8, &mask_key, frame[2..6]);

    // Verify masked payload by unmasking
    var payload: [5]u8 = undefined;
    @memcpy(&payload, frame[6..11]);
    unmaskPayload(&payload, mask_key);
    try std.testing.expectEqualStrings("Hello", &payload);
}

test "FrameEncoder encode 64-bit length" {
    const allocator = std.testing.allocator;
    var encoder = FrameEncoder.init(allocator);

    // Create payload larger than 65535 bytes
    const payload = try allocator.alloc(u8, 70000);
    defer allocator.free(payload);
    @memset(payload, 'X');

    const frame = try encoder.encode(.binary, payload, true);
    defer encoder.free(frame);

    try std.testing.expectEqual(@as(u8, 0x82), frame[0]); // FIN=1, Opcode=2
    try std.testing.expectEqual(@as(u8, 127), frame[1]); // Extended 64-bit length

    // Verify 64-bit length encoding
    const encoded_len: u64 = (@as(u64, frame[2]) << 56) |
        (@as(u64, frame[3]) << 48) |
        (@as(u64, frame[4]) << 40) |
        (@as(u64, frame[5]) << 32) |
        (@as(u64, frame[6]) << 24) |
        (@as(u64, frame[7]) << 16) |
        (@as(u64, frame[8]) << 8) |
        @as(u64, frame[9]);
    try std.testing.expectEqual(@as(u64, 70000), encoded_len);
}

test "FrameEncoder encode non-final frame (fragmentation)" {
    const allocator = std.testing.allocator;
    var encoder = FrameEncoder.init(allocator);

    // First fragment (FIN=0)
    const frame = try encoder.encode(.text, "Hello", false);
    defer encoder.free(frame);

    try std.testing.expectEqual(@as(u8, 0x01), frame[0]); // FIN=0, Opcode=1
    try std.testing.expectEqual(@as(u8, 0x05), frame[1]); // Mask=0, Length=5
    try std.testing.expectEqualStrings("Hello", frame[2..]);
}

test "FrameEncoder encode continuation frame" {
    const allocator = std.testing.allocator;
    var encoder = FrameEncoder.init(allocator);

    // Continuation fragment (FIN=1)
    const frame = try encoder.encode(.continuation, " World", true);
    defer encoder.free(frame);

    try std.testing.expectEqual(@as(u8, 0x80), frame[0]); // FIN=1, Opcode=0
    try std.testing.expectEqual(@as(u8, 0x06), frame[1]); // Mask=0, Length=6
    try std.testing.expectEqualStrings(" World", frame[2..]);
}

test "maskPayload and unmaskPayload are symmetric" {
    var data1 = [_]u8{ 'H', 'e', 'l', 'l', 'o' };
    var data2 = [_]u8{ 'H', 'e', 'l', 'l', 'o' };
    const mask_key = [_]u8{ 0x12, 0x34, 0x56, 0x78 };

    maskPayload(&data1, mask_key);
    try std.testing.expect(!std.mem.eql(u8, &data1, "Hello")); // Should be masked

    unmaskPayload(&data1, mask_key);
    try std.testing.expectEqualSlices(u8, &data2, &data1); // Should be unmasked
}

test "FrameParser 64-bit length frame" {
    const allocator = std.testing.allocator;
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    // Frame with 64-bit length encoding for 300 bytes
    var frame_data = try allocator.alloc(u8, 10 + 300);
    defer allocator.free(frame_data);

    frame_data[0] = 0x82; // FIN=1, Opcode=2 (binary)
    frame_data[1] = 127; // 64-bit length marker
    // 64-bit length = 300
    frame_data[2] = 0;
    frame_data[3] = 0;
    frame_data[4] = 0;
    frame_data[5] = 0;
    frame_data[6] = 0;
    frame_data[7] = 0;
    frame_data[8] = 1; // 256
    frame_data[9] = 44; // + 44 = 300

    @memset(frame_data[10..], 'Y');

    try parser.feed(frame_data);

    const frame = try parser.parse();
    try std.testing.expect(frame != null);

    if (frame) |f| {
        defer parser.freeFrame(f);
        try std.testing.expectEqual(@as(u64, 300), f.header.payload_len);
        try std.testing.expectEqual(@as(usize, 300), f.payload.len);
    }
}

test "FrameEncoder round-trip with FrameParser" {
    const allocator = std.testing.allocator;

    var encoder = FrameEncoder.init(allocator);
    var parser = FrameParser.init(allocator, 1024 * 1024);
    defer parser.deinit();

    // Encode a frame
    const original = "Hello, WebSocket!";
    const encoded = try encoder.encodeText(original);
    defer encoder.free(encoded);

    // Parse it back
    try parser.feed(encoded);
    const frame = try parser.parse();
    try std.testing.expect(frame != null);

    if (frame) |f| {
        defer parser.freeFrame(f);
        try std.testing.expectEqualStrings(original, f.payload);
        try std.testing.expect(f.header.fin);
        try std.testing.expectEqual(Opcode.text, f.header.opcode);
    }
}
