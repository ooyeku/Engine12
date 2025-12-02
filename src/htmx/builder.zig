const std = @import("std");
const Response = @import("../response.zig").Response;

/// Fluent response builder for HTMX responses
/// Provides a cleaner API for chaining HTMX response methods
///
/// Example:
/// ```zig
/// // Old way (still works):
/// return Response.fragment(html)
///     .htmxTrigger("todoCreated")
///     .htmxTarget("#todo-list")
///     .htmxSwap("beforeend");
///
/// // New fluent way (optional):
/// return HtmxResponseBuilder.init(html)
///     .trigger("todoCreated")
///     .target("#todo-list")
///     .swap("beforeend")
///     .build();
/// ```
pub const HtmxResponseBuilder = struct {
    resp: Response,

    /// Initialize builder with HTML fragment
    pub fn init(html: []const u8) HtmxResponseBuilder {
        return .{ .resp = Response.fragment(html) };
    }

    /// Initialize builder from existing response
    pub fn fromResponse(resp: Response) HtmxResponseBuilder {
        return .{ .resp = resp };
    }

    /// Add trigger event
    pub fn trigger(self: HtmxResponseBuilder, event: []const u8) HtmxResponseBuilder {
        return .{ .resp = self.resp.htmxTrigger(event) };
    }

    /// Set target selector
    pub fn target(self: HtmxResponseBuilder, selector: []const u8) HtmxResponseBuilder {
        return .{ .resp = self.resp.htmxRetarget(selector) };
    }

    /// Set swap style
    /// Valid values: innerHTML, outerHTML, beforebegin, afterbegin, beforeend, afterend, delete, none
    pub fn swap(self: HtmxResponseBuilder, style: []const u8) HtmxResponseBuilder {
        return .{ .resp = self.resp.htmxReswap(style) };
    }

    /// Set status code
    pub fn status(self: HtmxResponseBuilder, code: u16) HtmxResponseBuilder {
        return .{ .resp = self.resp.withStatus(code) };
    }

    /// Push URL to history
    pub fn pushUrl(self: HtmxResponseBuilder, url: []const u8) HtmxResponseBuilder {
        return .{ .resp = self.resp.htmxPushUrl(url) };
    }

    /// Replace URL in history (no new entry)
    pub fn replaceUrl(self: HtmxResponseBuilder, url: []const u8) HtmxResponseBuilder {
        return .{ .resp = self.resp.htmxReplaceUrl(url) };
    }

    /// Trigger event after swap is complete
    pub fn triggerAfterSwap(self: HtmxResponseBuilder, event: []const u8) HtmxResponseBuilder {
        return .{ .resp = self.resp.htmxTriggerAfterSwap(event) };
    }

    /// Trigger event after settle step is complete
    pub fn triggerAfterSettle(self: HtmxResponseBuilder, event: []const u8) HtmxResponseBuilder {
        return .{ .resp = self.resp.htmxTriggerAfterSettle(event) };
    }

    /// Add custom header
    pub fn header(self: HtmxResponseBuilder, name: []const u8, value: []const u8) HtmxResponseBuilder {
        return .{ .resp = self.resp.withHeader(name, value) };
    }

    /// Build final response
    pub fn build(self: HtmxResponseBuilder) Response {
        return self.resp;
    }
};

// Tests
test "HtmxResponseBuilder.init" {
    const builder = HtmxResponseBuilder.init("<div>Test</div>");
    const resp = builder.build();
    try std.testing.expect(resp.getBody().len > 0);
}

test "HtmxResponseBuilder.chain" {
    const resp = HtmxResponseBuilder.init("<div>Test</div>")
        .trigger("todoCreated")
        .target("#todo-list")
        .swap("beforeend")
        .status(201)
        .build();

    try std.testing.expect(resp.getBody().len > 0);
    // Note: Header checking would require accessing internal response structure
}

test "HtmxResponseBuilder.fromResponse" {
    const original = Response.fragment("<div>Test</div>");
    const builder = HtmxResponseBuilder.fromResponse(original);
    const resp = builder.trigger("test").build();
    try std.testing.expect(resp.getBody().len > 0);
}

