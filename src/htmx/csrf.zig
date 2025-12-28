const std = @import("std");
const Response = @import("../http/response.zig").Response;

/// CSRF (Cross-Site Request Forgery) protection for HTMX applications.
///
/// This module provides token generation, validation, and HTML helpers
/// for integrating CSRF protection with HTMX forms and requests.
///
/// Usage:
/// 1. Generate a token per session: `const token = csrf.generateToken(allocator);`
/// 2. Include in forms: `csrf.hiddenInput(allocator, token)` or `csrf.metaTag(allocator, token)`
/// 3. Validate on POST/PUT/DELETE: `csrf.validateToken(submitted, stored)`
///
/// HTMX Integration:
/// - Add meta tag to head: `<meta name="csrf-token" content="...">`
/// - Configure HTMX to send token: `hx-headers='{"X-CSRF-Token": "..."}'`
/// - Or use the provided form helpers that auto-include hidden inputs
/// CSRF configuration
pub const Config = struct {
    /// Token length in bytes (before base64 encoding)
    token_length: usize = 32,
    /// Header name for CSRF token
    header_name: []const u8 = "X-CSRF-Token",
    /// Form field name for CSRF token
    field_name: []const u8 = "_csrf",
    /// Cookie name for double-submit pattern
    cookie_name: []const u8 = "csrf_token",
    /// Token expiration in seconds (0 = session only)
    expiration_seconds: u64 = 0,
};

pub const default_config = Config{};

/// Generate a cryptographically secure CSRF token
pub fn generateToken(allocator: std.mem.Allocator) ![]const u8 {
    return generateTokenWithLength(allocator, 32);
}

/// Generate a CSRF token with custom length
pub fn generateTokenWithLength(allocator: std.mem.Allocator, length: usize) ![]const u8 {
    const random_bytes = try allocator.alloc(u8, length);
    defer allocator.free(random_bytes);

    std.crypto.random.bytes(random_bytes);

    // Base64 encode for safe transmission
    const encoded_len = std.base64.standard.Encoder.calcSize(length);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, random_bytes);

    return encoded;
}

/// Validate a submitted CSRF token against the stored token
/// Uses constant-time comparison to prevent timing attacks
pub fn validateToken(submitted: ?[]const u8, stored: ?[]const u8) bool {
    const sub = submitted orelse return false;
    const sto = stored orelse return false;

    if (sub.len != sto.len) return false;

    // Constant-time comparison
    var result: u8 = 0;
    for (sub, sto) |a, b| {
        result |= a ^ b;
    }

    return result == 0;
}

/// Generate a hidden input field containing the CSRF token
pub fn hiddenInput(allocator: std.mem.Allocator, token: []const u8) ![]const u8 {
    return hiddenInputWithName(allocator, token, "_csrf");
}

/// Generate a hidden input field with custom name
pub fn hiddenInputWithName(allocator: std.mem.Allocator, token: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<input type="hidden" name="{s}" value="{s}">
    , .{ name, token });
}

/// Generate a meta tag for CSRF token (for JavaScript/HTMX access)
pub fn metaTag(allocator: std.mem.Allocator, token: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<meta name="csrf-token" content="{s}">
    , .{token});
}

/// Generate hx-headers attribute value with CSRF token
pub fn hxHeaders(allocator: std.mem.Allocator, token: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"X-CSRF-Token": "{s}"}}
    , .{token});
}

/// Generate a complete hx-headers attribute for HTMX elements
pub fn hxHeadersAttribute(allocator: std.mem.Allocator, token: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\hx-headers='{{"X-CSRF-Token": "{s}"}}'
    , .{token});
}

/// Generate HTMX config script that adds CSRF token to all requests
pub fn htmxConfigScript(allocator: std.mem.Allocator, token: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<script>
        \\  document.body.addEventListener('htmx:configRequest', function(evt) {{
        \\    evt.detail.headers['X-CSRF-Token'] = '{s}';
        \\  }});
        \\</script>
    , .{token});
}

/// Generate a form opening tag with CSRF token included
pub fn formStart(allocator: std.mem.Allocator, action: []const u8, method: []const u8, token: []const u8) ![]const u8 {
    const hidden = try hiddenInput(allocator, token);
    defer allocator.free(hidden);

    return std.fmt.allocPrint(allocator,
        \\<form action="{s}" method="{s}">
        \\  {s}
    , .{ action, method, hidden });
}

/// Generate an HTMX-enabled form opening tag with CSRF token
pub fn htmxFormStart(
    allocator: std.mem.Allocator,
    hx_post: []const u8,
    hx_target: []const u8,
    token: []const u8,
) ![]const u8 {
    const headers = try hxHeaders(allocator, token);
    defer allocator.free(headers);

    return std.fmt.allocPrint(allocator,
        \\<form hx-post="{s}" hx-target="{s}" hx-headers='{s}'>
    , .{ hx_post, hx_target, headers });
}

/// Extract CSRF token from request header
pub fn getTokenFromHeader(headers: anytype, header_name: []const u8) ?[]const u8 {
    return headers.get(header_name);
}

/// CSRF middleware result
pub const ValidationResult = enum {
    valid,
    missing_token,
    invalid_token,
    method_not_checked,
};

/// Check if a request method requires CSRF validation
pub fn requiresValidation(method: []const u8) bool {
    // Safe methods don't need CSRF validation
    if (std.mem.eql(u8, method, "GET")) return false;
    if (std.mem.eql(u8, method, "HEAD")) return false;
    if (std.mem.eql(u8, method, "OPTIONS")) return false;
    if (std.mem.eql(u8, method, "TRACE")) return false;

    // Unsafe methods need validation
    return true;
}

/// Generate a CSRF error response
pub fn errorResponse(allocator: std.mem.Allocator) Response {
    const html = std.fmt.allocPrint(allocator,
        \\<div class="csrf-error" id="csrf-error" hx-swap-oob="true">
        \\  <p>Security token expired or invalid. Please refresh the page and try again.</p>
        \\</div>
    , .{}) catch {
        return Response.text("CSRF validation failed").withStatus(403);
    };

    return Response.fragment(html).withStatus(403);
}

/// Generate a token refresh response (for AJAX/HTMX)
pub fn refreshTokenResponse(allocator: std.mem.Allocator, new_token: []const u8) Response {
    const html = std.fmt.allocPrint(allocator,
        \\<meta name="csrf-token" content="{s}" hx-swap-oob="true">
    , .{new_token}) catch {
        return Response.serverError("Failed to generate token refresh");
    };

    return Response.fragment(html);
}

// ============================================================================
// Token Store (in-memory, for simple use cases)
// ============================================================================

/// Simple in-memory token store for development/testing
/// For production, use a proper session store (Redis, database, etc.)
pub const TokenStore = struct {
    tokens: std.StringHashMap(TokenEntry),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    const TokenEntry = struct {
        token: []const u8,
        created_at: i64,
        expires_at: ?i64,
    };

    pub fn init(allocator: std.mem.Allocator) TokenStore {
        return .{
            .tokens = std.StringHashMap(TokenEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TokenStore) void {
        var iter = self.tokens.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.token);
        }
        self.tokens.deinit();
    }

    /// Generate and store a new token for a session
    pub fn createToken(self: *TokenStore, session_id: []const u8, expiration_seconds: ?u64) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const token = try generateToken(self.allocator);
        const session_key = try self.allocator.dupe(u8, session_id);

        const now = std.time.timestamp();
        const expires_at: ?i64 = if (expiration_seconds) |exp|
            now + @as(i64, @intCast(exp))
        else
            null;

        try self.tokens.put(session_key, .{
            .token = token,
            .created_at = now,
            .expires_at = expires_at,
        });

        return token;
    }

    /// Validate a token for a session
    pub fn validate(self: *TokenStore, session_id: []const u8, submitted_token: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = self.tokens.get(session_id) orelse return false;

        // Check expiration
        if (entry.expires_at) |exp| {
            if (std.time.timestamp() > exp) {
                return false;
            }
        }

        return validateToken(submitted_token, entry.token);
    }

    /// Remove a token (e.g., on logout)
    pub fn removeToken(self: *TokenStore, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tokens.fetchRemove(session_id)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.token);
        }
    }

    /// Clean up expired tokens
    pub fn cleanup(self: *TokenStore) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var iter = self.tokens.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.expires_at) |exp| {
                if (now > exp) {
                    to_remove.append(entry.key_ptr.*) catch {};
                }
            }
        }

        for (to_remove.items) |key| {
            if (self.tokens.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.value.token);
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "generateToken creates valid base64 token" {
    const allocator = std.testing.allocator;
    const token = try generateToken(allocator);
    defer allocator.free(token);

    // Should be base64 encoded 32 bytes = 44 chars (with padding)
    try std.testing.expect(token.len > 0);
    try std.testing.expect(token.len == 44); // 32 bytes -> 44 base64 chars
}

test "generateTokenWithLength creates correct size" {
    const allocator = std.testing.allocator;
    const token = try generateTokenWithLength(allocator, 16);
    defer allocator.free(token);

    // 16 bytes -> 24 base64 chars (with padding)
    try std.testing.expect(token.len == 24);
}

test "validateToken with matching tokens" {
    const result = validateToken("abc123", "abc123");
    try std.testing.expect(result);
}

test "validateToken with different tokens" {
    const result = validateToken("abc123", "def456");
    try std.testing.expect(!result);
}

test "validateToken with null submitted" {
    const result = validateToken(null, "abc123");
    try std.testing.expect(!result);
}

test "validateToken with null stored" {
    const result = validateToken("abc123", null);
    try std.testing.expect(!result);
}

test "validateToken with different lengths" {
    const result = validateToken("abc", "abcdef");
    try std.testing.expect(!result);
}

test "hiddenInput generates correct HTML" {
    const allocator = std.testing.allocator;
    const html = try hiddenInput(allocator, "test-token");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "type=\"hidden\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"_csrf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "value=\"test-token\"") != null);
}

test "metaTag generates correct HTML" {
    const allocator = std.testing.allocator;
    const html = try metaTag(allocator, "test-token");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"csrf-token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "content=\"test-token\"") != null);
}

test "hxHeaders generates correct JSON" {
    const allocator = std.testing.allocator;
    const headers = try hxHeaders(allocator, "test-token");
    defer allocator.free(headers);

    try std.testing.expect(std.mem.indexOf(u8, headers, "X-CSRF-Token") != null);
    try std.testing.expect(std.mem.indexOf(u8, headers, "test-token") != null);
}

test "htmxConfigScript generates valid script" {
    const allocator = std.testing.allocator;
    const script = try htmxConfigScript(allocator, "test-token");
    defer allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "<script>") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "htmx:configRequest") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "test-token") != null);
}

test "formStart generates form with hidden input" {
    const allocator = std.testing.allocator;
    const html = try formStart(allocator, "/submit", "POST", "test-token");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "action=\"/submit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "method=\"POST\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "_csrf") != null);
}

test "htmxFormStart generates htmx form" {
    const allocator = std.testing.allocator;
    const html = try htmxFormStart(allocator, "/api/submit", "#result", "test-token");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "hx-post=\"/api/submit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hx-target=\"#result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hx-headers") != null);
}

test "requiresValidation for safe methods" {
    try std.testing.expect(!requiresValidation("GET"));
    try std.testing.expect(!requiresValidation("HEAD"));
    try std.testing.expect(!requiresValidation("OPTIONS"));
}

test "requiresValidation for unsafe methods" {
    try std.testing.expect(requiresValidation("POST"));
    try std.testing.expect(requiresValidation("PUT"));
    try std.testing.expect(requiresValidation("DELETE"));
    try std.testing.expect(requiresValidation("PATCH"));
}

test "TokenStore create and validate" {
    const allocator = std.testing.allocator;
    var store = TokenStore.init(allocator);
    defer store.deinit();

    const token = try store.createToken("session-123", null);

    try std.testing.expect(store.validate("session-123", token));
    try std.testing.expect(!store.validate("session-123", "wrong-token"));
    try std.testing.expect(!store.validate("wrong-session", token));
}

test "TokenStore remove token" {
    const allocator = std.testing.allocator;
    var store = TokenStore.init(allocator);
    defer store.deinit();

    const token = try store.createToken("session-123", null);
    try std.testing.expect(store.validate("session-123", token));

    store.removeToken("session-123");
    try std.testing.expect(!store.validate("session-123", token));
}
