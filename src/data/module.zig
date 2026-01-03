//! Data module
//!
//! This module provides data handling utilities for Engine12.
//! Includes JSON parsing, validation, caching, and request parsers.
//!
//! ## Components
//!
//! - **json** - JSON parsing and serialization
//! - **validation** - Data validation utilities
//! - **cache** - Response caching with TTL
//! - **parsers** - Request body parsers (form data, JSON, etc.)
//!
//! ## Example
//! ```zig
//! const data = @import("data/module.zig");
//!
//! // Caching
//! var cache = data.cache.ResponseCache.init(allocator);
//! defer cache.deinit();
//!
//! // Validation
//! const email_valid = data.validation.isValidEmail("user@example.com");
//! ```

pub const json = @import("json.zig");
pub const validation = @import("validation.zig");
pub const cache = @import("cache.zig");
pub const parsers = @import("parsers.zig");

// Re-export commonly used types
pub const ResponseCache = cache.ResponseCache;
pub const CacheEntry = cache.CacheEntry;
