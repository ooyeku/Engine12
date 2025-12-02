//! HTMX Integration Module for Engine12
//!
//! This module provides zero-configuration HTMX support, enabling server-driven
//! interactivity with all logic written in Zig. No JavaScript required.
//!
//! ## Features
//!
//! - **Automatic Script Injection**: HTMX script is automatically injected into
//!   HTML responses in development mode
//! - **Request Detection**: Easily detect HTMX requests and their context
//! - **Response Helpers**: Fluent API for HTMX-specific response headers
//! - **Fragment Support**: Create partial HTML responses for DOM updates
//! - **Form Parsing**: Built-in form parser for `application/x-www-form-urlencoded` data
//! - **Error Helpers**: Standardized error fragment responses
//! - **Builder Methods**: Convenient aliases for common HTMX patterns
//!
//! ## Quick Start
//!
//! HTMX is automatically enabled in development mode:
//!
//! ```zig
//! var app = try Engine12.initDevelopment();
//! // HTMX is now enabled - scripts are auto-injected into HTML responses
//! ```
//!
//! For production, explicitly enable:
//!
//! ```zig
//! var app = try Engine12.initProduction();
//! app.enableHtmx();
//! ```
//!
//! ## Handler Example
//!
//! ```zig
//! fn handleAddTodo(req: *Request) Response {
//!     // Use form parser for easy form data access
//!     var form = req.getFormParser();
//!     
//!     // Parse required field
//!     const title = form.getRequired("title") catch {
//!         return htmx.errors.validationErrorFragment("title", "Title is required");
//!     };
//!     defer req.allocator().free(title);
//!
//!     // Parse optional fields
//!     const priority = (form.get("priority") catch null) orelse "medium";
//!     defer if (priority) |p| req.allocator().free(p);
//!
//!     // Save todo and return fragment
//!     const todo = createTodo(title, priority) catch {
//!         return htmx.errors.errorFragment("Failed to create todo");
//!     };
//!
//!     return Response.fragment(renderTodoHtml(todo))
//!         .htmxTrigger("todoAdded");
//! }
//! ```
//!
//! ## Template Example
//!
//! ```html
//! <!-- Add todo form -->
//! <form hx-post="/todos" hx-target="#todo-list" hx-swap="beforeend">
//!     <input name="title" placeholder="New todo...">
//!     <button type="submit">Add</button>
//! </form>
//!
//! <!-- Todo list -->
//! <ul id="todo-list">
//!     {% for todo in todos %}
//!     <li hx-delete="/todos/{{ todo.id }}" hx-swap="outerHTML">
//!         {{ todo.title }}
//!     </li>
//!     {% endfor %}
//! </ul>
//! ```

const std = @import("std");

// Re-export all public types and functions
pub const config = @import("config.zig");
pub const injector = @import("injector.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const form = @import("form.zig");
pub const errors = @import("errors.zig");
pub const form_validator = @import("form_validator.zig");
pub const security = @import("security.zig");
pub const builder = @import("builder.zig");
pub const testing = @import("testing.zig");

// Type aliases for convenience
pub const HtmxConfig = config.HtmxConfig;
pub const HtmxRequestInfo = request.HtmxRequestInfo;

// Configuration presets
pub const default_config = config.default_config;
pub const development_config = config.development_config;
pub const production_config = config.production_config;
pub const disabled_config = config.disabled_config;

// Injector functions
pub const setConfig = injector.setConfig;
pub const getConfig = injector.getConfig;
pub const isEnabled = injector.isEnabled;
pub const injectHtmx = injector.injectHtmx;
pub const addRouteExclusion = injector.addRouteExclusion;

// Request helpers
pub const fromRequest = request.fromRequest;
pub const isHtmxRequest = request.isHtmxRequest;
pub const isHtmxBoosted = request.isHtmxBoosted;
pub const isHtmxPartial = request.isHtmxPartial;
pub const getHtmxTarget = request.getHtmxTarget;
pub const getHtmxTrigger = request.getHtmxTrigger;
pub const getHtmxCurrentUrl = request.getHtmxCurrentUrl;
pub const getHtmxPrompt = request.getHtmxPrompt;

// Response helpers
pub const fragment = response.fragment;
pub const fragmentWithStatus = response.fragmentWithStatus;
pub const withTrigger = response.withTrigger;
pub const withTriggerData = response.withTriggerData;
pub const withTriggerAfterSwap = response.withTriggerAfterSwap;
pub const withTriggerAfterSettle = response.withTriggerAfterSettle;
pub const htmxRedirect = response.htmxRedirect;
pub const htmxRedirectWithStatus = response.htmxRedirectWithStatus;
pub const htmxRefresh = response.htmxRefresh;
pub const withPushUrl = response.withPushUrl;
pub const withNoPushUrl = response.withNoPushUrl;
pub const withReplaceUrl = response.withReplaceUrl;
pub const withNoReplaceUrl = response.withNoReplaceUrl;
pub const withRetarget = response.withRetarget;
pub const withTarget = response.withTarget;
pub const withReswap = response.withReswap;
pub const withSwap = response.withSwap;
pub const withReselect = response.withReselect;
pub const withLocation = response.withLocation;
pub const stopPolling = response.stopPolling;
pub const replaceWith = response.replaceWith;
pub const prependTo = response.prependTo;
pub const appendTo = response.appendTo;
pub const deleteElement = response.deleteElement;
pub const withMultipleTriggers = response.withMultipleTriggers;

// Form parsing helpers
pub const FormParser = form.FormParser;

// Error response helpers
pub const errorFragment = errors.errorFragment;
pub const validationErrorFragment = errors.validationErrorFragment;
pub const notFoundFragment = errors.notFoundFragment;
pub const errorFragmentWithStatus = errors.errorFragmentWithStatus;
pub const fieldErrorFragment = errors.fieldErrorFragment;
pub const multipleValidationErrors = errors.multipleValidationErrors;
pub const errorWithRetry = errors.errorWithRetry;
pub const toastError = errors.toastError;
pub const inlineFieldError = errors.inlineFieldError;
pub const ValidationError = errors.ValidationError;

// Form validator
pub const FormValidator = form_validator.FormValidator;

// Security utilities
pub const Security = security.Security;

// Fluent response builder
pub const HtmxResponseBuilder = builder.HtmxResponseBuilder;

// Testing utilities
pub const Testing = testing.Testing;

// Tests
test "module exports" {
    // Verify all exports are accessible
    _ = HtmxConfig{};
    _ = default_config;
    _ = development_config;
    _ = production_config;
}

test {
    // Run all sub-module tests
    std.testing.refAllDecls(@This());
}
