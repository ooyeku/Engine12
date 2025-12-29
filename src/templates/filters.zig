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
        const T = @TypeOf(value);
        return switch (@typeInfo(T)) {
            .pointer => |ptr_info| switch (ptr_info.size) {
                .slice => value.len,
                .one => switch (@typeInfo(ptr_info.child)) {
                    .array => |arr_info| arr_info.len,
                    else => 0,
                },
                else => 0,
            },
            .array => |arr_info| arr_info.len,
            else => 0,
        };
    }

    pub fn format(value: anytype, comptime fmt: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, fmt, .{value});
    }


    pub fn capitalize(value: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        if (value.len == 0) return try allocator.dupe(u8, "");
        const result = try allocator.alloc(u8, value.len);
        result[0] = std.ascii.toUpper(value[0]);
        if (value.len > 1) {
            @memcpy(result[1..], value[1..]);
        }
        return result;
    }


    pub fn truncate(value: []const u8, max_len: usize, allocator: std.mem.Allocator) ![]const u8 {
        if (value.len <= max_len) return try allocator.dupe(u8, value);
        if (max_len < 3) return try allocator.dupe(u8, "...");
        const result = try allocator.alloc(u8, max_len);
        @memcpy(result[0 .. max_len - 3], value[0 .. max_len - 3]);
        @memcpy(result[max_len - 3 ..], "...");
        return result;
    }


    pub fn replace(value: []const u8, from: []const u8, to: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        if (from.len == 0) return try allocator.dupe(u8, value);


        var count: usize = 0;
        var i: usize = 0;
        while (i < value.len) {
            if (i + from.len <= value.len and std.mem.eql(u8, value[i .. i + from.len], from)) {
                count += 1;
                i += from.len;
            } else {
                i += 1;
            }
        }

        if (count == 0) return try allocator.dupe(u8, value);


        const new_len = value.len - (count * from.len) + (count * to.len);
        const result = try allocator.alloc(u8, new_len);

        var src_idx: usize = 0;
        var dst_idx: usize = 0;
        while (src_idx < value.len) {
            if (src_idx + from.len <= value.len and std.mem.eql(u8, value[src_idx .. src_idx + from.len], from)) {
                @memcpy(result[dst_idx .. dst_idx + to.len], to);
                dst_idx += to.len;
                src_idx += from.len;
            } else {
                result[dst_idx] = value[src_idx];
                dst_idx += 1;
                src_idx += 1;
            }
        }

        return result;
    }


    pub fn json(value: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var escaped_len: usize = 2;
        for (value) |c| {
            escaped_len += switch (c) {
                '"', '\\', '/' => 2,
                '\n', '\r', '\t' => 2,
                else => if (c < 32) 6 else 1,
            };
        }

        const result = try allocator.alloc(u8, escaped_len);
        result[0] = '"';
        var idx: usize = 1;
        for (value) |c| {
            switch (c) {
                '"' => {
                    result[idx] = '\\';
                    result[idx + 1] = '"';
                    idx += 2;
                },
                '\\' => {
                    result[idx] = '\\';
                    result[idx + 1] = '\\';
                    idx += 2;
                },
                '\n' => {
                    result[idx] = '\\';
                    result[idx + 1] = 'n';
                    idx += 2;
                },
                '\r' => {
                    result[idx] = '\\';
                    result[idx + 1] = 'r';
                    idx += 2;
                },
                '\t' => {
                    result[idx] = '\\';
                    result[idx + 1] = 't';
                    idx += 2;
                },
                else => {
                    if (c < 32) {
                        _ = std.fmt.bufPrint(result[idx .. idx + 6], "\\u{x:0>4}", .{c}) catch {};
                        idx += 6;
                    } else {
                        result[idx] = c;
                        idx += 1;
                    }
                },
            }
        }
        result[idx] = '"';
        return result;
    }


    pub fn nl2br(value: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var count: usize = 0;
        for (value) |c| {
            if (c == '\n') count += 1;
        }

        if (count == 0) return try allocator.dupe(u8, value);

        const result = try allocator.alloc(u8, value.len + count * 3);
        var src_idx: usize = 0;
        var dst_idx: usize = 0;
        while (src_idx < value.len) {
            if (value[src_idx] == '\n') {
                @memcpy(result[dst_idx .. dst_idx + 4], "<br>");
                dst_idx += 4;
                src_idx += 1;
            } else {
                result[dst_idx] = value[src_idx];
                dst_idx += 1;
                src_idx += 1;
            }
        }
        return result[0..dst_idx];
    }


    pub fn escapeJs(value: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var escaped_len: usize = 0;
        for (value) |c| {
            escaped_len += switch (c) {
                '\'', '"', '\\', '\n', '\r' => 2,
                else => 1,
            };
        }

        if (escaped_len == value.len) return try allocator.dupe(u8, value);

        const result = try allocator.alloc(u8, escaped_len);
        var idx: usize = 0;
        for (value) |c| {
            switch (c) {
                '\'' => {
                    result[idx] = '\\';
                    result[idx + 1] = '\'';
                    idx += 2;
                },
                '"' => {
                    result[idx] = '\\';
                    result[idx + 1] = '"';
                    idx += 2;
                },
                '\\' => {
                    result[idx] = '\\';
                    result[idx + 1] = '\\';
                    idx += 2;
                },
                '\n' => {
                    result[idx] = '\\';
                    result[idx + 1] = 'n';
                    idx += 2;
                },
                '\r' => {
                    result[idx] = '\\';
                    result[idx + 1] = 'r';
                    idx += 2;
                },
                else => {
                    result[idx] = c;
                    idx += 1;
                },
            }
        }
        return result;
    }


    pub fn escapeUrl(value: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var escaped_len: usize = 0;
        for (value) |c| {
            escaped_len += if (isUrlSafe(c)) 1 else 3;
        }

        if (escaped_len == value.len) return try allocator.dupe(u8, value);

        const result = try allocator.alloc(u8, escaped_len);
        var idx: usize = 0;
        for (value) |c| {
            if (isUrlSafe(c)) {
                result[idx] = c;
                idx += 1;
            } else {
                result[idx] = '%';
                const hex = "0123456789ABCDEF";
                result[idx + 1] = hex[c >> 4];
                result[idx + 2] = hex[c & 0xF];
                idx += 3;
            }
        }
        return result;
    }

    fn isUrlSafe(c: u8) bool {
        return (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
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

test "capitalize filter - basic" {
    const allocator = std.testing.allocator;
    const result = try Filters.capitalize("hello world", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "Hello world");
}

test "capitalize filter - empty string" {
    const allocator = std.testing.allocator;
    const result = try Filters.capitalize("", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "");
}

test "capitalize filter - already uppercase" {
    const allocator = std.testing.allocator;
    const result = try Filters.capitalize("HELLO", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "HELLO");
}

test "capitalize filter - single char" {
    const allocator = std.testing.allocator;
    const result = try Filters.capitalize("a", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "A");
}

test "truncate filter - shorter than limit" {
    const allocator = std.testing.allocator;
    const result = try Filters.truncate("hi", 10, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "hi");
}

test "truncate filter - longer than limit" {
    const allocator = std.testing.allocator;
    const result = try Filters.truncate("hello world", 8, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "hello...");
}

test "truncate filter - exact length" {
    const allocator = std.testing.allocator;
    const result = try Filters.truncate("12345", 5, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "12345");
}

test "truncate filter - empty string" {
    const allocator = std.testing.allocator;
    const result = try Filters.truncate("", 10, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "");
}

test "replace filter - basic" {
    const allocator = std.testing.allocator;
    const result = try Filters.replace("hello world", "world", "zig", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "hello zig");
}

test "replace filter - multiple occurrences" {
    const allocator = std.testing.allocator;
    const result = try Filters.replace("a-b-c-d", "-", "_", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "a_b_c_d");
}

test "replace filter - no match" {
    const allocator = std.testing.allocator;
    const result = try Filters.replace("hello", "xyz", "abc", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "hello");
}

test "replace filter - empty pattern" {
    const allocator = std.testing.allocator;
    const result = try Filters.replace("hello", "", "x", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "hello");
}

test "json filter - basic string" {
    const allocator = std.testing.allocator;
    const result = try Filters.json("hello", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "\"hello\"");
}

test "json filter - with quotes" {
    const allocator = std.testing.allocator;
    const result = try Filters.json("say \"hi\"", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "\"say \\\"hi\\\"\"");
}

test "json filter - with backslash" {
    const allocator = std.testing.allocator;
    const result = try Filters.json("path\\to\\file", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "\"path\\\\to\\\\file\"");
}

test "json filter - with newline" {
    const allocator = std.testing.allocator;
    const result = try Filters.json("line1\nline2", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "\"line1\\nline2\"");
}

test "nl2br filter - basic" {
    const allocator = std.testing.allocator;
    const result = try Filters.nl2br("line1\nline2", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "line1<br>line2");
}

test "nl2br filter - multiple newlines" {
    const allocator = std.testing.allocator;
    const result = try Filters.nl2br("a\nb\nc", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "a<br>b<br>c");
}

test "nl2br filter - no newlines" {
    const allocator = std.testing.allocator;
    const result = try Filters.nl2br("no newlines", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "no newlines");
}

test "escape_js filter - basic" {
    const allocator = std.testing.allocator;
    const result = try Filters.escapeJs("hello", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "hello");
}

test "escape_js filter - quotes" {
    const allocator = std.testing.allocator;
    const result = try Filters.escapeJs("say 'hi'", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "say \\'hi\\'");
}

test "escape_js filter - backslash" {
    const allocator = std.testing.allocator;
    const result = try Filters.escapeJs("a\\b", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "a\\\\b");
}

test "escape_url filter - basic" {
    const allocator = std.testing.allocator;
    const result = try Filters.escapeUrl("hello", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "hello");
}

test "escape_url filter - spaces" {
    const allocator = std.testing.allocator;
    const result = try Filters.escapeUrl("hello world", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "hello%20world");
}

test "escape_url filter - special chars" {
    const allocator = std.testing.allocator;
    const result = try Filters.escapeUrl("a=b&c=d", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "a%3Db%26c%3Dd");
}

test "uppercase filter - empty string" {
    const allocator = std.testing.allocator;
    const result = try Filters.uppercase("", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "");
}

test "lowercase filter - empty string" {
    const allocator = std.testing.allocator;
    const result = try Filters.lowercase("", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "");
}

test "trim filter - only whitespace" {
    const allocator = std.testing.allocator;
    const result = try Filters.trim("   ", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "");
}

test "trim filter - tabs and newlines" {
    const allocator = std.testing.allocator;
    const result = try Filters.trim("\t\nhello\t\n", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "hello");
}
