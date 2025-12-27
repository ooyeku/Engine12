const std = @import("std");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const middleware = @import("middleware.zig");

pub const RequestIdConfig = struct {
    header_name: []const u8 = "X-Request-ID",
};

pub const RequestIdMiddleware = struct {
    config: RequestIdConfig,

    pub fn init(config: RequestIdConfig) RequestIdMiddleware {
        return RequestIdMiddleware{ .config = config };
    }

    fn preRequestMiddleware(req: *Request) middleware.MiddlewareResult {
        req.set("request_id_header", "X-Request-ID") catch {};
        return .proceed;
    }

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
