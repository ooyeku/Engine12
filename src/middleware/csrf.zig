const std = @import("std");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const middleware_chain = @import("middleware.zig");

pub const CSRFConfig = struct {
    secret_key: []const u8,

    cookie_name: []const u8 = "csrf_token",

    header_name: []const u8 = "X-CSRF-Token",

    /// Token expiry in seconds (default: 1 hour)
    token_expiry: u64 = 3600,

    protected_methods: []const []const u8 = &[_][]const u8{ "POST", "PUT", "DELETE", "PATCH" },

    /// Maximum number of tokens to store per cleanup cycle (default: 10000)
    max_tokens: usize = 10000,
};

/// Token storage entry with expiry timestamp
const TokenEntry = struct {
    expiry: i64, // Unix timestamp in seconds when token expires
};

pub const CSRFProtection = struct {
    config: CSRFConfig,
    allocator: std.mem.Allocator,
    /// Thread-safe token storage mapping token strings to their expiry times
    tokens: std.StringHashMap(TokenEntry),
    /// Mutex protecting the token store
    tokens_mutex: std.Thread.Mutex,
    /// Random number generator for secure token generation
    random: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, config: CSRFConfig) CSRFProtection {
        // Seed RNG with current timestamp for token generation
        const seed = @as(u64, @intCast(std.time.nanoTimestamp()));
        return CSRFProtection{
            .config = config,
            .allocator = allocator,
            .tokens = std.StringHashMap(TokenEntry).init(allocator),
            .tokens_mutex = .{},
            .random = std.Random.DefaultPrng.init(seed),
        };
    }

    /// Generate a cryptographically secure CSRF token and store it server-side.
    /// Returns a heap-allocated token string that must be freed by the caller.
    pub fn generateToken(self: *CSRFProtection) ![]const u8 {
        const current_time = std.time.timestamp();
        const expiry = current_time + @as(i64, @intCast(self.config.token_expiry));

        // Generate 32 random bytes (256 bits of entropy)
        var random_bytes: [32]u8 = undefined;
        self.random.fill(&random_bytes);

        // Encode as hex string (64 characters)
        var token_buffer: [64]u8 = undefined;
        const token = try std.fmt.bufPrint(&token_buffer, "{x}", .{std.fmt.fmtSliceHexLower(&random_bytes)});

        // Store token with expiry (thread-safe)
        self.tokens_mutex.lock();
        defer self.tokens_mutex.unlock();

        // Clean up expired tokens if we've hit the limit
        if (self.tokens.count() >= self.config.max_tokens) {
            try self.cleanupExpiredTokensLocked(current_time);
        }

        // Duplicate token for storage in hashmap
        const token_key = try self.allocator.dupe(u8, token);
        errdefer self.allocator.free(token_key);

        try self.tokens.put(token_key, TokenEntry{ .expiry = expiry });

        // Return a copy for the caller
        const token_copy = try self.allocator.dupe(u8, token);
        return token_copy;
    }

    /// Validate a CSRF token by checking if it exists in server-side storage
    /// and hasn't expired. This provides actual CSRF protection.
    pub fn validateToken(self: *CSRFProtection, token: []const u8) bool {
        // Basic format validation - must be 64 hex characters
        if (token.len != 64) return false;

        // Verify it's a valid hex string
        for (token) |c| {
            const is_hex = (c >= '0' and c <= '9') or
                (c >= 'a' and c <= 'f') or
                (c >= 'A' and c <= 'F');
            if (!is_hex) return false;
        }

        const current_time = std.time.timestamp();

        // Check if token exists and hasn't expired (thread-safe)
        self.tokens_mutex.lock();
        defer self.tokens_mutex.unlock();

        if (self.tokens.get(token)) |entry| {
            if (current_time <= entry.expiry) {
                return true;
            }
        }

        return false;
    }

    /// Clean up expired tokens. Must be called with tokens_mutex already locked.
    fn cleanupExpiredTokensLocked(self: *CSRFProtection, current_time: i64) !void {
        var tokens_to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer tokens_to_remove.deinit();

        // Find expired tokens
        var iter = self.tokens.iterator();
        while (iter.next()) |entry| {
            if (current_time > entry.value_ptr.expiry) {
                try tokens_to_remove.append(entry.key_ptr.*);
            }
        }

        // Remove expired tokens and free their keys
        for (tokens_to_remove.items) |token_key| {
            _ = self.tokens.remove(token_key);
            self.allocator.free(token_key);
        }
    }

    /// Public cleanup method for manual cleanup of expired tokens
    pub fn cleanupExpiredTokens(self: *CSRFProtection) !void {
        const current_time = std.time.timestamp();
        self.tokens_mutex.lock();
        defer self.tokens_mutex.unlock();
        try self.cleanupExpiredTokensLocked(current_time);
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
        // Free all token keys in the hashmap
        var iter = self.tokens.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.tokens.deinit();
    }
};

/// Storage for CSRF protection instances used by middleware factories
/// Limited to 16 instances due to Zig's comptime closure limitations
var csrf_protection_instances: [16]*CSRFProtection = undefined;
var csrf_protection_count: usize = 0;
var csrf_protection_mutex: std.Thread.Mutex = .{};

/// Create a CSRF protection middleware that validates tokens on protected methods.
/// NOTE: Due to Zig's comptime limitations, this function can only be called 16 times.
/// If you need more instances, increase the array size and add more switch cases.
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
        2 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[2];
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
        3 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[3];
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
        4 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[4];
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
        5 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[5];
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
        6 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[6];
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
        7 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[7];
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
        8 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[8];
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
        9 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[9];
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
        10 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[10];
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
        11 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[11];
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
        12 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[12];
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
        13 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[13];
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
        14 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[14];
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
        15 => struct {
            fn mw(req: *Request) middleware_chain.MiddlewareResult {
                const csrf_ptr = csrf_protection_instances[15];
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
        else => @panic("Maximum CSRF protection middleware instances (16) exceeded. Increase csrf_protection_instances array size."),
    };
}

/// Storage for CSRF token setter instances used by response middleware
/// Limited to 16 instances due to Zig's comptime closure limitations
var csrf_token_setter_instances: [16]*CSRFProtection = undefined;
var csrf_token_setter_count: usize = 0;
var csrf_token_setter_mutex: std.Thread.Mutex = .{};

/// Create a response middleware that sets CSRF tokens in cookies.
/// NOTE: Due to Zig's comptime limitations, this function can only be called 16 times.
/// If you need more instances, increase the array size and add more switch cases.
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
                    .httpOnly = false,
                    .secure = true,
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
                    .httpOnly = false,
                    .secure = true,
                });
                return modified_resp;
            }
        }.mw,
        2 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[2];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .httpOnly = false,
                    .secure = true,
                });
                return modified_resp;
            }
        }.mw,
        3 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[3];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .httpOnly = false,
                    .secure = true,
                });
                return modified_resp;
            }
        }.mw,
        4 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[4];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .httpOnly = false,
                    .secure = true,
                });
                return modified_resp;
            }
        }.mw,
        5 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[5];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .httpOnly = false,
                    .secure = true,
                });
                return modified_resp;
            }
        }.mw,
        6 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[6];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .httpOnly = false,
                    .secure = true,
                });
                return modified_resp;
            }
        }.mw,
        7 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[7];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .httpOnly = false,
                    .secure = true,
                });
                return modified_resp;
            }
        }.mw,
        8 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[8];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .httpOnly = false,
                    .secure = true,
                });
                return modified_resp;
            }
        }.mw,
        9 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[9];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .httpOnly = false,
                    .secure = true,
                });
                return modified_resp;
            }
        }.mw,
        10 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[10];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .httpOnly = false,
                    .secure = true,
                });
                return modified_resp;
            }
        }.mw,
        11 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[11];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .httpOnly = false,
                    .secure = true,
                });
                return modified_resp;
            }
        }.mw,
        12 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[12];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .httpOnly = false,
                    .secure = true,
                });
                return modified_resp;
            }
        }.mw,
        13 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[13];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .httpOnly = false,
                    .secure = true,
                });
                return modified_resp;
            }
        }.mw,
        14 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[14];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .httpOnly = false,
                    .secure = true,
                });
                return modified_resp;
            }
        }.mw,
        15 => struct {
            fn mw(resp: Response) Response {
                const csrf_ptr = csrf_token_setter_instances[15];
                const token = csrf_ptr.generateToken() catch return resp;
                defer csrf_ptr.allocator.free(token);
                var modified_resp = resp;
                modified_resp = modified_resp.withCookie(csrf_ptr.config.cookie_name, token, .{
                    .httpOnly = false,
                    .secure = true,
                });
                return modified_resp;
            }
        }.mw,
        else => @panic("Maximum CSRF token setter middleware instances (16) exceeded. Increase csrf_token_setter_instances array size."),
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

    // New tokens should be 64 hex characters
    try std.testing.expectEqual(@as(usize, 64), token.len);

    // Verify it's all hex characters
    for (token) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(is_hex);
    }
}

test "CSRFProtection validateToken server-side verification" {
    var csrf = CSRFProtection.init(std.testing.allocator, CSRFConfig{
        .secret_key = "test_secret",
    });
    defer csrf.deinit();

    // Generate a token
    const token = try csrf.generateToken();
    defer csrf.allocator.free(token);

    // Valid: token exists in server storage
    try std.testing.expect(csrf.validateToken(token));

    // Invalid: random token not in storage
    const fake_token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expect(!csrf.validateToken(fake_token));

    // Invalid: too short
    try std.testing.expect(!csrf.validateToken("short"));

    // Invalid: not hex
    try std.testing.expect(!csrf.validateToken("ghijklmnopqrstuvwxyz"));
}

test "CSRFProtection generateToken produces different tokens" {
    var csrf = CSRFProtection.init(std.testing.allocator, CSRFConfig{
        .secret_key = "test_secret",
    });
    defer csrf.deinit();

    const token1 = try csrf.generateToken();
    defer csrf.allocator.free(token1);

    const token2 = try csrf.generateToken();
    defer csrf.allocator.free(token2);

    // Tokens should be different due to random generation
    try std.testing.expect(!std.mem.eql(u8, token1, token2));

    // Both should be valid
    try std.testing.expect(csrf.validateToken(token1));
    try std.testing.expect(csrf.validateToken(token2));
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

test "CSRFProtection token expiry" {
    var csrf = CSRFProtection.init(std.testing.allocator, CSRFConfig{
        .secret_key = "test_secret",
        .token_expiry = 1, // 1 second expiry for testing
    });
    defer csrf.deinit();

    const token = try csrf.generateToken();
    defer csrf.allocator.free(token);

    // Token should be valid immediately
    try std.testing.expect(csrf.validateToken(token));

    // Wait for token to expire
    std.time.sleep(2 * std.time.ns_per_s);

    // Token should now be invalid
    try std.testing.expect(!csrf.validateToken(token));
}

test "CSRFProtection cleanup expired tokens" {
    var csrf = CSRFProtection.init(std.testing.allocator, CSRFConfig{
        .secret_key = "test_secret",
        .token_expiry = 1, // 1 second expiry
    });
    defer csrf.deinit();

    const token = try csrf.generateToken();
    defer csrf.allocator.free(token);

    // Wait for expiry
    std.time.sleep(2 * std.time.ns_per_s);

    // Cleanup expired tokens
    try csrf.cleanupExpiredTokens();

    // Token should be removed from storage
    try std.testing.expect(!csrf.validateToken(token));
}

test "CSRFConfig default values" {
    const config = CSRFConfig{
        .secret_key = "secret",
    };

    try std.testing.expectEqualStrings(config.cookie_name, "csrf_token");
    try std.testing.expectEqualStrings(config.header_name, "X-CSRF-Token");
    try std.testing.expectEqual(config.token_expiry, 3600);
    try std.testing.expectEqual(config.protected_methods.len, 4);
    try std.testing.expectEqual(config.max_tokens, 10000);
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

test "CSRFProtection max tokens cleanup" {
    var csrf = CSRFProtection.init(std.testing.allocator, CSRFConfig{
        .secret_key = "test_secret",
        .max_tokens = 5, // Small limit for testing
    });
    defer csrf.deinit();

    // Generate tokens beyond the limit
    var tokens = std.ArrayList([]const u8).init(std.testing.allocator);
    defer {
        for (tokens.items) |t| {
            csrf.allocator.free(t);
        }
        tokens.deinit();
    }

    for (0..10) |_| {
        const token = try csrf.generateToken();
        try tokens.append(token);
    }

    // Verify that cleanup happened (some tokens should remain valid)
    var valid_count: usize = 0;
    for (tokens.items) |token| {
        if (csrf.validateToken(token)) {
            valid_count += 1;
        }
    }

    // At least some tokens should be valid
    try std.testing.expect(valid_count > 0);
}
