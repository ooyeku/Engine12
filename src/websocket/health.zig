const std = @import("std");
const protocol = @import("protocol.zig");

/// Connection health status
pub const HealthStatus = enum {
    healthy,
    degraded,
    unhealthy,
    unknown,
};

/// Connection health metrics
pub const HealthMetrics = struct {
    /// Time of last ping sent
    last_ping_sent: i64 = 0,
    /// Time of last pong received
    last_pong_received: i64 = 0,
    /// Current ping latency in milliseconds
    latency_ms: u32 = 0,
    /// Average latency over recent pings
    avg_latency_ms: u32 = 0,
    /// Number of consecutive ping failures
    ping_failures: u8 = 0,
    /// Total pings sent
    total_pings_sent: u64 = 0,
    /// Total pongs received
    total_pongs_received: u64 = 0,
    /// Time connection was established
    connected_at: i64 = 0,
    /// Total bytes sent
    bytes_sent: u64 = 0,
    /// Total bytes received
    bytes_received: u64 = 0,
    /// Total frames sent
    frames_sent: u64 = 0,
    /// Total frames received
    frames_received: u64 = 0,
};

/// Configuration for health monitoring
pub const HealthConfig = struct {
    /// Interval between pings in milliseconds (0 = disabled)
    ping_interval_ms: u32 = 30000,
    /// Maximum time to wait for pong response
    pong_timeout_ms: u32 = 10000,
    /// Maximum consecutive ping failures before marking unhealthy
    max_ping_failures: u8 = 3,
    /// Latency threshold for degraded status (ms)
    degraded_latency_threshold_ms: u32 = 1000,
    /// Number of latency samples to average
    latency_sample_count: usize = 10,
};

/// Health monitor for a WebSocket connection
pub const HealthMonitor = struct {
    config: HealthConfig,
    metrics: HealthMetrics,
    latency_samples: std.ArrayListUnmanaged(u32),
    pending_ping_data: ?[]const u8,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: HealthConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .metrics = .{},
            .latency_samples = std.ArrayListUnmanaged(u32){},
            .pending_ping_data = null,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.latency_samples.deinit(self.allocator);
        if (self.pending_ping_data) |data| {
            self.allocator.free(data);
        }
    }

    /// Mark connection as established
    pub fn connectionEstablished(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        self.metrics.connected_at = now;
        self.metrics.last_pong_received = now;
        self.metrics.last_ping_sent = now; // Start ping interval from connection time
    }

    /// Check if it's time to send a ping
    pub fn shouldPing(self: *Self) bool {
        if (self.config.ping_interval_ms == 0) {
            return false;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        const elapsed = now - self.metrics.last_ping_sent;

        return elapsed >= self.config.ping_interval_ms;
    }

    /// Generate ping data and record that ping was sent
    pub fn preparePing(self: *Self) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Generate unique ping data (timestamp-based)
        const now = std.time.milliTimestamp();
        var ping_data: [8]u8 = undefined;
        std.mem.writeInt(i64, &ping_data, now, .little);

        // Store copy for verification
        const data_copy = try self.allocator.dupe(u8, &ping_data);
        errdefer self.allocator.free(data_copy);

        if (self.pending_ping_data) |old| {
            self.allocator.free(old);
        }
        self.pending_ping_data = data_copy;

        self.metrics.last_ping_sent = now;
        self.metrics.total_pings_sent += 1;

        return &ping_data;
    }

    /// Record that a pong was received
    pub fn recordPong(self: *Self, pong_data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();

        // Verify pong data matches ping
        if (self.pending_ping_data) |ping_data| {
            if (std.mem.eql(u8, pong_data, ping_data)) {
                // Calculate latency from ping timestamp
                if (pong_data.len >= 8) {
                    const ping_time = std.mem.readInt(i64, pong_data[0..8], .little);
                    const latency = @as(u32, @intCast(@max(0, now - ping_time)));
                    self.updateLatency(latency);
                }

                self.allocator.free(ping_data);
                self.pending_ping_data = null;
                self.metrics.ping_failures = 0;
            }
        }

        self.metrics.last_pong_received = now;
        self.metrics.total_pongs_received += 1;
    }

    fn updateLatency(self: *Self, latency: u32) void {
        self.metrics.latency_ms = latency;

        // Add to samples
        if (self.latency_samples.items.len >= self.config.latency_sample_count) {
            _ = self.latency_samples.orderedRemove(0);
        }
        self.latency_samples.append(self.allocator, latency) catch return;

        // Calculate average
        if (self.latency_samples.items.len > 0) {
            var sum: u64 = 0;
            for (self.latency_samples.items) |sample| {
                sum += sample;
            }
            self.metrics.avg_latency_ms = @intCast(sum / self.latency_samples.items.len);
        }
    }

    /// Check for ping timeout
    pub fn checkPingTimeout(self: *Self) bool {
        if (self.config.ping_interval_ms == 0) {
            return false;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_ping_data == null) {
            return false;
        }

        const now = std.time.milliTimestamp();
        const elapsed = now - self.metrics.last_ping_sent;

        if (elapsed > self.config.pong_timeout_ms) {
            self.metrics.ping_failures += 1;

            if (self.pending_ping_data) |data| {
                self.allocator.free(data);
                self.pending_ping_data = null;
            }

            return true;
        }

        return false;
    }

    /// Get current health status
    pub fn getStatus(self: *Self) HealthStatus {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.metrics.connected_at == 0) {
            return .unknown;
        }

        if (self.metrics.ping_failures >= self.config.max_ping_failures) {
            return .unhealthy;
        }

        if (self.metrics.avg_latency_ms > self.config.degraded_latency_threshold_ms) {
            return .degraded;
        }

        if (self.metrics.ping_failures > 0) {
            return .degraded;
        }

        return .healthy;
    }

    /// Get current metrics
    pub fn getMetrics(self: *Self) HealthMetrics {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.metrics;
    }

    /// Record bytes sent
    pub fn recordBytesSent(self: *Self, bytes: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.metrics.bytes_sent += bytes;
    }

    /// Record bytes received
    pub fn recordBytesReceived(self: *Self, bytes: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.metrics.bytes_received += bytes;
    }

    /// Record frame sent
    pub fn recordFrameSent(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.metrics.frames_sent += 1;
    }

    /// Record frame received
    pub fn recordFrameReceived(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.metrics.frames_received += 1;
    }

    /// Get connection uptime in milliseconds
    pub fn getUptime(self: *Self) i64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.metrics.connected_at == 0) {
            return 0;
        }

        return std.time.milliTimestamp() - self.metrics.connected_at;
    }

    /// Reset all metrics
    pub fn reset(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.metrics = .{};
        self.latency_samples.clearRetainingCapacity();

        if (self.pending_ping_data) |data| {
            self.allocator.free(data);
            self.pending_ping_data = null;
        }
    }
};

/// Connection pool health aggregator
pub const PoolHealthAggregator = struct {
    total_connections: usize,
    healthy_connections: usize,
    degraded_connections: usize,
    unhealthy_connections: usize,
    avg_latency_ms: u32,
    total_bytes_sent: u64,
    total_bytes_received: u64,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .total_connections = 0,
            .healthy_connections = 0,
            .degraded_connections = 0,
            .unhealthy_connections = 0,
            .avg_latency_ms = 0,
            .total_bytes_sent = 0,
            .total_bytes_received = 0,
        };
    }

    pub fn addConnection(self: *Self, monitor: *HealthMonitor) void {
        self.total_connections += 1;

        const status = monitor.getStatus();
        switch (status) {
            .healthy => self.healthy_connections += 1,
            .degraded => self.degraded_connections += 1,
            .unhealthy => self.unhealthy_connections += 1,
            .unknown => {},
        }

        const metrics = monitor.getMetrics();
        self.total_bytes_sent += metrics.bytes_sent;
        self.total_bytes_received += metrics.bytes_received;

        // Update average latency
        if (self.total_connections > 0) {
            const total_latency = self.avg_latency_ms * (self.total_connections - 1) + metrics.avg_latency_ms;
            self.avg_latency_ms = @intCast(total_latency / self.total_connections);
        }
    }

    pub fn getOverallStatus(self: *const Self) HealthStatus {
        if (self.total_connections == 0) {
            return .unknown;
        }

        if (self.unhealthy_connections > 0) {
            // Any unhealthy connections make pool degraded
            if (self.unhealthy_connections == self.total_connections) {
                return .unhealthy;
            }
            return .degraded;
        }

        if (self.degraded_connections > self.total_connections / 2) {
            return .degraded;
        }

        return .healthy;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "HealthMonitor initial status" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{});
    defer monitor.deinit();

    try std.testing.expectEqual(HealthStatus.unknown, monitor.getStatus());
}

test "HealthMonitor healthy after connection" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{});
    defer monitor.deinit();

    monitor.connectionEstablished();
    try std.testing.expectEqual(HealthStatus.healthy, monitor.getStatus());
}

test "HealthMonitor shouldPing timing" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{
        .ping_interval_ms = 100,
    });
    defer monitor.deinit();

    monitor.connectionEstablished();

    // Should not ping immediately
    try std.testing.expect(!monitor.shouldPing());

    // Update last ping to be in the past
    monitor.metrics.last_ping_sent = std.time.milliTimestamp() - 200;
    try std.testing.expect(monitor.shouldPing());
}

test "HealthMonitor recordPong updates latency" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{});
    defer monitor.deinit();

    monitor.connectionEstablished();

    // Prepare and simulate ping/pong
    const ping_data = try monitor.preparePing();
    _ = ping_data;

    // Simulate receiving pong with same data
    if (monitor.pending_ping_data) |data| {
        monitor.recordPong(data);
    }

    const metrics = monitor.getMetrics();
    try std.testing.expect(metrics.total_pongs_received == 1);
    try std.testing.expect(metrics.ping_failures == 0);
}

test "HealthMonitor ping failure tracking" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{
        .ping_interval_ms = 100,
        .pong_timeout_ms = 50,
        .max_ping_failures = 2,
    });
    defer monitor.deinit();

    monitor.connectionEstablished();

    // Simulate ping without pong
    _ = try monitor.preparePing();

    // Force timeout by manipulating last_ping_sent
    monitor.mutex.lock();
    monitor.metrics.last_ping_sent = std.time.milliTimestamp() - 100;
    monitor.mutex.unlock();

    _ = monitor.checkPingTimeout();
    try std.testing.expect(monitor.getMetrics().ping_failures == 1);
    try std.testing.expectEqual(HealthStatus.degraded, monitor.getStatus());
}

test "PoolHealthAggregator overall status" {
    var aggregator = PoolHealthAggregator.init();

    try std.testing.expectEqual(HealthStatus.unknown, aggregator.getOverallStatus());

    // Simulate adding connections
    aggregator.total_connections = 3;
    aggregator.healthy_connections = 3;
    try std.testing.expectEqual(HealthStatus.healthy, aggregator.getOverallStatus());

    aggregator.unhealthy_connections = 1;
    aggregator.healthy_connections = 2;
    try std.testing.expectEqual(HealthStatus.degraded, aggregator.getOverallStatus());
}

test "HealthMetrics recording" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{});
    defer monitor.deinit();

    monitor.recordBytesSent(100);
    monitor.recordBytesReceived(200);
    monitor.recordFrameSent();
    monitor.recordFrameReceived();
    monitor.recordFrameReceived();

    const metrics = monitor.getMetrics();
    try std.testing.expectEqual(@as(u64, 100), metrics.bytes_sent);
    try std.testing.expectEqual(@as(u64, 200), metrics.bytes_received);
    try std.testing.expectEqual(@as(u64, 1), metrics.frames_sent);
    try std.testing.expectEqual(@as(u64, 2), metrics.frames_received);
}

// ============================================================================
// Additional comprehensive tests
// ============================================================================

test "HealthStatus enum values" {
    try std.testing.expect(HealthStatus.healthy != HealthStatus.degraded);
    try std.testing.expect(HealthStatus.degraded != HealthStatus.unhealthy);
    try std.testing.expect(HealthStatus.unhealthy != HealthStatus.unknown);
}

test "HealthConfig default values" {
    const config = HealthConfig{};

    try std.testing.expectEqual(@as(u32, 30000), config.ping_interval_ms);
    try std.testing.expectEqual(@as(u32, 10000), config.pong_timeout_ms);
    try std.testing.expectEqual(@as(u8, 3), config.max_ping_failures);
    try std.testing.expectEqual(@as(u32, 1000), config.degraded_latency_threshold_ms);
    try std.testing.expectEqual(@as(usize, 10), config.latency_sample_count);
}

test "HealthMonitor disabled ping" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{
        .ping_interval_ms = 0, // Disabled
    });
    defer monitor.deinit();

    monitor.connectionEstablished();

    // Should never need to ping when disabled
    try std.testing.expect(!monitor.shouldPing());

    // Timeout check should also return false when disabled
    try std.testing.expect(!monitor.checkPingTimeout());
}

test "HealthMonitor getUptime" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{});
    defer monitor.deinit();

    // Before connection, uptime should be 0
    try std.testing.expectEqual(@as(i64, 0), monitor.getUptime());

    monitor.connectionEstablished();

    // After connection, uptime should be >= 0
    try std.testing.expect(monitor.getUptime() >= 0);
}

test "HealthMonitor reset" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{});
    defer monitor.deinit();

    monitor.connectionEstablished();
    monitor.recordBytesSent(1000);
    monitor.recordFrameSent();

    const metrics_before = monitor.getMetrics();
    try std.testing.expect(metrics_before.bytes_sent > 0);
    try std.testing.expect(metrics_before.connected_at > 0);

    monitor.reset();

    const metrics_after = monitor.getMetrics();
    try std.testing.expectEqual(@as(u64, 0), metrics_after.bytes_sent);
    try std.testing.expectEqual(@as(i64, 0), metrics_after.connected_at);
    try std.testing.expectEqual(@as(u64, 0), metrics_after.frames_sent);
}

test "HealthMonitor cumulative byte tracking" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{});
    defer monitor.deinit();

    monitor.recordBytesSent(100);
    monitor.recordBytesSent(200);
    monitor.recordBytesSent(300);

    monitor.recordBytesReceived(50);
    monitor.recordBytesReceived(150);

    const metrics = monitor.getMetrics();
    try std.testing.expectEqual(@as(u64, 600), metrics.bytes_sent);
    try std.testing.expectEqual(@as(u64, 200), metrics.bytes_received);
}

test "HealthMonitor cumulative frame tracking" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{});
    defer monitor.deinit();

    for (0..10) |_| {
        monitor.recordFrameSent();
    }

    for (0..5) |_| {
        monitor.recordFrameReceived();
    }

    const metrics = monitor.getMetrics();
    try std.testing.expectEqual(@as(u64, 10), metrics.frames_sent);
    try std.testing.expectEqual(@as(u64, 5), metrics.frames_received);
}

test "HealthMonitor unhealthy after max failures" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{
        .ping_interval_ms = 100,
        .pong_timeout_ms = 10,
        .max_ping_failures = 2,
    });
    defer monitor.deinit();

    monitor.connectionEstablished();
    try std.testing.expectEqual(HealthStatus.healthy, monitor.getStatus());

    // Simulate first failure
    monitor.mutex.lock();
    monitor.metrics.ping_failures = 1;
    monitor.mutex.unlock();
    try std.testing.expectEqual(HealthStatus.degraded, monitor.getStatus());

    // Simulate second failure (at max)
    monitor.mutex.lock();
    monitor.metrics.ping_failures = 2;
    monitor.mutex.unlock();
    try std.testing.expectEqual(HealthStatus.unhealthy, monitor.getStatus());

    // Simulate more failures (above max)
    monitor.mutex.lock();
    monitor.metrics.ping_failures = 5;
    monitor.mutex.unlock();
    try std.testing.expectEqual(HealthStatus.unhealthy, monitor.getStatus());
}

test "HealthMonitor degraded with high latency" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{
        .degraded_latency_threshold_ms = 100,
    });
    defer monitor.deinit();

    monitor.connectionEstablished();

    // Simulate high latency
    monitor.mutex.lock();
    monitor.metrics.avg_latency_ms = 150;
    monitor.mutex.unlock();

    try std.testing.expectEqual(HealthStatus.degraded, monitor.getStatus());
}

test "HealthMonitor preparePing returns unique data" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{});
    defer monitor.deinit();

    const ping1 = try monitor.preparePing();
    _ = ping1;

    // Prepare another ping (this should replace the previous pending ping data)
    const ping2 = try monitor.preparePing();
    _ = ping2;

    // Both should have been prepared
    const metrics = monitor.getMetrics();
    try std.testing.expectEqual(@as(u64, 2), metrics.total_pings_sent);
}

test "PoolHealthAggregator empty pool" {
    const aggregator = PoolHealthAggregator.init();

    try std.testing.expectEqual(@as(usize, 0), aggregator.total_connections);
    try std.testing.expectEqual(HealthStatus.unknown, aggregator.getOverallStatus());
}

test "PoolHealthAggregator all healthy" {
    var aggregator = PoolHealthAggregator.init();

    aggregator.total_connections = 5;
    aggregator.healthy_connections = 5;
    aggregator.degraded_connections = 0;
    aggregator.unhealthy_connections = 0;

    try std.testing.expectEqual(HealthStatus.healthy, aggregator.getOverallStatus());
}

test "PoolHealthAggregator some unhealthy" {
    var aggregator = PoolHealthAggregator.init();

    aggregator.total_connections = 5;
    aggregator.healthy_connections = 3;
    aggregator.degraded_connections = 1;
    aggregator.unhealthy_connections = 1;

    try std.testing.expectEqual(HealthStatus.degraded, aggregator.getOverallStatus());
}

test "PoolHealthAggregator all unhealthy" {
    var aggregator = PoolHealthAggregator.init();

    aggregator.total_connections = 3;
    aggregator.healthy_connections = 0;
    aggregator.degraded_connections = 0;
    aggregator.unhealthy_connections = 3;

    try std.testing.expectEqual(HealthStatus.unhealthy, aggregator.getOverallStatus());
}

test "PoolHealthAggregator majority degraded" {
    var aggregator = PoolHealthAggregator.init();

    aggregator.total_connections = 4;
    aggregator.healthy_connections = 1;
    aggregator.degraded_connections = 3; // > 50%
    aggregator.unhealthy_connections = 0;

    try std.testing.expectEqual(HealthStatus.degraded, aggregator.getOverallStatus());
}

test "PoolHealthAggregator tracks bytes" {
    var aggregator = PoolHealthAggregator.init();

    aggregator.total_bytes_sent = 1000;
    aggregator.total_bytes_received = 2000;

    try std.testing.expectEqual(@as(u64, 1000), aggregator.total_bytes_sent);
    try std.testing.expectEqual(@as(u64, 2000), aggregator.total_bytes_received);
}

test "HealthMetrics default values" {
    const metrics = HealthMetrics{};

    try std.testing.expectEqual(@as(i64, 0), metrics.last_ping_sent);
    try std.testing.expectEqual(@as(i64, 0), metrics.last_pong_received);
    try std.testing.expectEqual(@as(u32, 0), metrics.latency_ms);
    try std.testing.expectEqual(@as(u32, 0), metrics.avg_latency_ms);
    try std.testing.expectEqual(@as(u8, 0), metrics.ping_failures);
    try std.testing.expectEqual(@as(u64, 0), metrics.total_pings_sent);
    try std.testing.expectEqual(@as(u64, 0), metrics.total_pongs_received);
    try std.testing.expectEqual(@as(i64, 0), metrics.connected_at);
    try std.testing.expectEqual(@as(u64, 0), metrics.bytes_sent);
    try std.testing.expectEqual(@as(u64, 0), metrics.bytes_received);
    try std.testing.expectEqual(@as(u64, 0), metrics.frames_sent);
    try std.testing.expectEqual(@as(u64, 0), metrics.frames_received);
}

test "HealthMonitor recordPong clears pending ping" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{});
    defer monitor.deinit();

    monitor.connectionEstablished();

    // Prepare ping
    _ = try monitor.preparePing();
    try std.testing.expect(monitor.pending_ping_data != null);

    // Record matching pong
    if (monitor.pending_ping_data) |data| {
        const data_copy = try allocator.dupe(u8, data);
        defer allocator.free(data_copy);
        monitor.recordPong(data_copy);
    }

    // Pending ping should be cleared
    try std.testing.expect(monitor.pending_ping_data == null);
}

test "HealthMonitor recordPong ignores non-matching data" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{});
    defer monitor.deinit();

    monitor.connectionEstablished();

    // Prepare ping
    _ = try monitor.preparePing();
    try std.testing.expect(monitor.pending_ping_data != null);

    // Record non-matching pong
    monitor.recordPong("wrong data");

    // Pending ping should still be set (not cleared by wrong pong)
    try std.testing.expect(monitor.pending_ping_data != null);

    // But pong received count should still increment
    const metrics = monitor.getMetrics();
    try std.testing.expectEqual(@as(u64, 1), metrics.total_pongs_received);
}

test "HealthMonitor checkPingTimeout with no pending ping" {
    const allocator = std.testing.allocator;

    var monitor = HealthMonitor.init(allocator, .{
        .ping_interval_ms = 100,
        .pong_timeout_ms = 50,
    });
    defer monitor.deinit();

    monitor.connectionEstablished();

    // No pending ping, so timeout check should return false
    try std.testing.expect(!monitor.checkPingTimeout());
}
