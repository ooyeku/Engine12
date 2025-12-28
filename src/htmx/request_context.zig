const std = @import("std");
const Request = @import("../http/request.zig").Request;

/// HTMX request context helper for easy access to HTMX state
pub const HtmxContext = struct {
    request: *Request,

    pub fn init(request: *Request) HtmxContext {
        return .{ .request = request };
    }

    /// Check if this is an HTMX request
    pub fn isHtmx(self: HtmxContext) bool {
        return self.request.header("HX-Request") != null;
    }

    /// Check if this is a partial/boosted request
    pub fn isPartial(self: HtmxContext) bool {
        return self.request.header("HX-Boosted") != null or
            self.request.header("HX-Request") != null;
    }

    /// Check if this is a boosted request
    pub fn isBoosted(self: HtmxContext) bool {
        return self.request.header("HX-Boosted") != null;
    }

    /// Get the target element ID
    pub fn target(self: HtmxContext) ?[]const u8 {
        return self.request.header("HX-Target");
    }

    /// Get the trigger element ID
    pub fn trigger(self: HtmxContext) ?[]const u8 {
        return self.request.header("HX-Trigger");
    }

    /// Get the trigger name (for hx-trigger-name)
    pub fn triggerName(self: HtmxContext) ?[]const u8 {
        return self.request.header("HX-Trigger-Name");
    }

    /// Get the current URL
    pub fn currentUrl(self: HtmxContext) ?[]const u8 {
        return self.request.header("HX-Current-URL");
    }

    /// Get the prompt response
    pub fn prompt(self: HtmxContext) ?[]const u8 {
        return self.request.header("HX-Prompt");
    }

    /// Check if this is a history restore request
    pub fn isHistoryRestore(self: HtmxContext) bool {
        const header = self.request.header("HX-History-Restore-Request");
        return header != null and std.mem.eql(u8, header.?, "true");
    }

    /// Get the active element ID
    pub fn activeElement(self: HtmxContext) ?[]const u8 {
        return self.request.header("HX-Active-Element");
    }

    /// Get the active element name
    pub fn activeElementName(self: HtmxContext) ?[]const u8 {
        return self.request.header("HX-Active-Element-Name");
    }

    /// Get the active element value
    pub fn activeElementValue(self: HtmxContext) ?[]const u8 {
        return self.request.header("HX-Active-Element-Value");
    }

    /// Check if request should return full page or partial
    pub fn shouldReturnPartial(self: HtmxContext) bool {
        return self.isHtmx() and !self.isBoosted();
    }

    /// Check if request should return full page
    pub fn shouldReturnFullPage(self: HtmxContext) bool {
        return !self.isHtmx() or self.isBoosted();
    }
};

/// Extension method to add htmx() to Request
pub fn htmx(request: *Request) HtmxContext {
    return HtmxContext.init(request);
}

// Tests
test "htmx context detects HTMX request" {
    // Note: Full testing would require mock Request objects
    // These are placeholder tests
}

test "htmx context detects boosted request" {
    // Placeholder
}

test "htmx context gets target" {
    // Placeholder
}
