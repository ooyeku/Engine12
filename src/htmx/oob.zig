const std = @import("std");
const Response = @import("../http/response.zig").Response;
const Security = @import("security.zig").Security;

/// Out-of-Band (OOB) Swap builder for updating multiple elements in a single response.
///
/// HTMX OOB swaps allow you to update multiple parts of the page with a single response.
/// Each OOB element must have an `id` attribute and `hx-swap-oob="true"` (or a swap strategy).
///
/// Example usage:
/// ```zig
/// const response = OobSwapBuilder.init(allocator)
///     .primary("<li id=\"todo-1\">New Todo</li>")
///     .swap("#stats", "<div id=\"stats\">5 items</div>")
///     .swap("#notification", "<div id=\"notification\">Todo created!</div>")
///     .build();
/// ```
///
/// This generates:
/// ```html
/// <li id="todo-1">New Todo</li>
/// <div id="stats" hx-swap-oob="true">5 items</div>
/// <div id="notification" hx-swap-oob="true">Todo created!</div>
/// ```
pub const OobSwapBuilder = struct {
    allocator: std.mem.Allocator,
    fragments: std.ArrayListUnmanaged([]const u8),
    primary_html: ?[]const u8 = null,
    trigger_event: ?[]const u8 = null,
    status_code: u16 = 200,

    const Self = @This();

    /// Initialize a new OOB swap builder
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .fragments = std.ArrayListUnmanaged([]const u8){},
        };
    }

    /// Set the primary HTML content (the main response body, not OOB)
    pub fn primary(self: *Self, html: []const u8) *Self {
        self.primary_html = html;
        return self;
    }

    /// Add an OOB swap with default "true" strategy (replaces element with matching id)
    /// The html must contain an element with an id attribute.
    pub fn swap(self: *Self, selector: []const u8, html: []const u8) *Self {
        return self.swapWithStrategy(selector, html, "true");
    }

    /// Add an OOB swap with a specific swap strategy
    /// Strategies: "true", "innerHTML", "outerHTML", "beforebegin", "afterbegin", "beforeend", "afterend", "delete", "none"
    pub fn swapWithStrategy(self: *Self, selector: []const u8, html: []const u8, strategy: []const u8) *Self {
        // Validate selector for security
        if (!Security.validateSelector(selector)) {
            return self;
        }

        // Build the OOB fragment with hx-swap-oob attribute
        const oob_html = self.buildOobFragment(selector, html, strategy) catch {
            return self;
        };

        self.fragments.append(self.allocator, oob_html) catch {};
        return self;
    }

    /// Add an OOB swap that uses innerHTML strategy
    pub fn swapInner(self: *Self, selector: []const u8, html: []const u8) *Self {
        return self.swapWithStrategy(selector, html, "innerHTML");
    }

    /// Add an OOB swap that uses outerHTML strategy (replaces entire element)
    pub fn swapOuter(self: *Self, selector: []const u8, html: []const u8) *Self {
        return self.swapWithStrategy(selector, html, "outerHTML");
    }

    /// Add an OOB swap that prepends content
    pub fn swapPrepend(self: *Self, selector: []const u8, html: []const u8) *Self {
        return self.swapWithStrategy(selector, html, "afterbegin");
    }

    /// Add an OOB swap that appends content
    pub fn swapAppend(self: *Self, selector: []const u8, html: []const u8) *Self {
        return self.swapWithStrategy(selector, html, "beforeend");
    }

    /// Add an OOB swap that deletes the target element
    pub fn swapDelete(self: *Self, selector: []const u8) *Self {
        const id = if (std.mem.startsWith(u8, selector, "#")) selector[1..] else selector;
        const delete_html = std.fmt.allocPrint(self.allocator, "<div id=\"{s}\" hx-swap-oob=\"delete\"></div>", .{id}) catch {
            return self;
        };
        self.fragments.append(self.allocator, delete_html) catch {};
        return self;
    }

    /// Set a trigger event for the response
    pub fn trigger(self: *Self, event: []const u8) *Self {
        self.trigger_event = event;
        return self;
    }

    /// Set the HTTP status code
    pub fn status(self: *Self, code: u16) *Self {
        self.status_code = code;
        return self;
    }

    /// Build the final response with all OOB swaps combined
    pub fn build(self: *Self) Response {
        var total_len: usize = 0;

        // Calculate total length
        if (self.primary_html) |p| {
            total_len += p.len;
        }
        for (self.fragments.items) |fragment| {
            total_len += fragment.len + 1; // +1 for newline
        }

        // Allocate and build combined HTML
        const combined = self.allocator.alloc(u8, total_len) catch {
            return Response.serverError("Failed to allocate OOB response");
        };

        var offset: usize = 0;

        // Add primary content first
        if (self.primary_html) |p| {
            @memcpy(combined[offset .. offset + p.len], p);
            offset += p.len;
        }

        // Add OOB fragments
        for (self.fragments.items) |fragment| {
            if (offset > 0 and offset < combined.len) {
                combined[offset] = '\n';
                offset += 1;
            }
            if (offset + fragment.len <= combined.len) {
                @memcpy(combined[offset .. offset + fragment.len], fragment);
                offset += fragment.len;
            }
        }

        var resp = Response.fragment(combined[0..offset]);

        if (self.trigger_event) |event| {
            resp = resp.htmxTrigger(event);
        }

        if (self.status_code != 200) {
            resp = resp.withStatus(self.status_code);
        }

        return resp;
    }

    /// Free all allocated memory
    pub fn deinit(self: *Self) void {
        for (self.fragments.items) |fragment| {
            self.allocator.free(fragment);
        }
        self.fragments.deinit(self.allocator);
    }

    // Internal helper to build an OOB fragment
    fn buildOobFragment(self: *Self, selector: []const u8, html: []const u8, strategy: []const u8) ![]const u8 {
        // Extract id from selector (remove # prefix if present)
        const id = if (std.mem.startsWith(u8, selector, "#")) selector[1..] else selector;

        // Check if html already has an id - if so, just add hx-swap-oob
        if (std.mem.indexOf(u8, html, "id=")) |_| {
            // HTML already has an id, inject hx-swap-oob attribute
            return try self.injectOobAttribute(html, strategy);
        }

        // Wrap content in a div with the id and hx-swap-oob
        return try std.fmt.allocPrint(
            self.allocator,
            "<div id=\"{s}\" hx-swap-oob=\"{s}\">{s}</div>",
            .{ id, strategy, html },
        );
    }

    // Inject hx-swap-oob attribute into existing HTML
    fn injectOobAttribute(self: *Self, html: []const u8, strategy: []const u8) ![]const u8 {
        // Find the first > after an opening tag
        const first_gt = std.mem.indexOf(u8, html, ">") orelse return html;

        // Insert hx-swap-oob before the >
        return try std.fmt.allocPrint(
            self.allocator,
            "{s} hx-swap-oob=\"{s}\"{s}",
            .{ html[0..first_gt], strategy, html[first_gt..] },
        );
    }
};

/// Convenience function to create a simple OOB response with one primary and one OOB swap
pub fn oobSwap(allocator: std.mem.Allocator, primary_html: []const u8, oob_selector: []const u8, oob_html: []const u8) Response {
    var builder = OobSwapBuilder.init(allocator);
    defer builder.deinit();
    return builder.primary(primary_html).swap(oob_selector, oob_html).build();
}

/// Convenience function to update multiple elements without a primary response
pub fn oobMultiple(allocator: std.mem.Allocator, swaps: []const struct { selector: []const u8, html: []const u8 }) Response {
    var builder = OobSwapBuilder.init(allocator);
    defer builder.deinit();
    for (swaps) |s| {
        _ = builder.swap(s.selector, s.html);
    }
    return builder.build();
}

// ============================================================================
// Tests
// ============================================================================

test "OobSwapBuilder basic usage" {
    // Use page_allocator since Response.fragment() uses persistent allocation
    const allocator = std.heap.page_allocator;
    var builder = OobSwapBuilder.init(allocator);
    defer builder.deinit();

    _ = builder.primary("<li>New Item</li>").swap("#stats", "5 items");

    const resp = builder.build();
    const body = resp.getBody();

    try std.testing.expect(body.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body, "<li>New Item</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "hx-swap-oob") != null);
}

test "OobSwapBuilder multiple swaps" {
    // Use page_allocator since Response.fragment() uses persistent allocation
    const allocator = std.heap.page_allocator;
    var builder = OobSwapBuilder.init(allocator);
    defer builder.deinit();

    _ = builder
        .primary("<div>Primary</div>")
        .swap("#stats", "Stats content")
        .swap("#notifications", "Notification content")
        .swap("#sidebar", "Sidebar content");

    const resp = builder.build();
    const body = resp.getBody();

    try std.testing.expect(std.mem.indexOf(u8, body, "Primary") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "stats") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "notifications") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "sidebar") != null);
}

test "OobSwapBuilder with trigger" {
    // Use page_allocator since Response.fragment() uses persistent allocation
    const allocator = std.heap.page_allocator;
    var builder = OobSwapBuilder.init(allocator);
    defer builder.deinit();

    _ = builder.primary("<div>Content</div>").trigger("itemCreated");

    const resp = builder.build();
    const headers = resp.getCustomHeaders() orelse return error.NoHeaders;

    try std.testing.expect(headers.get("HX-Trigger") != null);
    try std.testing.expectEqualStrings("itemCreated", headers.get("HX-Trigger").?);
}

test "OobSwapBuilder with status" {
    // Use page_allocator since Response.fragment() uses persistent allocation
    const allocator = std.heap.page_allocator;
    var builder = OobSwapBuilder.init(allocator);
    defer builder.deinit();

    _ = builder.primary("<div>Created</div>").status(201);

    const resp = builder.build();
    try std.testing.expect(resp.getBody().len > 0);
}

test "OobSwapBuilder swap strategies" {
    // Use page_allocator since Response.fragment() uses persistent allocation
    const allocator = std.heap.page_allocator;
    var builder = OobSwapBuilder.init(allocator);
    defer builder.deinit();

    _ = builder
        .swapInner("#inner", "Inner content")
        .swapOuter("#outer", "Outer content")
        .swapPrepend("#prepend", "Prepend content")
        .swapAppend("#append", "Append content");

    const resp = builder.build();
    const body = resp.getBody();

    try std.testing.expect(std.mem.indexOf(u8, body, "innerHTML") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "outerHTML") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "afterbegin") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "beforeend") != null);
}

test "OobSwapBuilder delete" {
    // Use page_allocator since Response.fragment() uses persistent allocation
    const allocator = std.heap.page_allocator;
    var builder = OobSwapBuilder.init(allocator);
    defer builder.deinit();

    _ = builder.swapDelete("#to-delete");

    const resp = builder.build();
    const body = resp.getBody();

    try std.testing.expect(std.mem.indexOf(u8, body, "to-delete") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "delete") != null);
}

test "OobSwapBuilder selector without hash" {
    // Use page_allocator since Response.fragment() uses persistent allocation
    const allocator = std.heap.page_allocator;
    var builder = OobSwapBuilder.init(allocator);
    defer builder.deinit();

    _ = builder.swap("stats", "Content");

    const resp = builder.build();
    const body = resp.getBody();

    try std.testing.expect(std.mem.indexOf(u8, body, "id=\"stats\"") != null);
}

test "oobSwap convenience function" {
    // Use page_allocator since Response uses persistent allocation internally
    const allocator = std.heap.page_allocator;
    const resp = oobSwap(
        allocator,
        "<li>New</li>",
        "#count",
        "10",
    );

    const body = resp.getBody();
    try std.testing.expect(std.mem.indexOf(u8, body, "<li>New</li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "count") != null);
}
