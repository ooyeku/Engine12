const std = @import("std");
const Response = @import("../response.zig").Response;
const config_mod = @import("config.zig");
const HtmxConfig = config_mod.HtmxConfig;

var global_htmx_config: ?HtmxConfig = null;
var global_htmx_config_mutex: std.Thread.Mutex = .{};

var cached_script: ?struct {
    config_hash: u64,
    script: []const u8,
} = null;
var cached_script_mutex: std.Thread.Mutex = .{};

var route_exclusions: std.ArrayListUnmanaged([]const u8) = std.ArrayListUnmanaged([]const u8){};
var route_exclusions_mutex: std.Thread.Mutex = .{};

pub fn setConfig(config: ?HtmxConfig) void {
    global_htmx_config_mutex.lock();
    defer global_htmx_config_mutex.unlock();
    global_htmx_config = config;
}

pub fn getConfig() ?HtmxConfig {
    global_htmx_config_mutex.lock();
    defer global_htmx_config_mutex.unlock();
    return global_htmx_config;
}

pub fn isEnabled() bool {
    const config = getConfig() orelse return false;
    return config.enabled;
}

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

fn buildScriptTag(allocator: std.mem.Allocator, config: HtmxConfig) ![]const u8 {
    const config_hash = computeConfigHash(config);

    cached_script_mutex.lock();
    defer cached_script_mutex.unlock();

    if (cached_script) |cached| {
        if (cached.config_hash == config_hash) {
            const script_copy = try allocator.dupe(u8, cached.script);
            return script_copy;
        }
    }

    var script = std.ArrayListUnmanaged(u8){};
    errdefer script.deinit(allocator);

    try script.appendSlice(allocator, "\n    <!-- HTMX (auto-injected by Engine12) -->\n");

    if (config.use_cdn) {
        try script.appendSlice(allocator, "    <script src=\"");
        try script.appendSlice(allocator, config.cdn_url);
        try script.appendSlice(allocator, "@");
        try script.appendSlice(allocator, config.version);
        try script.appendSlice(allocator, "/dist/htmx.min.js\"");

        if (config.script_attributes.len > 0) {
            try script.appendSlice(allocator, " ");
            try script.appendSlice(allocator, config.script_attributes);
        }

        try script.appendSlice(allocator, "></script>\n");
    } else {
        try script.appendSlice(allocator, "    <script src=\"/static/js/htmx.min.js\"");
        if (config.script_attributes.len > 0) {
            try script.appendSlice(allocator, " ");
            try script.appendSlice(allocator, config.script_attributes);
        }
        try script.appendSlice(allocator, "></script>\n");
    }

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

    if (config.debug) {
        try script.appendSlice(allocator, "    <script>htmx.logAll();</script>\n");
    }

    const script_slice = try script.toOwnedSlice(allocator);
    defer allocator.free(script_slice); // Free the intermediate slice

    if (cached_script) |old_cached| {
        std.heap.page_allocator.free(old_cached.script);
    }
    const cached_script_copy = try std.heap.page_allocator.dupe(u8, script_slice);
    cached_script = .{
        .config_hash = config_hash,
        .script = cached_script_copy,
    };

    const request_copy = try allocator.dupe(u8, script_slice);
    return request_copy;
}

pub fn clearCache() void {
    cached_script_mutex.lock();
    defer cached_script_mutex.unlock();

    if (cached_script) |old_cached| {
        std.heap.page_allocator.free(old_cached.script);
        cached_script = null;
    }
}

pub fn addRouteExclusion(pattern: []const u8) !void {
    route_exclusions_mutex.lock();
    defer route_exclusions_mutex.unlock();

    const pattern_copy = try std.heap.page_allocator.dupe(u8, pattern);
    try route_exclusions.append(std.heap.page_allocator, pattern_copy);
}

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

fn isFullHtmlPage(body: []const u8) bool {
    const check_len = @min(body.len, 500);
    const check_body = body[0..check_len];

    return std.mem.indexOf(u8, check_body, "<!DOCTYPE") != null or
        std.mem.indexOf(u8, check_body, "<!doctype") != null or
        std.mem.indexOf(u8, check_body, "<html") != null or
        std.mem.indexOf(u8, check_body, "<HTML") != null;
}

fn findInjectionPoint(body: []const u8) ?usize {
    if (std.mem.indexOf(u8, body, "</head>")) |pos| {
        return pos;
    }
    if (std.mem.indexOf(u8, body, "</HEAD>")) |pos| {
        return pos;
    }

    if (std.mem.lastIndexOf(u8, body, "</body>")) |pos| {
        return pos;
    }
    if (std.mem.lastIndexOf(u8, body, "</BODY>")) |pos| {
        return pos;
    }

    return null;
}

pub fn injectHtmx(resp: Response) Response {
    const config = getConfig() orelse return resp;
    if (!config.enabled) return resp;


    const body = resp.getBody();
    if (body.len == 0) return resp;

    if (!config.inject_fragments and !isFullHtmlPage(body)) {
        return resp;
    }

    if (std.mem.indexOf(u8, body, "htmx.org") != null or
        std.mem.indexOf(u8, body, "htmx.min.js") != null)
    {
        return resp;
    }

    const injection_point = findInjectionPoint(body) orelse return resp;

    const allocator = std.heap.page_allocator;
    const script = buildScriptTag(allocator, config) catch return resp;
    defer allocator.free(script);

    const new_body = allocator.alloc(u8, body.len + script.len) catch return resp;
    @memcpy(new_body[0..injection_point], body[0..injection_point]);
    @memcpy(new_body[injection_point..][0..script.len], script);
    @memcpy(new_body[injection_point + script.len ..], body[injection_point..]);

    return Response.html(new_body);
}

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
    var html = std.ArrayListUnmanaged(u8){};
    defer html.deinit(std.testing.allocator);

    try html.appendNTimes(std.testing.allocator, 'x', 600);
    try html.appendSlice(std.testing.allocator, "<!DOCTYPE html>");

    try std.testing.expect(!isFullHtmlPage(html.items));
}

test "findInjectionPoint" {
    const html1 = "<!DOCTYPE html><html><head><title>Test</title></head><body>Hello</body></html>";
    try std.testing.expectEqual(@as(?usize, 46), findInjectionPoint(html1));

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
    const html = "<!DOCTYPE html><html><body><div>Content</div></body><script>test</script></body></html>";
    const pos = findInjectionPoint(html);
    try std.testing.expect(pos != null);
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

    const script1 = try buildScriptTag(std.testing.allocator, config);
    defer std.testing.allocator.free(script1);

    const script2 = try buildScriptTag(std.testing.allocator, config);
    defer std.testing.allocator.free(script2);

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
    try std.testing.expect(!isExcludedPath("/unique-test-path-12345"));
}

test "injectHtmx disabled" {
    setConfig(null);
    const resp = Response.html("<!DOCTYPE html><html><head></head><body>Test</body></html>");
    const result = injectHtmx(resp);

    try std.testing.expectEqualStrings(resp.getBody(), result.getBody());
}

test "injectHtmx empty body" {
    setConfig(.{ .enabled = true });
    const resp = Response.html("");
    const result = injectHtmx(resp);

    try std.testing.expectEqualStrings("", result.getBody());
}

test "injectHtmx fragment without inject_fragments" {
    setConfig(.{
        .enabled = true,
        .inject_fragments = false,
    });

    const resp = Response.html("<div>Fragment</div>");
    const result = injectHtmx(resp);

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

    const body = result.getBody();
    var count: usize = 0;
    var pos: ?usize = 0;
    while (std.mem.indexOfPos(u8, body, pos.?, "htmx.min.js")) |found| {
        count += 1;
        pos = found + 1;
    }
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
    try std.testing.expect(std.mem.indexOf(u8, body, "<h1>Hello World</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<p>Test content</p>") != null);
}
