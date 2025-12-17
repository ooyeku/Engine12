const std = @import("std");

pub const Filters = struct {
    pub fn uppercase(value: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const upper = try allocator.alloc(u8, value.len);
        for (value, 0..) |char, i| {
            upper[i] = std.ascii.toUpper(char);
        }
        return upper;
    }

    pub fn lowercase(value: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const lower = try allocator.alloc(u8, value.len);
        for (value, 0..) |char, i| {
            lower[i] = std.ascii.toLower(char);
        }
        return lower;
    }

    pub fn trim(value: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const trimmed = std.mem.trim(u8, value, " \t\n\r");
        return try allocator.dupe(u8, trimmed);
    }

    pub fn default(value: ?[]const u8, default_val: []const u8) []const u8 {
        if (value) |v| {
            if (v.len == 0) {
                return default_val;
            }
            return v;
        }
        return default_val;
    }

    pub fn length(value: anytype) usize {
        return switch (@typeInfo(@TypeOf(value))) {
            .Pointer => |ptr_info| switch (ptr_info.size) {
                .slice => value.len,
                else => 0,
            },
            .Array => |arr_info| arr_info.len,
            else => 0,
        };
    }

    pub fn format(value: anytype, comptime fmt: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, fmt, .{value});
    }
};

test "uppercase filter" {
    const allocator = std.testing.allocator;
    const result = try Filters.uppercase("hello", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "HELLO");
}

test "lowercase filter" {
    const allocator = std.testing.allocator;
    const result = try Filters.lowercase("HELLO", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "hello");
}

test "trim filter" {
    const allocator = std.testing.allocator;
    const result = try Filters.trim("  hello  ", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "hello");
}

test "default filter" {
    try std.testing.expectEqualStrings(Filters.default(null, "default"), "default");
    try std.testing.expectEqualStrings(Filters.default("", "default"), "default");
    try std.testing.expectEqualStrings(Filters.default("value", "default"), "value");
}

test "length filter" {
    try std.testing.expectEqual(Filters.length("hello"), 5);
    try std.testing.expectEqual(Filters.length(&[_]u8{ 1, 2, 3 }), 3);
}
