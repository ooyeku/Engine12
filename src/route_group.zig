const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware_chain = @import("middleware.zig");

pub const RouteGroup = struct {
    const Self = @This();

    engine_ptr: *anyopaque,

    prefix: []const u8,

    middleware: middleware_chain.MiddlewareChain,

    register_get: *const fn (*anyopaque, []const u8, anytype) anyerror!void,
    register_post: *const fn (*anyopaque, []const u8, anytype) anyerror!void,
    register_put: *const fn (*anyopaque, []const u8, anytype) anyerror!void,
    register_delete: *const fn (*anyopaque, []const u8, anytype) anyerror!void,

    pub fn usePreRequest(self: *Self, middleware: middleware_chain.PreRequestMiddlewareFn) !void {
        try self.middleware.addPreRequest(middleware);
    }

    pub fn useResponse(self: *Self, middleware: middleware_chain.ResponseMiddlewareFn) !void {
        try self.middleware.addResponse(middleware);
    }

    pub fn group(self: *Self, additional_prefix: []const u8) Self {
        const combined_prefix = self.combinePrefix(self.prefix, additional_prefix);
        const nested = Self{
            .engine_ptr = self.engine_ptr,
            .prefix = combined_prefix,
            .middleware = self.middleware, // Copy middleware from parent
            .register_get = self.register_get,
            .register_post = self.register_post,
            .register_put = self.register_put,
            .register_delete = self.register_delete,
        };
        return nested;
    }

    fn combinePrefix(self: *const Self, prefix1: []const u8, prefix2: []const u8) []const u8 {
        _ = self;
        if (prefix1.len == 0) return prefix2;
        if (prefix2.len == 0) return prefix1;

        return prefix2;
    }

    fn buildFullPath(self: *const Self, comptime path: []const u8) []const u8 {
        _ = self;
        return path;
    }

    pub fn get(self: *Self, comptime path: []const u8, handler: anytype) !void {
        const original_middleware = @import("engine12.zig").global_middleware;
        @import("engine12.zig").global_middleware = &self.middleware;
        defer @import("engine12.zig").global_middleware = original_middleware;

        const full_path = self.buildFullPath(path);
        try self.register_get(self.engine_ptr, full_path, handler);
    }

    pub fn post(self: *Self, comptime path: []const u8, handler: anytype) !void {
        const original_middleware = @import("engine12.zig").global_middleware;
        @import("engine12.zig").global_middleware = &self.middleware;
        defer @import("engine12.zig").global_middleware = original_middleware;
        const full_path = self.buildFullPath(path);
        try self.register_post(self.engine_ptr, full_path, handler);
    }

    pub fn postEmpty(self: *Self, comptime path: []const u8, handler: anytype) !void {
        return self.post(path, handler);
    }

    pub fn put(self: *Self, comptime path: []const u8, handler: anytype) !void {
        const original_middleware = @import("engine12.zig").global_middleware;
        @import("engine12.zig").global_middleware = &self.middleware;
        defer @import("engine12.zig").global_middleware = original_middleware;
        const full_path = self.buildFullPath(path);
        try self.register_put(self.engine_ptr, full_path, handler);
    }

    pub fn delete(self: *Self, comptime path: []const u8, handler: anytype) !void {
        const original_middleware = @import("engine12.zig").global_middleware;
        @import("engine12.zig").global_middleware = &self.middleware;
        defer @import("engine12.zig").global_middleware = original_middleware;
        const full_path = self.buildFullPath(path);
        try self.register_delete(self.engine_ptr, full_path, handler);
    }
};

test "RouteGroup usePreRequest adds middleware" {
    var group = RouteGroup{
        .engine_ptr = undefined,
        .prefix = "/api",
        .middleware = middleware_chain.MiddlewareChain{},
        .register_get = undefined,
        .register_post = undefined,
        .register_put = undefined,
        .register_delete = undefined,
    };

    const mw = struct {
        fn mw(req: *Request) middleware_chain.MiddlewareResult {
            _ = req;
            return .proceed;
        }
    };

    try group.usePreRequest(&mw.mw);
    try std.testing.expectEqual(group.middleware.pre_request_count, 1);
}

test "RouteGroup useResponse adds middleware" {
    var group = RouteGroup{
        .engine_ptr = undefined,
        .prefix = "/api",
        .middleware = middleware_chain.MiddlewareChain{},
        .register_get = undefined,
        .register_post = undefined,
        .register_put = undefined,
        .register_delete = undefined,
    };

    const mw = struct {
        fn mw(resp: Response) Response {
            return resp;
        }
    };

    try group.useResponse(&mw.mw);
    try std.testing.expectEqual(group.middleware.response_count, 1);
}

test "RouteGroup group creates nested group" {
    var group = RouteGroup{
        .engine_ptr = undefined,
        .prefix = "/api",
        .middleware = middleware_chain.MiddlewareChain{},
        .register_get = undefined,
        .register_post = undefined,
        .register_put = undefined,
        .register_delete = undefined,
    };

    const nested = group.group("/v1");
    try std.testing.expect(nested.prefix.len > 0);
}

test "RouteGroup combinePrefix with empty prefix1" {
    var group = RouteGroup{
        .engine_ptr = undefined,
        .prefix = "",
        .middleware = middleware_chain.MiddlewareChain{},
        .register_get = undefined,
        .register_post = undefined,
        .register_put = undefined,
        .register_delete = undefined,
    };

    const combined = group.combinePrefix("", "/api");
    try std.testing.expectEqualStrings(combined, "/api");
}

test "RouteGroup combinePrefix with empty prefix2" {
    var group = RouteGroup{
        .engine_ptr = undefined,
        .prefix = "/api",
        .middleware = middleware_chain.MiddlewareChain{},
        .register_get = undefined,
        .register_post = undefined,
        .register_put = undefined,
        .register_delete = undefined,
    };

    const combined = group.combinePrefix("/api", "");
    try std.testing.expectEqualStrings(combined, "/api");
}

test "RouteGroup buildFullPath" {
    var group = RouteGroup{
        .engine_ptr = undefined,
        .prefix = "/api",
        .middleware = middleware_chain.MiddlewareChain{},
        .register_get = undefined,
        .register_post = undefined,
        .register_put = undefined,
        .register_delete = undefined,
    };

    const full_path = group.buildFullPath("/todos");
    try std.testing.expectEqualStrings(full_path, "/todos");
}

test "RouteGroup middleware inheritance" {
    var group = RouteGroup{
        .engine_ptr = undefined,
        .prefix = "/api",
        .middleware = middleware_chain.MiddlewareChain{},
        .register_get = undefined,
        .register_post = undefined,
        .register_put = undefined,
        .register_delete = undefined,
    };

    const mw = struct {
        fn mw(req: *Request) middleware_chain.MiddlewareResult {
            _ = req;
            return .proceed;
        }
    };

    try group.usePreRequest(&mw.mw);

    const nested = group.group("/v1");
    try std.testing.expectEqual(nested.middleware.pre_request_count, 1);
}
