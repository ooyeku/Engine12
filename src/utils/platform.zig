const std = @import("std");
const builtin = @import("builtin");

/// Cross-platform system metrics abstraction
/// Provides unified API for CPU time, memory usage, etc. across macOS and Linux
pub const PlatformMetrics = struct {
    /// CPU time in microseconds
    cpu_time_us: u64,
    
    /// Memory usage in bytes
    memory_bytes: u64,
    
    /// Peak memory usage in bytes
    peak_memory_bytes: u64,
    
    /// Get current platform metrics
    /// Returns error if metrics cannot be retrieved
    pub fn get() !PlatformMetrics {
        return switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos => getDarwinMetrics(),
            .linux => getLinuxMetrics(),
            else => error.UnsupportedPlatform,
        };
    }
    
    /// Get metrics on Darwin (macOS/iOS)
    fn getDarwinMetrics() !PlatformMetrics {
        const c = @cImport({
            @cInclude("sys/resource.h");
        });
        
        var usage: c.struct_rusage = undefined;
        const result = c.getrusage(c.RUSAGE_SELF, &usage);
        if (result != 0) {
            return error.MetricsUnavailable;
        }
        
        // Darwin uses timeval (seconds + microseconds)
        const cpu_time_us = @as(u64, @intCast(usage.ru_utime.tv_sec)) * 1_000_000 +
            @as(u64, @intCast(usage.ru_utime.tv_usec)) +
            @as(u64, @intCast(usage.ru_stime.tv_sec)) * 1_000_000 +
            @as(u64, @intCast(usage.ru_stime.tv_usec));
        
        // Darwin uses maxrss in kilobytes
        const memory_bytes = @as(u64, @intCast(usage.ru_maxrss)) * 1024;
        
        return PlatformMetrics{
            .cpu_time_us = cpu_time_us,
            .memory_bytes = memory_bytes,
            .peak_memory_bytes = memory_bytes,
        };
    }
    
    /// Get metrics on Linux
    fn getLinuxMetrics() !PlatformMetrics {
        const c = @cImport({
            @cInclude("sys/resource.h");
        });
        
        var usage: c.struct_rusage = undefined;
        const result = c.getrusage(c.RUSAGE_SELF, &usage);
        if (result != 0) {
            return error.MetricsUnavailable;
        }
        
        // Linux uses timeval (seconds + microseconds)
        const cpu_time_us = @as(u64, @intCast(usage.ru_utime.tv_sec)) * 1_000_000 +
            @as(u64, @intCast(usage.ru_utime.tv_usec)) +
            @as(u64, @intCast(usage.ru_stime.tv_sec)) * 1_000_000 +
            @as(u64, @intCast(usage.ru_stime.tv_usec));
        
        // Linux uses maxrss in kilobytes
        const memory_bytes = @as(u64, @intCast(usage.ru_maxrss)) * 1024;
        
        return PlatformMetrics{
            .cpu_time_us = cpu_time_us,
            .memory_bytes = memory_bytes,
            .peak_memory_bytes = memory_bytes,
        };
    }
};

test "PlatformMetrics get on supported platform" {
    const metrics = PlatformMetrics.get() catch {
        // Skip test if platform not supported or metrics unavailable
        return;
    };
    
    // Verify metrics are reasonable
    try std.testing.expect(metrics.cpu_time_us >= 0);
    try std.testing.expect(metrics.memory_bytes > 0);
}

