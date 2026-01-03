//! Templates module
//!
//! This module provides template rendering for Engine12.
//! Supports Zig-like syntax with hot-reloading in development mode.
//!
//! ## Components
//!
//! - **template** - Main template engine
//! - **simple** - Simple template rendering without hot-reload
//! - **parser** - Template syntax parser
//! - **ast** - Abstract Syntax Tree for templates
//! - **codegen** - Code generation from templates
//! - **type_checker** - Type checking for template expressions
//! - **filters** - Template filters (upper, lower, etc.)
//! - **escape** - HTML/XML escaping
//!
//! ## Example
//! ```zig
//! const templates = @import("templates/module.zig");
//!
//! // Simple template
//! const html = try templates.simple.render(allocator,
//!     "<h1>Hello, {name}!</h1>",
//!     .{ .name = "World" }
//! );
//! defer allocator.free(html);
//!
//! // With hot-reload (in Engine12 app)
//! app.get("/", indexHandler).withTemplate("views/index.html");
//! ```

pub const template = @import("template.zig");
pub const simple = @import("simple.zig");
pub const parser = @import("parser.zig");
pub const ast = @import("ast.zig");
pub const codegen = @import("codegen.zig");
pub const type_checker = @import("type_checker.zig");
pub const filters = @import("filters.zig");
pub const escape = @import("escape.zig");

// Re-export commonly used types
pub const Template = template.Template;
pub const TemplateEngine = template.TemplateEngine;
