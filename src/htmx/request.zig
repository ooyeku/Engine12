const std = @import("std");
const Request = @import("../http/request.zig").Request;

pub const HtmxRequestInfo = struct {
    is_htmx: bool,

    is_boosted: bool,

    is_history_restore: bool,

    target: ?[]const u8,

    trigger: ?[]const u8,

    trigger_name: ?[]const u8,

    current_url: ?[]const u8,

    prompt: ?[]const u8,

    pub fn isPartial(self: HtmxRequestInfo) bool {
        return self.is_htmx and !self.is_boosted;
    }

    pub fn wantsFullPage(self: HtmxRequestInfo) bool {
        return !self.is_htmx or self.is_boosted or self.is_history_restore;
    }
};

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

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

pub fn isHtmxRequest(req: *const Request) bool {
    return req.header("HX-Request") != null;
}

pub fn isHtmxBoosted(req: *const Request) bool {
    return eqlIgnoreCase(req.header("HX-Boosted") orelse "", "true");
}

pub fn isHtmxPartial(req: *const Request) bool {
    return isHtmxRequest(req) and !isHtmxBoosted(req);
}

pub fn getHtmxTarget(req: *const Request) ?[]const u8 {
    return req.header("HX-Target");
}

pub fn getHtmxTrigger(req: *const Request) ?[]const u8 {
    return req.header("HX-Trigger");
}

pub fn getHtmxCurrentUrl(req: *const Request) ?[]const u8 {
    return req.header("HX-Current-URL");
}

pub fn getHtmxPrompt(req: *const Request) ?[]const u8 {
    return req.header("HX-Prompt");
}

test "HtmxRequestInfo detection" {
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
