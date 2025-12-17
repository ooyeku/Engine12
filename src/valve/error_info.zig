const std = @import("std");

pub const ValveErrorPhase = enum {
    init,
    start,
    stop,
    runtime,
};

pub const ValveErrorInfo = struct {
    phase: ValveErrorPhase,
    error_type: []const u8,
    message: []const u8,
    timestamp: i64,

    pub fn deinit(self: *ValveErrorInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.error_type);
        allocator.free(self.message);
    }

    pub fn create(
        allocator: std.mem.Allocator,
        phase: ValveErrorPhase,
        error_type: []const u8,
        message: []const u8,
    ) !ValveErrorInfo {
        const error_type_copy = try allocator.dupe(u8, error_type);
        errdefer allocator.free(error_type_copy);

        const message_copy = try allocator.dupe(u8, message);
        errdefer allocator.free(message_copy);

        const timestamp = std.time.milliTimestamp();

        return ValveErrorInfo{
            .phase = phase,
            .error_type = error_type_copy,
            .message = message_copy,
            .timestamp = timestamp,
        };
    }

    pub fn format(self: *const ValveErrorInfo, allocator: std.mem.Allocator) ![]const u8 {
        const phase_str = switch (self.phase) {
            .init => "init",
            .start => "onAppStart",
            .stop => "onAppStop",
            .runtime => "runtime",
        };

        return std.fmt.allocPrint(
            allocator,
            "{s}: {s} ({s})",
            .{ phase_str, self.message, self.error_type },
        );
    }
};

test "ValveErrorInfo create and deinit" {
    const allocator = std.testing.allocator;

    var error_info = try ValveErrorInfo.create(
        allocator,
        .init,
        "OutOfMemory",
        "Failed to allocate memory",
    );
    defer error_info.deinit(allocator);

    try std.testing.expectEqual(error_info.phase, .init);
    try std.testing.expectEqualStrings(error_info.error_type, "OutOfMemory");
    try std.testing.expectEqualStrings(error_info.message, "Failed to allocate memory");
    try std.testing.expect(error_info.timestamp > 0);
}

test "ValveErrorInfo format" {
    const allocator = std.testing.allocator;

    var error_info = try ValveErrorInfo.create(
        allocator,
        .start,
        "DatabaseError",
        "Connection failed",
    );
    defer error_info.deinit(allocator);

    const formatted = try error_info.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "onAppStart") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Connection failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "DatabaseError") != null);
}
