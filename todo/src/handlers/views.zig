const std = @import("std");
const E12 = @import("engine12");
const Request = E12.Request;
const Response = E12.Response;
const RuntimeTemplate = E12.RuntimeTemplate;
const database = @import("../database.zig");
const getGlobalTemplateRegistry = database.getGlobalTemplateRegistry;

const allocator = std.heap.page_allocator;

/// Handle index page (root route) - serves the HTMX interface
pub fn handleIndex(request: *Request) Response {
    return handleHtmxIndex(request);
}

/// Handle HTMX-powered index page
pub fn handleHtmxIndex(request: *Request) Response {
    _ = request;

    // Use template registry (from auto-discovery) if available
    var template: ?*RuntimeTemplate = null;
    if (getGlobalTemplateRegistry()) |registry| {
        template = registry.get("htmx-index");
    }

    const final_template = template orelse {
        return Response.text("HTMX template not loaded. Make sure htmx-index.zt.html exists in templates/").withStatus(500);
    };

    // Define context type
    const IndexContext = struct {
        title: []const u8,
        subtitle: []const u8,
    };

    // Create context
    const context = IndexContext{
        .title = "Todo List",
        .subtitle = "A simple todo app powered by HTMX and Engine12",
    };

    // Render template
    const html = final_template.render(IndexContext, context, allocator) catch {
        return Response.text("Internal server error: template rendering failed").withStatus(500);
    };

    return Response.html(html);
}
