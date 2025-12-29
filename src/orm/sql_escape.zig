const std = @import("std");

/// Utility for escaping strings to prevent SQL injection when parameters cannot be used.
pub const SqlEscape = struct {
    /// Escapes single quotes by doubling them.
    pub fn escapeString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        defer result.deinit(allocator);

        try result.ensureTotalCapacity(allocator, input.len * 2);

        for (input) |char| {
            if (char == '\'') {
                try result.append(allocator, '\'');
                try result.append(allocator, '\'');
            } else {
                try result.append(allocator, char);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Escapes characters with special meaning in SQL LIKE patterns (%, _, \).
    pub fn escapeLikePattern(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        defer result.deinit(allocator);

        try result.ensureTotalCapacity(allocator, input.len * 3);

        for (input) |char| {
            switch (char) {
                '\'' => {
                    try result.append(allocator, '\'');
                    try result.append(allocator, '\'');
                },
                '%' => {
                    try result.append(allocator, '\\');
                    try result.append(allocator, '%');
                },
                '_' => {
                    try result.append(allocator, '\\');
                    try result.append(allocator, '_');
                },
                '\\' => {
                    try result.append(allocator, '\\');
                    try result.append(allocator, '\\');
                },
                else => {
                    try result.append(allocator, char);
                },
            }
        }

        return result.toOwnedSlice(allocator);
    }
};

test "SqlEscape.escapeString basic" {
    const allocator = std.testing.allocator;
    const input = "hello";
    const escaped = try SqlEscape.escapeString(allocator, input);
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings("hello", escaped);
}

test "SqlEscape.escapeString with quotes" {
    const allocator = std.testing.allocator;
    const input = "O'Brien";
    const escaped = try SqlEscape.escapeString(allocator, input);
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings("O''Brien", escaped);
}

test "SqlEscape.escapeString multiple quotes" {
    const allocator = std.testing.allocator;
    const input = "test'string'here";
    const escaped = try SqlEscape.escapeString(allocator, input);
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings("test''string''here", escaped);
}

test "SqlEscape.escapeLikePattern basic" {
    const allocator = std.testing.allocator;
    const input = "test";
    const escaped = try SqlEscape.escapeLikePattern(allocator, input);
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings("test", escaped);
}

test "SqlEscape.escapeLikePattern with wildcards" {
    const allocator = std.testing.allocator;
    const input = "test%_data";
    const escaped = try SqlEscape.escapeLikePattern(allocator, input);
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings("test\\%\\_data", escaped);
}

test "SqlEscape.escapeLikePattern with quotes and wildcards" {
    const allocator = std.testing.allocator;
    const input = "test'%_data";
    const escaped = try SqlEscape.escapeLikePattern(allocator, input);
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings("test''\\%\\_data", escaped);
}
