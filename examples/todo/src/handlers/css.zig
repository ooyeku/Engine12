//! CSS Handler - Serves dynamically generated CSS using Engine12's CSS-in-Zig API
const std = @import("std");
const E12 = @import("engine12");
const Request = E12.Request;
const Response = E12.Response;
const styles = @import("../styles.zig");

/// Handler to serve the generated CSS stylesheet
pub fn handleCss(_: *Request) Response {
    const allocator = std.heap.page_allocator;

    // Generate the CSS (or use minified for production)
    const css_content = styles.generateCss(allocator) catch {
        return Response.text("/* Error generating CSS */").withStatus(500);
    };

    // Note: In a production app, you'd want to:
    // 1. Cache this generated CSS at startup
    // 2. Only regenerate when styles change (during development)
    // For now, we generate on each request

    var resp = Response.text(css_content);
    resp = resp.withContentType("text/css; charset=utf-8");
    resp = resp.withHeader("Cache-Control", "public, max-age=3600"); // Cache for 1 hour
    return resp;
}

/// Handler to serve minified CSS (for production)
pub fn handleMinifiedCss(_: *Request) Response {
    const allocator = std.heap.page_allocator;

    const css_content = styles.generateMinifiedCss(allocator) catch {
        return Response.text("/* Error generating CSS */").withStatus(500);
    };

    var resp = Response.text(css_content);
    resp = resp.withContentType("text/css; charset=utf-8");
    resp = resp.withHeader("Cache-Control", "public, max-age=86400"); // Cache for 24 hours
    return resp;
}
