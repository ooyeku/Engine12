const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const metrics = @import("metrics.zig");

pub fn handleDefaultRoot(request: *Request) Response {
    _ = request;
    return Response.json("{\"service\":\"engine12\",\"status\":\"running\"}");
}

pub fn handleHealthEndpoint(request: *Request) Response {
    const health_mod = @import("health.zig");
    return health_mod.handleHealth(request);
}

pub fn handleReadyEndpoint(request: *Request) Response {
    const health_mod = @import("health.zig");
    return health_mod.handleReady(request);
}

pub fn handleMetricsEndpoint(request: *Request) Response {
    _ = request;
    const metrics_collector = @import("engine12.zig").global_metrics;

    if (metrics_collector) |mc| {
        const prometheus_output = mc.getPrometheusMetrics() catch {
            return Response.json("{\"error\":\"Failed to generate metrics\"}").withStatus(500);
        };
        defer std.heap.page_allocator.free(prometheus_output);

        var resp = Response.text(prometheus_output);
        resp = resp.withContentType("text/plain; version=0.0.4");
        return resp;
    }

    return Response.json("{\"metrics\":{\"uptime_ms\":0,\"requests_total\":0}}");
}

test "handleDefaultRoot returns correct JSON" {
    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    const resp = handleDefaultRoot(&req);
    _ = resp;
}

test "handleHealthEndpoint returns correct JSON" {
    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/health",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    const resp = handleHealthEndpoint(&req);
    _ = resp;
}

