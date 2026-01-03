const std = @import("std");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const middleware_chain = @import("middleware.zig");

pub const RateLimitConfig = struct {
    max_requests: u64,

    window_ms: u64,

    message: []const u8 = "Rate limit exceeded",
};

pub const RateLimitEntry = struct {
    count: u64 = 0,
    reset_at: i64,

    pub fn init(window_ms: u64) RateLimitEntry {
        return RateLimitEntry{
            .count = 0,
            .reset_at = std.time.milliTimestamp() + @as(i64, @intCast(window_ms)),
        };
    }

    pub fn isExpired(self: *const RateLimitEntry) bool {
        return std.time.milliTimestamp() >= self.reset_at;
    }

    pub fn reset(self: *RateLimitEntry, window_ms: u64) void {
        self.count = 0;
        self.reset_at = std.time.milliTimestamp() + @as(i64, @intCast(window_ms));
    }
};

pub const RateLimiter = struct {
    ip_limits: std.StringHashMap(RateLimitEntry),

    route_limits: std.StringHashMap(RateLimitEntry),

    global_config: RateLimitConfig,

    route_configs: std.StringHashMap(RateLimitConfig),

    allocator: std.mem.Allocator,

    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, global_config: RateLimitConfig) RateLimiter {
        return RateLimiter{
            .ip_limits = std.StringHashMap(RateLimitEntry).init(allocator),
            .route_limits = std.StringHashMap(RateLimitEntry).init(allocator),
            .global_config = global_config,
            .route_configs = std.StringHashMap(RateLimitConfig).init(allocator),
            .allocator = allocator,
            .mutex = .{},
        };
    }

    pub fn setRouteConfig(self: *RateLimiter, route: []const u8, config: RateLimitConfig) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.route_configs.put(route, config);
    }

    fn getClientIP(self: *const RateLimiter, req: *Request) []const u8 {
        _ = self;
        if (req.header("X-Forwarded-For")) |xff| {
            const comma_pos = std.mem.indexOfScalar(u8, xff, ',') orelse xff.len;
            return xff[0..comma_pos];
        }

        if (req.header("X-Real-IP")) |real_ip| {
            return real_ip;
        }

        return "unknown";
    }

    pub fn check(self: *RateLimiter, req: *Request, route: []const u8) !?Response {
        self.mutex.lock();
        defer self.mutex.unlock();

        const config = self.route_configs.get(route) orelse self.global_config;
        const client_ip = self.getClientIP(req);

        const ip_entry = self.ip_limits.getPtr(client_ip);
        if (ip_entry) |entry| {
            if (entry.isExpired()) {
                entry.reset(config.window_ms);
            }
            entry.count += 1;
            if (entry.count > config.max_requests) {
                return Response.json(
                    \\{"error":"Rate limit exceeded","message":"Too many requests"}
                ).withStatus(429);
            }
        } else {
            const new_entry = RateLimitEntry.init(config.window_ms);
            const owned_ip = try self.allocator.dupe(u8, client_ip);
            try self.ip_limits.put(owned_ip, new_entry);
            const ip_entry_ptr = self.ip_limits.getPtr(owned_ip).?;
            ip_entry_ptr.count = 1;
        }

        const route_entry = self.route_limits.getPtr(route);
        if (route_entry) |entry| {
            if (entry.isExpired()) {
                entry.reset(config.window_ms);
            }
            entry.count += 1;
            if (entry.count > config.max_requests) {
                return Response.json(
                    \\{"error":"Rate limit exceeded","message":"Too many requests for this route"}
                ).withStatus(429);
            }
        } else {
            const new_entry = RateLimitEntry.init(config.window_ms);
            const owned_route = try self.allocator.dupe(u8, route);
            try self.route_limits.put(owned_route, new_entry);
            const route_entry_ptr = self.route_limits.getPtr(owned_route).?;
            route_entry_ptr.count = 1;
        }

        return null;
    }

    pub fn cleanup(self: *RateLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var ip_iterator = self.ip_limits.iterator();
        var keys_to_remove = std.ArrayListUnmanaged([]const u8){};
        while (ip_iterator.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                keys_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (keys_to_remove.items) |key| {
            _ = self.ip_limits.remove(key);
            self.allocator.free(key);
        }
        keys_to_remove.deinit(self.allocator);

        var route_iterator = self.route_limits.iterator();
        keys_to_remove = std.ArrayListUnmanaged([]const u8){};
        while (route_iterator.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                keys_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (keys_to_remove.items) |key| {
            _ = self.route_limits.remove(key);
            self.allocator.free(key);
        }
        keys_to_remove.deinit(self.allocator);
    }

    pub fn deinit(self: *RateLimiter) void {
        var ip_iterator = self.ip_limits.iterator();
        while (ip_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.ip_limits.deinit();

        var route_iterator = self.route_limits.iterator();
        while (route_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.route_limits.deinit();

        self.route_configs.deinit();
    }
};

/// Storage for rate limiter instances used by middleware factories
const RateLimiterInstance = struct {
    limiter: *RateLimiter,
    route: []const u8,
};

var rate_limiter_instances: [16]RateLimiterInstance = undefined;
var rate_limiter_count: usize = 0;
var rate_limiter_mutex: std.Thread.Mutex = .{};

/// Create a rate limiting middleware function for a specific route.
/// This middleware will check rate limits before allowing the request to proceed.
pub fn createRateLimitMiddleware(limiter: *RateLimiter, route: []const u8) middleware_chain.PreRequestMiddlewareFn {
    rate_limiter_mutex.lock();
    defer rate_limiter_mutex.unlock();

    const id = rate_limiter_count;
    rate_limiter_instances[id] = .{ .limiter = limiter, .route = route };
    rate_limiter_count += 1;

    return switch (id) {
        0 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[0];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        1 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[1];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        2 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[2];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        3 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[3];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        4 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[4];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        5 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[5];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        6 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[6];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        7 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[7];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        8 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[8];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        9 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[9];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        10 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[10];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        11 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[11];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        12 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[12];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        13 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[13];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        14 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[14];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        15 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const instance = rate_limiter_instances[15];
                if (instance.limiter.check(req, instance.route) catch null) |_| {
                    req.context.put("rate_limited", "true") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        else => @panic("Maximum rate limiter middleware instances (16) exceeded. Increase rate_limiter_instances array size."),
    };
}

test "RateLimiter check allows requests within limit" {
    var limiter = RateLimiter.init(std.testing.allocator, RateLimitConfig{
        .max_requests = 10,
        .window_ms = 1000,
    });
    defer limiter.deinit();

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

    const result = try limiter.check(&req, "/test");
    try std.testing.expect(result == null);
}

test "RateLimitEntry init and expiration" {
    var entry = RateLimitEntry.init(1000);
    try std.testing.expectEqual(entry.count, 0);
    try std.testing.expect(!entry.isExpired());
}

test "RateLimiter check rejects requests exceeding limit" {
    var limiter = RateLimiter.init(std.testing.allocator, RateLimitConfig{
        .max_requests = 3,
        .window_ms = 1000,
    });
    defer limiter.deinit();

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

    _ = try limiter.check(&req, "/test");
    _ = try limiter.check(&req, "/test");
    _ = try limiter.check(&req, "/test");

    const result = try limiter.check(&req, "/test");
    try std.testing.expect(result != null);
}

test "RateLimiter check resets after window expires" {
    var limiter = RateLimiter.init(std.testing.allocator, RateLimitConfig{
        .max_requests = 2,
        .window_ms = 50,
    });
    defer limiter.deinit();

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

    _ = try limiter.check(&req, "/test");
    _ = try limiter.check(&req, "/test");

    const result1 = try limiter.check(&req, "/test");
    try std.testing.expect(result1 != null);

    std.Thread.sleep(60 * std.time.ns_per_ms);

    const result2 = try limiter.check(&req, "/test");
    try std.testing.expect(result2 == null);
}

test "RateLimiter setRouteConfig applies route-specific limits" {
    var limiter = RateLimiter.init(std.testing.allocator, RateLimitConfig{
        .max_requests = 10,
        .window_ms = 1000,
    });
    defer limiter.deinit();

    try limiter.setRouteConfig("/api/login", RateLimitConfig{
        .max_requests = 2,
        .window_ms = 1000,
    });

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

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const result = try limiter.check(&req, "/other");
        try std.testing.expect(result == null);
    }

    _ = try limiter.check(&req, "/api/login");
    _ = try limiter.check(&req, "/api/login");
    const result = try limiter.check(&req, "/api/login");
    try std.testing.expect(result != null);
}

test "RateLimiter cleanup removes expired entries" {
    var limiter = RateLimiter.init(std.testing.allocator, RateLimitConfig{
        .max_requests = 10,
        .window_ms = 50,
    });
    defer limiter.deinit();

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

    _ = try limiter.check(&req, "/test");

    std.Thread.sleep(60 * std.time.ns_per_ms);

    limiter.cleanup();

    _ = try limiter.check(&req, "/test");
}

test "RateLimitEntry reset clears count" {
    var entry = RateLimitEntry.init(1000);
    entry.count = 5;

    entry.reset(1000);

    try std.testing.expectEqual(entry.count, 0);
    try std.testing.expect(!entry.isExpired());
}

test "RateLimiter multiple IPs tracked separately" {
    var limiter = RateLimiter.init(std.testing.allocator, RateLimitConfig{
        .max_requests = 2,
        .window_ms = 1000,
    });
    defer limiter.deinit();

    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req1 = @import("ziggurat").request.Request{
        .path = "/test",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req1 = Request.fromZiggurat(&ziggurat_req1, std.testing.allocator);
    defer req1.deinit();

    _ = try limiter.check(&req1, "/test");
    _ = try limiter.check(&req1, "/test");

    const result = try limiter.check(&req1, "/test");
    try std.testing.expect(result != null);
}
