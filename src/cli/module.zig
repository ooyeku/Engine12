//! CLI module
//!
//! This module provides command-line interface tools for Engine12.
//! Includes commands for project scaffolding, documentation generation, and more.
//!
//! ## Components
//!
//! - **main** - CLI entry point
//! - **utils** - CLI utilities
//! - **commands** - Available CLI commands
//!   - **new** - Create new Engine12 projects
//!   - **docs** - Generate documentation
//!
//! ## Example
//! ```bash
//! # Create a new project
//! engine12 new my-app
//!
//! # Generate documentation
//! engine12 docs
//! ```

pub const main = @import("main.zig");
pub const utils = @import("utils.zig");

pub const commands = struct {
    pub const new = @import("commands/new.zig");
    pub const docs = @import("commands/docs.zig");
};
