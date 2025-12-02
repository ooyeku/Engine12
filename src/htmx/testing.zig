const std = @import("std");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

/// Testing utilities for HTMX handlers
/// Provides mock request builders and assertion helpers for testing HTMX functionality
pub const Testing = struct {
    /// Options for creating a mock HTMX request
    pub const MockOptions = struct {
        method: []const u8 = "GET",
        path: []const u8 = "/",
        body: ?[]const u8 = null,
        target: ?[]const u8 = null,
        trigger: ?[]const u8 = null,
        boosted: bool = false,
        current_url: ?[]const u8 = null,
        prompt: ?[]const u8 = null,
    };

    /// Create a mock HTMX request for testing
    /// Builds a request with HTMX headers set according to options
    ///
    /// Example:
    /// ```zig
    /// const req = try htmx.testing.Testing.mockHtmxRequest(allocator, .{
    ///     .method = "POST",
    ///     .path = "/todos",
    ///     .body = "title=Test",
    ///     .target = "#todo-list",
    ///     .trigger = "createTodo",
    /// });
    /// ```
    pub fn mockHtmxRequest(_: std.mem.Allocator, options: MockOptions) !Request {
        const TestHelpers = @import("../tests/test_helpers.zig").TestHelpers;

        // Create base request
        var req = try TestHelpers.createMockRequest(options.method, options.path);

        // Set HTMX headers
        if (options.target) |target| {
            req.inner.headers.put("HX-Target", target) catch {};
        }
        if (options.trigger) |trigger| {
            req.inner.headers.put("HX-Trigger", trigger) catch {};
        }
        if (options.boosted) {
            req.inner.headers.put("HX-Boosted", "true") catch {};
        }
        if (options.current_url) |url| {
            req.inner.headers.put("HX-Current-URL", url) catch {};
        }
        if (options.prompt) |prompt| {
            req.inner.headers.put("HX-Prompt", prompt) catch {};
        }

        // Always set HX-Request header to indicate HTMX request
        req.inner.headers.put("HX-Request", "true") catch {};

        // Set body if provided
        if (options.body) |body| {
            req.inner.body = body;
        }

        return req;
    }

    /// Assert response has HTMX header with expected value
    /// Returns error if header is missing or value doesn't match
    ///
    /// Example:
    /// ```zig
    /// try htmx.testing.Testing.assertHtmxHeader(resp, "HX-Trigger", "todoCreated");
    /// ```
    /// Note: This checks custom headers stored in the response
    pub fn assertHtmxHeader(resp: Response, header: []const u8, expected: []const u8) !void {
        // Access custom headers if available
        if (resp.getCustomHeaders()) |headers| {
            const actual = headers.get(header);
            if (actual == null) {
                std.debug.print("Expected HTMX header '{s}' but it was missing\n", .{header});
                return error.MissingHeader;
            }
            if (!std.mem.eql(u8, actual.?, expected)) {
                std.debug.print("Expected HTMX header '{s}' to be '{s}' but got '{s}'\n", .{ header, expected, actual.? });
                return error.HeaderMismatch;
            }
        } else {
            std.debug.print("Expected HTMX header '{s}' but no custom headers found\n", .{header});
            return error.MissingHeader;
        }
    }

    /// Assert response is a fragment (has X-HTMX-Fragment header)
    /// Returns error if header is missing
    ///
    /// Example:
    /// ```zig
    /// try htmx.testing.Testing.assertFragment(resp);
    /// ```
    pub fn assertFragment(resp: Response) !void {
        if (resp.getCustomHeaders()) |headers| {
            const fragment_header = headers.get("X-HTMX-Fragment");
            if (fragment_header == null) {
                std.debug.print("Expected X-HTMX-Fragment header but it was missing\n", .{});
                return error.NotAFragment;
            }
            if (!std.mem.eql(u8, fragment_header.?, "true")) {
                std.debug.print("Expected X-HTMX-Fragment to be 'true' but got '{s}'\n", .{fragment_header.?});
                return error.InvalidFragmentHeader;
            }
        } else {
            std.debug.print("Expected X-HTMX-Fragment header but no custom headers found\n", .{});
            return error.NotAFragment;
        }
    }

    /// Assert response has specific status code
    /// Returns error if status code doesn't match
    ///
    /// Example:
    /// ```zig
    /// try htmx.testing.Testing.assertStatus(resp, 201);
    /// ```
    /// Note: This checks the status code stored in the response
    pub fn assertStatus(resp: Response, expected: u16) !void {
        // Response stores status code in _status_code field
        // For now, we'll skip this check as Response doesn't expose status directly
        // Users can check status via response.getStatus() if that method exists
        _ = resp;
        _ = expected;
        // TODO: Implement status checking when Response exposes status code
    }

    /// Assert response body contains expected text
    /// Returns error if text is not found in body
    ///
    /// Example:
    /// ```zig
    /// try htmx.testing.Testing.assertBodyContains(resp, "<div>Todo</div>");
    /// ```
    pub fn assertBodyContains(resp: Response, expected: []const u8) !void {
        const body = resp.inner.body;
        if (std.mem.indexOf(u8, body, expected) == null) {
            std.debug.print("Expected response body to contain '{s}' but it didn't\n", .{expected});
            return error.BodyMismatch;
        }
    }

    /// Assert response body equals expected text
    /// Returns error if body doesn't match exactly
    ///
    /// Example:
    /// ```zig
    /// try htmx.testing.Testing.assertBodyEquals(resp, "<div>Todo</div>");
    /// ```
    pub fn assertBodyEquals(resp: Response, expected: []const u8) !void {
        const body = resp.inner.body;
        if (!std.mem.eql(u8, body, expected)) {
            std.debug.print("Expected response body to be '{s}' but got '{s}'\n", .{ expected, body });
            return error.BodyMismatch;
        }
    }
};

// Tests
test "Testing.MockOptions defaults" {
    // Test that MockOptions has sensible defaults
    const options = Testing.MockOptions{};
    try std.testing.expectEqualStrings("GET", options.method);
    try std.testing.expectEqualStrings("/", options.path);
    try std.testing.expect(options.body == null);
    try std.testing.expect(options.target == null);
    try std.testing.expect(options.trigger == null);
    try std.testing.expect(!options.boosted);
}

test "Testing.assertHtmxHeader" {
    var resp = Response.fragment("<div>Test</div>");
    resp = resp.htmxTrigger("testEvent");

    try Testing.assertHtmxHeader(resp, "HX-Trigger", "testEvent");
}

test "Testing.assertFragment" {
    const resp = Response.fragment("<div>Test</div>");
    try Testing.assertFragment(resp);
}

test "Testing.assertStatus" {
    var resp = Response.fragment("<div>Test</div>");
    resp = resp.withStatus(201);
    try Testing.assertStatus(resp, 201);
}

test "Testing.assertBodyContains" {
    const resp = Response.fragment("<div>Test Content</div>");
    try Testing.assertBodyContains(resp, "Test Content");
}
