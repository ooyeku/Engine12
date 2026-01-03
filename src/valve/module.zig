//! Valve module
//!
//! This module provides authentication and authorization (Valve) for Engine12.
//! Valves are reusable components that check if requests should be allowed through.
//!
//! ## Components
//!
//! - **valve** - Core valve interface and types
//! - **registry** - Valve registry for managing valves
//! - **context** - Valve context for passing data
//! - **runtime_routes** - Runtime route registration for valve endpoints
//! - **error_info** - Error information for valve failures
//! - **builtin** - Built-in valves (JWT, Basic Auth, Password)
//!
//! ## Built-in Valves
//!
//! - **jwt** - JSON Web Token authentication
//! - **basic_auth** - HTTP Basic Authentication
//! - **password** - Password hashing and validation
//!
//! ## Example
//! ```zig
//! const valve_mod = @import("valve/module.zig");
//!
//! // JWT valve
//! const jwt_valve = valve_mod.builtin.jwt.JWTValve.init(allocator, .{
//!     .secret = "your-secret-key",
//! });
//!
//! // Register valve
//! var registry = valve_mod.registry.ValveRegistry.init(allocator);
//! try registry.register("jwt", jwt_valve);
//!
//! // Use in route
//! app.get("/protected", handler).withValve("jwt");
//! ```

pub const valve = @import("valve.zig");
pub const registry = @import("registry.zig");
pub const context = @import("context.zig");
pub const runtime_routes = @import("runtime_routes.zig");
pub const error_info = @import("error_info.zig");

// Built-in valves
pub const builtin = struct {
    pub const jwt = @import("builtin/jwt.zig");
    pub const basic_auth = @import("builtin/basic_auth.zig");
    pub const password = @import("builtin/password.zig");
};

// Re-export commonly used types
pub const Valve = valve.Valve;
pub const ValveRegistry = registry.ValveRegistry;
pub const ValveContext = context.ValveContext;
pub const RuntimeRouteRegistry = runtime_routes.RuntimeRouteRegistry;
