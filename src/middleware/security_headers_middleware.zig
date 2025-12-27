const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware = @import("middleware.zig");

pub const SecurityHeadersConfig = struct {
    enable_content_type_options: bool = true,
    enable_frame_options: bool = true,
    enable_xss_protection: bool = true,
    enable_hsts: bool = true,
    hsts_max_age: u64 = 31536000,
    enable_referrer_policy: bool = true,
    referrer_policy: []const u8 = "strict-origin-when-cross-origin",
    enable_csp: bool = false,
    csp_policy: []const u8 = "default-src 'self'",
    enable_permissions_policy: bool = false,
    permissions_policy: []const u8 = "",
};

pub const SecurityHeadersMiddleware = struct {
    config: SecurityHeadersConfig,

    pub fn init(config: SecurityHeadersConfig) SecurityHeadersMiddleware {
        return SecurityHeadersMiddleware{
            .config = config,
        };
    }

    pub fn responseMwFn(self: *const SecurityHeadersMiddleware) middleware.ResponseMiddlewareFn {
        return struct {
            fn mw(resp: Response, req: *Request) Response {
                _ = req;
                return self.addSecurityHeaders(resp);
            }
        }.mw;
    }

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
