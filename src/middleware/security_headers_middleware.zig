const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware = @import("middleware.zig");

/// Configuration for security headers middleware.
/// Controls which security headers are added to responses and their values.
///
/// ## Example
/// ```zig
/// const security_config = SecurityHeadersConfig{
///     .enable_content_type_options = true,  // Prevent MIME sniffing
///     .enable_frame_options = true,         // Prevent clickjacking
///     .enable_xss_protection = true,        // Enable XSS filter
///     .enable_hsts = true,                  // Force HTTPS
///     .hsts_max_age = 31536000,             // 1 year
///     .enable_csp = true,                   // Content Security Policy
///     .csp_policy = "default-src 'self'; script-src 'self' 'unsafe-inline'",
/// };
/// ```
pub const SecurityHeadersConfig = struct {
    /// Enable X-Content-Type-Options: nosniff header to prevent MIME sniffing
    enable_content_type_options: bool = true,
    /// Enable X-Frame-Options: DENY header to prevent clickjacking attacks
    enable_frame_options: bool = true,
    /// Enable X-XSS-Protection header (deprecated but still useful for older browsers)
    enable_xss_protection: bool = true,
    /// Enable HTTP Strict Transport Security (HSTS) to force HTTPS
    enable_hsts: bool = true,
    /// Maximum age in seconds for HSTS header (default: 1 year)
    hsts_max_age: u64 = 31536000,
    /// Enable Referrer-Policy header to control referrer information
    enable_referrer_policy: bool = true,
    /// Referrer policy value (default: strict-origin-when-cross-origin)
    referrer_policy: []const u8 = "strict-origin-when-cross-origin",
    /// Enable Content-Security-Policy header to prevent XSS and injection attacks
    enable_csp: bool = false,
    /// Content Security Policy directives
    csp_policy: []const u8 = "default-src 'self'",
    /// Enable Permissions-Policy header (formerly Feature-Policy)
    enable_permissions_policy: bool = false,
    /// Permissions policy directives
    permissions_policy: []const u8 = "",
};

/// Middleware for adding security-related HTTP headers to responses.
/// These headers help protect against common web vulnerabilities:
/// - XSS (Cross-Site Scripting)
/// - Clickjacking
/// - MIME sniffing
/// - Protocol downgrade attacks
/// - And more
///
/// ## Example
/// ```zig
/// const security = SecurityHeadersMiddleware.init(.{
///     .enable_hsts = true,
///     .enable_csp = true,
///     .csp_policy = "default-src 'self'",
/// });
/// app.useResponse(security.responseMwFn());
/// ```
pub const SecurityHeadersMiddleware = struct {
    config: SecurityHeadersConfig,

    /// Initialize security headers middleware with the given configuration.
    pub fn init(config: SecurityHeadersConfig) SecurityHeadersMiddleware {
        return SecurityHeadersMiddleware{
            .config = config,
        };
    }

    /// Get the response middleware function that adds security headers.
    /// Headers are added based on the configuration provided during initialization.
    ///
    /// ## Example
    /// ```zig
    /// var security = SecurityHeadersMiddleware.init(.{});
    /// app.useResponse(security.responseMwFn());
    /// ```
    pub fn responseMwFn(self: *const SecurityHeadersMiddleware) middleware.ResponseMiddlewareFn {
        return struct {
            fn mw(resp: Response, req: *Request) Response {
                _ = req;
                return self.addSecurityHeaders(resp);
            }
        }.mw;
    }

    /// Add security headers to a response based on the middleware configuration.
    /// This is called internally by the response middleware function.
    ///
    /// Each header is added conditionally based on its enable flag:
    /// - X-Content-Type-Options: nosniff (prevents MIME sniffing)
    /// - X-Frame-Options: DENY (prevents clickjacking)
    /// - X-XSS-Protection: 1; mode=block (enables XSS filter)
    /// - Strict-Transport-Security: max-age=<seconds> (forces HTTPS)
    /// - Referrer-Policy: <policy> (controls referrer information)
    /// - Content-Security-Policy: <policy> (prevents XSS/injection)
    /// - Permissions-Policy: <policy> (controls browser features)
    pub fn addSecurityHeaders(self: *const SecurityHeadersMiddleware, resp: Response) Response {
        var result = resp;

        if (self.config.enable_content_type_options) {
            result = result.withHeader("X-Content-Type-Options", "nosniff");
        }

        if (self.config.enable_frame_options) {
            result = result.withHeader("X-Frame-Options", "DENY");
        }

        if (self.config.enable_xss_protection) {
            result = result.withHeader("X-XSS-Protection", "1; mode=block");
        }

        if (self.config.enable_hsts) {
            const hsts_value = std.fmt.allocPrint(
                std.heap.page_allocator,
                "max-age={d}",
                .{self.config.hsts_max_age},
            ) catch {
                return result; // If allocation fails, return response without HSTS
            };
            defer std.heap.page_allocator.free(hsts_value);
            result = result.withHeader("Strict-Transport-Security", hsts_value);
        }

        if (self.config.enable_referrer_policy) {
            result = result.withHeader("Referrer-Policy", self.config.referrer_policy);
        }

        if (self.config.enable_csp) {
            result = result.withHeader("Content-Security-Policy", self.config.csp_policy);
        }

        if (self.config.enable_permissions_policy and self.config.permissions_policy.len > 0) {
            result = result.withHeader("Permissions-Policy", self.config.permissions_policy);
        }

        return result;
    }
};

test "SecurityHeadersMiddleware adds headers" {
    const config = SecurityHeadersConfig{
        .enable_content_type_options = true,
        .enable_frame_options = true,
        .enable_xss_protection = true,
    };
    const mw = SecurityHeadersMiddleware.init(config);

    const resp = Response.ok();
    const resp_with_headers = mw.addSecurityHeaders(resp);

    const ziggurat_resp = resp_with_headers.toZiggurat();
    _ = ziggurat_resp;
}

test "SecurityHeadersMiddleware respects config" {
    const config = SecurityHeadersConfig{
        .enable_content_type_options = false,
        .enable_frame_options = false,
    };
    const mw = SecurityHeadersMiddleware.init(config);

    const resp = Response.ok();
    const resp_with_headers = mw.addSecurityHeaders(resp);

    _ = resp_with_headers;
}
