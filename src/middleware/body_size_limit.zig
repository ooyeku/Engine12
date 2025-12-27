const std = @import("std");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const middleware_chain = @import("middleware.zig");

pub const BodySizeLimit = struct {
    max_bytes: u64,
    error_message: []const u8 = "Request body too large",
};

pub const DefaultLimits = struct {
    pub const json: u64 = 1024 * 1024;

    pub const form_data: u64 = 10 * 1024 * 1024;

    pub const file_upload: u64 = 50 * 1024 * 1024;

    pub const general: u64 = 5 * 1024 * 1024;
};

const BodySizeLimitMiddleware = struct {
    limit: BodySizeLimit,

    pub fn middleware(self: *const BodySizeLimitMiddleware, req: *Request) middleware_chain.MiddlewareResult {
        const body = req.body();

        if (body.len > self.limit.max_bytes) {
            req.context.put("body_size_exceeded", "true") catch {};
            const limit_str = std.fmt.allocPrint(req.arena.allocator(), "{d}", .{self.limit.max_bytes}) catch "unknown";
            req.context.put("body_size_limit", limit_str) catch {};
            return .abort;
        }

        return .proceed;
    }
};

var body_size_limit_instances: [8]*const BodySizeLimitMiddleware = undefined;
var body_size_limit_count: usize = 0;
var body_size_limit_mutex: std.Thread.Mutex = .{};

pub fn createBodySizeLimitMiddleware(limit: BodySizeLimit) middleware_chain.PreRequestMiddlewareFn {
    body_size_limit_mutex.lock();
    defer body_size_limit_mutex.unlock();

    const instance = std.heap.page_allocator.create(BodySizeLimitMiddleware) catch {
        return struct {
            fn mw(_: *Request) middleware_chain.MiddlewareResult {
                return .proceed;
            }
        }.mw;
    };
    instance.* = BodySizeLimitMiddleware{ .limit = limit };

    const id = body_size_limit_count;
    body_size_limit_instances[id] = instance;
    body_size_limit_count += 1;

    return switch (id) {
        0 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                return body_size_limit_instances[0].middleware(req);
            }
        }.mw,
        1 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                return body_size_limit_instances[1].middleware(req);
            }
        }.mw,
        2 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                return body_size_limit_instances[2].middleware(req);
            }
        }.mw,
        3 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                return body_size_limit_instances[3].middleware(req);
            }
        }.mw,
        4 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                return body_size_limit_instances[4].middleware(req);
            }
        }.mw,
        5 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                return body_size_limit_instances[5].middleware(req);
            }
        }.mw,
        6 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                return body_size_limit_instances[6].middleware(req);
            }
        }.mw,
        7 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                return body_size_limit_instances[7].middleware(req);
            }
        }.mw,
        else => unreachable,
    };
}

pub fn createContentTypeBodySizeLimitMiddleware() middleware_chain.PreRequestMiddlewareFn {
    return struct {
        fn mw(req: *Request) middleware_chain.MiddlewareResult {
            const body = req.body();
            const content_type = req.header("Content-Type") orelse "";

            var limit: u64 = DefaultLimits.general;

            if (std.mem.indexOf(u8, content_type, "application/json") != null) {
                limit = DefaultLimits.json;
            } else if (std.mem.indexOf(u8, content_type, "multipart/form-data") != null) {
                limit = DefaultLimits.file_upload;
            } else if (std.mem.indexOf(u8, content_type, "application/x-www-form-urlencoded") != null) {
                limit = DefaultLimits.form_data;
            }

            if (body.len > limit) {
                req.context.put("body_size_exceeded", "true") catch {};
                const limit_str = std.fmt.allocPrint(req.arena.allocator(), "{d}", .{limit}) catch "unknown";
                req.context.put("body_size_limit", limit_str) catch {};
                return .abort;
            }

            return .proceed;
        }
    }.mw;
}

test "createBodySizeLimitMiddleware allows requests within limit" {
    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .POST,
        .body = "small body",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const mw = createBodySizeLimitMiddleware(BodySizeLimit{
        .max_bytes = 1000,
    });

    const result = mw(&req);
    try std.testing.expectEqual(result, .proceed);
}

test "createBodySizeLimitMiddleware rejects requests exceeding limit" {
    var large_body = std.ArrayList(u8).init(std.testing.allocator);
    defer large_body.deinit();
    try large_body.writer().print("{s}", .{"x"} ** 2000); // Create 2000 byte body

    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/test",
        .method = .POST,
        .body = large_body.items,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const mw = createBodySizeLimitMiddleware(BodySizeLimit{
        .max_bytes = 1000,
    });

    const result = mw(&req);
    try std.testing.expectEqual(result, .abort);

    try std.testing.expect(req.context.get("body_size_exceeded") != null);
}

test "createContentTypeBodySizeLimitMiddleware sets appropriate limits" {
    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .POST,
        .body = "small",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const mw = createContentTypeBodySizeLimitMiddleware();
    const result = mw(&req);
    try std.testing.expectEqual(result, .proceed);
}

test "createBodySizeLimitMiddleware allows exact limit size" {
    var exact_body = std.ArrayList(u8).init(std.testing.allocator);
    defer exact_body.deinit();
    try exact_body.writer().print("{s}", .{"x"} ** 1000); // Exactly 1000 bytes

    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/test",
        .method = .POST,
        .body = exact_body.items,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const mw = createBodySizeLimitMiddleware(BodySizeLimit{
        .max_bytes = 1000,
    });

    const result = mw(&req);
    try std.testing.expectEqual(result, .proceed);
}

test "createBodySizeLimitMiddleware rejects exact limit plus one byte" {
    var too_large_body = std.ArrayList(u8).init(std.testing.allocator);
    defer too_large_body.deinit();
    try too_large_body.writer().print("{s}", .{"x"} ** 1001); // 1001 bytes

    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/test",
        .method = .POST,
        .body = too_large_body.items,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const mw = createBodySizeLimitMiddleware(BodySizeLimit{
        .max_bytes = 1000,
    });

    const result = mw(&req);
    try std.testing.expectEqual(result, .abort);
    try std.testing.expect(req.context.get("body_size_exceeded") != null);
    try std.testing.expect(req.context.get("body_size_limit") != null);
}

test "createBodySizeLimitMiddleware allows empty body" {
    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .POST,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const mw = createBodySizeLimitMiddleware(BodySizeLimit{
        .max_bytes = 1000,
    });

    const result = mw(&req);
    try std.testing.expectEqual(result, .proceed);
}

test "createBodySizeLimitMiddleware with zero limit rejects all bodies" {
    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .POST,
        .body = "x",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const mw = createBodySizeLimitMiddleware(BodySizeLimit{
        .max_bytes = 0,
    });

    const result = mw(&req);
    try std.testing.expectEqual(result, .abort);
}

test "createBodySizeLimitMiddleware with zero limit allows empty body" {
    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .POST,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const mw = createBodySizeLimitMiddleware(BodySizeLimit{
        .max_bytes = 0,
    });

    const result = mw(&req);
    try std.testing.expectEqual(result, .proceed);
}

test "createContentTypeBodySizeLimitMiddleware detects JSON content type" {
    var json_body = std.ArrayList(u8).init(std.testing.allocator);
    defer json_body.deinit();
    try json_body.writer().print("{s}", .{"x"} ** (DefaultLimits.json + 1));

    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/test",
        .method = .POST,
        .body = json_body.items,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const mw = createContentTypeBodySizeLimitMiddleware();
    const result = mw(&req);
    try std.testing.expectEqual(result, .abort);
}

test "createContentTypeBodySizeLimitMiddleware allows JSON within limit" {
    var json_body = std.ArrayList(u8).init(std.testing.allocator);
    defer json_body.deinit();
    try json_body.writer().print("{s}", .{"x"} ** (DefaultLimits.json - 1));

    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/test",
        .method = .POST,
        .body = json_body.items,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const mw = createContentTypeBodySizeLimitMiddleware();
    const result = mw(&req);
    try std.testing.expectEqual(result, .proceed);
}

test "createContentTypeBodySizeLimitMiddleware handles empty Content-Type" {
    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/test",
        .method = .POST,
        .body = "small body",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const mw = createContentTypeBodySizeLimitMiddleware();
    const result = mw(&req);
    try std.testing.expectEqual(result, .proceed);
}

test "createContentTypeBodySizeLimitMiddleware handles very large body" {
    var huge_body = std.ArrayList(u8).init(std.testing.allocator);
    defer huge_body.deinit();
    try huge_body.writer().print("{s}", .{"x"} ** (DefaultLimits.general + 1));

    var ziggurat_req = @import("ziggurat").request.Request{
        .path = "/test",
        .method = .POST,
        .body = huge_body.items,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const mw = createContentTypeBodySizeLimitMiddleware();
    const result = mw(&req);
    try std.testing.expectEqual(result, .abort);
    try std.testing.expect(req.context.get("body_size_exceeded") != null);
}

test "DefaultLimits constants are correct" {
    try std.testing.expectEqual(DefaultLimits.json, 1024 * 1024);
    try std.testing.expectEqual(DefaultLimits.form_data, 10 * 1024 * 1024);
    try std.testing.expectEqual(DefaultLimits.file_upload, 50 * 1024 * 1024);
    try std.testing.expectEqual(DefaultLimits.general, 5 * 1024 * 1024);
}

test "BodySizeLimit struct initialization" {
    const limit = BodySizeLimit{
        .max_bytes = 1000,
        .error_message = "Custom error",
    };
    try std.testing.expectEqual(limit.max_bytes, 1000);
    try std.testing.expectEqualStrings(limit.error_message, "Custom error");
}

test "BodySizeLimit struct default error message" {
    const limit = BodySizeLimit{
        .max_bytes = 1000,
    };
    try std.testing.expectEqualStrings(limit.error_message, "Request body too large");
}
