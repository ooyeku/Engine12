const std = @import("std");
const protocol = @import("protocol.zig");

/// Security configuration for WebSocket connections
pub const SecurityConfig = struct {
    /// Maximum payload size per frame (default: 16MB)
    max_frame_size: usize = 16 * 1024 * 1024,

    /// Maximum total message size for fragmented messages (default: 64MB)
    max_message_size: usize = 64 * 1024 * 1024,

    /// Maximum number of queued frames before backpressure (default: 1000)
    max_queued_frames: usize = 1000,

    /// Rate limit: max frames per second (0 = unlimited)
    max_frames_per_second: u32 = 0,

    /// Rate limit: max bytes per second (0 = unlimited)
    max_bytes_per_second: u64 = 0,

    /// Require client frames to be masked (RFC 6455 compliance)
    require_masking: bool = true,

    /// Maximum time to wait for handshake completion (ms)
    handshake_timeout_ms: u32 = 5000,

    /// Maximum time between frames before considering connection dead (ms)
    idle_timeout_ms: u32 = 60000,

    /// Ping interval for connection health checks (ms, 0 = disabled)
    ping_interval_ms: u32 = 30000,

    /// Maximum consecutive ping failures before disconnect
    max_ping_failures: u8 = 3,

    /// Allowed origins for CORS (null = allow all)
    allowed_origins: ?[]const []const u8 = null,

    /// Maximum header size during handshake
    max_header_size: usize = 8192,

    /// Validate UTF-8 in text frames
    validate_utf8: bool = true,
};

/// Rate limiter for connection-level throttling
pub const RateLimiter = struct {
    config: SecurityConfig,
    frame_count: u64,
    byte_count: u64,
    last_reset: i64,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(config: SecurityConfig) Self {
        return Self{
            .config = config,
            .frame_count = 0,
            .byte_count = 0,
            .last_reset = std.time.milliTimestamp(),
            .mutex = .{},
        };
    }

    /// Check if a frame of the given size is allowed
    /// Returns true if allowed, false if rate limited
    pub fn allowFrame(self: *Self, size: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        const elapsed = now - self.last_reset;

        // Reset counters every second
        if (elapsed >= 1000) {
            self.frame_count = 0;
            self.byte_count = 0;
            self.last_reset = now;
        }

        // Check frame rate limit
        if (self.config.max_frames_per_second > 0) {
            if (self.frame_count >= self.config.max_frames_per_second) {
                return false;
            }
        }

        // Check byte rate limit
        if (self.config.max_bytes_per_second > 0) {
            if (self.byte_count + size > self.config.max_bytes_per_second) {
                return false;
            }
        }

        self.frame_count += 1;
        self.byte_count += size;
        return true;
    }

    /// Reset rate limiter state
    pub fn reset(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.frame_count = 0;
        self.byte_count = 0;
        self.last_reset = std.time.milliTimestamp();
    }
};

/// Validates WebSocket frames for security and protocol compliance
pub const FrameValidator = struct {
    config: SecurityConfig,
    fragmented_opcode: ?protocol.Opcode,
    fragmented_size: usize,

    const Self = @This();

    pub fn init(config: SecurityConfig) Self {
        return Self{
            .config = config,
            .fragmented_opcode = null,
            .fragmented_size = 0,
        };
    }

    /// Validate a frame for security and protocol compliance
    pub fn validate(self: *Self, frame: *const protocol.Frame) ValidationError!void {
        // Check masking requirement
        if (self.config.require_masking and !frame.header.masked) {
            return ValidationError.UnmaskedClientFrame;
        }

        // Check frame size
        if (frame.header.payload_len > self.config.max_frame_size) {
            return ValidationError.FrameTooLarge;
        }

        // Validate control frames
        if (frame.header.opcode.isControl()) {
            try self.validateControlFrame(frame);
        } else {
            try self.validateDataFrame(frame);
        }

        // Validate UTF-8 for text frames
        if (self.config.validate_utf8 and frame.header.opcode == .text) {
            if (!std.unicode.utf8ValidateSlice(frame.payload)) {
                return ValidationError.InvalidUtf8;
            }
        }

        // Validate close frame payload
        if (frame.header.opcode == .close) {
            try self.validateClosePayload(frame.payload);
        }
    }

    fn validateControlFrame(self: *Self, frame: *const protocol.Frame) ValidationError!void {
        _ = self;

        // Control frames must not be fragmented
        if (!frame.header.fin) {
            return ValidationError.FragmentedControlFrame;
        }

        // Control frames must have payload <= 125 bytes
        if (frame.header.payload_len > 125) {
            return ValidationError.ControlFrameTooLarge;
        }
    }

    fn validateDataFrame(self: *Self, frame: *const protocol.Frame) ValidationError!void {
        const opcode = frame.header.opcode;

        if (opcode == .continuation) {
            // Continuation must have a previous fragmented frame
            if (self.fragmented_opcode == null) {
                return ValidationError.UnexpectedContinuation;
            }
        } else {
            // New data frame while fragmented message in progress
            if (self.fragmented_opcode != null) {
                return ValidationError.NewFrameDuringFragmentation;
            }
        }

        // Track fragmentation state
        if (!frame.header.fin) {
            if (opcode != .continuation) {
                self.fragmented_opcode = opcode;
                self.fragmented_size = @intCast(frame.header.payload_len);
            } else {
                self.fragmented_size += @intCast(frame.header.payload_len);
            }
        } else {
            if (opcode == .continuation) {
                self.fragmented_size += @intCast(frame.header.payload_len);
            }

            // Check total message size
            const total_size = if (self.fragmented_opcode != null)
                self.fragmented_size
            else
                @as(usize, @intCast(frame.header.payload_len));

            if (total_size > self.config.max_message_size) {
                return ValidationError.MessageTooLarge;
            }

            // Reset fragmentation state
            self.fragmented_opcode = null;
            self.fragmented_size = 0;
        }
    }

    fn validateClosePayload(self: *Self, payload: []const u8) ValidationError!void {
        _ = self;

        if (payload.len == 0) {
            return; // Empty close is valid
        }

        if (payload.len == 1) {
            return ValidationError.InvalidClosePayload;
        }

        // Validate close code
        const code = (@as(u16, payload[0]) << 8) | @as(u16, payload[1]);

        // Check for reserved/invalid codes
        if (code < 1000) {
            return ValidationError.InvalidCloseCode;
        }

        // 1004, 1005, 1006, 1015 are reserved and must not be sent
        if (code == 1004 or code == 1005 or code == 1006 or code == 1015) {
            return ValidationError.ReservedCloseCode;
        }

        // 1016-2999 are reserved for future use
        if (code >= 1016 and code < 3000) {
            return ValidationError.ReservedCloseCode;
        }

        // Validate close reason is valid UTF-8
        if (payload.len > 2) {
            if (!std.unicode.utf8ValidateSlice(payload[2..])) {
                return ValidationError.InvalidUtf8;
            }
        }
    }

    /// Reset fragmentation state
    pub fn reset(self: *Self) void {
        self.fragmented_opcode = null;
        self.fragmented_size = 0;
    }
};

pub const ValidationError = error{
    UnmaskedClientFrame,
    FrameTooLarge,
    MessageTooLarge,
    FragmentedControlFrame,
    ControlFrameTooLarge,
    InvalidUtf8,
    InvalidClosePayload,
    InvalidCloseCode,
    ReservedCloseCode,
    UnexpectedContinuation,
    NewFrameDuringFragmentation,
};

/// Origin validation for CORS
pub fn validateOrigin(origin: ?[]const u8, allowed_origins: ?[]const []const u8) bool {
    // If no origins configured, allow all
    if (allowed_origins == null) {
        return true;
    }

    const origins = allowed_origins.?;

    // Check for wildcard first - allows all origins including null
    for (origins) |allowed| {
        if (std.mem.eql(u8, allowed, "*")) {
            return true;
        }
    }

    // If origin header missing and no wildcard, reject
    if (origin == null) {
        return false;
    }

    const client_origin = origin.?;

    for (origins) |allowed| {
        if (std.mem.eql(u8, allowed, client_origin)) {
            return true;
        }
    }

    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "RateLimiter allows frames within limit" {
    var limiter = RateLimiter.init(.{
        .max_frames_per_second = 10,
        .max_bytes_per_second = 1024,
    });

    // Should allow first frame
    try std.testing.expect(limiter.allowFrame(100));
    try std.testing.expect(limiter.allowFrame(100));
}

test "RateLimiter blocks frames over limit" {
    var limiter = RateLimiter.init(.{
        .max_frames_per_second = 2,
        .max_bytes_per_second = 0,
    });

    try std.testing.expect(limiter.allowFrame(10));
    try std.testing.expect(limiter.allowFrame(10));
    try std.testing.expect(!limiter.allowFrame(10)); // Should be blocked
}

test "RateLimiter blocks bytes over limit" {
    var limiter = RateLimiter.init(.{
        .max_frames_per_second = 0,
        .max_bytes_per_second = 100,
    });

    try std.testing.expect(limiter.allowFrame(50));
    try std.testing.expect(limiter.allowFrame(50));
    try std.testing.expect(!limiter.allowFrame(10)); // Would exceed 100 bytes
}

test "FrameValidator rejects unmasked client frames" {
    var validator = FrameValidator.init(.{
        .require_masking = true,
    });

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

    try std.testing.expectError(ValidationError.UnmaskedClientFrame, validator.validate(&frame));
}

test "FrameValidator accepts masked frames" {
    var validator = FrameValidator.init(.{
        .require_masking = true,
        .validate_utf8 = true,
    });

    const frame = protocol.Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .text,
            .masked = true,
            .payload_len = 5,
            .mask_key = [_]u8{ 0, 0, 0, 0 },
        },
        .payload = "Hello",
    };

    try validator.validate(&frame);
}

test "FrameValidator rejects invalid UTF-8" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
        .validate_utf8 = true,
    });

    const frame = protocol.Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .text,
            .masked = false,
            .payload_len = 3,
            .mask_key = null,
        },
        .payload = &[_]u8{ 0xFF, 0xFE, 0x00 }, // Invalid UTF-8
    };

    try std.testing.expectError(ValidationError.InvalidUtf8, validator.validate(&frame));
}

test "FrameValidator rejects fragmented control frames" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
    });

    const frame = protocol.Frame{
        .header = .{
            .fin = false, // Fragmented
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

    try std.testing.expectError(ValidationError.FragmentedControlFrame, validator.validate(&frame));
}

test "FrameValidator rejects reserved close codes" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
    });

    // Close code 1005 is reserved
    const frame = protocol.Frame{
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
        .payload = &[_]u8{ 0x03, 0xED }, // 1005
    };

    try std.testing.expectError(ValidationError.ReservedCloseCode, validator.validate(&frame));
}

test "validateOrigin allows configured origins" {
    const allowed = [_][]const u8{ "http://localhost:8080", "https://example.com" };

    try std.testing.expect(validateOrigin("http://localhost:8080", &allowed));
    try std.testing.expect(validateOrigin("https://example.com", &allowed));
    try std.testing.expect(!validateOrigin("https://evil.com", &allowed));
}

test "validateOrigin allows wildcard" {
    const allowed = [_][]const u8{"*"};

    try std.testing.expect(validateOrigin("http://anything.com", &allowed));
    try std.testing.expect(validateOrigin(null, &allowed));
}

test "validateOrigin allows all when not configured" {
    try std.testing.expect(validateOrigin("http://anything.com", null));
    try std.testing.expect(validateOrigin(null, null));
}

// ============================================================================
// Additional comprehensive tests
// ============================================================================

test "SecurityConfig default values" {
    const config = SecurityConfig{};

    try std.testing.expectEqual(@as(usize, 16 * 1024 * 1024), config.max_frame_size);
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), config.max_message_size);
    try std.testing.expectEqual(@as(usize, 1000), config.max_queued_frames);
    try std.testing.expectEqual(@as(u32, 0), config.max_frames_per_second);
    try std.testing.expectEqual(@as(u64, 0), config.max_bytes_per_second);
    try std.testing.expect(config.require_masking);
    try std.testing.expectEqual(@as(u32, 5000), config.handshake_timeout_ms);
    try std.testing.expectEqual(@as(u32, 60000), config.idle_timeout_ms);
    try std.testing.expectEqual(@as(u32, 30000), config.ping_interval_ms);
    try std.testing.expectEqual(@as(u8, 3), config.max_ping_failures);
    try std.testing.expect(config.allowed_origins == null);
    try std.testing.expectEqual(@as(usize, 8192), config.max_header_size);
    try std.testing.expect(config.validate_utf8);
}

test "RateLimiter allows unlimited when limits are 0" {
    var limiter = RateLimiter.init(.{
        .max_frames_per_second = 0,
        .max_bytes_per_second = 0,
    });

    // Should allow any amount
    for (0..100) |_| {
        try std.testing.expect(limiter.allowFrame(10000));
    }
}

test "RateLimiter reset clears counters" {
    var limiter = RateLimiter.init(.{
        .max_frames_per_second = 2,
        .max_bytes_per_second = 100,
    });

    try std.testing.expect(limiter.allowFrame(50));
    try std.testing.expect(limiter.allowFrame(50));
    try std.testing.expect(!limiter.allowFrame(50)); // Blocked by byte limit

    limiter.reset();

    // After reset, should allow again
    try std.testing.expect(limiter.allowFrame(50));
}

test "RateLimiter tracks both frame count and byte count" {
    var limiter = RateLimiter.init(.{
        .max_frames_per_second = 100,
        .max_bytes_per_second = 50,
    });

    // Should be blocked by byte limit, not frame limit
    try std.testing.expect(limiter.allowFrame(25));
    try std.testing.expect(limiter.allowFrame(25));
    try std.testing.expect(!limiter.allowFrame(1)); // Would exceed 50 bytes
}

test "FrameValidator allows unmasked frames when not required" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
    });

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

    try validator.validate(&frame);
}

test "FrameValidator rejects frame exceeding max size" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
        .max_frame_size = 100,
    });

    const frame = protocol.Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .text,
            .masked = false,
            .payload_len = 200,
            .mask_key = null,
        },
        .payload = "",
    };

    try std.testing.expectError(ValidationError.FrameTooLarge, validator.validate(&frame));
}

test "FrameValidator rejects control frame larger than 125 bytes" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
    });

    const frame = protocol.Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .ping,
            .masked = false,
            .payload_len = 126,
            .mask_key = null,
        },
        .payload = "",
    };

    try std.testing.expectError(ValidationError.ControlFrameTooLarge, validator.validate(&frame));
}

test "FrameValidator accepts control frame with 125 bytes" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
    });

    const frame = protocol.Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .pong,
            .masked = false,
            .payload_len = 125,
            .mask_key = null,
        },
        .payload = "",
    };

    try validator.validate(&frame);
}

test "FrameValidator tracks fragmentation state" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
    });

    // Start fragmented message
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
    try validator.validate(&frame1);

    // Continue with continuation
    const frame2 = protocol.Frame{
        .header = .{
            .fin = false,
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
    try validator.validate(&frame2);

    // Finish fragmented message
    const frame3 = protocol.Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .continuation,
            .masked = false,
            .payload_len = 1,
            .mask_key = null,
        },
        .payload = "!",
    };
    try validator.validate(&frame3);
}

test "FrameValidator rejects unexpected continuation" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
    });

    // Continuation without prior fragment
    const frame = protocol.Frame{
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
        .payload = "Hello",
    };

    try std.testing.expectError(ValidationError.UnexpectedContinuation, validator.validate(&frame));
}

test "FrameValidator rejects new data frame during fragmentation" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
    });

    // Start fragmented message
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
    try validator.validate(&frame1);

    // Try to start a new message (should fail)
    const frame2 = protocol.Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .binary,
            .masked = false,
            .payload_len = 5,
            .mask_key = null,
        },
        .payload = "World",
    };

    try std.testing.expectError(ValidationError.NewFrameDuringFragmentation, validator.validate(&frame2));
}

test "FrameValidator validates close codes" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
    });

    // Valid close code 1000
    const valid_frame = protocol.Frame{
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
        .payload = &[_]u8{ 0x03, 0xE8 }, // 1000
    };
    try validator.validate(&valid_frame);
}

test "FrameValidator rejects close code below 1000" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
    });

    const frame = protocol.Frame{
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
        .payload = &[_]u8{ 0x00, 0x64 }, // 100
    };

    try std.testing.expectError(ValidationError.InvalidCloseCode, validator.validate(&frame));
}

test "FrameValidator rejects single byte close payload" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
    });

    const frame = protocol.Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .close,
            .masked = false,
            .payload_len = 1,
            .mask_key = null,
        },
        .payload = &[_]u8{0x03},
    };

    try std.testing.expectError(ValidationError.InvalidClosePayload, validator.validate(&frame));
}

test "FrameValidator allows empty close payload" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
    });

    const frame = protocol.Frame{
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

    try validator.validate(&frame);
}

test "FrameValidator rejects close with invalid UTF-8 reason" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
    });

    const frame = protocol.Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .close,
            .masked = false,
            .payload_len = 5,
            .mask_key = null,
        },
        .payload = &[_]u8{ 0x03, 0xE8, 0xFF, 0xFE, 0x00 }, // 1000 + invalid UTF-8
    };

    try std.testing.expectError(ValidationError.InvalidUtf8, validator.validate(&frame));
}

test "FrameValidator reset clears fragmentation state" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
    });

    // Start fragmented message
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
    try validator.validate(&frame1);

    // Reset
    validator.reset();

    // Should now accept a new text frame
    const frame2 = protocol.Frame{
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
        .payload = "World",
    };
    try validator.validate(&frame2);
}

test "FrameValidator allows valid UTF-8 text frames" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
        .validate_utf8 = true,
    });

    const frame = protocol.Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .text,
            .masked = false,
            .payload_len = 12,
            .mask_key = null,
        },
        .payload = "Hello, 世界!",
    };

    try validator.validate(&frame);
}

test "FrameValidator skips UTF-8 validation when disabled" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
        .validate_utf8 = false,
    });

    const frame = protocol.Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .text,
            .masked = false,
            .payload_len = 3,
            .mask_key = null,
        },
        .payload = &[_]u8{ 0xFF, 0xFE, 0x00 }, // Invalid UTF-8
    };

    try validator.validate(&frame);
}

test "FrameValidator rejects reserved close codes 1016-2999" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
    });

    const frame = protocol.Frame{
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
        .payload = &[_]u8{ 0x07, 0xD0 }, // 2000
    };

    try std.testing.expectError(ValidationError.ReservedCloseCode, validator.validate(&frame));
}

test "validateOrigin rejects non-matching origins" {
    const allowed = [_][]const u8{ "http://example.com", "https://example.org" };

    try std.testing.expect(!validateOrigin("http://evil.com", &allowed));
    try std.testing.expect(!validateOrigin("https://example.net", &allowed));
}

test "validateOrigin with empty allowed list" {
    const allowed = [_][]const u8{};

    try std.testing.expect(!validateOrigin("http://anything.com", &allowed));
}

test "validateOrigin exact match required" {
    const allowed = [_][]const u8{"http://example.com"};

    try std.testing.expect(validateOrigin("http://example.com", &allowed));
    try std.testing.expect(!validateOrigin("http://example.com:8080", &allowed));
    try std.testing.expect(!validateOrigin("https://example.com", &allowed));
    try std.testing.expect(!validateOrigin("http://www.example.com", &allowed));
}

test "FrameValidator message size limit across fragments" {
    var validator = FrameValidator.init(.{
        .require_masking = false,
        .max_message_size = 10,
    });

    // First fragment (5 bytes)
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
    try validator.validate(&frame1);

    // Second fragment (6 bytes - would exceed 10 byte limit)
    const frame2 = protocol.Frame{
        .header = .{
            .fin = true,
            .rsv1 = false,
            .rsv2 = false,
            .rsv3 = false,
            .opcode = .continuation,
            .masked = false,
            .payload_len = 6,
            .mask_key = null,
        },
        .payload = " World",
    };

    try std.testing.expectError(ValidationError.MessageTooLarge, validator.validate(&frame2));
}
