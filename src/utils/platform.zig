const std = @import("std");
const builtin = @import("builtin");

pub const PlatformMetrics = struct {
    cpu_time_us: u64,
    
    memory_bytes: u64,
    
    peak_memory_bytes: u64,
    
    pub fn get() !PlatformMetrics {
        return switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos => getDarwinMetrics(),
            .linux => getLinuxMetrics(),
            else => error.UnsupportedPlatform,
        };
    }
    
    fn getDarwinMetrics() !PlatformMetrics {
        const c = @cImport({
            @cInclude("sys/resource.h");
        });
        
        var usage: c.struct_rusage = undefined;
        const result = c.getrusage(c.RUSAGE_SELF, &usage);
        if (result != 0) {
            return error.MetricsUnavailable;
        }
        
        const cpu_time_us = @as(u64, @intCast(usage.ru_utime.tv_sec)) * 1_000_000 +
            @as(u64, @intCast(usage.ru_utime.tv_usec)) +
            @as(u64, @intCast(usage.ru_stime.tv_sec)) * 1_000_000 +
            @as(u64, @intCast(usage.ru_stime.tv_usec));
        
        const memory_bytes = @as(u64, @intCast(usage.ru_maxrss)) * 1024;
        
        return PlatformMetrics{
            .cpu_time_us = cpu_time_us,
            .memory_bytes = memory_bytes,
            .peak_memory_bytes = memory_bytes,
        };
    }
    
    fn getLinuxMetrics() !PlatformMetrics {
        const c = @cImport({
            @cInclude("sys/resource.h");
        });
        
        var usage: c.struct_rusage = undefined;
        const result = c.getrusage(c.RUSAGE_SELF, &usage);
        if (result != 0) {
            return error.MetricsUnavailable;
        }
        
        const cpu_time_us = @as(u64, @intCast(usage.ru_utime.tv_sec)) * 1_000_000 +
            @as(u64, @intCast(usage.ru_utime.tv_usec)) +
            @as(u64, @intCast(usage.ru_stime.tv_sec)) * 1_000_000 +
            @as(u64, @intCast(usage.ru_stime.tv_usec));
        
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
        return;
    };
    
    try std.testing.expect(metrics.cpu_time_us >= 0);
    try std.testing.expect(metrics.memory_bytes > 0);
}

