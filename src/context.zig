//! Engine Context
//!
//! Central dependency injection container that holds all global components.
//! This replaces individual global pointers with a single context pointer,
//! improving testability and reducing global state.

const std = @import("std");
const middleware_chain = @import("middleware/middleware.zig");
const metrics = @import("observability/metrics.zig");
const rate_limit = @import("middleware/rate_limit.zig");
const cache = @import("data/cache.zig");
const dev_tools = @import("observability/dev_tools.zig");
const error_handler = @import("error_handler.zig");
const runtime_routes_mod = @import("valve/runtime_routes.zig");
const shutdown_utils = @import("utils/shutdown.zig");
const config_mod = @import("config/module.zig");

/// EngineContext holds all "global" dependencies for dependency injection.
/// Instead of having 8+ separate global pointers, we have one global context pointer.
pub const EngineContext = struct {
    /// Middleware chain for pre-request and response middleware
    middleware: *const middleware_chain.MiddlewareChain,

    /// Metrics collector for observability
    metrics: *metrics.MetricsCollector,

    /// Optional rate limiter
    rate_limiter: ?*rate_limit.RateLimiter,

    /// Optional response cache
    cache: ?*cache.ResponseCache,

    /// Logger for debugging and monitoring
    logger: *dev_tools.Logger,

    /// Error handler registry
    error_handler: *error_handler.ErrorHandlerRegistry,

    /// Runtime route registry for dynamic routes
    runtime_routes: *runtime_routes_mod.RuntimeRouteRegistry,

    /// Active request tracker for graceful shutdown
    active_request_tracker: *shutdown_utils.ActiveRequestTracker,

    /// Configurable limits
    limits: config_mod.LimitsConfig,
};
