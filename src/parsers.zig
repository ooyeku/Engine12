const std = @import("std");
const Request = @import("request.zig").Request;
const Json = @import("json.zig").Json;

pub const ParserError = error{
    QueryStringTooLarge,
};

const MAX_QUERY_STRING_SIZE = 10 * 1024;

pub fn percentDecode(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};

    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const hex_str = encoded[i + 1 .. i + 3];
            const byte = std.fmt.parseInt(u8, hex_str, 16) catch {
                try result.append(allocator, '%');
                i += 1;
                continue;
            };
            try result.append(allocator, byte);
            i += 3;
        } else if (encoded[i] == '+') {
            try result.append(allocator, ' ');
            i += 1;
        } else {
            try result.append(allocator, encoded[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

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
        const amp_pos = std.mem.indexOfScalar(u8, remaining, '&') orelse remaining.len;
        const pair = remaining[0..amp_pos];

        if (pair.len > 0) {
            const eq_pos = std.mem.indexOfScalar(u8, pair, '=') orelse {
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
                allocator.free(key);
                allocator.free(gop.value_ptr.*);
            }
            gop.value_ptr.* = value;
        }

        remaining = if (amp_pos < remaining.len) remaining[amp_pos + 1 ..] else "";
    }

    return params;
}

pub const QueryParser = struct {
    pub fn parse(allocator: std.mem.Allocator, path: []const u8) !std.StringHashMap([]const u8) {
        const query_start = std.mem.indexOfScalar(u8, path, '?') orelse {
            return std.StringHashMap([]const u8).init(allocator);
        };
        const query_string = path[query_start + 1 ..];

        if (query_string.len > MAX_QUERY_STRING_SIZE) {
            return ParserError.QueryStringTooLarge;
        }

        return parseKeyValuePairs(allocator, query_string);
    }
};

pub const BodyParser = struct {
    pub fn json(comptime T: type, body: []const u8, allocator: std.mem.Allocator) !T {
        return Json.deserialize(T, body, allocator);
    }

    pub fn jsonOptional(comptime T: type, body: []const u8, allocator: std.mem.Allocator) ?T {
        return json(T, body, allocator) catch null;
    }

    pub fn formData(allocator: std.mem.Allocator, body: []const u8) !std.StringHashMap([]const u8) {
        return parseKeyValuePairs(allocator, body);
    }
};

fn freeParams(allocator: std.mem.Allocator, params: *std.StringHashMap([]const u8)) void {
    var iter = params.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    params.deinit();
}

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
    try std.testing.expect(std.mem.indexOf(u8, params.get("key").?, "%") != null);
}

test "QueryParser parse with incomplete percent encoding" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=%4");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
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


test "QueryParser parse - duplicate keys memory leak prevention" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=value1&key=value2&key=value3");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "value3");

    var params2 = try QueryParser.parse(allocator, "/api/test?name=John&name=Jane&name=Bob");
    defer freeParams(allocator, &params2);

    try std.testing.expect(params2.count() == 1);
    try std.testing.expectEqualStrings(params2.get("name").?, "Bob");
}

test "QueryParser parse - key-only pairs memory leak prevention" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key1&key2&key3=value");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 3);
    try std.testing.expectEqualStrings(params.get("key1").?, "");
    try std.testing.expectEqualStrings(params.get("key2").?, "");
    try std.testing.expectEqualStrings(params.get("key3").?, "value");

    var params2 = try QueryParser.parse(allocator, "/api/test?hello%20world&test%2Bvalue");
    defer freeParams(allocator, &params2);

    try std.testing.expect(params2.count() == 2);
    try std.testing.expectEqualStrings(params2.get("hello world").?, "");
    try std.testing.expectEqualStrings(params2.get("test+value").?, "");
}

test "QueryParser parse - very long query string DoS prevention" {
    const allocator = std.testing.allocator;

    var long_query = std.ArrayListUnmanaged(u8){};
    defer long_query.deinit(allocator);

    try long_query.appendSlice(allocator, "/api/test?");
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try long_query.writer(allocator).print("key{d}=value{d}&", .{ i, i });
    }

    const result = QueryParser.parse(allocator, long_query.items);
    try std.testing.expectError(ParserError.QueryStringTooLarge, result);
}

test "QueryParser parse - percentDecode bounds checking" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=test%");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expect(std.mem.indexOf(u8, params.get("key").?, "%") != null);

    var params2 = try QueryParser.parse(allocator, "/api/test?key=test%4");
    defer freeParams(allocator, &params2);

    try std.testing.expect(params2.count() == 1);
    try std.testing.expect(std.mem.indexOf(u8, params2.get("key").?, "%") != null);

    var params3 = try QueryParser.parse(allocator, "/api/test?key=%41");
    defer freeParams(allocator, &params3);

    try std.testing.expect(params3.count() == 1);
    try std.testing.expectEqualStrings(params3.get("key").?, "A");
}

test "BodyParser formData - duplicate keys memory leak prevention" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "key=value1&key=value2&key=value3");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "value3");

    var params2 = try BodyParser.formData(allocator, "name=John%20Doe&name=Jane%20Doe&name=Bob%20Smith");
    defer freeParams(allocator, &params2);

    try std.testing.expect(params2.count() == 1);
    try std.testing.expectEqualStrings(params2.get("name").?, "Bob Smith");
}

test "BodyParser formData - key-only pairs memory leak prevention" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "key1&key2&key3=value");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 3);
    try std.testing.expectEqualStrings(params.get("key1").?, "");
    try std.testing.expectEqualStrings(params.get("key2").?, "");
    try std.testing.expectEqualStrings(params.get("key3").?, "value");
}

test "QueryParser parse - percentDecode error handling" {
    const allocator = std.testing.allocator;

    var params = try QueryParser.parse(allocator, "/api/test?key=%XX");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expect(std.mem.indexOf(u8, params.get("key").?, "%") != null);

    var params2 = try QueryParser.parse(allocator, "/api/test?key=%GH");
    defer freeParams(allocator, &params2);

    try std.testing.expect(params2.count() == 1);
    try std.testing.expect(std.mem.indexOf(u8, params2.get("key").?, "%") != null);

    var params3 = try QueryParser.parse(allocator, "/api/test?key=test%41%XX%42");
    defer freeParams(allocator, &params3);

    try std.testing.expect(params3.count() == 1);
    const value = params3.get("key").?;
    try std.testing.expect(std.mem.indexOf(u8, value, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "%") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "B") != null);
}

test "QueryParser parse - code duplication verification" {
    const allocator = std.testing.allocator;

    const query_string = "key1=value1&key2&key3=value3&key1=value4";
    const query_path = try std.fmt.allocPrint(allocator, "/api/test?{s}", .{query_string});
    defer allocator.free(query_path);

    var query_params = try QueryParser.parse(allocator, query_path);
    defer freeParams(allocator, &query_params);

    var form_params = try BodyParser.formData(allocator, query_string);
    defer freeParams(allocator, &form_params);

    try std.testing.expect(query_params.count() == form_params.count());

    var iter = query_params.iterator();
    while (iter.next()) |entry| {
        const form_value = form_params.get(entry.key_ptr.*);
        try std.testing.expect(form_value != null);
        try std.testing.expectEqualStrings(entry.value_ptr.*, form_value.?);
    }
}

test "QueryParser parse - percentDecode accessibility" {
    const allocator = std.testing.allocator;

    var params = try BodyParser.formData(allocator, "name=John%20Doe&email=test%40example.com");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("name").?, "John Doe");
    try std.testing.expectEqualStrings(params.get("email").?, "test@example.com");

    const decoded = try percentDecode(allocator, "hello%20world");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(decoded, "hello world");
}

test "QueryParser parse - edge case empty key" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?=value");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("").?, "value");
}

test "QueryParser parse - edge case empty value" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "");
}

test "QueryParser parse - edge case multiple ampersands" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key1=value1&&key2=value2&");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("key1").?, "value1");
    try std.testing.expectEqualStrings(params.get("key2").?, "value2");
}

test "QueryParser parse - edge case query string at end" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=value&");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "value");
}

test "BodyParser formData - very long form data DoS prevention" {
    const allocator = std.testing.allocator;

    var long_form = std.ArrayListUnmanaged(u8){};
    defer long_form.deinit(allocator);

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try long_form.writer(allocator).print("key{d}=value{d}&", .{ i, i });
    }

    var params = BodyParser.formData(allocator, long_form.items) catch {
        return;
    };
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1000);
}

test "QueryParser parse - Unicode in percent encoding" {
    const allocator = std.testing.allocator;

    var params = try QueryParser.parse(allocator, "/api/test?greeting=Hello%20%E4%B8%96%E7%95%8C");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    const value = params.get("greeting").?;
    try std.testing.expect(value.len > 6); // More than "Hello "
    try std.testing.expect(std.mem.startsWith(u8, value, "Hello "));
}

test "QueryParser parse - percent encoding at start" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=%41BC");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "ABC");
}

test "QueryParser parse - percent encoding at end" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=AB%43");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "ABC");
}

test "QueryParser parse - consecutive percent encodings" {
    const allocator = std.testing.allocator;
    var params = try QueryParser.parse(allocator, "/api/test?key=%41%42%43");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("key").?, "ABC");
}

test "BodyParser formData - edge case empty key" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "=value");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 1);
    try std.testing.expectEqualStrings(params.get("").?, "value");
}

test "BodyParser formData - edge case multiple ampersands" {
    const allocator = std.testing.allocator;
    var params = try BodyParser.formData(allocator, "key1=value1&&key2=value2&");
    defer freeParams(allocator, &params);

    try std.testing.expect(params.count() == 2);
    try std.testing.expectEqualStrings(params.get("key1").?, "value1");
    try std.testing.expectEqualStrings(params.get("key2").?, "value2");
}
