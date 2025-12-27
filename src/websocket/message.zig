const std = @import("std");
const protocol = @import("protocol.zig");
const security = @import("security.zig");

/// Represents a complete WebSocket message (potentially assembled from multiple frames)
pub const Message = struct {
    /// The message type (text or binary)
    opcode: protocol.Opcode,
    /// The complete message payload
    data: []const u8,
    /// Whether this message was fragmented
    was_fragmented: bool,
    /// Number of fragments that made up this message
    fragment_count: usize,

    /// Check if this is a text message
    pub fn isText(self: Message) bool {
        return self.opcode == .text;
    }

    /// Check if this is a binary message
    pub fn isBinary(self: Message) bool {
        return self.opcode == .binary;
    }

    /// Get data as a string (only valid for text messages)
    pub fn asText(self: Message) []const u8 {
        return self.data;
    }

    /// Get data as bytes
    pub fn asBytes(self: Message) []const u8 {
        return self.data;
    }
};

/// Assembles fragmented WebSocket messages into complete messages
pub const MessageAssembler = struct {
    allocator: std.mem.Allocator,
    config: security.SecurityConfig,

    /// Current fragmented message being assembled
    fragments: std.ArrayListUnmanaged(u8),
    /// The opcode of the fragmented message
    opcode: ?protocol.Opcode,
    /// Number of fragments received
    fragment_count: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: security.SecurityConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .fragments = std.ArrayListUnmanaged(u8){},
            .opcode = null,
            .fragment_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.fragments.deinit(self.allocator);
    }

    /// Process a frame and return a complete message if available
    /// Returns null if frame is part of an incomplete fragmented message
    pub fn processFrame(self: *Self, frame: *const protocol.Frame) !?Message {
        const opcode = frame.header.opcode;

        // Control frames are passed through immediately
        if (opcode.isControl()) {
            return null; // Control frames handled separately
        }

        if (opcode == .continuation) {
            // Must have an ongoing fragmented message
            if (self.opcode == null) {
                return error.UnexpectedContinuation;
            }

            // Append fragment
            try self.appendFragment(frame.payload);

            if (frame.header.fin) {
                // Message complete - wrap in optional to match return type
                const msg = try self.completeMessage();
                return msg;
            }

            return null; // Need more fragments
        }

        // New data frame (text or binary)
        if (self.opcode != null) {
            return error.NewFrameDuringFragmentation;
        }

        if (frame.header.fin) {
            // Single-frame message
            const data = try self.allocator.dupe(u8, frame.payload);
            return Message{
                .opcode = opcode,
                .data = data,
                .was_fragmented = false,
                .fragment_count = 1,
            };
        }

        // Start of fragmented message
        self.opcode = opcode;
        self.fragment_count = 1;
        try self.appendFragment(frame.payload);

        return null; // Need more fragments
    }

    fn appendFragment(self: *Self, data: []const u8) !void {
        // Check size limit
        if (self.fragments.items.len + data.len > self.config.max_message_size) {
            return error.MessageTooLarge;
        }

        try self.fragments.appendSlice(self.allocator, data);
        self.fragment_count += 1;
    }

    fn completeMessage(self: *Self) !Message {
        const opcode = self.opcode.?;
        const data = try self.fragments.toOwnedSlice(self.allocator);
        const fragment_count = self.fragment_count;

        // Reset state
        self.opcode = null;
        self.fragment_count = 0;

        return Message{
            .opcode = opcode,
            .data = data,
            .was_fragmented = true,
            .fragment_count = fragment_count,
        };
    }

    /// Free a message's data
    pub fn freeMessage(self: *Self, message: *const Message) void {
        if (message.data.len > 0) {
            self.allocator.free(message.data);
        }
    }

    /// Reset assembler state (e.g., on connection close)
    pub fn reset(self: *Self) void {
        self.fragments.clearRetainingCapacity();
        self.opcode = null;
        self.fragment_count = 0;
    }

    /// Check if currently assembling a fragmented message
    pub fn isAssembling(self: *const Self) bool {
        return self.opcode != null;
    }

    /// Get the current fragment count
    pub fn currentFragmentCount(self: *const Self) usize {
        return self.fragment_count;
    }
};

/// Message builder for creating outgoing messages
pub const MessageBuilder = struct {
    allocator: std.mem.Allocator,
    encoder: protocol.FrameEncoder,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .encoder = protocol.FrameEncoder.init(allocator),
        };
    }

    /// Create a text message frame
    pub fn text(self: *Self, data: []const u8) ![]u8 {
        return self.encoder.encodeText(data);
    }

    /// Create a binary message frame
    pub fn binary(self: *Self, data: []const u8) ![]u8 {
        return self.encoder.encodeBinary(data);
    }

    /// Create a close frame
    pub fn close(self: *Self, code: protocol.CloseCode, reason: []const u8) ![]u8 {
        return self.encoder.encodeClose(code, reason);
    }

    /// Create a ping frame
    pub fn ping(self: *Self, data: []const u8) ![]u8 {
        return self.encoder.encodePing(data);
    }

    /// Create a pong frame
    pub fn pong(self: *Self, data: []const u8) ![]u8 {
        return self.encoder.encodePong(data);
    }

    /// Create fragmented message frames
    pub fn fragmentedText(self: *Self, data: []const u8, fragment_size: usize) ![][]u8 {
        return self.fragmented(.text, data, fragment_size);
    }

    /// Create fragmented binary frames
    pub fn fragmentedBinary(self: *Self, data: []const u8, fragment_size: usize) ![][]u8 {
        return self.fragmented(.binary, data, fragment_size);
    }

    fn fragmented(self: *Self, opcode: protocol.Opcode, data: []const u8, fragment_size: usize) ![][]u8 {
        if (data.len == 0 or fragment_size == 0) {
            return error.InvalidInput;
        }

        const num_fragments = (data.len + fragment_size - 1) / fragment_size;
        const frames = try self.allocator.alloc([]u8, num_fragments);
        errdefer {
            for (frames) |frame| {
                self.allocator.free(frame);
            }
            self.allocator.free(frames);
        }

        var offset: usize = 0;
        for (frames, 0..) |*frame, i| {
            const chunk_end = @min(offset + fragment_size, data.len);
            const chunk = data[offset..chunk_end];

            const is_first = (i == 0);
            const is_last = (i == num_fragments - 1);
            const frame_opcode = if (is_first) opcode else .continuation;

            frame.* = try self.encoder.encode(frame_opcode, chunk, is_last);
            offset = chunk_end;
        }

        return frames;
    }

    /// Free a fragmented message's frames
    pub fn freeFragmented(self: *Self, frames: [][]u8) void {
        for (frames) |frame| {
            self.allocator.free(frame);
        }
        self.allocator.free(frames);
    }

    /// Free a single frame
    pub fn free(self: *Self, frame: []u8) void {
        self.encoder.free(frame);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MessageAssembler single frame message" {
    const allocator = std.testing.allocator;

    var assembler = MessageAssembler.init(allocator, .{});
    defer assembler.deinit();

    const frame = protocol.Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .text,
            .masked = false,
            .payload_len = 5,
            .mask_key = null,
        },
        .payload = "Hello",
    };

    const message = try assembler.processFrame(&frame);
    try std.testing.expect(message != null);

    if (message) |m| {
        defer assembler.freeMessage(&m);
        try std.testing.expectEqualStrings("Hello", m.data);
        try std.testing.expect(!m.was_fragmented);
        try std.testing.expectEqual(@as(usize, 1), m.fragment_count);
    }
}

test "MessageAssembler fragmented message" {
    const allocator = std.testing.allocator;

    var assembler = MessageAssembler.init(allocator, .{});
    defer assembler.deinit();

    // First fragment
    const frame1 = protocol.Frame{
        .header = .{
            .fin = false,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .text,
            .masked = false,
            .payload_len = 5,
            .mask_key = null,
        },
        .payload = "Hello",
    };

    const result1 = try assembler.processFrame(&frame1);
    try std.testing.expect(result1 == null);
    try std.testing.expect(assembler.isAssembling());

    // Continuation fragment
    const frame2 = protocol.Frame{
        .header = .{
            .fin = false,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .continuation,
            .masked = false,
            .payload_len = 1,
            .mask_key = null,
        },
        .payload = " ",
    };

    const result2 = try assembler.processFrame(&frame2);
    try std.testing.expect(result2 == null);

    // Final fragment
    const frame3 = protocol.Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .continuation,
            .masked = false,
            .payload_len = 5,
            .mask_key = null,
        },
        .payload = "World",
    };

    const message = try assembler.processFrame(&frame3);
    try std.testing.expect(message != null);

    if (message) |m| {
        defer assembler.freeMessage(&m);
        try std.testing.expectEqualStrings("Hello World", m.data);
        try std.testing.expect(m.was_fragmented);
        try std.testing.expectEqual(@as(usize, 4), m.fragment_count); // includes the 2 additional fragments after start
    }
}

test "MessageAssembler rejects unexpected continuation" {
    const allocator = std.testing.allocator;

    var assembler = MessageAssembler.init(allocator, .{});
    defer assembler.deinit();

    const frame = protocol.Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .continuation, // No previous fragment
            .masked = false,
            .payload_len = 5,
            .mask_key = null,
        },
        .payload = "Hello",
    };

    try std.testing.expectError(error.UnexpectedContinuation, assembler.processFrame(&frame));
}

test "MessageBuilder text message" {
    const allocator = std.testing.allocator;

    var builder = MessageBuilder.init(allocator);

    const frame = try builder.text("Hello, World!");
    defer builder.free(frame);

    try std.testing.expect(frame.len > 0);
    try std.testing.expectEqual(@as(u8, 0x81), frame[0]); // FIN=1, text opcode
}

test "MessageBuilder fragmented message" {
    const allocator = std.testing.allocator;

    var builder = MessageBuilder.init(allocator);

    const frames = try builder.fragmentedText("Hello World", 5);
    defer builder.freeFragmented(frames);

    try std.testing.expectEqual(@as(usize, 3), frames.len);

    // First frame: text opcode, FIN=0
    try std.testing.expectEqual(@as(u8, 0x01), frames[0][0]); // FIN=0, text

    // Middle frame: continuation, FIN=0
    try std.testing.expectEqual(@as(u8, 0x00), frames[1][0]); // FIN=0, continuation

    // Last frame: continuation, FIN=1
    try std.testing.expectEqual(@as(u8, 0x80), frames[2][0]); // FIN=1, continuation
}

test "Message type checks" {
    const text_msg = Message{
        .opcode = .text,
        .data = "Hello",
        .was_fragmented = false,
        .fragment_count = 1,
    };

    const binary_msg = Message{
        .opcode = .binary,
        .data = &[_]u8{ 0x01, 0x02, 0x03 },
        .was_fragmented = false,
        .fragment_count = 1,
    };

    try std.testing.expect(text_msg.isText());
    try std.testing.expect(!text_msg.isBinary());

    try std.testing.expect(!binary_msg.isText());
    try std.testing.expect(binary_msg.isBinary());
}
