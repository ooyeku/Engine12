//! Services module
//!
//! This module provides service management for Engine12.
//! Services are background tasks or workers that run alongside the HTTP server.
//!
//! ## Components
//!
//! - **services** - Service interface and management
//!
//! ## Example
//! ```zig
//! const services = @import("services/module.zig");
//!
//! const MyService = struct {
//!     pub fn start(self: *@This()) !void {
//!         // Service startup logic
//!     }
//!
//!     pub fn stop(self: *@This()) void {
//!         // Service cleanup logic
//!     }
//! };
//!
//! var service = MyService{};
//! try services.services.registerService(&service);
//! ```

pub const services = @import("services.zig");
