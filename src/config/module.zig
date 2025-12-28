//! Engine12 Configuration Module
//!
//! Centralized configuration system that reads from .env files and system
//! environment variables. All Engine12-specific variables use the `E12_` prefix.
//!
//! Usage:
//! ```zig
//! const config = @import("config");
//!
//! pub fn main() !void {
//!     const cfg = try config.Config.load(allocator);
//!     cfg.printSummary();
//! }
//! ```

pub const Env = @import("env.zig").Env;
pub const Config = @import("config.zig").Config;
pub const ServerConfig = @import("config.zig").ServerConfig;
pub const DatabaseConfig = @import("config.zig").DatabaseConfig;
pub const LogConfig = @import("config.zig").LogConfig;
pub const CacheConfig = @import("config.zig").CacheConfig;
pub const LimitsConfig = @import("config.zig").LimitsConfig;
pub const Environment = @import("config.zig").Environment;
pub const LogLevel = @import("config.zig").LogLevel;
pub const DatabaseDriver = @import("config.zig").DatabaseDriver;

test {
    _ = @import("env.zig");
    _ = @import("config.zig");
}
