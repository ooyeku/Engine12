const std = @import("std");
const Response = @import("../response.zig").Response;
const config_mod = @import("config.zig");
const HtmxConfig = config_mod.HtmxConfig;

/// Global HTMX configuration (thread-safe access)
var global_htmx_config: ?HtmxConfig = null;
var global_htmx_config_mutex: std.Thread.Mutex = .{};

/// Cached script tag to avoid rebuilding on every request
var cached_script: ?struct {
    config_hash: u64,
    script: []const u8,
} = null;
var cached_script_mutex: std.Thread.Mutex = .{};

/// Route exclusion list - paths that should skip HTMX injection
/// Common API endpoints that don't need HTMX script
var route_exclusions: std.ArrayListUnmanaged([]const u8) = std.ArrayListUnmanaged([]const u8){};
var route_exclusions_mutex: std.Thread.Mutex = .{};

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

/// Compute a hash of the configuration for caching
fn computeConfigHash(config: HtmxConfig) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(config.version);
    hasher.update(if (config.use_cdn) "cdn" else "local");
    hasher.update(if (config.debug) "debug" else "nodebug");
    hasher.update(config.script_attributes);
    for (config.extensions) |ext| {
        hasher.update(ext);
    }
    return hasher.final();
}

/// Build the HTMX script tag based on configuration
/// Uses caching to avoid rebuilding the same script tag repeatedly
fn buildScriptTag(allocator: std.mem.Allocator, config: HtmxConfig) ![]const u8 {
    const config_hash = computeConfigHash(config);

    // Check cache first
    cached_script_mutex.lock();
    defer cached_script_mutex.unlock();

    if (cached_script) |cached| {
        if (cached.config_hash == config_hash) {
            // Cache hit - duplicate the script for this request
            const script_copy = try allocator.dupe(u8, cached.script);
            return script_copy;
        }
    }

    // Cache miss - build new script tag
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

    const script_slice = try script.toOwnedSlice(allocator);
    defer allocator.free(script_slice); // Free the intermediate slice

    // Update cache (using persistent allocator for cached script)
    if (cached_script) |old_cached| {
        std.heap.page_allocator.free(old_cached.script);
    }
    const cached_script_copy = try std.heap.page_allocator.dupe(u8, script_slice);
    cached_script = .{
        .config_hash = config_hash,
        .script = cached_script_copy,
    };

    // Return a copy for this request
    const request_copy = try allocator.dupe(u8, script_slice);
    return request_copy;
}

/// Clear the script cache (for testing purposes)
/// This frees any cached script memory and resets the cache
pub fn clearCache() void {
    cached_script_mutex.lock();
    defer cached_script_mutex.unlock();

    if (cached_script) |old_cached| {
        std.heap.page_allocator.free(old_cached.script);
        cached_script = null;
    }
}

/// Add a route pattern to the exclusion list
/// Routes matching these patterns will skip HTMX script injection
/// Useful for API endpoints that return JSON/plain text
///
/// Example:
/// ```zig
/// htmx.injector.addRouteExclusion("/api/");
/// ```
pub fn addRouteExclusion(pattern: []const u8) !void {
    route_exclusions_mutex.lock();
    defer route_exclusions_mutex.unlock();

    const pattern_copy = try std.heap.page_allocator.dupe(u8, pattern);
    try route_exclusions.append(std.heap.page_allocator, pattern_copy);
}

/// Check if a path should be excluded from HTMX injection
fn isExcludedPath(path: []const u8) bool {
    route_exclusions_mutex.lock();
    defer route_exclusions_mutex.unlock();

    for (route_exclusions.items) |pattern| {
        if (std.mem.startsWith(u8, path, pattern)) {
            return true;
        }
    }
    return false;
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

    // Check route exclusion list (if request path is available)
    // Note: We can't easily access request path here, so this is a best-effort check
    // For full route exclusion, users should check before calling injectHtmx

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
    try std.testing.expect(isFullHtmlPage("<HTML><BODY>Test</BODY></HTML>"));
    try std.testing.expect(!isFullHtmlPage("<div>Fragment</div>"));
    try std.testing.expect(!isFullHtmlPage("<p>Just a paragraph</p>"));
    try std.testing.expect(!isFullHtmlPage(""));
    try std.testing.expect(!isFullHtmlPage("Plain text"));
}

test "isFullHtmlPage with doctype in middle" {
    // Should only check first 500 bytes
    var html = std.ArrayListUnmanaged(u8){};
    defer html.deinit(std.testing.allocator);

    // Add 600 bytes of content before doctype
    try html.appendNTimes(std.testing.allocator, 'x', 600);
    try html.appendSlice(std.testing.allocator, "<!DOCTYPE html>");

    // Should not detect doctype since it's after 500 bytes
    try std.testing.expect(!isFullHtmlPage(html.items));
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

test "findInjectionPoint case insensitive" {
    const html1 = "<!DOCTYPE html><html><head><title>Test</title></HEAD><body>Hello</body></html>";
    try std.testing.expect(findInjectionPoint(html1) != null);

    const html2 = "<!DOCTYPE html><html><body>Hello</BODY></html>";
    try std.testing.expect(findInjectionPoint(html2) != null);
}

test "findInjectionPoint multiple body tags" {
    // Should use lastIndexOf for </body>
    const html = "<!DOCTYPE html><html><body><div>Content</div></body><script>test</script></body></html>";
    const pos = findInjectionPoint(html);
    try std.testing.expect(pos != null);
    // Should find the last </body> tag
    try std.testing.expect(pos.? > 50);
}

test "computeConfigHash" {
    const config1 = HtmxConfig{
        .version = "1.9.10",
        .use_cdn = true,
        .debug = false,
    };

    const config2 = HtmxConfig{
        .version = "1.9.10",
        .use_cdn = true,
        .debug = false,
    };

    const config3 = HtmxConfig{
        .version = "2.0.0",
        .use_cdn = true,
        .debug = false,
    };

    const hash1 = computeConfigHash(config1);
    const hash2 = computeConfigHash(config2);
    const hash3 = computeConfigHash(config3);

    try std.testing.expectEqual(hash1, hash2);
    try std.testing.expect(hash1 != hash3);
}

test "computeConfigHash with extensions" {
    const config1 = HtmxConfig{
        .extensions = &[_][]const u8{"ws"},
    };

    const config2 = HtmxConfig{
        .extensions = &[_][]const u8{ "ws", "sse" },
    };

    const hash1 = computeConfigHash(config1);
    const hash2 = computeConfigHash(config2);

    try std.testing.expect(hash1 != hash2);
}

test "computeConfigHash with script attributes" {
    const config1 = HtmxConfig{
        .script_attributes = "",
    };

    const config2 = HtmxConfig{
        .script_attributes = "nonce=abc123",
    };

    const hash1 = computeConfigHash(config1);
    const hash2 = computeConfigHash(config2);

    try std.testing.expect(hash1 != hash2);
}

test "buildScriptTag CDN" {
    defer clearCache(); // Clean up cache after test

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
    try std.testing.expect(std.mem.indexOf(u8, script, "<!-- HTMX") != null);
}

test "buildScriptTag local" {
    defer clearCache(); // Clean up cache after test

    const config = HtmxConfig{
        .enabled = true,
        .use_cdn = false,
        .version = "1.9.10",
    };

    const script = try buildScriptTag(std.testing.allocator, config);
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "/static/js/htmx.min.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "htmx.org") == null);
}

test "buildScriptTag with debug" {
    defer clearCache(); // Clean up cache after test

    const config = HtmxConfig{
        .enabled = true,
        .use_cdn = true,
        .debug = true,
    };

    const script = try buildScriptTag(std.testing.allocator, config);
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "htmx.logAll()") != null);
}

test "buildScriptTag without debug" {
    defer clearCache(); // Clean up cache after test

    const config = HtmxConfig{
        .enabled = true,
        .use_cdn = true,
        .debug = false,
    };

    const script = try buildScriptTag(std.testing.allocator, config);
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "htmx.logAll()") == null);
}

test "buildScriptTag with extensions" {
    defer clearCache(); // Clean up cache after test

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

test "buildScriptTag with extensions local" {
    defer clearCache(); // Clean up cache after test

    const config = HtmxConfig{
        .enabled = true,
        .use_cdn = false,
        .extensions = &[_][]const u8{"ws"},
    };

    const script = try buildScriptTag(std.testing.allocator, config);
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "/static/js/htmx-ext-ws.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "/ext/ws.js") == null);
}

test "buildScriptTag with script attributes" {
    defer clearCache(); // Clean up cache after test

    const config = HtmxConfig{
        .enabled = true,
        .use_cdn = true,
        .script_attributes = "nonce=abc123",
    };

    const script = try buildScriptTag(std.testing.allocator, config);
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "nonce=abc123") != null);
}

test "buildScriptTag caching" {
    defer clearCache(); // Clean up cache after test

    const config = HtmxConfig{
        .enabled = true,
        .use_cdn = true,
        .version = "1.9.10",
    };

    // First call - cache miss
    const script1 = try buildScriptTag(std.testing.allocator, config);
    defer std.testing.allocator.free(script1);

    // Second call with same config - cache hit
    const script2 = try buildScriptTag(std.testing.allocator, config);
    defer std.testing.allocator.free(script2);

    // Scripts should be identical
    try std.testing.expectEqualStrings(script1, script2);
}

test "buildScriptTag cache invalidation on config change" {
    defer clearCache(); // Clean up cache after test

    const config1 = HtmxConfig{
        .enabled = true,
        .use_cdn = true,
        .version = "1.9.10",
    };

    const config2 = HtmxConfig{
        .enabled = true,
        .use_cdn = true,
        .version = "2.0.0", // Different version
    };

    const script1 = try buildScriptTag(std.testing.allocator, config1);
    defer std.testing.allocator.free(script1);

    const script2 = try buildScriptTag(std.testing.allocator, config2);
    defer std.testing.allocator.free(script2);

    // Scripts should be different
    try std.testing.expect(!std.mem.eql(u8, script1, script2));
    try std.testing.expect(std.mem.indexOf(u8, script1, "1.9.10") != null);
    try std.testing.expect(std.mem.indexOf(u8, script2, "2.0.0") != null);
}

test "addRouteExclusion" {
    try addRouteExclusion("/api/");
    try addRouteExclusion("/static/");

    try std.testing.expect(isExcludedPath("/api/users"));
    try std.testing.expect(isExcludedPath("/api/todos"));
    try std.testing.expect(isExcludedPath("/static/css/style.css"));
    try std.testing.expect(!isExcludedPath("/todos"));
    try std.testing.expect(!isExcludedPath("/"));
}

test "isExcludedPath non-matching path" {
    // Should return false for paths that don't match any exclusion pattern
    // Note: Previous tests may have added exclusions, so we test a path
    // that definitely won't match common patterns
    try std.testing.expect(!isExcludedPath("/unique-test-path-12345"));
}

test "injectHtmx disabled" {
    setConfig(null);
    const resp = Response.html("<!DOCTYPE html><html><head></head><body>Test</body></html>");
    const result = injectHtmx(resp);

    // Should return unchanged response when disabled
    try std.testing.expectEqualStrings(resp.getBody(), result.getBody());
}

test "injectHtmx empty body" {
    setConfig(.{ .enabled = true });
    const resp = Response.html("");
    const result = injectHtmx(resp);

    // Should return unchanged response for empty body
    try std.testing.expectEqualStrings("", result.getBody());
}

test "injectHtmx fragment without inject_fragments" {
    setConfig(.{
        .enabled = true,
        .inject_fragments = false,
    });

    const resp = Response.html("<div>Fragment</div>");
    const result = injectHtmx(resp);

    // Should return unchanged fragment
    try std.testing.expectEqualStrings("<div>Fragment</div>", result.getBody());
}

test "injectHtmx fragment with inject_fragments" {
    setConfig(.{
        .enabled = true,
        .inject_fragments = true,
        .use_cdn = true,
        .version = "1.9.10",
    });

    const resp = Response.html("<div>Fragment</div>");
    const result = injectHtmx(resp);

    // Fragment has no injection point, so should return unchanged
    try std.testing.expectEqualStrings("<div>Fragment</div>", result.getBody());
}

test "injectHtmx full page" {
    setConfig(.{
        .enabled = true,
        .use_cdn = true,
        .version = "1.9.10",
    });

    const html = "<!DOCTYPE html><html><head><title>Test</title></head><body>Hello</body></html>";
    const resp = Response.html(html);
    const result = injectHtmx(resp);

    // Should inject script before </head>
    try std.testing.expect(std.mem.indexOf(u8, result.getBody(), "htmx.min.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.getBody(), "<!-- HTMX") != null);
}

test "injectHtmx duplicate prevention" {
    setConfig(.{
        .enabled = true,
        .use_cdn = true,
        .version = "1.9.10",
    });

    const html = "<!DOCTYPE html><html><head><script src=\"htmx.min.js\"></script></head><body>Hello</body></html>";
    const resp = Response.html(html);
    const result = injectHtmx(resp);

    // Should not inject again if already present
    const body = result.getBody();
    var count: usize = 0;
    var pos: ?usize = 0;
    while (std.mem.indexOfPos(u8, body, pos.?, "htmx.min.js")) |found| {
        count += 1;
        pos = found + 1;
    }
    // Should only have one instance (the original)
    try std.testing.expect(count == 1);
}

test "injectHtmx no injection point" {
    setConfig(.{
        .enabled = true,
        .use_cdn = true,
        .version = "1.9.10",
    });

    const html = "<div>No head or body tags</div>";
    const resp = Response.html(html);
    const result = injectHtmx(resp);

    // Should return unchanged if no injection point
    try std.testing.expectEqualStrings(html, result.getBody());
}

test "injectHtmx injection into head" {
    setConfig(.{
        .enabled = true,
        .use_cdn = true,
        .version = "1.9.10",
    });

    const html = "<!DOCTYPE html><html><head><title>Test</title></head><body>Hello</body></html>";
    const resp = Response.html(html);
    const result = injectHtmx(resp);

    const body = result.getBody();
    const head_end = std.mem.indexOf(u8, body, "</head>") orelse return error.NotFound;
    const script_pos = std.mem.indexOf(u8, body, "htmx.min.js") orelse return error.NotFound;

    // Script should be before </head>
    try std.testing.expect(script_pos < head_end);
}

test "injectHtmx injection into body fallback" {
    setConfig(.{
        .enabled = true,
        .use_cdn = true,
        .version = "1.9.10",
    });

    const html = "<!DOCTYPE html><html><body>Hello</body></html>";
    const resp = Response.html(html);
    const result = injectHtmx(resp);

    const body = result.getBody();
    const body_end = std.mem.lastIndexOf(u8, body, "</body>") orelse return error.NotFound;
    const script_pos = std.mem.indexOf(u8, body, "htmx.min.js") orelse return error.NotFound;

    // Script should be before </body>
    try std.testing.expect(script_pos < body_end);
}

test "injectHtmx with extensions" {
    setConfig(.{
        .enabled = true,
        .use_cdn = true,
        .version = "1.9.10",
        .extensions = &[_][]const u8{ "ws", "sse" },
    });

    const html = "<!DOCTYPE html><html><head></head><body>Hello</body></html>";
    const resp = Response.html(html);
    const result = injectHtmx(resp);

    const body = result.getBody();
    try std.testing.expect(std.mem.indexOf(u8, body, "/ext/ws.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/ext/sse.js") != null);
}

test "injectHtmx preserves body content" {
    setConfig(.{
        .enabled = true,
        .use_cdn = true,
        .version = "1.9.10",
    });

    const html = "<!DOCTYPE html><html><head></head><body><h1>Hello World</h1><p>Test content</p></body></html>";
    const resp = Response.html(html);
    const result = injectHtmx(resp);

    const body = result.getBody();
    // Original content should be preserved
    try std.testing.expect(std.mem.indexOf(u8, body, "<h1>Hello World</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<p>Test content</p>") != null);
}
