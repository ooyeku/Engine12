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
//!     // Check if this is an HTMX request
//!     if (req.isHtmx()) {
//!         // Parse the todo from request body
//!         const todo = parseTodo(req) catch return Response.badRequest("Invalid data");
//!
//!         // Return just the new todo HTML fragment
//!         return htmx.response.fragment(renderTodoHtml(todo))
//!             .htmxTrigger("todoAdded");
//!     }
//!
//!     // Regular request - return full page
//!     return Response.html(renderFullPage());
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
pub const withReswap = response.withReswap;
pub const withReselect = response.withReselect;
pub const withLocation = response.withLocation;
pub const stopPolling = response.stopPolling;
pub const replaceWith = response.replaceWith;
pub const prependTo = response.prependTo;
pub const appendTo = response.appendTo;
pub const deleteElement = response.deleteElement;
pub const withMultipleTriggers = response.withMultipleTriggers;

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
