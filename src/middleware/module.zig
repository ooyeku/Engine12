//! Middleware module
//!
//! This module provides request/response middleware for Engine12.
//! Middleware functions can intercept, modify, or abort requests before they reach route handlers,
//! and transform responses before they're sent to clients.
//!
//! ## Available Middleware
//!
//! - **middleware** - Core middleware chain and types
//! - **csrf** - Cross-Site Request Forgery protection with server-side token validation
//! - **rate_limit** - Rate limiting based on IP address and route
//! - **cors_middleware** - Cross-Origin Resource Sharing (CORS) headers
//! - **logging_middleware** - Request/response logging
//! - **request_id_middleware** - Unique request ID generation and tracking
//! - **security_headers_middleware** - Security headers (HSTS, CSP, X-Frame-Options, etc.)
//! - **body_size_limit** - Request body size validation
//!
//! ## Example
//! ```zig
//! const middleware = @import("middleware/module.zig");
//!
//! // CSRF protection
//! var csrf = middleware.csrf.CSRFProtection.init(allocator, .{
//!     .secret_key = "your-secret-key",
//! });
//! app.usePreRequest(middleware.csrf.createCSRFProtectionMiddleware(&csrf));
//!
//! // Rate limiting
//! var limiter = middleware.rate_limit.RateLimiter.init(allocator, .{
//!     .max_requests = 100,
//!     .window_ms = 60000,
//! });
//! app.usePreRequest(middleware.rate_limit.createRateLimitMiddleware(&limiter, "/api"));
//!
//! // Security headers
//! var security = middleware.security_headers_middleware.SecurityHeadersMiddleware.init(.{});
//! app.useResponse(security.responseMwFn());
//! ```

// Core middleware types and chain
pub const middleware = @import("middleware.zig");
pub const MiddlewareResult = middleware.MiddlewareResult;
pub const PreRequestMiddlewareFn = middleware.PreRequestMiddlewareFn;
pub const ResponseMiddlewareFn = middleware.ResponseMiddlewareFn;
pub const MiddlewareChain = middleware.MiddlewareChain;

// CSRF protection
pub const csrf = @import("csrf.zig");
pub const CSRFConfig = csrf.CSRFConfig;
pub const CSRFProtection = csrf.CSRFProtection;

// Rate limiting
pub const rate_limit = @import("rate_limit.zig");
pub const RateLimitConfig = rate_limit.RateLimitConfig;
pub const RateLimiter = rate_limit.RateLimiter;

// CORS
pub const cors_middleware = @import("cors_middleware.zig");
pub const CorsConfig = cors_middleware.CorsConfig;
pub const CorsMiddleware = cors_middleware.CorsMiddleware;

// Logging
pub const logging_middleware = @import("logging_middleware.zig");
pub const LoggingConfig = logging_middleware.LoggingConfig;
pub const LoggingMiddleware = logging_middleware.LoggingMiddleware;

// Request ID
pub const request_id_middleware = @import("request_id_middleware.zig");
pub const RequestIdConfig = request_id_middleware.RequestIdConfig;
pub const RequestIdMiddleware = request_id_middleware.RequestIdMiddleware;

// Security headers
pub const security_headers_middleware = @import("security_headers_middleware.zig");
pub const SecurityHeadersConfig = security_headers_middleware.SecurityHeadersConfig;
pub const SecurityHeadersMiddleware = security_headers_middleware.SecurityHeadersMiddleware;

// Body size limiting
pub const body_size_limit = @import("body_size_limit.zig");
pub const BodySizeLimit = body_size_limit.BodySizeLimit;
pub const DefaultLimits = body_size_limit.DefaultLimits;
