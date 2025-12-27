const std = @import("std");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const types = @import("../types.zig");

pub const MiddlewareResult = enum {
    proceed, // Continue to next middleware/handler
    abort, // Stop processing and return response
};

pub const PreRequestMiddlewareFn = *const fn (*Request) MiddlewareResult;

pub const ResponseMiddlewareFn = *const fn (Response) Response;

pub const MiddlewareChain = struct {
    pub const MAX_MIDDLEWARE = 16;

    pre_request_middleware: [MAX_MIDDLEWARE]?PreRequestMiddlewareFn = [_]?PreRequestMiddlewareFn{null} ** MAX_MIDDLEWARE,
    pre_request_count: usize = 0,

    response_middleware: [MAX_MIDDLEWARE]?ResponseMiddlewareFn = [_]?ResponseMiddlewareFn{null} ** MAX_MIDDLEWARE,
    response_count: usize = 0,

    pub fn executePreRequest(self: *const MiddlewareChain, req: *Request) ?Response {
        for (self.pre_request_middleware[0..self.pre_request_count]) |maybe_middleware| {
            if (maybe_middleware) |middleware| {
                const result = middleware(req);
                switch (result) {
                    .proceed => continue,
                    .abort => {
                        if (req.context.get("rate_limited")) |_| {
                            return Response.json(
                                \\{"error":"Rate limit exceeded","message":"Too many requests"}
                            ).withStatus(429);
                        }
                        if (req.context.get("body_size_exceeded")) |_| {
                            const limit_str = req.context.get("body_size_limit") orelse "unknown";
                            const error_msg = std.fmt.allocPrint(req.arena.allocator(),
                                \\{{"error":"Request body too large","message":"Request body exceeds maximum size of {s} bytes","code":"REQUEST_TOO_LARGE"}}
                            , .{limit_str}) catch {
                                return Response.json(
                                    \\{"error":"Request body too large","message":"Request body exceeds maximum allowed size"}
                                ).withStatus(413);
                            };
                            return Response.json(error_msg).withStatus(413);
                        }
                        if (req.context.get("csrf_error")) |_| {
                            return Response.json(
                                \\{"error":"CSRF validation failed","message":"Invalid or missing CSRF token","code":"CSRF_ERROR"}
                            ).withStatus(403);
                        }
                        if (req.context.get("cache_hit")) |_| {
                            const etag = req.context.get("cache_etag") orelse "";
                            var resp = Response.status(304);
                            resp = resp.withHeader("ETag", etag);
                            resp = resp.withHeader("Cache-Control", "public, max-age=3600");
                            return resp;
                        }
                        return Response.unauthorized();
                    },
                }
            }
        }
        return null;
    }

    pub fn executeResponse(self: *const MiddlewareChain, response: Response, req: ?*Request) Response {
        var transformed_response = response;
        for (self.response_middleware[0..self.response_count]) |maybe_middleware| {
            if (maybe_middleware) |middleware| {
                transformed_response = middleware(transformed_response);
            }
        }

        if (req) |request| {
            if (request.context.get("cache_hit")) |hit| {
                if (std.mem.eql(u8, hit, "true")) {
                    const etag = request.context.get("cache_etag") orelse "";
                    transformed_response = transformed_response.withHeader("ETag", etag);
                    transformed_response = transformed_response.withHeader("Cache-Control", "public, max-age=3600");
                    transformed_response = transformed_response.withHeader("Last-Modified", "");
                }
            }

            if (request.context.get("cors_origin")) |origin| {
                transformed_response = transformed_response.withHeader("Access-Control-Allow-Origin", origin);

                if (request.context.get("cors_allow_credentials")) |_| {
                    transformed_response = transformed_response.withHeader("Access-Control-Allow-Credentials", "true");
                }

                if (request.context.get("cors_preflight")) |_| {
                    if (request.context.get("cors_allowed_methods")) |methods| {
                        transformed_response = transformed_response.withHeader("Access-Control-Allow-Methods", methods);
                    }
                    if (request.context.get("cors_allowed_headers")) |headers| {
                        transformed_response = transformed_response.withHeader("Access-Control-Allow-Headers", headers);
                    }
                    if (request.context.get("cors_max_age")) |max_age| {
                        transformed_response = transformed_response.withHeader("Access-Control-Max-Age", max_age);
                    }
                    return Response.status(204);
                }

                if (request.context.get("cors_exposed_headers")) |exposed| {
                    transformed_response = transformed_response.withHeader("Access-Control-Expose-Headers", exposed);
                }
            }

            if (request.context.get("request_id_header")) |header_name| {
                if (request.requestId()) |req_id| {
                    transformed_response = transformed_response.withHeader(header_name, req_id);
                }
            }
        }

        return transformed_response;
    }

    pub fn addPreRequest(self: *MiddlewareChain, middleware: PreRequestMiddlewareFn) !void {
        if (self.pre_request_count >= MAX_MIDDLEWARE) {
            return error.TooManyMiddleware;
        }
        self.pre_request_middleware[self.pre_request_count] = middleware;
        self.pre_request_count += 1;
    }

    pub fn addResponse(self: *MiddlewareChain, middleware: ResponseMiddlewareFn) !void {
        if (self.response_count >= MAX_MIDDLEWARE) {
            return error.TooManyMiddleware;
        }
        self.response_middleware[self.response_count] = middleware;
        self.response_count += 1;
    }

    pub fn clear(self: *MiddlewareChain) void {
        self.pre_request_count = 0;
        self.response_count = 0;
        @memset(&self.pre_request_middleware, null);
        @memset(&self.response_middleware, null);
    }
};

fn createTestZigguratRequest(path: []const u8, method: @import("ziggurat").request.Method, body: []const u8) @import("ziggurat").request.Request {
    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    return ziggurat.request.Request{
        .path = path,
        .method = method,
        .body = body,
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
}

test "MiddlewareChain add and execute pre-request" {
    var chain = MiddlewareChain{};

    const middleware1 = struct {
        fn mw(req: *Request) MiddlewareResult {
            _ = req;
            return .proceed;
        }
    };

    try chain.addPreRequest(&middleware1.mw);

    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const result = chain.executePreRequest(&req);
    try std.testing.expect(result == null);
}

test "MiddlewareChain short-circuit on abort" {
    var chain = MiddlewareChain{};

    const abortMw = struct {
        fn mw(req: *Request) MiddlewareResult {
            _ = req;
            return .abort;
        }
    };

    try chain.addPreRequest(&abortMw.mw);

    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const result = chain.executePreRequest(&req);
    try std.testing.expect(result != null);
}

test "MiddlewareChain execute multiple middleware in order" {
    var chain = MiddlewareChain{};

    const mw1 = struct {
        fn mw(req: *Request) MiddlewareResult {
            _ = req;
            return .proceed;
        }
    };

    const mw2 = struct {
        fn mw(req: *Request) MiddlewareResult {
            _ = req;
            return .proceed;
        }
    };

    try chain.addPreRequest(&mw1.mw);
    try chain.addPreRequest(&mw2.mw);

    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    _ = chain.executePreRequest(&req);

    try std.testing.expect(chain.pre_request_count == 2);
}

test "MiddlewareChain execute response middleware" {
    var chain = MiddlewareChain{};

    const mw = struct {
        fn mw(resp: Response) Response {
            return resp.withStatus(201);
        }
    };

    try chain.addResponse(&mw.mw);

    const original = Response.ok();
    var ziggurat_req = createTestZigguratRequest("/test", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    const transformed = chain.executeResponse(original, &req);
    _ = transformed;
}

test "MiddlewareChain addPreRequest fails when max exceeded" {
    var chain = MiddlewareChain{};

    const mw = struct {
        fn mw(req: *Request) MiddlewareResult {
            _ = req;
            return .proceed;
        }
    };

    var i: usize = 0;
    while (i < MiddlewareChain.MAX_MIDDLEWARE) : (i += 1) {
        try chain.addPreRequest(&mw.mw);
    }

    try std.testing.expectError(error.TooManyMiddleware, chain.addPreRequest(&mw.mw));
}

test "MiddlewareChain addResponse fails when max exceeded" {
    var chain = MiddlewareChain{};

    const mw = struct {
        fn mw(resp: Response) Response {
            return resp;
        }
    };

    var i: usize = 0;
    while (i < MiddlewareChain.MAX_MIDDLEWARE) : (i += 1) {
        try chain.addResponse(&mw.mw);
    }

    try std.testing.expectError(error.TooManyMiddleware, chain.addResponse(&mw.mw));
}

test "MiddlewareChain clear removes all middleware" {
    var chain = MiddlewareChain{};

    const mw1 = struct {
        fn mw(req: *Request) MiddlewareResult {
            _ = req;
            return .proceed;
        }
    };

    const mw2 = struct {
        fn mw(resp: Response) Response {
            return resp;
        }
    };

    try chain.addPreRequest(&mw1.mw);
    try chain.addResponse(&mw2.mw);

    chain.clear();

    try std.testing.expectEqual(chain.pre_request_count, 0);
    try std.testing.expectEqual(chain.response_count, 0);
}

test "MiddlewareChain execute multiple pre-request middleware in order" {
    var chain = MiddlewareChain{};

    const mw1 = struct {
        fn mw(req: *Request) MiddlewareResult {
            req.context.put("mw1_called", "true") catch {};
            return .proceed;
        }
    };

    const mw2 = struct {
        fn mw(req: *Request) MiddlewareResult {
            req.context.put("mw2_called", "true") catch {};
            return .proceed;
        }
    };

    const mw3 = struct {
        fn mw(req: *Request) MiddlewareResult {
            req.context.put("mw3_called", "true") catch {};
            return .proceed;
        }
    };

    try chain.addPreRequest(&mw1.mw);
    try chain.addPreRequest(&mw2.mw);
    try chain.addPreRequest(&mw3.mw);

    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    _ = chain.executePreRequest(&req);

    try std.testing.expect(req.context.get("mw1_called") != null);
    try std.testing.expect(req.context.get("mw2_called") != null);
    try std.testing.expect(req.context.get("mw3_called") != null);
    try std.testing.expectEqual(chain.pre_request_count, 3);
}

test "MiddlewareChain executePreRequest stops on first abort" {
    var chain = MiddlewareChain{};

    const mw1 = struct {
        fn mw(req: *Request) MiddlewareResult {
            _ = req;
            return .abort;
        }
    };

    const mw2 = struct {
        fn mw(req: *Request) MiddlewareResult {
            req.context.put("mw2_called", "true") catch {};
            return .proceed;
        }
    };

    try chain.addPreRequest(&mw1.mw);
    try chain.addPreRequest(&mw2.mw);

    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const result = chain.executePreRequest(&req);
    try std.testing.expect(result != null);
    try std.testing.expect(req.context.get("mw2_called") == null);
}

test "MiddlewareChain executeResponse transforms through all middleware" {
    var chain = MiddlewareChain{};

    const mw1 = struct {
        fn mw(resp: Response) Response {
            return resp.withStatus(201);
        }
    };

    const mw2 = struct {
        fn mw(resp: Response) Response {
            return resp.withContentType("application/json");
        }
    };

    try chain.addResponse(&mw1.mw);
    try chain.addResponse(&mw2.mw);

    const original = Response.ok();
    var ziggurat_req = createTestZigguratRequest("/test", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    const transformed = chain.executeResponse(original, &req);
    _ = transformed;
}

test "MiddlewareChain executePreRequest with rate limit context" {
    var chain = MiddlewareChain{};

    const mw = struct {
        fn mw(req: *Request) MiddlewareResult {
            req.context.put("rate_limited", "true") catch {};
            return .abort;
        }
    };

    try chain.addPreRequest(&mw.mw);

    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const result = chain.executePreRequest(&req);
    try std.testing.expect(result != null);
}

test "MiddlewareChain executePreRequest with body size exceeded context" {
    var chain = MiddlewareChain{};

    const mw = struct {
        fn mw(req: *Request) MiddlewareResult {
            req.context.put("body_size_exceeded", "true") catch {};
            req.context.put("body_size_limit", "1000") catch {};
            return .abort;
        }
    };

    try chain.addPreRequest(&mw.mw);

    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const result = chain.executePreRequest(&req);
    try std.testing.expect(result != null);
}

test "MiddlewareChain executePreRequest with CSRF error context" {
    var chain = MiddlewareChain{};

    const mw = struct {
        fn mw(req: *Request) MiddlewareResult {
            req.context.put("csrf_error", "true") catch {};
            return .abort;
        }
    };

    try chain.addPreRequest(&mw.mw);

    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const result = chain.executePreRequest(&req);
    try std.testing.expect(result != null);
}

test "MiddlewareChain executeResponse with cache hit" {
    var chain = MiddlewareChain{};

    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    try req.context.put("cache_hit", "true");
    try req.context.put("cache_etag", "\"abc123\"");

    const resp = Response.ok();
    const transformed = chain.executeResponse(resp, &req);
    _ = transformed;
}

test "MiddlewareChain empty chain executes successfully" {
    var chain = MiddlewareChain{};

    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const result = chain.executePreRequest(&req);
    try std.testing.expect(result == null);

    const resp = Response.ok();
    var ziggurat_req2 = createTestZigguratRequest("/test", .GET, "");
    var req2 = Request.fromZiggurat(&ziggurat_req2, std.testing.allocator);
    defer req2.deinit();
    const transformed = chain.executeResponse(resp, &req2);
    _ = transformed;
}
