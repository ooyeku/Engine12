//! Routing module
//!
//! This module provides HTTP routing for Engine12.
//! Includes route matching, route groups, and REST API generation.
//!
//! ## Components
//!
//! - **router** - Core routing engine with path parameters
//! - **route_group** - Route grouping with shared prefixes and middleware
//! - **rest_api** - Automatic REST API generation from ORM models
//!
//! ## Example
//! ```zig
//! const routing = @import("routing/module.zig");
//!
//! // Route groups
//! var api_group = app.group("/api");
//! api_group.get("/users", getUsersHandler);
//! api_group.post("/users", createUserHandler);
//!
//! // REST API
//! try routing.rest_api.registerRESTAPI(User, app, "/api/users");
//! ```

pub const router = @import("router.zig");
pub const route_group = @import("route_group.zig");
pub const rest_api = @import("rest_api.zig");

// Re-export commonly used types
pub const Router = router.Router;
pub const RouteGroup = route_group.RouteGroup;
