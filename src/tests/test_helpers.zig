const std = @import("std");
const engine12 = @import("../engine12.zig");
const Engine12 = engine12.Engine12;
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const types = @import("../types.zig");

pub const TestHelpers = struct {
    const allocator = std.testing.allocator;

    pub fn createTestApp() !Engine12 {
        return Engine12.initTesting();
    }

    pub fn createMockRequest(method: []const u8, path: []const u8) !Request {
        const ziggurat = @import("ziggurat");
        const method_enum = if (std.mem.eql(u8, method, "GET")) ziggurat.request.Method.GET else if (std.mem.eql(u8, method, "POST")) ziggurat.request.Method.POST else if (std.mem.eql(u8, method, "PUT")) ziggurat.request.Method.PUT else if (std.mem.eql(u8, method, "DELETE")) ziggurat.request.Method.DELETE else if (std.mem.eql(u8, method, "PATCH")) ziggurat.request.Method.PATCH else ziggurat.request.Method.GET;

        const headers = std.StringHashMap([]const u8).init(allocator);
        const user_data = std.StringHashMap([]const u8).init(allocator);
        var ziggurat_req = ziggurat.request.Request{
            .path = path,
            .method = method_enum,
            .body = "",
            .headers = headers,
            .allocator = allocator,
            .user_data = user_data,
        };
        return Request.fromZiggurat(&ziggurat_req, allocator);
    }

    pub fn createMockRequestWithBody(method: []const u8, path: []const u8, body: []const u8) !Request {
        const ziggurat = @import("ziggurat");
        const method_enum = if (std.mem.eql(u8, method, "GET")) ziggurat.request.Method.GET else if (std.mem.eql(u8, method, "POST")) ziggurat.request.Method.POST else if (std.mem.eql(u8, method, "PUT")) ziggurat.request.Method.PUT else if (std.mem.eql(u8, method, "DELETE")) ziggurat.request.Method.DELETE else if (std.mem.eql(u8, method, "PATCH")) ziggurat.request.Method.PATCH else ziggurat.request.Method.GET;

        const headers = std.StringHashMap([]const u8).init(allocator);
        const user_data = std.StringHashMap([]const u8).init(allocator);
        var ziggurat_req = ziggurat.request.Request{
            .path = path,
            .method = method_enum,
            .body = body,
            .headers = headers,
            .allocator = allocator,
            .user_data = user_data,
        };
        return Request.fromZiggurat(&ziggurat_req, allocator);
    }

    pub fn createTestDbPath() ![]const u8 {
        const test_db = "test.db";
        std.fs.cwd().deleteFile(test_db) catch {};
        return test_db;
    }

    pub fn cleanupTestDb(path: []const u8) void {
        std.fs.cwd().deleteFile(path) catch {};
    }

    pub fn assertStatus(resp: Response, expected: u16) !void {
        if (resp._status_code) |status| {
            if (status != expected) {
                std.debug.print("Expected status {d}, got {d}\n", .{ expected, status });
                return error.TestExpectedEqual;
            }
            return;
        }
        const ziggurat_resp = resp.toZiggurat();
        const actual = @intFromEnum(ziggurat_resp.status);
        if (actual != expected) {
            std.debug.print("Expected status {d}, got {d}\n", .{ expected, actual });
            return error.TestExpectedEqual;
        }
    }

    pub fn assertBodyContains(resp: Response, text: []const u8) !void {
        const ziggurat_resp = resp.toZiggurat();
        const body = ziggurat_resp.body;
        if (std.mem.indexOf(u8, body, text) == null) {
            std.debug.print("Response body does not contain '{s}'\n", .{text});
            std.debug.print("Body: {s}\n", .{body});
            return error.TestExpectedEqual;
        }
    }

    pub fn assertJsonContains(resp: Response, key: []const u8) !void {
        const ziggurat_resp = resp.toZiggurat();
        const body = ziggurat_resp.body;
        const key_pattern = try std.fmt.allocPrint(allocator, "\"{s}\"", .{key});
        defer allocator.free(key_pattern);
        if (std.mem.indexOf(u8, body, key_pattern) == null) {
            std.debug.print("Response JSON does not contain key '{s}'\n", .{key});
            return error.TestExpectedEqual;
        }
    }

    pub fn dummyHandler(_: *Request) Response {
        return Response.text("OK");
    }

    pub fn dummyJsonHandler(_: *Request) Response {
        return Response.json("{\"status\":\"ok\"}");
    }

    pub fn dummyStatusHandler(_: *Request) Response {
        return Response.text("").withStatus(200);
    }
};

test "createTestApp" {
    var app = try TestHelpers.createTestApp();
    defer app.deinit();
    try std.testing.expectEqual(app.profile.environment, types.Environment.staging);
}

test "createMockRequest" {
    var req = try TestHelpers.createMockRequest("GET", "/test");
    defer req.deinit();
    try std.testing.expectEqualStrings(req.path(), "/test");
    try std.testing.expectEqualStrings(req.method(), "GET");
}

test "createMockRequestWithBody" {
    var req = try TestHelpers.createMockRequestWithBody("POST", "/test", "{\"key\":\"value\"}");
    defer req.deinit();
    try std.testing.expectEqualStrings(req.body(), "{\"key\":\"value\"}");
}

test "assertStatus" {
    const resp = Response.text("").withStatus(200);
    try TestHelpers.assertStatus(resp, 200);
}

test "assertBodyContains" {
    const resp = Response.text("Hello World");
    try TestHelpers.assertBodyContains(resp, "Hello");
}
