//! Utils module
//!
//! This module provides utility functions for Engine12.
//! Includes error handling, memory utilities, platform detection, graceful shutdown, and time helpers.
//!
//! ## Components
//!
//! - **error_context** - Error context and stack traces
//! - **memory** - Memory allocation utilities
//! - **platform** - Platform detection (Windows, Linux, macOS)
//! - **shutdown** - Graceful shutdown helpers
//! - **time** - Time formatting and utilities
//!
//! ## Example
//! ```zig
//! const utils = @import("utils/module.zig");
//!
//! // Graceful shutdown
//! var tracker = utils.shutdown.ActiveRequestTracker.init(allocator);
//! defer tracker.deinit();
//! tracker.beginRequest();
//! defer tracker.endRequest();
//!
//! // Platform detection
//! if (utils.platform.isWindows()) {
//!     // Windows-specific code
//! }
//! ```

pub const error_context = @import("error_context.zig");
pub const memory = @import("memory.zig");
pub const platform = @import("platform.zig");
pub const shutdown = @import("shutdown.zig");
pub const time = @import("time.zig");

// Re-export commonly used types
pub const ActiveRequestTracker = shutdown.ActiveRequestTracker;
