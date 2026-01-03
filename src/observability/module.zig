//! Observability module
//!
//! This module provides monitoring and debugging tools for Engine12.
//! Includes metrics collection, logging, and health checks.
//!
//! ## Components
//!
//! - **metrics** - Prometheus-compatible metrics collection
//! - **dev_tools** - Development tools including logging
//! - **health** - Health check endpoints (liveness, readiness)
//!
//! ## Example
//! ```zig
//! const observability = @import("observability/module.zig");
//!
//! // Metrics
//! var metrics = observability.metrics.MetricsCollector.init(allocator);
//! defer metrics.deinit();
//! metrics.recordRequest("/api/users", 200, 45);
//!
//! // Logging
//! var logger = observability.dev_tools.Logger.init(allocator, .info);
//! logger.info("Server started", .{});
//!
//! // Health checks
//! app.get("/health/live", observability.health.livenessHandler);
//! app.get("/health/ready", observability.health.readinessHandler);
//! ```

pub const metrics = @import("metrics.zig");
pub const dev_tools = @import("dev_tools.zig");
pub const health = @import("health.zig");

// Re-export commonly used types
pub const MetricsCollector = metrics.MetricsCollector;
pub const Logger = dev_tools.Logger;
pub const LogLevel = dev_tools.LogLevel;
