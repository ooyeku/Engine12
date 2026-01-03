//! HTTP module
//!
//! This module provides HTTP request/response handling for Engine12.
//! Includes request parsing, response building, file serving, and pagination utilities.
//!
//! ## Core Types
//!
//! - **Request** - HTTP request with headers, body, cookies, and context
//! - **Response** - HTTP response builder with fluent API
//! - **HandlerContext** - Shared context for request handlers
//! - **FileServer** - Static file serving with caching and MIME types
//! - **Pagination** - Pagination helpers for list endpoints
//!
//! ## Example
//! ```zig
//! const http = @import("http/module.zig");
//!
//! fn handler(req: *http.Request) http.Response {
//!     const name = req.param("name") orelse "World";
//!     return http.Response.ok()
//!         .withContentType("text/plain")
//!         .withBody("Hello, " ++ name);
//! }
//! ```

pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const HandlerContext = @import("handler_context.zig").HandlerContext;
pub const handlers = @import("handlers.zig");
pub const fileserver = @import("fileserver.zig");
pub const pagination = @import("pagination.zig");

// Re-export commonly used types
pub const Pagination = pagination.Pagination;
pub const PaginationParams = pagination.PaginationParams;
