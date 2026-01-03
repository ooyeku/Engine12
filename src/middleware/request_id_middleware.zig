const std = @import("std");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const middleware = @import("middleware.zig");

/// Configuration for request ID middleware.
/// Request IDs help trace requests through logs and distributed systems.
pub const RequestIdConfig = struct {
    /// Name of the HTTP header that will contain the request ID in responses
    header_name: []const u8 = "X-Request-ID",
};

/// Middleware for generating and tracking unique request IDs.
/// Request IDs are automatically generated for each incoming request and can be:
/// - Included in log entries to correlate related log messages
/// - Returned in response headers for client-side debugging
/// - Used to trace requests across microservices
///
/// ## Example
/// ```zig
/// const req_id = RequestIdMiddleware.init(.{ .header_name = "X-Request-ID" });
/// app.usePreRequest(req_id.preRequestMwFn());
/// ```
pub const RequestIdMiddleware = struct {
    config: RequestIdConfig,

    /// Initialize request ID middleware with the given configuration.
    pub fn init(config: RequestIdConfig) RequestIdMiddleware {
        return RequestIdMiddleware{ .config = config };
    }

    fn preRequestMiddleware(req: *Request) middleware.MiddlewareResult {
        req.set("request_id_header", "X-Request-ID") catch {};
        return .proceed;
    }

    /// Get the pre-request middleware function for request ID generation.
    /// This middleware stores the request ID header name in the request context,
    /// which is then used by the middleware chain to add the header to responses.
    ///
    /// ## Example
    /// ```zig
    /// var req_id_mw = RequestIdMiddleware.init(.{});
    /// app.usePreRequest(req_id_mw.preRequestMwFn());
    /// ```
    pub fn preRequestMwFn(_: *const RequestIdMiddleware) middleware.PreRequestMiddlewareFn {
        const Self = @This();
        return struct {
            fn mw(req: *Request) middleware.MiddlewareResult {
                return Self.preRequestMiddleware(req);
            }
        }.mw;
    }
};

test "RequestIdMiddleware init" {
    const req_id_mw = RequestIdMiddleware.init(.{ .header_name = "X-Request-ID" });
    try std.testing.expectEqualStrings(req_id_mw.config.header_name, "X-Request-ID");
}

test "RequestIdMiddleware default config" {
    const req_id_mw = RequestIdMiddleware.init(.{});
    try std.testing.expectEqualStrings(req_id_mw.config.header_name, "X-Request-ID");
}
