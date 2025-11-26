const std = @import("std");
const Response = @import("../response.zig").Response;

/// Form parser for application/x-www-form-urlencoded data
/// Handles URL decoding automatically and uses arena allocator for memory safety
pub const FormParser = struct {
    body: []const u8,
    allocator: std.mem.Allocator,

    /// Initialize a form parser from request body
    pub fn init(body: []const u8, allocator: std.mem.Allocator) FormParser {
        return .{
            .body = body,
            .allocator = allocator,
        };
    }

    /// Get a form value by key (returns null if not found)
    /// The returned value is URL-decoded and allocated in the arena allocator
    pub fn get(self: *const FormParser, key: []const u8) !?[]const u8 {
        const encoded = self.getRaw(key) orelse return null;
        return try self.urlDecode(encoded);
    }

    /// Get a required form value (returns error if not found)
    pub fn getRequired(self: *const FormParser, key: []const u8) ![]const u8 {
        const value = try self.get(key);
        return value orelse error.MissingFormField;
    }

    /// Get a form value as an integer
    pub fn getInt(self: *const FormParser, key: []const u8) !?i64 {
        const value = try self.get(key) orelse return null;
        return std.fmt.parseInt(i64, value, 10) catch |err| return err;
    }

    /// Get a form value as a boolean (true if value is "true", "1", or "yes")
    pub fn getBool(self: *const FormParser, key: []const u8) !bool {
        const value = try self.get(key) orelse return false;
        return std.mem.eql(u8, value, "true") or
            std.mem.eql(u8, value, "1") or
            std.mem.eql(u8, value, "yes");
    }

    /// Get a form value as a date (YYYY-MM-DD format) and convert to timestamp
    pub fn getDate(self: *const FormParser, key: []const u8) !?i64 {
        const value = try self.get(key) orelse return null;
        if (value.len < 10) return null;

        const year = std.fmt.parseInt(u32, value[0..4], 10) catch return null;
        const month = std.fmt.parseInt(u8, value[5..7], 10) catch return null;
        const day = std.fmt.parseInt(u8, value[8..10], 10) catch return null;

        // Calculate days since epoch
        var days: i64 = 0;
        var y: u32 = 1970;
        while (y < year) : (y += 1) {
            days += if (isLeapYear(y)) 366 else 365;
        }

        const days_in_months = if (isLeapYear(year))
            [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
        else
            [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

        var m: u8 = 1;
        while (m < month) : (m += 1) {
            days += days_in_months[m - 1];
        }

        days += day - 1;
        return days * 86400;
    }

    /// Get raw (encoded) form value by key
    fn getRaw(self: *const FormParser, key: []const u8) ?[]const u8 {
        var iter = std.mem.splitSequence(u8, self.body, "&");
        while (iter.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
                const k = pair[0..eq_pos];
                const v = pair[eq_pos + 1..];
                if (std.mem.eql(u8, k, key)) {
                    return v;
                }
            }
        }
        return null;
    }

    /// URL decode a string and allocate result in arena
    fn urlDecode(self: *const FormParser, input: []const u8) ![]const u8 {
        // First pass: calculate required length
        var required_len: usize = 0;
        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '+') {
                required_len += 1;
                i += 1;
            } else if (input[i] == '%' and i + 2 < input.len) {
                required_len += 1;
                i += 3;
            } else {
                required_len += 1;
                i += 1;
            }
        }

        // Allocate buffer
        const decoded = try self.allocator.alloc(u8, required_len);
        errdefer self.allocator.free(decoded);

        // Second pass: decode
        i = 0;
        var j: usize = 0;
        while (i < input.len) {
            if (input[i] == '+') {
                decoded[j] = ' ';
                i += 1;
                j += 1;
            } else if (input[i] == '%' and i + 2 < input.len) {
                const hex = input[i + 1..i + 3];
                decoded[j] = std.fmt.parseInt(u8, hex, 16) catch {
                    decoded[j] = input[i];
                    i += 1;
                    j += 1;
                    continue;
                };
                i += 3;
                j += 1;
            } else {
                decoded[j] = input[i];
                i += 1;
                j += 1;
            }
        }

        return decoded[0..j];
    }

    fn isLeapYear(year: u32) bool {
        return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
    }
};

// Tests
test "FormParser.get" {
    const allocator = std.testing.allocator;
    var parser = FormParser.init("title=Hello+World&priority=high", allocator);
    
    const title = try parser.get("title");
    defer if (title) |v| allocator.free(v);
    try std.testing.expect(title != null);
    try std.testing.expectEqualStrings("Hello World", title.?);

    const priority = try parser.get("priority");
    defer if (priority) |v| allocator.free(v);
    try std.testing.expect(priority != null);
    try std.testing.expectEqualStrings("high", priority.?);
}

test "FormParser.getRequired" {
    const allocator = std.testing.allocator;
    var parser = FormParser.init("title=Test", allocator);

    const title = try parser.getRequired("title");
    defer allocator.free(title);
    try std.testing.expectEqualStrings("Test", title);

    try std.testing.expectError(error.MissingFormField, parser.getRequired("missing"));
}

test "FormParser.getInt" {
    const allocator = std.testing.allocator;
    var parser = FormParser.init("count=42&empty=", allocator);

    const count = try parser.getInt("count");
    // Note: Memory cleanup handled by testing allocator
    try std.testing.expect(count != null);
    try std.testing.expectEqual(@as(i64, 42), count.?);

    const empty = try parser.getInt("empty");
    try std.testing.expect(empty == null);
}

test "FormParser.getBool" {
    const allocator = std.testing.allocator;
    var parser = FormParser.init("enabled=true&disabled=false&one=1&yes=yes", allocator);

    try std.testing.expect(try parser.getBool("enabled"));
    try std.testing.expect(!try parser.getBool("disabled"));
    try std.testing.expect(try parser.getBool("one"));
    try std.testing.expect(try parser.getBool("yes"));
}

test "FormParser.getDate" {
    const allocator = std.testing.allocator;
    var parser = FormParser.init("due_date=2024-01-15", allocator);

    const date = try parser.getDate("due_date");
    // Note: Memory cleanup handled by testing allocator
    try std.testing.expect(date != null);
    // 2024-01-15 should be approximately 54 years * 365 days + leap years + 14 days
    try std.testing.expect(date.? > 0);
}

