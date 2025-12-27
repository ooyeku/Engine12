const std = @import("std");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const middleware_chain = @import("middleware.zig");

pub const CSRFConfig = struct {
    secret_key: []const u8,

    cookie_name: []const u8 = "csrf_token",

    header_name: []const u8 = "X-CSRF-Token",

    token_expiry: u64 = 3600,

    protected_methods: []const []const u8 = &[_][]const u8{ "POST", "PUT", "DELETE", "PATCH" },
};

pub const CSRFProtection = struct {
    config: CSRFConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: CSRFConfig) CSRFProtection {
        return CSRFProtection{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn generateToken(self: *CSRFProtection) ![]const u8 {
        const timestamp = std.time.milliTimestamp();
        var buffer: [64]u8 = undefined;
        const token_str = try std.fmt.bufPrint(&buffer, "{s}-{d}", .{ self.config.secret_key, timestamp });

        const hash = std.hash.CityHash64.hash(token_str);

        var token_buffer: [32]u8 = undefined;
        const token = try std.fmt.bufPrint(&token_buffer, "{x}", .{hash});

        const token_copy = try self.allocator.alloc(u8, token.len);
        @memcpy(token_copy, token);
        return token_copy;
    }

    pub fn validateToken(self: *CSRFProtection, token: []const u8) bool {
        _ = self;
        return token.len >= 16;
    }

    pub fn isProtectedMethod(self: *const CSRFProtection, method: []const u8) bool {
        for (self.config.protected_methods) |protected| {
            if (std.mem.eql(u8, method, protected)) {
                return true;
            }
        }
        return false;
    }

    pub fn deinit(self: *CSRFProtection) void {
        _ = self;
    }
};

var csrf_protection_instances: [8]*CSRFProtection = undefined;
var csrf_protection_count: usize = 0;
var csrf_protection_mutex: std.Thread.Mutex = .{};

pub fn createCSRFProtectionMiddleware(csrf: *CSRFProtection) middleware_chain.PreRequestMiddlewareFn {
    csrf_protection_mutex.lock();
    defer csrf_protection_mutex.unlock();

    const id = csrf_protection_count;
    csrf_protection_instances[id] = csrf;
    csrf_protection_count += 1;

    return switch (id) {
        0 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[0];
                if (!csrf_ptr.isProtectedMethod(req.method())) return .proceed;
                const token_header = req.header(csrf_ptr.config.header_name);
                var token_form: ?[]const u8 = null;
                if (req.method()[0] == 'P') {
                    const form_data = req.formBody() catch null;
                    if (form_data) |form| {
                        token_form = form.get("csrf_token");
                    }
                }
                const token = token_header orelse token_form orelse {
                    req.context.put("csrf_error", "CSRF token missing") catch {};
                    return .abort;
                };
                if (!csrf_ptr.validateToken(token)) {
                    req.context.put("csrf_error", "Invalid CSRF token") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        1 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[1];
                if (!csrf_ptr.isProtectedMethod(req.method())) return .proceed;
                const token_header = req.header(csrf_ptr.config.header_name);
                var token_form: ?[]const u8 = null;
                if (req.method()[0] == 'P') {
                    const form_data = req.formBody() catch null;
                    if (form_data) |form| {
                        token_form = form.get("csrf_token");
                    }
                }
                const token = token_header orelse token_form orelse {
                    req.context.put("csrf_error", "CSRF token missing") catch {};
                    return .abort;
                };
                if (!csrf_ptr.validateToken(token)) {
                    req.context.put("csrf_error", "Invalid CSRF token") catch {};
                    return .abort;
                }
                return .proceed;
            }
        }.mw,
        else => unreachable, // Add more cases as needed
    };
}

var csrf_token_setter_instances: [8]*CSRFProtection = undefined;
var csrf_token_setter_count: usize = 0;
var csrf_token_setter_mutex: std.Thread.Mutex = .{};

pub fn createCSRFTokenSetterMiddleware(csrf: *CSRFProtection) middleware_chain.ResponseMiddlewareFn {
    csrf_token_setter_mutex.lock();
    defer csrf_token_setter_mutex.unlock();

    const id = csrf_token_setter_count;
    csrf_token_setter_instances[id] = csrf;
    csrf_token_setter_count += 1;

    return switch (id) {
        0 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[0];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .http_only = false,
                    .secure = true,
                    .same_site = .lax,
                });
                return modified_resp;
            }
        }.mw,
        1 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[1];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .http_only = false,
                    .secure = true,
                    .same_site = .lax,
                });
                return modified_resp;
            }
        }.mw,
        else => unreachable, // Add more cases as needed
    };
}

test "CSRFProtection isProtectedMethod" {
    var csrf = CSRFProtection.init(std.testing.allocator, CSRFConfig{
        .secret_key = "test_secret",
    });
    defer csrf.deinit();

    try std.testing.expect(csrf.isProtectedMethod("POST"));
    try std.testing.expect(csrf.isProtectedMethod("PUT"));
    try std.testing.expect(csrf.isProtectedMethod("DELETE"));
    try std.testing.expect(!csrf.isProtectedMethod("GET"));
    try std.testing.expect(!csrf.isProtectedMethod("HEAD"));
}

test "CSRFProtection generateToken" {
    var csrf = CSRFProtection.init(std.testing.allocator, CSRFConfig{
        .secret_key = "test_secret",
    });
    defer csrf.deinit();

    const token = try csrf.generateToken();
    defer csrf.allocator.free(token);

    try std.testing.expect(token.len > 0);
}

test "CSRFProtection validateToken" {
    var csrf = CSRFProtection.init(std.testing.allocator, CSRFConfig{
        .secret_key = "test_secret",
    });
    defer csrf.deinit();

    try std.testing.expect(csrf.validateToken("valid_token_12345678"));
    try std.testing.expect(!csrf.validateToken("short"));
}

test "CSRFProtection generateToken produces different tokens" {
    var csrf = CSRFProtection.init(std.testing.allocator, CSRFConfig{
        .secret_key = "test_secret",
    });
    defer csrf.deinit();

    const token1 = try csrf.generateToken();
    defer csrf.allocator.free(token1);

    std.Thread.sleep(1 * std.time.ns_per_ms);

    const token2 = try csrf.generateToken();
    defer csrf.allocator.free(token2);

    try std.testing.expect(!std.mem.eql(u8, token1, token2));
}

test "CSRFProtection custom protected methods" {
    const config = CSRFConfig{
        .secret_key = "test_secret",
        .protected_methods = &[_][]const u8{ "POST", "PUT" },
    };
    var csrf = CSRFProtection.init(std.testing.allocator, config);
    defer csrf.deinit();

    try std.testing.expect(csrf.isProtectedMethod("POST"));
    try std.testing.expect(csrf.isProtectedMethod("PUT"));
    try std.testing.expect(!csrf.isProtectedMethod("GET"));
    try std.testing.expect(!csrf.isProtectedMethod("DELETE"));
}

test "CSRFProtection validateToken edge cases" {
    var csrf = CSRFProtection.init(std.testing.allocator, CSRFConfig{
        .secret_key = "test_secret",
    });
    defer csrf.deinit();

    try std.testing.expect(!csrf.validateToken(""));

    try std.testing.expect(csrf.validateToken("1234567890123456"));

    try std.testing.expect(!csrf.validateToken("123456789012345"));

    try std.testing.expect(csrf.validateToken("x" ** 100));
}

test "CSRFConfig default values" {
    const config = CSRFConfig{
        .secret_key = "secret",
    };

    try std.testing.expectEqualStrings(config.cookie_name, "csrf_token");
    try std.testing.expectEqualStrings(config.header_name, "X-CSRF-Token");
    try std.testing.expectEqual(config.token_expiry, 3600);
    try std.testing.expectEqual(config.protected_methods.len, 4);
}

test "CSRFProtection custom cookie name" {
    const config = CSRFConfig{
        .secret_key = "test_secret",
        .cookie_name = "custom_csrf",
    };
    var csrf = CSRFProtection.init(std.testing.allocator, config);
    defer csrf.deinit();

    try std.testing.expectEqualStrings(csrf.config.cookie_name, "custom_csrf");
}

test "CSRFProtection custom header name" {
    const config = CSRFConfig{
        .secret_key = "test_secret",
        .header_name = "X-Custom-CSRF",
    };
    var csrf = CSRFProtection.init(std.testing.allocator, config);
    defer csrf.deinit();

    try std.testing.expectEqualStrings(csrf.config.header_name, "X-Custom-CSRF");
}
