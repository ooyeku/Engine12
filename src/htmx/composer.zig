const std = @import("std");
const Response = @import("../http/response.zig").Response;

/// Response composer for combining multiple fragments with OOB swaps
pub const ResponseComposer = struct {
    allocator: std.mem.Allocator,
    primary_fragment: ?[]const u8 = null,
    oob_swaps: std.ArrayListUnmanaged(OobSwap) = .{},
    triggers: std.ArrayListUnmanaged([]const u8) = .{},
    headers: std.ArrayListUnmanaged(Header) = .{},
    status_code: u16 = 200,

    const OobSwap = struct {
        selector: []const u8,
        content: []const u8,
        swap_type: []const u8 = "innerHTML",
    };

    const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) ResponseComposer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ResponseComposer) void {
        self.oob_swaps.deinit(self.allocator);
        self.triggers.deinit(self.allocator);
        self.headers.deinit(self.allocator);
    }

    /// Set the primary fragment content
    pub fn fragment(self: *ResponseComposer, selector: []const u8, content: []const u8) *ResponseComposer {
        _ = selector;
        self.primary_fragment = content;
        return self;
    }

    /// Add an out-of-band swap
    pub fn oob(self: *ResponseComposer, selector: []const u8, content: []const u8) *ResponseComposer {
        self.oob_swaps.append(self.allocator, .{
            .selector = selector,
            .content = content,
        }) catch return self;
        return self;
    }

    /// Add an out-of-band swap with custom swap type
    pub fn oobWithSwap(self: *ResponseComposer, selector: []const u8, content: []const u8, swap_type: []const u8) *ResponseComposer {
        self.oob_swaps.append(self.allocator, .{
            .selector = selector,
            .content = content,
            .swap_type = swap_type,
        }) catch return self;
        return self;
    }

    /// Add a trigger event
    pub fn trigger(self: *ResponseComposer, event_name: []const u8) *ResponseComposer {
        self.triggers.append(self.allocator, event_name) catch return self;
        return self;
    }

    /// Add a custom header
    pub fn header(self: *ResponseComposer, name: []const u8, value: []const u8) *ResponseComposer {
        self.headers.append(self.allocator, .{
            .name = name,
            .value = value,
        }) catch return self;
        return self;
    }

    /// Set response status code
    pub fn status(self: *ResponseComposer, code: u16) *ResponseComposer {
        self.status_code = code;
        return self;
    }

    /// Build the final response
    pub fn build(self: *ResponseComposer) Response {
        var html = std.ArrayListUnmanaged(u8){};
        errdefer html.deinit(self.allocator);

        // Add primary fragment if exists
        if (self.primary_fragment) |primary| {
            html.appendSlice(self.allocator, primary) catch {};
        }

        // Add OOB swaps
        for (self.oob_swaps.items) |swap| {
            html.appendSlice(self.allocator, "\n") catch {};

            // Extract ID from selector (remove # or .)
            const id = if (std.mem.startsWith(u8, swap.selector, "#"))
                swap.selector[1..]
            else if (std.mem.startsWith(u8, swap.selector, "."))
                swap.selector[1..]
            else
                swap.selector;

            // Build OOB element
            if (std.mem.eql(u8, swap.swap_type, "innerHTML")) {
                html.appendSlice(self.allocator, "<div id=\"") catch {};
                html.appendSlice(self.allocator, id) catch {};
                html.appendSlice(self.allocator, "\" hx-swap-oob=\"innerHTML\">") catch {};
                html.appendSlice(self.allocator, swap.content) catch {};
                html.appendSlice(self.allocator, "</div>") catch {};
            } else if (std.mem.eql(u8, swap.swap_type, "outerHTML")) {
                html.appendSlice(self.allocator, "<div id=\"") catch {};
                html.appendSlice(self.allocator, id) catch {};
                html.appendSlice(self.allocator, "\" hx-swap-oob=\"outerHTML\">") catch {};
                html.appendSlice(self.allocator, swap.content) catch {};
                html.appendSlice(self.allocator, "</div>") catch {};
            } else {
                html.appendSlice(self.allocator, "<div id=\"") catch {};
                html.appendSlice(self.allocator, id) catch {};
                html.appendSlice(self.allocator, "\" hx-swap-oob=\"") catch {};
                html.appendSlice(self.allocator, swap.swap_type) catch {};
                html.appendSlice(self.allocator, "\">") catch {};
                html.appendSlice(self.allocator, swap.content) catch {};
                html.appendSlice(self.allocator, "</div>") catch {};
            }
        }

        const final_html = html.toOwnedSlice(self.allocator) catch "";
        var response = Response.fragment(final_html).withStatus(self.status_code);

        // Add triggers
        if (self.triggers.items.len > 0) {
            var trigger_buf = std.ArrayListUnmanaged(u8){};
            defer trigger_buf.deinit(self.allocator);

            for (self.triggers.items, 0..) |trig, i| {
                if (i > 0) trigger_buf.appendSlice(self.allocator, ", ") catch {};
                trigger_buf.appendSlice(self.allocator, trig) catch {};
            }

            const trigger_header = trigger_buf.toOwnedSlice(self.allocator) catch "";
            response = response.withHeader("HX-Trigger", trigger_header);
        }

        // Add custom headers
        for (self.headers.items) |hdr| {
            response = response.withHeader(hdr.name, hdr.value);
        }

        return response;
    }
};

/// Convenience function to create a response composer
pub fn compose(allocator: std.mem.Allocator) ResponseComposer {
    return ResponseComposer.init(allocator);
}

// Tests
test "response composer with primary fragment" {
    const allocator = std.heap.page_allocator;
    var comp = ResponseComposer.init(allocator);
    defer comp.deinit();

    _ = comp.fragment("#content", "<div>Primary Content</div>");
    const response = comp.build();

    try std.testing.expect(std.mem.indexOf(u8, response.getBody(), "Primary Content") != null);
}

test "response composer with OOB swaps" {
    const allocator = std.heap.page_allocator;
    var comp = ResponseComposer.init(allocator);
    defer comp.deinit();

    _ = comp.fragment("#main", "<div>Main</div>");
    _ = comp.oob("#stats", "<span>Stats</span>");
    _ = comp.oob("#notifications", "<div>Notification</div>");
    const response = comp.build();

    try std.testing.expect(std.mem.indexOf(u8, response.getBody(), "Main") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.getBody(), "hx-swap-oob") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.getBody(), "Stats") != null);
}

test "response composer with triggers" {
    const allocator = std.heap.page_allocator;
    var comp = ResponseComposer.init(allocator);
    defer comp.deinit();

    _ = comp.fragment("#content", "<div>Content</div>");
    _ = comp.trigger("dataUpdated");
    _ = comp.trigger("statsRefreshed");
    const response = comp.build();

    // Check that response was built successfully
    try std.testing.expect(response.getBody().len > 0);
}

test "response composer with status code" {
    const allocator = std.heap.page_allocator;
    var comp = ResponseComposer.init(allocator);
    defer comp.deinit();

    _ = comp.fragment("#content", "<div>Created</div>");
    _ = comp.status(201);
    const response = comp.build();

    try std.testing.expectEqual(@as(u16, 201), response._status_code.?);
}
