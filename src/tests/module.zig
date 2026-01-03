//! Tests module
//!
//! This module provides testing utilities and integration tests for Engine12.
//!
//! ## Components
//!
//! - **test_helpers** - Helper functions for writing tests
//! - **integration** - Integration tests for Engine12 features
//!
//! ## Example
//! ```zig
//! const tests = @import("tests/module.zig");
//!
//! test "my feature" {
//!     const helper = tests.test_helpers.createTestHelper();
//!     defer helper.deinit();
//!
//!     // Test your feature
//! }
//! ```

pub const test_helpers = @import("test_helpers.zig");
pub const integration = @import("integration.zig");
