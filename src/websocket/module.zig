// Native WebSocket implementation for Engine12
// RFC 6455 compliant WebSocket protocol implementation
//
// This module provides a complete, production-ready WebSocket implementation
// that can be used standalone or as part of the Engine12 framework.
//
// Features:
// - Full RFC 6455 compliance
// - Fragmented message support
// - Security hardening (rate limiting, input validation, DoS protection)
// - Connection health monitoring (ping/pong)
// - Cross-platform support (Linux, macOS, Windows)
// - Thread-safe connection management
// - Builder pattern API for easy configuration

const std = @import("std");

// Core modules
pub const connection = @import("connection.zig");
pub const handler = @import("handler.zig");
pub const manager = @import("manager.zig");
pub const room = @import("room.zig");
pub const protocol = @import("protocol.zig");
pub const handshake = @import("handshake.zig");
pub const server = @import("server.zig");

// Enhanced modules
pub const security = @import("security.zig");
pub const message = @import("message.zig");
pub const client_api = @import("client_api.zig");
pub const health = @import("health.zig");

// ============================================================================
// Main public types (Engine12 integration)
// ============================================================================

pub const WebSocketConnection = connection.WebSocketConnection;
pub const WebSocketHandler = handler.WebSocketHandler;
pub const WebSocketManager = manager.WebSocketManager;
pub const WebSocketRoom = room.WebSocketRoom;
pub const WebSocketServerEntry = manager.WebSocketServerEntry;

// ============================================================================
// Protocol types
// ============================================================================

pub const Opcode = protocol.Opcode;
pub const CloseCode = protocol.CloseCode;
pub const Frame = protocol.Frame;
pub const FrameHeader = protocol.FrameHeader;
pub const FrameParser = protocol.FrameParser;
pub const FrameEncoder = protocol.FrameEncoder;

// ============================================================================
// Server types
// ============================================================================

pub const Server = server.Server;
pub const ServerConfig = server.ServerConfig;
pub const Client = server.Client;
pub const Callbacks = server.Callbacks;

// ============================================================================
// Connection utilities
// ============================================================================

pub const ThreadSafeContext = connection.ThreadSafeContext;
pub const MessageQueue = connection.MessageQueue;

// ============================================================================
// Handshake utilities
// ============================================================================

pub const HandshakeRequest = handshake.HandshakeRequest;
pub const HandshakeError = handshake.HandshakeError;
pub const parseHandshakeRequest = handshake.parseHandshakeRequest;
pub const validateHandshake = handshake.validateHandshake;
pub const generateAcceptKey = handshake.generateAcceptKey;
pub const generateHandshakeResponse = handshake.generateHandshakeResponse;

// ============================================================================
// Security types
// ============================================================================

pub const SecurityConfig = security.SecurityConfig;
pub const RateLimiter = security.RateLimiter;
pub const FrameValidator = security.FrameValidator;
pub const ValidationError = security.ValidationError;
pub const validateOrigin = security.validateOrigin;

// ============================================================================
// Message types
// ============================================================================

pub const Message = message.Message;
pub const MessageAssembler = message.MessageAssembler;
pub const MessageBuilder = message.MessageBuilder;

// ============================================================================
// Client API (standalone usage)
// ============================================================================

pub const WebSocketClient = client_api.WebSocketClient;
pub const ClientBuilder = client_api.ClientBuilder;
pub const ClientConfig = client_api.WebSocketClient.ClientConfig;
pub const ClientState = client_api.WebSocketClient.State;

// ============================================================================
// Health monitoring
// ============================================================================

pub const HealthStatus = health.HealthStatus;
pub const HealthMetrics = health.HealthMetrics;
pub const HealthConfig = health.HealthConfig;
pub const HealthMonitor = health.HealthMonitor;
pub const PoolHealthAggregator = health.PoolHealthAggregator;

// ============================================================================
// Convenience functions for standalone usage
// ============================================================================

/// Create a new WebSocket client builder
pub fn client(allocator: std.mem.Allocator) ClientBuilder {
    return ClientBuilder.init(allocator);
}

/// Create a new WebSocket server with default configuration
pub fn createServer(allocator: std.mem.Allocator, config: ServerConfig, callbacks: Callbacks) Server {
    return Server.init(allocator, config, callbacks);
}

/// Create a message builder for encoding frames
pub fn messageBuilder(allocator: std.mem.Allocator) MessageBuilder {
    return MessageBuilder.init(allocator);
}

/// Create a frame parser for decoding frames
pub fn frameParser(allocator: std.mem.Allocator, max_size: usize) FrameParser {
    return FrameParser.init(allocator, max_size);
}

/// Create a health monitor for connection monitoring
pub fn healthMonitor(allocator: std.mem.Allocator, config: HealthConfig) HealthMonitor {
    return HealthMonitor.init(allocator, config);
}

// ============================================================================
// Tests - run with `zig build test`
// ============================================================================

test {
    // Reference all test declarations
    std.testing.refAllDecls(@This());

    // Explicitly import test modules
    _ = @import("protocol.zig");
    _ = @import("handshake.zig");
    _ = @import("security.zig");
    _ = @import("message.zig");
    _ = @import("client_api.zig");
    _ = @import("health.zig");
    _ = @import("connection.zig");
    _ = @import("server.zig");
    _ = @import("manager.zig");
    _ = @import("room.zig");
}
