const std = @import("std");
const Response = @import("../http/response.zig").Response;

/// Server-Sent Events (SSE) helper for real-time updates with HTMX.
///
/// SSE allows the server to push updates to the client without polling.
/// HTMX supports SSE natively with the `hx-sse` attribute.
///
/// Example handler:
/// ```zig
/// pub fn handleSSE(request: *Request) Response {
///     const sse = SSE.init(allocator);
///     return sse.response();
/// }
/// ```
///
/// Example HTML:
/// ```html
/// <div hx-sse="connect:/api/events">
///     <div hx-sse="swap:message"></div>
/// </div>
/// ```
/// SSE Event structure
pub const Event = struct {
    event: ?[]const u8 = null,
    data: []const u8,
    id: ?[]const u8 = null,
    retry: ?u32 = null,

    /// Format the event as SSE protocol text
    pub fn format(self: Event, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(allocator);

        // Event type (optional)
        if (self.event) |e| {
            try result.appendSlice(allocator, "event: ");
            try result.appendSlice(allocator, e);
            try result.append(allocator, '\n');
        }

        // Event ID (optional)
        if (self.id) |i| {
            try result.appendSlice(allocator, "id: ");
            try result.appendSlice(allocator, i);
            try result.append(allocator, '\n');
        }

        // Retry interval (optional)
        if (self.retry) |r| {
            const retry_str = try std.fmt.allocPrint(allocator, "retry: {d}\n", .{r});
            defer allocator.free(retry_str);
            try result.appendSlice(allocator, retry_str);
        }

        // Data (required, can be multi-line)
        var lines = std.mem.splitScalar(u8, self.data, '\n');
        while (lines.next()) |line| {
            try result.appendSlice(allocator, "data: ");
            try result.appendSlice(allocator, line);
            try result.append(allocator, '\n');
        }

        // End of event
        try result.append(allocator, '\n');

        return result.toOwnedSlice(allocator);
    }
};

/// SSE stream builder for sending multiple events
pub const SSEStream = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged([]const u8),
    retry_ms: ?u32 = null,

    const Self = @This();

    /// Initialize a new SSE stream
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .events = std.ArrayListUnmanaged([]const u8){},
        };
    }

    /// Set the default retry interval for reconnection
    pub fn setRetry(self: *Self, ms: u32) *Self {
        self.retry_ms = ms;
        return self;
    }

    /// Add a simple message event
    pub fn message(self: *Self, data: []const u8) *Self {
        return self.event("message", data);
    }

    /// Add a named event
    pub fn event(self: *Self, event_name: []const u8, data: []const u8) *Self {
        const e = Event{
            .event = event_name,
            .data = data,
            .retry = self.retry_ms,
        };
        const formatted = e.format(self.allocator) catch return self;
        self.events.append(self.allocator, formatted) catch {};
        return self;
    }

    /// Add an event with ID
    pub fn eventWithId(self: *Self, event_name: []const u8, data: []const u8, id: []const u8) *Self {
        const e = Event{
            .event = event_name,
            .data = data,
            .id = id,
            .retry = self.retry_ms,
        };
        const formatted = e.format(self.allocator) catch return self;
        self.events.append(self.allocator, formatted) catch {};
        return self;
    }

    /// Add raw event data
    pub fn raw(self: *Self, data: []const u8) *Self {
        const e = Event{ .data = data };
        const formatted = e.format(self.allocator) catch return self;
        self.events.append(self.allocator, formatted) catch {};
        return self;
    }

    /// Add an HTMX fragment event (for use with hx-sse="swap:eventName")
    pub fn fragment(self: *Self, event_name: []const u8, html: []const u8) *Self {
        return self.event(event_name, html);
    }

    /// Send a keep-alive comment
    pub fn keepAlive(self: *Self) *Self {
        const comment = self.allocator.dupe(u8, ": keepalive\n\n") catch return self;
        self.events.append(self.allocator, comment) catch {};
        return self;
    }

    /// Build the complete SSE response body
    pub fn build(self: *Self) []const u8 {
        var total_len: usize = 0;
        for (self.events.items) |e| {
            total_len += e.len;
        }

        const result = self.allocator.alloc(u8, total_len) catch return "";
        var offset: usize = 0;

        for (self.events.items) |e| {
            @memcpy(result[offset .. offset + e.len], e);
            offset += e.len;
        }

        return result;
    }

    /// Build and return as an SSE Response
    pub fn response(self: *Self) Response {
        const body = self.build();
        return Response.sse(body);
    }

    /// Free all allocated memory
    pub fn deinit(self: *Self) void {
        for (self.events.items) |e| {
            self.allocator.free(e);
        }
        self.events.deinit(self.allocator);
    }
};

/// Convenience function to create a single SSE event response
pub fn sseEvent(allocator: std.mem.Allocator, event_name: []const u8, data: []const u8) Response {
    var stream = SSEStream.init(allocator);
    defer stream.deinit();
    return stream.event(event_name, data).response();
}

/// Convenience function to create a simple message event response
pub fn sseMessage(allocator: std.mem.Allocator, data: []const u8) Response {
    var stream = SSEStream.init(allocator);
    defer stream.deinit();
    return stream.message(data).response();
}

/// Convenience function to create an HTMX fragment event response
pub fn sseFragment(allocator: std.mem.Allocator, event_name: []const u8, html: []const u8) Response {
    return sseEvent(allocator, event_name, html);
}

// ============================================================================
// HTMX SSE Attribute Builders
// ============================================================================

/// Build an hx-sse attribute value for connecting to an SSE endpoint
pub fn connectAttribute(url: []const u8) []const u8 {
    // Returns format: "connect:/api/events"
    _ = url;
    return "connect:";
}

/// Generate an SSE-enabled element with HTMX attributes
pub fn sseContainer(allocator: std.mem.Allocator, url: []const u8, inner_html: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<div hx-ext="sse" sse-connect="{s}">
        \\  {s}
        \\</div>
    , .{ url, inner_html });
}

/// Generate an SSE swap target element
pub fn sseSwapTarget(allocator: std.mem.Allocator, event_name: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<div id="{s}" sse-swap="{s}"></div>
    , .{ id, event_name });
}

/// SSE target definition
pub const SseTarget = struct {
    event: []const u8,
    id: []const u8,
};

/// Generate a complete SSE container with multiple swap targets
pub fn sseContainerWithTargets(
    allocator: std.mem.Allocator,
    url: []const u8,
    targets: []const SseTarget,
) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    const header = try std.fmt.allocPrint(allocator, "<div hx-ext=\"sse\" sse-connect=\"{s}\">\n", .{url});
    defer allocator.free(header);
    try result.appendSlice(allocator, header);

    for (targets) |t| {
        const target = try sseSwapTarget(allocator, t.event, t.id);
        defer allocator.free(target);
        try result.appendSlice(allocator, "  ");
        try result.appendSlice(allocator, target);
        try result.append(allocator, '\n');
    }

    try result.appendSlice(allocator, "</div>");

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "Event format basic" {
    const allocator = std.testing.allocator;
    const e = Event{ .data = "Hello, World!" };
    const formatted = try e.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "data: Hello, World!") != null);
    try std.testing.expect(std.mem.endsWith(u8, formatted, "\n\n"));
}

test "Event format with event type" {
    const allocator = std.testing.allocator;
    const e = Event{
        .event = "update",
        .data = "New data",
    };
    const formatted = try e.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "event: update") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "data: New data") != null);
}

test "Event format with id" {
    const allocator = std.testing.allocator;
    const e = Event{
        .event = "message",
        .data = "Content",
        .id = "123",
    };
    const formatted = try e.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "id: 123") != null);
}

test "Event format with retry" {
    const allocator = std.testing.allocator;
    const e = Event{
        .data = "Content",
        .retry = 5000,
    };
    const formatted = try e.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "retry: 5000") != null);
}

test "Event format multiline data" {
    const allocator = std.testing.allocator;
    const e = Event{ .data = "Line 1\nLine 2\nLine 3" };
    const formatted = try e.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "data: Line 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "data: Line 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "data: Line 3") != null);
}

test "SSEStream basic usage" {
    const allocator = std.testing.allocator;
    var stream = SSEStream.init(allocator);
    defer stream.deinit();

    _ = stream.message("Hello").event("update", "New content");

    const body = stream.build();
    defer allocator.free(body);

    try std.testing.expect(body.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body, "event: message") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "event: update") != null);
}

test "SSEStream with retry" {
    const allocator = std.testing.allocator;
    var stream = SSEStream.init(allocator);
    defer stream.deinit();

    _ = stream.setRetry(3000).message("Test");

    const body = stream.build();
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "retry: 3000") != null);
}

test "SSEStream keep alive" {
    const allocator = std.testing.allocator;
    var stream = SSEStream.init(allocator);
    defer stream.deinit();

    _ = stream.keepAlive();

    const body = stream.build();
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, ": keepalive") != null);
}

test "SSEStream fragment" {
    const allocator = std.testing.allocator;
    var stream = SSEStream.init(allocator);
    defer stream.deinit();

    _ = stream.fragment("todoUpdate", "<li>New Todo</li>");

    const body = stream.build();
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "event: todoUpdate") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<li>New Todo</li>") != null);
}

test "sseContainer" {
    const allocator = std.testing.allocator;
    const html = try sseContainer(allocator, "/api/events", "<div>Content</div>");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "sse-connect=\"/api/events\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hx-ext=\"sse\"") != null);
}

test "sseSwapTarget" {
    const allocator = std.testing.allocator;
    const html = try sseSwapTarget(allocator, "todoUpdate", "todo-list");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "sse-swap=\"todoUpdate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"todo-list\"") != null);
}

test "sseContainerWithTargets" {
    const allocator = std.testing.allocator;
    const targets = [_]SseTarget{
        .{ .event = "todos", .id = "todo-list" },
        .{ .event = "stats", .id = "stats-panel" },
    };
    const html = try sseContainerWithTargets(allocator, "/api/events", &targets);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "/api/events") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "todo-list") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "stats-panel") != null);
}
