const std = @import("std");
const Request = @import("request.zig").Request;
const Json = @import("json.zig").Json;

/// Parser-specific errors
pub const ParserError = error{
    QueryStringTooLarge,
};

/// Maximum query string size to prevent DoS attacks (10KB)
const MAX_QUERY_STRING_SIZE = 10 * 1024;

/// Percent-decode a URL-encoded string
/// Decodes %XX hex sequences and + (plus signs) to spaces
/// Invalid hex sequences are treated as literal characters
///
/// Example: "hello%20world" -> "hello world"
/// Example: "test%2Bvalue" -> "test+value"
pub fn percentDecode(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};

    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            // Decode hex sequence
            const hex_str = encoded[i + 1 .. i + 3];
            const byte = std.fmt.parseInt(u8, hex_str, 16) catch {
                // Invalid hex - treat as literal
                try result.append(allocator, '%');
                i += 1;
                continue;
            };
            try result.append(allocator, byte);
            i += 3;
        } else if (encoded[i] == '+') {
            // + is encoded space
            try result.append(allocator, ' ');
            i += 1;
        } else {
            try result.append(allocator, encoded[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Shared helper to parse key=value pairs from a string
/// Handles URL encoding, empty values, and duplicate keys
/// Returns a hashmap that must be freed using freeParams()
fn parseKeyValuePairs(allocator: std.mem.Allocator, input: []const u8) !std.StringHashMap([]const u8) {
    var params = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var iter = params.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        params.deinit();
    }

    var remaining = input;
    while (remaining.len > 0) {
        // Find next & or end of string
        const amp_pos = std.mem.indexOfScalar(u8, remaining, '&') orelse remaining.len;
        const pair = remaining[0..amp_pos];

        if (pair.len > 0) {
            // Find = separator
            const eq_pos = std.mem.indexOfScalar(u8, pair, '=') orelse {
                // No = found, treat as key with empty value
                const key = try percentDecode(allocator, pair);
                errdefer allocator.free(key);
                try params.put(key, "");
                remaining = if (amp_pos < remaining.len) remaining[amp_pos + 1 ..] else "";
                continue;
            };

            const key_raw = pair[0..eq_pos];
            const value_raw = if (eq_pos + 1 < pair.len) pair[eq_pos + 1 ..] else "";

            const key = try percentDecode(allocator, key_raw);
            errdefer allocator.free(key);
            const value = try percentDecode(allocator, value_raw);
            errdefer allocator.free(value);

            const gop = try params.getOrPut(key);
            if (gop.found_existing) {
                // Key already exists in HashMap, free the duplicate key we just allocated
                allocator.free(key);
                // Free the old value before replacing
                allocator.free(gop.value_ptr.*);
            }
            // HashMap now owns the key (if new) or we've freed the duplicate
            // Set the new value
            gop.value_ptr.* = value;
        }

        // Move to next pair
        remaining = if (amp_pos < remaining.len) remaining[amp_pos + 1 ..] else "";
    }

    return params;
}

/// Query parameter parsing utilities
pub const QueryParser = struct {
    /// Parse query string from URL path
    /// Returns a hashmap of key-value pairs
    /// Validates query string size to prevent DoS attacks (max 10KB)
    ///
    /// Example:
    /// Path: "/api/todos?limit=10&offset=20"
    /// Returns: {"limit": "10", "offset": "20"}
    pub fn parse(allocator: std.mem.Allocator, path: []const u8) !std.StringHashMap([]const u8) {
        // Find query string separator
        const query_start = std.mem.indexOfScalar(u8, path, '?') orelse {
            // No query string, return empty params
            return std.StringHashMap([]const u8).init(allocator);
        };
        const query_string = path[query_start + 1 ..];

        // Validate query string size to prevent DoS attacks
        if (query_string.len > MAX_QUERY_STRING_SIZE) {
            return ParserError.QueryStringTooLarge;
        }

        // Use shared parsing logic
        return parseKeyValuePairs(allocator, query_string);
    }
};

/// Body parsing utilities
pub const BodyParser = struct {
    /// Parse JSON body into a struct
    /// Uses engine12's Json module for type-safe deserialization
    ///
    /// Example:
    /// ```zig
    /// const Todo = struct { title: []const u8, completed: bool };
    /// const todo = try BodyParser.json(Todo, req.body(), req.arena.allocator());
    /// ```
    pub fn json(comptime T: type, body: []const u8, allocator: std.mem.Allocator) !T {
        return Json.deserialize(T, body, allocator);
    }

    /// Parse JSON body into a struct, returning null on error
    pub fn jsonOptional(comptime T: type, body: []const u8, allocator: std.mem.Allocator) ?T {
        return json(T, body, allocator) catch null;
    }

    /// Parse URL-encoded form data
    /// Returns a hashmap of key-value pairs
    /// Note: Size validation should be done by the caller (e.g., request.zig)
    ///
    /// Example:
    /// Body: "title=Hello&completed=true"
    /// Returns: {"title": "Hello", "completed": "true"}
    pub fn formData(allocator: std.mem.Allocator, body: []const u8) !std.StringHashMap([]const u8) {
        // Use shared parsing logic
        return parseKeyValuePairs(allocator, body);
    }
};

// Helper for tests to cleanup params
fn freeParams(allocator: std.mem.Allocator, params: *std.StringHashMap([]const u8)) void {
    var iter = params.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    params.deinit();
}

// Tests
test "QueryParser parse simple query" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/todos?limit=10&offset=20");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("limit").?, "10");
    try std.testing.expectEqualStrings(params.get("offset").?, "20");
}

test "QueryParser parse empty query" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/todos");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 0);
}

test "QueryParser parse URL encoded" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/search?q=hello%20world&tag=test");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("q").?, "hello world");
    try std.testing.expectEqualStrings(params.get("tag").?, "test");
}

test "BodyParser formData" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "title=Hello&completed=true");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("title").?, "Hello");
    try std.testing.expectEqualStrings(params.get("completed").?, "true");
}

test "QueryParser parse with single parameter" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=value");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "value");
}

test "QueryParser parse with no equals sign" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?keyonly");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("keyonly").?, "");
}

test "QueryParser parse with multiple equals signs" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=value=extra");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    // Should take everything after first = as value
    try std.testing.expectEqualStrings(params.get("key").?, "value=extra");
}

test "QueryParser parse with special characters" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?q=hello%20world&tag=test%2Bvalue%26more");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("q").?, "hello world");
    try std.testing.expectEqualStrings(params.get("tag").?, "test+value&more");
}

test "QueryParser parse with percent encoding edge cases" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=%41%42%43");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "ABC");
}

test "QueryParser parse with invalid percent encoding" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=%XX");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    // Invalid hex should be treated as literal
    try std.testing.expect(std.mem.indexOf(u8, params.get("key").?, "%") != null);
}

test "QueryParser parse with incomplete percent encoding" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=%4");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    // Incomplete encoding should be treated as literal
    try std.testing.expect(std.mem.indexOf(u8, params.get("key").?, "%") != null);
}

test "QueryParser parse with plus sign encoding" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?q=hello+world");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("q").?, "hello world");
}

test "QueryParser parse with empty query string" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 0);
}

test "QueryParser parse with ampersand only" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?&");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 0);
}

test "QueryParser parse with duplicate keys" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=value1&key=value2");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    // Last value wins
    try std.testing.expectEqualStrings(params.get("key").?, "value2");
}

test "BodyParser formData with empty values" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "key1=&key2=value&key3=");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 3);
    try std.testing.expectEqualStrings(params.get("key1").?, "");
    try std.testing.expectEqualStrings(params.get("key2").?, "value");
    try std.testing.expectEqualStrings(params.get("key3").?, "");
}

test "BodyParser formData with URL encoded values" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "name=John%20Doe&email=test%40example.com");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("name").?, "John Doe");
    try std.testing.expectEqualStrings(params.get("email").?, "test@example.com");
}

test "BodyParser formData with no equals sign" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "keyonly");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("keyonly").?, "");
}

test "BodyParser formData with duplicate keys" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "key=value1&key=value2");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    // Last value wins
    try std.testing.expectEqualStrings(params.get("key").?, "value2");
}

test "BodyParser formData with plus sign encoding" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "name=John+Doe");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("name").?, "John Doe");
}

test "BodyParser formData with special characters" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "msg=hello%26world%3Dtest");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("msg").?, "hello&world=test");
}

test "BodyParser formData with empty body" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 0);
}

test "QueryParser parse with many parameters" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?a=1&b=2&c=3&d=4&e=5");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 5);
    try std.testing.expectEqualStrings(params.get("a").?, "1");
    try std.testing.expectEqualStrings(params.get("b").?, "2");
    try std.testing.expectEqualStrings(params.get("c").?, "3");
    try std.testing.expectEqualStrings(params.get("d").?, "4");
    try std.testing.expectEqualStrings(params.get("e").?, "5");
}

test "QueryParser parse with mixed encoding" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?normal=value&encoded=hello%20world&plus=test+value");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 3);
    try std.testing.expectEqualStrings(params.get("normal").?, "value");
    try std.testing.expectEqualStrings(params.get("encoded").?, "hello world");
    try std.testing.expectEqualStrings(params.get("plus").?, "test value");
}

// ============================================================================
// Bug Verification Tests
// ============================================================================

test "QueryParser parse - duplicate keys memory leak prevention" {
    const allocator = std.testing.allocator;
    // Test that duplicate keys don't leak memory (BUG #1)
    // This test verifies the behavior works, but can't directly test for leaks
    // In a fixed implementation, memory should be properly freed
    var params = try QueryParser.parse(allocator, "/api/test?key=value1&key=value2&key=value3");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    // Last value should win
    try std.testing.expectEqualStrings(params.get("key").?, "value3");

    // Test with URL-encoded duplicate keys
    var params2 = try QueryParser.parse(allocator, "/api/test?name=John&name=Jane&name=Bob");
    defer freeParams(allocator, &params2);

    try std.testing.expect(params2.count() == 1);
    try std.testing.expectEqualStrings(params2.get("name").?, "Bob");
}

test "QueryParser parse - key-only pairs memory leak prevention" {
    const allocator = std.testing.allocator;
    // Test that key-only pairs (no = sign) don't leak memory (BUG #2)
    var params = try QueryParser.parse(allocator, "/api/test?key1&key2&key3=value");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 3);
    try std.testing.expectEqualStrings(params.get("key1").?, "");
    try std.testing.expectEqualStrings(params.get("key2").?, "");
    try std.testing.expectEqualStrings(params.get("key3").?, "value");

    // Test with URL-encoded key-only pairs
    var params2 = try QueryParser.parse(allocator, "/api/test?hello%20world&test%2Bvalue");
    defer freeParams(allocator, &params2);

    try std.testing.expect(params2.count() == 2);
    try std.testing.expectEqualStrings(params2.get("hello world").?, "");
    try std.testing.expectEqualStrings(params2.get("test+value").?, "");
}

test "QueryParser parse - very long query string DoS prevention" {
    const allocator = std.testing.allocator;
    // Test that very long query strings are handled (BUG #7 - no size limit)
    // Currently there's no size validation, so this will succeed
    // In a fixed implementation, this should be rejected or limited

    // Create a very long query string (100KB)
    var long_query = std.ArrayListUnmanaged(u8){};
    defer long_query.deinit(allocator);

    try long_query.appendSlice(allocator, "/api/test?");
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try long_query.writer(allocator).print("key{d}=value{d}&", .{ i, i });
    }

    // Should fail with QueryStringTooLarge error (now fixed with size limit)
    const result = QueryParser.parse(allocator, long_query.items);
    try std.testing.expectError(ParserError.QueryStringTooLarge, result);
}

test "QueryParser parse - percentDecode bounds checking" {
    const allocator = std.testing.allocator;
    // Test bounds checking in percentDecode (BUG #3)
    // Test with percent at end of string
    var params = try QueryParser.parse(allocator, "/api/test?key=test%");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    // Should treat incomplete % as literal
    try std.testing.expect(std.mem.indexOf(u8, params.get("key").?, "%") != null);

    // Test with percent and one character
    var params2 = try QueryParser.parse(allocator, "/api/test?key=test%4");
    defer freeParams(allocator, &params2);

    try std.testing.expect(params2.count() == 1);
    try std.testing.expect(std.mem.indexOf(u8, params2.get("key").?, "%") != null);

    // Test with valid encoding at boundary
    var params3 = try QueryParser.parse(allocator, "/api/test?key=%41");
    defer freeParams(allocator, &params3);

    try std.testing.expect(params3.count() == 1);
    try std.testing.expectEqualStrings(params3.get("key").?, "A");
}

test "BodyParser formData - duplicate keys memory leak prevention" {
    const allocator = std.testing.allocator;
    // Test that duplicate keys in form data don't leak memory (BUG #1)
    var params = try BodyParser.formData(allocator, "key=value1&key=value2&key=value3");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "value3");

    // Test with URL-encoded duplicate keys
    var params2 = try BodyParser.formData(allocator, "name=John%20Doe&name=Jane%20Doe&name=Bob%20Smith");
    defer freeParams(allocator, &params2);

    try std.testing.expect(params2.count() == 1);
    try std.testing.expectEqualStrings(params2.get("name").?, "Bob Smith");
}

test "BodyParser formData - key-only pairs memory leak prevention" {
    const allocator = std.testing.allocator;
    // Test that key-only pairs in form data don't leak memory (BUG #2)
    var params = try BodyParser.formData(allocator, "key1&key2&key3=value");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 3);
    try std.testing.expectEqualStrings(params.get("key1").?, "");
    try std.testing.expectEqualStrings(params.get("key2").?, "");
    try std.testing.expectEqualStrings(params.get("key3").?, "value");
}

test "QueryParser parse - percentDecode error handling" {
    const allocator = std.testing.allocator;
    // Test error handling in percentDecode (BUG #4)
    // Invalid hex sequences should be treated as literals

    // Test with invalid hex characters
    var params = try QueryParser.parse(allocator, "/api/test?key=%XX");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    // Should contain literal %
    try std.testing.expect(std.mem.indexOf(u8, params.get("key").?, "%") != null);

    // Test with invalid hex (non-hex characters)
    var params2 = try QueryParser.parse(allocator, "/api/test?key=%GH");
    defer freeParams(allocator, &params2);

    try std.testing.expect(params2.count() == 1);
    try std.testing.expect(std.mem.indexOf(u8, params2.get("key").?, "%") != null);

    // Test with mixed valid and invalid encoding
    var params3 = try QueryParser.parse(allocator, "/api/test?key=test%41%XX%42");
    defer freeParams(allocator, &params3);

    try std.testing.expect(params3.count() == 1);
    const value = params3.get("key").?;
    // Should contain "A" from %41, literal "%XX", and "B" from %42
    try std.testing.expect(std.mem.indexOf(u8, value, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "%") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "B") != null);
}

test "QueryParser parse - code duplication verification" {
    const allocator = std.testing.allocator;
    // Test that QueryParser and BodyParser handle the same cases consistently (BUG #5)
    // This test documents that both parsers should behave identically

    const query_string = "key1=value1&key2&key3=value3&key1=value4";
    const query_path = try std.fmt.allocPrint(allocator, "/api/test?{s}", .{query_string});
    defer allocator.free(query_path);

    var query_params = try QueryParser.parse(allocator, query_path);
    defer freeParams(allocator, &query_params);

    var form_params = try BodyParser.formData(allocator, query_string);
    defer freeParams(allocator, &form_params);

    // Both should have the same count
    try std.testing.expect(query_params.count() == form_params.count());

    // Both should have the same keys and values
    var iter = query_params.iterator();
    while (iter.next()) |entry| {
        const form_value = form_params.get(entry.key_ptr.*);
        try std.testing.expect(form_value != null);
        try std.testing.expectEqualStrings(entry.value_ptr.*, form_value.?);
    }
}

test "QueryParser parse - percentDecode accessibility" {
    const allocator = std.testing.allocator;
    // Test that percentDecode is now public and accessible (BUG #6 - fixed)
    // percentDecode is now a module-level public function

    // Test that BodyParser can decode properly (uses shared percentDecode)
    var params = try BodyParser.formData(allocator, "name=John%20Doe&email=test%40example.com");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("name").?, "John Doe");
    try std.testing.expectEqualStrings(params.get("email").?, "test@example.com");

    // Test that percentDecode can be called directly
    const decoded = try percentDecode(allocator, "hello%20world");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(decoded, "hello world");
}

test "QueryParser parse - edge case empty key" {
    const allocator = std.testing.allocator;
    // Test edge case: empty key name
    var params = try QueryParser.parse(allocator, "/api/test?=value");
    defer freeParams(allocator, &params);

    // Should handle empty key
    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("").?, "value");
}

test "QueryParser parse - edge case empty value" {
    const allocator = std.testing.allocator;
    // Test edge case: empty value
    var params = try QueryParser.parse(allocator, "/api/test?key=");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "");
}

test "QueryParser parse - edge case multiple ampersands" {
    const allocator = std.testing.allocator;
    // Test edge case: multiple consecutive ampersands
    var params = try QueryParser.parse(allocator, "/api/test?key1=value1&&key2=value2&");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("key1").?, "value1");
    try std.testing.expectEqualStrings(params.get("key2").?, "value2");
}

test "QueryParser parse - edge case query string at end" {
    const allocator = std.testing.allocator;
    // Test edge case: query string ends with &
    var params = try QueryParser.parse(allocator, "/api/test?key=value&");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "value");
}

test "BodyParser formData - very long form data DoS prevention" {
    const allocator = std.testing.allocator;
    // Test that very long form data is handled (note: request.zig validates this)
    // But BodyParser.formData itself doesn't validate

    // Create a very long form data string (100KB)
    var long_form = std.ArrayListUnmanaged(u8){};
    defer long_form.deinit(allocator);

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try long_form.writer(allocator).print("key{d}=value{d}&", .{ i, i });
    }

    // This should succeed (BodyParser doesn't validate size)
    // request.zig validates before calling BodyParser.formData
    var params = BodyParser.formData(allocator, long_form.items) catch {
        return;
    };
    defer freeParams(allocator, &params);

    // Currently succeeds - documents that BodyParser doesn't validate size
    try std.testing.expect(params.count() == 1000);
}

test "QueryParser parse - Unicode in percent encoding" {
    const allocator = std.testing.allocator;
    // Test Unicode characters in percent encoding
    // UTF-8 encoding of "Hello 世界" is: Hello %E4%B8%96%E7%95%8C

    // Note: This tests that percent encoding works for multi-byte UTF-8
    // The current implementation decodes byte-by-byte, which is correct for UTF-8
    var params = try QueryParser.parse(allocator, "/api/test?greeting=Hello%20%E4%B8%96%E7%95%8C");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    const value = params.get("greeting").?;
    // Should decode to "Hello 世界" (UTF-8)
    try std.testing.expect(value.len > 6); // More than "Hello "
    // Verify it contains "Hello "
    try std.testing.expect(std.mem.startsWith(u8, value, "Hello "));
}

test "QueryParser parse - percent encoding at start" {
    const allocator = std.testing.allocator;
    // Test percent encoding at the start of value
    var params = try QueryParser.parse(allocator, "/api/test?key=%41BC");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "ABC");
}

test "QueryParser parse - percent encoding at end" {
    const allocator = std.testing.allocator;
    // Test percent encoding at the end of value
    var params = try QueryParser.parse(allocator, "/api/test?key=AB%43");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "ABC");
}

test "QueryParser parse - consecutive percent encodings" {
    const allocator = std.testing.allocator;
    // Test consecutive percent encodings
    var params = try QueryParser.parse(allocator, "/api/test?key=%41%42%43");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "ABC");
}

test "BodyParser formData - edge case empty key" {
    const allocator = std.testing.allocator;
    // Test edge case: empty key name in form data
    var params = try BodyParser.formData(allocator, "=value");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("").?, "value");
}

test "BodyParser formData - edge case multiple ampersands" {
    const allocator = std.testing.allocator;
    // Test edge case: multiple consecutive ampersands in form data
    var params = try BodyParser.formData(allocator, "key1=value1&&key2=value2&");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("key1").?, "value1");
    try std.testing.expectEqualStrings(params.get("key2").?, "value2");
}
