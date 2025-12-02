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
    const html = "<div>Test</div>";
    const builder = HtmxResponseBuilder.init(html);
    const resp = builder.build();

    try std.testing.expect(resp.getBody().len > 0);
    try std.testing.expectEqualStrings(html, resp.getBody());
}

test "HtmxResponseBuilder.init with empty string" {
    const builder = HtmxResponseBuilder.init("");
    const resp = builder.build();
    try std.testing.expectEqualStrings("", resp.getBody());
}

test "HtmxResponseBuilder.trigger" {
    const resp = HtmxResponseBuilder.init("<div>Test</div>")
        .trigger("todoCreated")
        .build();

    const headers = resp.getCustomHeaders() orelse return error.NoHeaders;
    try std.testing.expect(headers.get("HX-Trigger") != null);
    try std.testing.expectEqualStrings("todoCreated", headers.get("HX-Trigger").?);
}

test "HtmxResponseBuilder.target" {
    const resp = HtmxResponseBuilder.init("<div>Test</div>")
        .target("#todo-list")
        .build();

    const headers = resp.getCustomHeaders() orelse return error.NoHeaders;
    try std.testing.expect(headers.get("HX-Retarget") != null);
    try std.testing.expectEqualStrings("#todo-list", headers.get("HX-Retarget").?);
}

test "HtmxResponseBuilder.swap" {
    const resp = HtmxResponseBuilder.init("<div>Test</div>")
        .swap("beforeend")
        .build();

    const headers = resp.getCustomHeaders() orelse return error.NoHeaders;
    try std.testing.expect(headers.get("HX-Reswap") != null);
    try std.testing.expectEqualStrings("beforeend", headers.get("HX-Reswap").?);
}

test "HtmxResponseBuilder.status" {
    const resp = HtmxResponseBuilder.init("<div>Test</div>")
        .status(201)
        .build();

    // Status code is stored internally, verify response was created
    try std.testing.expect(resp.getBody().len > 0);
}

test "HtmxResponseBuilder.pushUrl" {
    const resp = HtmxResponseBuilder.init("<div>Test</div>")
        .pushUrl("/todos/new")
        .build();

    const headers = resp.getCustomHeaders() orelse return error.NoHeaders;
    try std.testing.expect(headers.get("HX-Push-Url") != null);
    try std.testing.expectEqualStrings("/todos/new", headers.get("HX-Push-Url").?);
}

test "HtmxResponseBuilder.replaceUrl" {
    const resp = HtmxResponseBuilder.init("<div>Test</div>")
        .replaceUrl("/todos")
        .build();

    const headers = resp.getCustomHeaders() orelse return error.NoHeaders;
    try std.testing.expect(headers.get("HX-Replace-Url") != null);
    try std.testing.expectEqualStrings("/todos", headers.get("HX-Replace-Url").?);
}

test "HtmxResponseBuilder.triggerAfterSwap" {
    const resp = HtmxResponseBuilder.init("<div>Test</div>")
        .triggerAfterSwap("swapComplete")
        .build();

    const headers = resp.getCustomHeaders() orelse return error.NoHeaders;
    try std.testing.expect(headers.get("HX-Trigger-After-Swap") != null);
    try std.testing.expectEqualStrings("swapComplete", headers.get("HX-Trigger-After-Swap").?);
}

test "HtmxResponseBuilder.triggerAfterSettle" {
    const resp = HtmxResponseBuilder.init("<div>Test</div>")
        .triggerAfterSettle("settleComplete")
        .build();

    const headers = resp.getCustomHeaders() orelse return error.NoHeaders;
    try std.testing.expect(headers.get("HX-Trigger-After-Settle") != null);
    try std.testing.expectEqualStrings("settleComplete", headers.get("HX-Trigger-After-Settle").?);
}

test "HtmxResponseBuilder.header" {
    const resp = HtmxResponseBuilder.init("<div>Test</div>")
        .header("Custom-Header", "custom-value")
        .build();

    const headers = resp.getCustomHeaders() orelse return error.NoHeaders;
    try std.testing.expect(headers.get("Custom-Header") != null);
    try std.testing.expectEqualStrings("custom-value", headers.get("Custom-Header").?);
}

test "HtmxResponseBuilder.complex chain" {
    const resp = HtmxResponseBuilder.init("<div>Test</div>")
        .trigger("todoCreated")
        .target("#todo-list")
        .swap("beforeend")
        .pushUrl("/todos/new")
        .triggerAfterSwap("updateCount")
        .triggerAfterSettle("refreshStats")
        .status(201)
        .header("X-Custom", "value")
        .build();

    const headers = resp.getCustomHeaders() orelse return error.NoHeaders;

    try std.testing.expect(headers.get("HX-Trigger") != null);
    try std.testing.expectEqualStrings("todoCreated", headers.get("HX-Trigger").?);

    try std.testing.expect(headers.get("HX-Retarget") != null);
    try std.testing.expectEqualStrings("#todo-list", headers.get("HX-Retarget").?);

    try std.testing.expect(headers.get("HX-Reswap") != null);
    try std.testing.expectEqualStrings("beforeend", headers.get("HX-Reswap").?);

    try std.testing.expect(headers.get("HX-Push-Url") != null);
    try std.testing.expectEqualStrings("/todos/new", headers.get("HX-Push-Url").?);

    try std.testing.expect(headers.get("HX-Trigger-After-Swap") != null);
    try std.testing.expectEqualStrings("updateCount", headers.get("HX-Trigger-After-Swap").?);

    try std.testing.expect(headers.get("HX-Trigger-After-Settle") != null);
    try std.testing.expectEqualStrings("refreshStats", headers.get("HX-Trigger-After-Settle").?);

    try std.testing.expect(headers.get("X-Custom") != null);
    try std.testing.expectEqualStrings("value", headers.get("X-Custom").?);
}

test "HtmxResponseBuilder.fromResponse" {
    const original = Response.fragment("<div>Original</div>");
    const builder = HtmxResponseBuilder.fromResponse(original);
    const resp = builder.trigger("test").build();

    try std.testing.expect(resp.getBody().len > 0);
    const headers = resp.getCustomHeaders() orelse return error.NoHeaders;
    try std.testing.expect(headers.get("HX-Trigger") != null);
    try std.testing.expectEqualStrings("test", headers.get("HX-Trigger").?);
}

test "HtmxResponseBuilder.fromResponse with existing headers" {
    var original = Response.fragment("<div>Test</div>");
    original = original.withHeader("Existing-Header", "existing-value");

    const builder = HtmxResponseBuilder.fromResponse(original);
    const resp = builder.trigger("newEvent").build();

    const headers = resp.getCustomHeaders() orelse return error.NoHeaders;
    try std.testing.expect(headers.get("Existing-Header") != null);
    try std.testing.expectEqualStrings("existing-value", headers.get("Existing-Header").?);
    try std.testing.expect(headers.get("HX-Trigger") != null);
    try std.testing.expectEqualStrings("newEvent", headers.get("HX-Trigger").?);
}

test "HtmxResponseBuilder.multiple triggers" {
    // Multiple trigger calls should overwrite, not append
    const resp = HtmxResponseBuilder.init("<div>Test</div>")
        .trigger("first")
        .trigger("second")
        .build();

    const headers = resp.getCustomHeaders() orelse return error.NoHeaders;
    try std.testing.expect(headers.get("HX-Trigger") != null);
    try std.testing.expectEqualStrings("second", headers.get("HX-Trigger").?);
}

test "HtmxResponseBuilder.empty event names" {
    const resp = HtmxResponseBuilder.init("<div>Test</div>")
        .trigger("")
        .build();

    const headers = resp.getCustomHeaders() orelse return error.NoHeaders;
    try std.testing.expect(headers.get("HX-Trigger") != null);
    try std.testing.expectEqualStrings("", headers.get("HX-Trigger").?);
}

test "HtmxResponseBuilder.long chain" {
    // Test that very long chains work correctly
    var builder = HtmxResponseBuilder.init("<div>Test</div>");

    // Chain 20 operations
    builder = builder.trigger("event1");
    builder = builder.target("#target1");
    builder = builder.swap("innerHTML");
    builder = builder.trigger("event2");
    builder = builder.target("#target2");
    builder = builder.swap("outerHTML");
    builder = builder.pushUrl("/url1");
    builder = builder.replaceUrl("/url2");
    builder = builder.triggerAfterSwap("swap1");
    builder = builder.triggerAfterSettle("settle1");
    builder = builder.status(200);
    builder = builder.header("Header1", "Value1");
    builder = builder.header("Header2", "Value2");
    builder = builder.trigger("event3");
    builder = builder.target("#target3");
    builder = builder.swap("beforeend");
    builder = builder.pushUrl("/url3");
    builder = builder.replaceUrl("/url4");
    builder = builder.triggerAfterSwap("swap2");
    builder = builder.triggerAfterSettle("settle2");

    const resp = builder.build();

    const headers = resp.getCustomHeaders() orelse return error.NoHeaders;
    // Verify last values are set
    try std.testing.expectEqualStrings("event3", headers.get("HX-Trigger").?);
    try std.testing.expectEqualStrings("#target3", headers.get("HX-Retarget").?);
    try std.testing.expectEqualStrings("beforeend", headers.get("HX-Reswap").?);
    try std.testing.expectEqualStrings("/url3", headers.get("HX-Push-Url").?);
    try std.testing.expectEqualStrings("/url4", headers.get("HX-Replace-Url").?);
    try std.testing.expectEqualStrings("swap2", headers.get("HX-Trigger-After-Swap").?);
    try std.testing.expectEqualStrings("settle2", headers.get("HX-Trigger-After-Settle").?);
    try std.testing.expectEqualStrings("Value1", headers.get("Header1").?);
    try std.testing.expectEqualStrings("Value2", headers.get("Header2").?);
}
