const std = @import("std");
const Response = @import("../response.zig").Response;
const config_mod = @import("config.zig");
const HtmxConfig = config_mod.HtmxConfig;

/// Global HTMX configuration (thread-safe access)
var global_htmx_config: ?HtmxConfig = null;
var global_htmx_config_mutex: std.Thread.Mutex = .{};

/// Set the global HTMX configuration
/// Called by Engine12.enableHtmx() or Engine12.enableHtmxWithConfig()
pub fn setConfig(config: ?HtmxConfig) void {
    global_htmx_config_mutex.lock();
    defer global_htmx_config_mutex.unlock();
    global_htmx_config = config;
}

/// Get the global HTMX configuration (thread-safe)
pub fn getConfig() ?HtmxConfig {
    global_htmx_config_mutex.lock();
    defer global_htmx_config_mutex.unlock();
    return global_htmx_config;
}

/// Check if HTMX is enabled
pub fn isEnabled() bool {
    const config = getConfig() orelse return false;
    return config.enabled;
}

/// Build the HTMX script tag based on configuration
fn buildScriptTag(allocator: std.mem.Allocator, config: HtmxConfig) ![]const u8 {
    var script = std.ArrayListUnmanaged(u8){};
    errdefer script.deinit(allocator);

    // Main HTMX script
    try script.appendSlice(allocator, "\n    <!-- HTMX (auto-injected by Engine12) -->\n");

    if (config.use_cdn) {
        try script.appendSlice(allocator, "    <script src=\"");
        try script.appendSlice(allocator, config.cdn_url);
        try script.appendSlice(allocator, "@");
        try script.appendSlice(allocator, config.version);
        try script.appendSlice(allocator, "/dist/htmx.min.js\"");

        // Add custom attributes if specified
        if (config.script_attributes.len > 0) {
            try script.appendSlice(allocator, " ");
            try script.appendSlice(allocator, config.script_attributes);
        }

        try script.appendSlice(allocator, "></script>\n");
    } else {
        // Local HTMX - user must serve it via static files
        try script.appendSlice(allocator, "    <script src=\"/static/js/htmx.min.js\"");
        if (config.script_attributes.len > 0) {
            try script.appendSlice(allocator, " ");
            try script.appendSlice(allocator, config.script_attributes);
        }
        try script.appendSlice(allocator, "></script>\n");
    }

    // Load extensions
    for (config.extensions) |ext_name| {
        if (config.use_cdn) {
            try script.appendSlice(allocator, "    <script src=\"");
            try script.appendSlice(allocator, config.cdn_url);
            try script.appendSlice(allocator, "@");
            try script.appendSlice(allocator, config.version);
            try script.appendSlice(allocator, "/dist/ext/");
            try script.appendSlice(allocator, ext_name);
            try script.appendSlice(allocator, ".js\"></script>\n");
        } else {
            try script.appendSlice(allocator, "    <script src=\"/static/js/htmx-ext-");
            try script.appendSlice(allocator, ext_name);
            try script.appendSlice(allocator, ".js\"></script>\n");
        }
    }

    // Add debug mode configuration
    if (config.debug) {
        try script.appendSlice(allocator, "    <script>htmx.logAll();</script>\n");
    }

    return script.toOwnedSlice(allocator);
}

/// Check if the body represents a full HTML page (vs a fragment)
fn isFullHtmlPage(body: []const u8) bool {
    // Check for common full-page indicators
    // Look in the first 500 bytes for efficiency
    const check_len = @min(body.len, 500);
    const check_body = body[0..check_len];

    return std.mem.indexOf(u8, check_body, "<!DOCTYPE") != null or
        std.mem.indexOf(u8, check_body, "<!doctype") != null or
        std.mem.indexOf(u8, check_body, "<html") != null or
        std.mem.indexOf(u8, check_body, "<HTML") != null;
}

/// Find the best injection point in the HTML
/// Prefers </head>, falls back to </body>, then end of document
fn findInjectionPoint(body: []const u8) ?usize {
    // Try </head> first (best location for scripts)
    if (std.mem.indexOf(u8, body, "</head>")) |pos| {
        return pos;
    }
    if (std.mem.indexOf(u8, body, "</HEAD>")) |pos| {
        return pos;
    }

    // Fall back to </body>
    if (std.mem.lastIndexOf(u8, body, "</body>")) |pos| {
        return pos;
    }
    if (std.mem.lastIndexOf(u8, body, "</BODY>")) |pos| {
        return pos;
    }

    return null;
}

/// Inject HTMX script into an HTML response
/// This is the main entry point called by the response pipeline
pub fn injectHtmx(resp: Response) Response {
    // Get configuration
    const config = getConfig() orelse return resp;
    if (!config.enabled) return resp;

    // Get response body
    const body = resp.getBody();
    if (body.len == 0) return resp;

    // Check if this is a fragment response
    // Fragments are detected by checking if the body is a full HTML page
    // If inject_fragments is false, we only inject into full HTML pages
    if (!config.inject_fragments and !isFullHtmlPage(body)) {
        return resp;
    }

    // Avoid duplicate injection
    if (std.mem.indexOf(u8, body, "htmx.org") != null or
        std.mem.indexOf(u8, body, "htmx.min.js") != null)
    {
        return resp;
    }

    // Find injection point
    const injection_point = findInjectionPoint(body) orelse return resp;

    // Build script tag
    const allocator = std.heap.page_allocator;
    const script = buildScriptTag(allocator, config) catch return resp;
    defer allocator.free(script);

    // Allocate new body with script injected
    const new_body = allocator.alloc(u8, body.len + script.len) catch return resp;
    @memcpy(new_body[0..injection_point], body[0..injection_point]);
    @memcpy(new_body[injection_point..][0..script.len], script);
    @memcpy(new_body[injection_point + script.len ..], body[injection_point..]);

    // Create new response with injected script
    return Response.html(new_body);
}

// Tests
test "isFullHtmlPage detection" {
    try std.testing.expect(isFullHtmlPage("<!DOCTYPE html><html><body>Hello</body></html>"));
    try std.testing.expect(isFullHtmlPage("<html><head></head><body>Hello</body></html>"));
    try std.testing.expect(isFullHtmlPage("<!doctype html><html>"));
    try std.testing.expect(!isFullHtmlPage("<div>Fragment</div>"));
    try std.testing.expect(!isFullHtmlPage("<p>Just a paragraph</p>"));
}

test "findInjectionPoint" {
    // "</head>" position: "<!DOCTYPE html><html><head><title>Test</title></head>" = 46 chars before </head>
    const html1 = "<!DOCTYPE html><html><head><title>Test</title></head><body>Hello</body></html>";
    try std.testing.expectEqual(@as(?usize, 46), findInjectionPoint(html1));

    // No </head>, so falls back to </body>: "<!DOCTYPE html><html><body>Hello</body>"
    const html2 = "<!DOCTYPE html><html><body>Hello</body></html>";
    try std.testing.expectEqual(@as(?usize, 32), findInjectionPoint(html2));

    const fragment = "<div>No injection point</div>";
    try std.testing.expectEqual(@as(?usize, null), findInjectionPoint(fragment));
}

test "buildScriptTag CDN" {
    const config = HtmxConfig{
        .enabled = true,
        .use_cdn = true,
        .version = "1.9.10",
        .debug = false,
    };

    const script = try buildScriptTag(std.testing.allocator, config);
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "htmx.org@1.9.10") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "htmx.min.js") != null);
}

test "buildScriptTag with debug" {
    const config = HtmxConfig{
        .enabled = true,
        .use_cdn = true,
        .debug = true,
    };

    const script = try buildScriptTag(std.testing.allocator, config);
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "htmx.logAll()") != null);
}

test "buildScriptTag with extensions" {
    const config = HtmxConfig{
        .enabled = true,
        .use_cdn = true,
        .extensions = &[_][]const u8{ "ws", "sse" },
    };

    const script = try buildScriptTag(std.testing.allocator, config);
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "/ext/ws.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "/ext/sse.js") != null);
}
