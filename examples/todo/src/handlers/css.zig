//! CSS Handler - Serves dynamically generated CSS using Engine12's CSS-in-Zig API
const std = @import("std");
const E12 = @import("engine12");
const Request = E12.Request;
const Response = E12.Response;
const styles = @import("../styles.zig");

// Global cache for the stylesheet to avoid regeneration on every request
var css_mutex = std.Thread.Mutex{};
var cached_styles: ?styles.CachedStylesheet = null;

/// Handler to serve the generated CSS stylesheet
pub fn handleCss(_: *Request) Response {
    // Protect cache access with mutex
    css_mutex.lock();
    defer css_mutex.unlock();

    if (cached_styles == null) {
        // Initialize cache on first request
        cached_styles = styles.CachedStylesheet.init(std.heap.page_allocator, styles.generateStylesheet);
    }

    // Get CSS from cache (generates only if dirty or empty)
    const css_content = cached_styles.?.getCss() catch {
        return Response.text("/* Error generating CSS */").withStatus(500);
    };

    var resp = Response.text(css_content);
    resp = resp.withContentType("text/css; charset=utf-8");
    // Cache for 1 hour in browser, but server-side cache handles regeneration efficiency
    resp = resp.withHeader("Cache-Control", "public, max-age=3600");
    return resp;
}

/// Handler to serve minified CSS (for production)
pub fn handleMinifiedCss(_: *Request) Response {
    css_mutex.lock();
    defer css_mutex.unlock();

    if (cached_styles == null) {
        cached_styles = styles.CachedStylesheet.init(std.heap.page_allocator, styles.generateStylesheet);
    }

    const css_content = cached_styles.?.getMinifiedCss() catch {
        return Response.text("/* Error generating CSS */").withStatus(500);
    };

    var resp = Response.text(css_content);
    resp = resp.withContentType("text/css; charset=utf-8");
    resp = resp.withHeader("Cache-Control", "public, max-age=86400"); // Cache for 24 hours
    return resp;
}
