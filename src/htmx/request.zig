const std = @import("std");
const Request = @import("../request.zig").Request;

/// HTMX request information extracted from headers
/// HTMX sends special headers with each request that provide context
/// about the request origin and intended behavior
pub const HtmxRequestInfo = struct {
    /// True if this request was initiated by HTMX (has HX-Request header)
    is_htmx: bool,

    /// True if this is a boosted link/form request (full page with HTMX enhancements)
    /// Boosted requests should return full pages, not fragments
    is_boosted: bool,

    /// True if this request is for history restoration
    is_history_restore: bool,

    /// The ID of the target element that will receive the response
    target: ?[]const u8,

    /// The ID of the element that triggered the request
    trigger: ?[]const u8,

    /// The name attribute of the triggering element
    trigger_name: ?[]const u8,

    /// The current URL of the browser when the request was made
    current_url: ?[]const u8,

    /// User's response to an hx-prompt attribute
    prompt: ?[]const u8,

    /// Check if this is an HTMX partial request (wants HTML fragment, not full page)
    /// Returns true if is_htmx is true AND is_boosted is false
    pub fn isPartial(self: HtmxRequestInfo) bool {
        return self.is_htmx and !self.is_boosted;
    }

    /// Check if this request wants a full page response
    /// Returns true if NOT htmx, or if boosted, or if history restore
    pub fn wantsFullPage(self: HtmxRequestInfo) bool {
        return !self.is_htmx or self.is_boosted or self.is_history_restore;
    }
};

/// Extract HTMX request information from a request
/// This reads HTMX-specific headers and returns structured info
pub fn fromRequest(req: *const Request) HtmxRequestInfo {
    return HtmxRequestInfo{
        .is_htmx = req.header("HX-Request") != null,
        .is_boosted = eqlIgnoreCase(req.header("HX-Boosted") orelse "", "true"),
        .is_history_restore = eqlIgnoreCase(req.header("HX-History-Restore-Request") orelse "", "true"),
        .target = req.header("HX-Target"),
        .trigger = req.header("HX-Trigger"),
        .trigger_name = req.header("HX-Trigger-Name"),
        .current_url = req.header("HX-Current-URL"),
        .prompt = req.header("HX-Prompt"),
    };
}

/// Case-insensitive string comparison for header values
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

// Convenience functions for direct request checking

/// Check if a request is from HTMX
pub fn isHtmxRequest(req: *const Request) bool {
    return req.header("HX-Request") != null;
}

/// Check if a request is a boosted HTMX request
pub fn isHtmxBoosted(req: *const Request) bool {
    return eqlIgnoreCase(req.header("HX-Boosted") orelse "", "true");
}

/// Check if a request is a partial HTMX request (wants fragment)
pub fn isHtmxPartial(req: *const Request) bool {
    return isHtmxRequest(req) and !isHtmxBoosted(req);
}

/// Get the HTMX target element ID
pub fn getHtmxTarget(req: *const Request) ?[]const u8 {
    return req.header("HX-Target");
}

/// Get the HTMX trigger element ID
pub fn getHtmxTrigger(req: *const Request) ?[]const u8 {
    return req.header("HX-Trigger");
}

/// Get the current URL from HTMX
pub fn getHtmxCurrentUrl(req: *const Request) ?[]const u8 {
    return req.header("HX-Current-URL");
}

/// Get the user's prompt response
pub fn getHtmxPrompt(req: *const Request) ?[]const u8 {
    return req.header("HX-Prompt");
}

// Tests
test "HtmxRequestInfo detection" {
    // Note: These tests would require mock Request objects
    // For now, test the helper functions
    try std.testing.expect(eqlIgnoreCase("true", "TRUE"));
    try std.testing.expect(eqlIgnoreCase("True", "true"));
    try std.testing.expect(!eqlIgnoreCase("true", "false"));
}

test "HtmxRequestInfo.isPartial" {
    const partial = HtmxRequestInfo{
        .is_htmx = true,
        .is_boosted = false,
        .is_history_restore = false,
        .target = null,
        .trigger = null,
        .trigger_name = null,
        .current_url = null,
        .prompt = null,
    };
    try std.testing.expect(partial.isPartial());
    try std.testing.expect(!partial.wantsFullPage());

    const boosted = HtmxRequestInfo{
        .is_htmx = true,
        .is_boosted = true,
        .is_history_restore = false,
        .target = null,
        .trigger = null,
        .trigger_name = null,
        .current_url = null,
        .prompt = null,
    };
    try std.testing.expect(!boosted.isPartial());
    try std.testing.expect(boosted.wantsFullPage());

    const normal = HtmxRequestInfo{
        .is_htmx = false,
        .is_boosted = false,
        .is_history_restore = false,
        .target = null,
        .trigger = null,
        .trigger_name = null,
        .current_url = null,
        .prompt = null,
    };
    try std.testing.expect(!normal.isPartial());
    try std.testing.expect(normal.wantsFullPage());
}
