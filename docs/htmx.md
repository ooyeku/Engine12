# Engine12 HTMX Module

Engine12 provides comprehensive HTMX support for building modern, interactive web applications without JavaScript. This module includes helpers for common HTMX patterns, form validation, component fragments, and real-time updates.

## Table of Contents

### Tier 1 Features
- [Out-of-Band (OOB) Swaps](#out-of-band-oob-swaps)
- [Component Helpers](#component-helpers)
- [Form Validators](#form-validators)
- [Server-Sent Events (SSE)](#server-sent-events-sse)
- [CSRF Token Integration](#csrf-token-integration)

### Tier 2 Features
- [Pagination & Infinite Scroll](#pagination--infinite-scroll)
- [Search & Autocomplete](#search--autocomplete)
- [Form Builder](#form-builder)
- [Optimistic UI](#optimistic-ui)
- [Fragment Caching](#fragment-caching)

### Tier 4 Features (Architecture Improvements)
- [Declarative Route Handlers](#declarative-route-handlers)
- [Response Composition](#response-composition)
- [Template Integration](#template-integration)
- [Request Context Helpers](#request-context-helpers)
- [Error Boundary Middleware](#error-boundary-middleware)

### Additional
- [Best Practices](#best-practices)

## Out-of-Band (OOB) Swaps

OOB swaps allow you to update multiple parts of the page with a single response. This is useful for updating counters, notifications, or any element outside the main target.

### Basic Usage

```zig
const htmx = @import("engine12").htmx;

pub fn handleCreateTodo(request: *Request) Response {
    // Create the todo...
    
    // Return primary content + OOB updates
    var builder = htmx.OobSwapBuilder.init(allocator);
    defer builder.deinit();
    
    return builder
        .primary("<li id=\"todo-1\">New Todo</li>")
        .swap("#todo-count", "<span id=\"todo-count\">5 items</span>")
        .swap("#notification", "<div id=\"notification\">Todo created!</div>")
        .trigger("todoCreated")
        .build();
}
```

### Swap Strategies

```zig
// Replace inner HTML
builder.swapInner("#stats", "New stats content");

// Replace entire element
builder.swapOuter("#element", "<div id=\"element\">New element</div>");

// Prepend content
builder.swapPrepend("#list", "<li>First item</li>");

// Append content
builder.swapAppend("#list", "<li>Last item</li>");

// Delete an element
builder.swapDelete("#to-remove");
```

### Convenience Functions

```zig
// Simple OOB swap with one additional element
const resp = htmx.oobSwap(allocator, 
    "<li>New Item</li>",     // Primary content
    "#count",                 // OOB target
    "<span>10</span>"         // OOB content
);
```

## Component Helpers

Pre-built HTML fragments for common UI patterns, all HTMX-ready.

### Toast Notifications

```zig
const htmx = @import("engine12").htmx;

// Simple toast (auto-dismisses after 5 seconds)
const html = try htmx.toast(allocator, "Item saved!", .success);

// Toast with custom duration
const warning = try htmx.toastWithDuration(allocator, "Warning!", .warning, 3000);

// Toast types: .success, .err, .warning, .info
```

### Modal Dialogs

```zig
// Simple modal
const modal_html = try htmx.modal(allocator, "Edit Item", "<form>...</form>");

// Modal with size and closable options
const large_modal = try htmx.modalWithOptions(
    allocator, 
    "Title", 
    "Content", 
    .large,      // .small, .medium, .large, .fullscreen
    true         // closable
);

// Modal with action buttons
const actions = "<button class=\"btn\">Save</button>";
const action_modal = try htmx.modalWithActions(allocator, "Confirm", "Are you sure?", actions);

// Close modal (returns empty container)
const close = try htmx.modalClose(allocator);
```

### Confirmation Dialogs

```zig
// Generic confirm dialog
const confirm = try htmx.confirmDialog(
    allocator,
    "Delete this item?",
    "/items/1",      // URL to call on confirm
    "DELETE"         // HTTP method
);

// Delete confirmation with item name
const delete = try htmx.deleteConfirm(allocator, "My Document", "/documents/1");
```

### Loading Indicators

```zig
// Simple spinner
const spinner = try htmx.loadingSpinner(allocator);

// Spinner with size
const large_spinner = try htmx.loadingSpinnerWithSize(allocator, .large);

// Spinner with text
const loading = try htmx.loadingSpinnerWithText(allocator, "Loading items...");

// Skeleton loader (placeholder lines)
const skeleton = try htmx.skeleton(allocator, 3); // 3 placeholder lines
```

### Empty State

```zig
// Simple empty state
const empty = try htmx.emptyState(allocator, "No items", "Add your first item");

// Empty state with action button
const with_action = try htmx.emptyStateWithAction(
    allocator,
    "No items",
    "Get started by adding your first item",
    "Add Item",      // Button label
    "/items/new"     // Action URL
);
```

### Alerts

```zig
// Dismissable alert
const alert_html = try htmx.alert(allocator, "Operation successful!", .success);

// Non-dismissable alert
const permanent = try htmx.alertWithDismiss(allocator, "Important notice", .info, false);
```

### Progress Bar

```zig
// Simple progress bar
const progress = try htmx.progressBar(allocator, 75); // 75%

// Progress bar with label
const labeled = try htmx.progressBarWithLabel(allocator, 50, "Uploading...");
```

### Pagination

```zig
// Pagination controls with HTMX attributes
const pages = try htmx.pagination(
    allocator,
    3,           // current page
    10,          // total pages
    "/items"     // base URL
);
```

## Form Validators

Built-in validators for common form field validation.

### Basic Validators

```zig
const validators = @import("engine12").htmx.validators;

// Required field
validators.isRequired("hello");      // true
validators.isRequired("");           // false

// Trimmed required (ignores whitespace)
validators.isRequiredTrimmed("  ");  // false
```

### String Length

```zig
// Minimum length
const minLen = validators.minLength(5);
minLen("hello");  // true
minLen("hi");     // false

// Maximum length
const maxLen = validators.maxLength(10);

// Length range
const range = validators.lengthBetween(3, 10);

// Exact length
const exact = validators.exactLength(5);
```

### Format Validators

```zig
// Email
validators.isEmail("user@example.com");  // true
validators.isEmail("invalid");           // false

// URL
validators.isUrl("https://example.com"); // true

// Phone number (basic)
validators.isPhone("+1 (555) 123-4567"); // true

// UUID
validators.isUuid("550e8400-e29b-41d4-a716-446655440000"); // true

// Hex color
validators.isHexColor("#FF5733");        // true
validators.isHexColor("#fff");           // true

// Date (YYYY-MM-DD)
validators.isDate("2024-01-15");         // true

// Time (HH:MM or HH:MM:SS)
validators.isTime("14:30:45");           // true
```

### Numeric Validators

```zig
// Digits only
validators.isNumeric("12345");   // true
validators.isNumeric("-123");    // false (no sign)

// Integer (with optional sign)
validators.isInteger("-123");    // true

// Decimal
validators.isDecimal("3.14159"); // true

// Value ranges
const minVal = validators.minValue(10);
const maxVal = validators.maxValue(100);
const between = validators.valueBetween(1, 100);
```

### Pattern Matching

```zig
// Contains substring
const hasTest = validators.contains("test");
hasTest("this is a test"); // true

// Starts with
const startsHello = validators.startsWith("hello");

// Ends with
const endsCom = validators.endsWith(".com");

// One of choices
const color = validators.oneOf(&.{ "red", "green", "blue" });
color("red");    // true
color("yellow"); // false
```

### Password Validators

```zig
// Strong password (8+ chars, letter + digit)
validators.isStrongPassword("Password1");  // true

// Very strong (upper, lower, digit, special)
validators.isVeryStrongPassword("Password1!"); // true
```

### Alphanumeric

```zig
validators.isAlphanumeric("abc123");  // true
validators.isAlpha("abcdef");         // true (letters only)
validators.isSlug("my-post-123");     // true (lowercase + hyphens)
validators.isUsername("user_name");   // true (3-20 chars, starts alphanumeric)
```

### Composite Validators

```zig
// All validators must pass
const strict = validators.allOf(&.{ &validators.isRequired, &validators.isAlphanumeric });

// Any validator passes
const flexible = validators.anyOf(&.{ &validators.isEmail, &validators.isUrl });

// Negate a validator
const notEmpty = validators.not(&isEmpty);
```

### Using with FormValidator

```zig
var validator = htmx.FormValidator.init(parser, allocator);
defer validator.deinit();

// Validate fields
validator.validate("email", validators.isEmail, "Invalid email address");
validator.validate("password", validators.isStrongPassword, "Password too weak");

if (validator.hasErrors()) {
    return htmx.validationErrorFragment(validator.getErrors());
}
```

## Server-Sent Events (SSE)

Real-time updates without WebSockets or polling.

### Server-Side (Zig Handler)

```zig
const htmx = @import("engine12").htmx;

pub fn handleEvents(request: *Request) Response {
    var stream = htmx.SSEStream.init(allocator);
    defer stream.deinit();
    
    return stream
        .setRetry(3000)  // Reconnect after 3 seconds
        .message("Connected!")
        .event("todoUpdate", "<li>New Todo</li>")
        .fragment("stats", "<span>5 items</span>")
        .response();
}
```

### Client-Side (HTML)

```html
<div hx-ext="sse" sse-connect="/api/events">
    <div id="todo-list" sse-swap="todoUpdate"></div>
    <div id="stats" sse-swap="stats"></div>
</div>
```

### HTML Helpers

```zig
// Generate SSE container
const container = try htmx.sseContainer(allocator, "/api/events", inner_html);

// Generate swap target
const target = try htmx.sseSwapTarget(allocator, "todoUpdate", "todo-list");

// Generate container with multiple targets
const targets = [_]htmx.sse.SseTarget{
    .{ .event = "todos", .id = "todo-list" },
    .{ .event = "stats", .id = "stats-panel" },
};
const full = try htmx.sseContainerWithTargets(allocator, "/api/events", &targets);
```

### Convenience Functions

```zig
// Single event response
const resp = htmx.sseEvent(allocator, "update", "New data");

// Simple message
const msg = htmx.sseMessage(allocator, "Hello!");

// HTMX fragment event
const frag = htmx.sseFragment(allocator, "todoList", "<li>Item</li>");
```

## CSRF Token Integration

Protect forms against Cross-Site Request Forgery attacks.

### Token Generation

```zig
const csrf = @import("engine12").htmx.csrf;

// Generate a secure token
const token = try csrf.generateToken(allocator);

// Or with custom length
const short_token = try csrf.generateTokenWithLength(allocator, 16);
```

### Token Validation

```zig
// Validate submitted token
const is_valid = csrf.validateToken(submitted_token, stored_token);

// Check if method requires validation
if (csrf.requiresValidation(request.method)) {
    const submitted = request.header("X-CSRF-Token");
    if (!csrf.validateToken(submitted, stored_token)) {
        return csrf.errorResponse(allocator);
    }
}
```

### HTML Helpers

```zig
// Hidden form input
const input = try csrf.hiddenInput(allocator, token);
// <input type="hidden" name="_csrf" value="...">

// Meta tag (for HTMX to read)
const meta = try csrf.metaTag(allocator, token);
// <meta name="csrf-token" content="...">

// HTMX headers JSON
const headers = try csrf.hxHeaders(allocator, token);
// {"X-CSRF-Token": "..."}

// Complete form opening tag
const form = try csrf.formStart(allocator, "/submit", "POST", token);

// HTMX form opening tag
const htmx_form = try csrf.htmxFormStart(allocator, "/api/submit", "#result", token);
```

### Auto-inject CSRF Token

```zig
// Script that adds CSRF to all HTMX requests
const script = try csrf.htmxConfigScript(allocator, token);
```

Add this to your page head:
```html
<meta name="csrf-token" content="{{ token }}">
<script>
  document.body.addEventListener('htmx:configRequest', function(evt) {
    evt.detail.headers['X-CSRF-Token'] = '{{ token }}';
  });
</script>
```

### Token Store (Development)

For simple use cases, use the built-in in-memory store:

```zig
var store = csrf.TokenStore.init(allocator);
defer store.deinit();

// Create token for session
const token = try store.createToken("session-123", 3600); // 1 hour expiry

// Validate
if (store.validate("session-123", submitted_token)) {
    // Valid!
}

// Remove on logout
store.removeToken("session-123");

// Clean up expired tokens
store.cleanup();
```

For production, integrate with your session storage (Redis, database, etc.).

## Complete Example

```zig
const std = @import("std");
const E12 = @import("engine12");
const Request = E12.Request;
const Response = E12.Response;
const htmx = E12.htmx;
const validators = htmx.validators;

pub fn handleCreateItem(request: *Request) Response {
    const allocator = std.heap.page_allocator;
    
    // Parse form
    const parser = htmx.FormParser.init(request.body(), allocator);
    var validator = htmx.FormValidator.init(parser, allocator);
    defer validator.deinit();
    
    // Validate
    validator.validate("name", validators.isRequired, "Name is required");
    validator.validate("email", validators.isEmail, "Invalid email");
    
    if (validator.hasErrors()) {
        return htmx.validationErrorFragment(validator.getErrors());
    }
    
    // Create item...
    
    // Return with OOB updates
    var builder = htmx.OobSwapBuilder.init(allocator);
    defer builder.deinit();
    
    return builder
        .primary("<tr id=\"item-1\"><td>New Item</td></tr>")
        .swap("#item-count", "<span id=\"item-count\">10 items</span>")
        .trigger("itemCreated")
        .build();
}
```

---

## Tier 2 Features

### Pagination & Infinite Scroll

Engine12 provides helpers for infinite scroll and pagination patterns.

#### Infinite Scroll

```zig
const htmx = @import("engine12").htmx;

pub fn handleListItems(request: *Request) Response {
    const page = request.queryParam("page").asInt() orelse 1;
    
    // Render items for this page
    var html = try renderItems(allocator, page);
    
    // Add infinite scroll trigger for next page
    if (hasMorePages(page)) {
        const trigger = try htmx.nextPageTrigger(allocator, "/api/items", page + 1);
        defer allocator.free(trigger);
        
        try html.appendSlice(allocator, trigger);
    }
    
    return Response.fragment(html);
}
```

#### Load More Button

```zig
pub fn handleLoadMore(request: *Request) Response {
    const page = request.queryParam("page").asInt() orelse 1;
    
    var html = try renderItems(allocator, page);
    
    // Add load more button
    const button = try htmx.loadMoreButton(allocator, "/api/items", page + 1);
    defer allocator.free(button);
    
    try html.appendSlice(allocator, button);
    
    return Response.fragment(html);
}
```

#### Numbered Pagination

```zig
pub fn handlePaginatedList(request: *Request) Response {
    const current_page = request.queryParam("page").asInt() orelse 1;
    const total_pages = 10;
    
    const pagination = try htmx.numberedPages(
        allocator,
        "/api/items",
        current_page,
        total_pages
    );
    defer allocator.free(pagination);
    
    return Response.fragment(pagination);
}
```

### Search & Autocomplete

Debounced search with keyboard navigation support.

#### Basic Search

```zig
pub fn renderSearchForm(allocator: std.mem.Allocator) ![]const u8 {
    const input = try htmx.searchInput(allocator, "/api/search", 300);
    defer allocator.free(input);
    
    const container = try htmx.searchResultsContainer(allocator, "search-results");
    defer allocator.free(container);
    
    var html = std.ArrayListUnmanaged(u8){};
    try html.appendSlice(allocator, "<div>");
    try html.appendSlice(allocator, input);
    try html.appendSlice(allocator, container);
    try html.appendSlice(allocator, "</div>");
    
    return html.toOwnedSlice(allocator);
}
```

#### Custom Search Options

```zig
const search_input = try htmx.searchInputWithOptions(allocator, "/api/users", 500, .{
    .name = "search",
    .placeholder = "Search users...",
    .target = "#user-results",
    .min_length = 3,
    .trigger_on_load = false,
});
defer allocator.free(search_input);
```

#### Search Results

```zig
pub fn handleSearch(request: *Request) Response {
    const query = request.queryParam("q").asString() orelse "";
    
    if (query.len == 0) {
        const empty = try htmx.searchNoResults(allocator, "Start typing to search...");
        defer allocator.free(empty);
        return Response.fragment(empty);
    }
    
    const results = try searchDatabase(allocator, query);
    
    var html = std.ArrayListUnmanaged(u8){};
    for (results) |result| {
        const item = try htmx.searchResultItem(
            allocator,
            result.name,
            result.id,
            try std.fmt.allocPrint(allocator, "/users/{s}", .{result.id})
        );
        defer allocator.free(item);
        try html.appendSlice(allocator, item);
    }
    
    return Response.fragment(try html.toOwnedSlice(allocator));
}
```

### Form Builder

Type-safe form generation with automatic validation attributes.

#### Basic Form

```zig
pub fn renderForm(allocator: std.mem.Allocator) ![]const u8 {
    var builder = htmx.FormBuilder.init(allocator);
    defer builder.deinit();
    
    _ = try builder.start("/api/users");
    _ = try builder.text("name", "Name", .{ .required = true, .min_length = 3 });
    _ = try builder.email("email", "Email", true);
    _ = try builder.password("password", "Password", true);
    _ = try builder.submit("Create User");
    
    return builder.build();
}
```

#### Form with Select

```zig
const options = [_]htmx.FormSelectOption{
    .{ .value = "low", .label = "Low Priority" },
    .{ .value = "medium", .label = "Medium Priority", .selected = true },
    .{ .value = "high", .label = "High Priority" },
};

var builder = htmx.FormBuilder.init(allocator);
defer builder.deinit();

_ = try builder.start("/api/todos");
_ = try builder.text("title", "Title", .{ .required = true });
_ = try builder.select("priority", "Priority", &options);
_ = try builder.textarea("description", "Description", 5);
_ = try builder.checkbox("urgent", "Mark as urgent", false);
_ = try builder.submit("Create Todo");

const html = try builder.build();
defer allocator.free(html);
```

#### Advanced Text Field Options

```zig
_ = try builder.text("username", "Username", .{
    .required = true,
    .min_length = 3,
    .max_length = 20,
    .pattern = "[a-zA-Z0-9_]+",
    .placeholder = "Enter username",
    .value = "default_value",
    .class = "custom-input",
});
```

### Optimistic UI

Show immediate feedback while requests are processing.

#### Optimistic Class Toggle

```zig
pub fn renderLikeButton(allocator: std.mem.Allocator) ![]const u8 {
    const attrs = try htmx.withOptimisticClass(allocator, "liked");
    defer allocator.free(attrs);
    
    var html = std.ArrayListUnmanaged(u8){};
    try html.appendSlice(allocator, "<button hx-post=\"/api/like\" ");
    try html.appendSlice(allocator, attrs);
    try html.appendSlice(allocator, ">Like</button>");
    
    return html.toOwnedSlice(allocator);
}
```

#### Optimistic Button State

```zig
const button = try htmx.optimisticButton(
    allocator,
    "Save Changes",
    "/api/save",
    "Saving..."
);
defer allocator.free(button);

return Response.fragment(button);
```

#### Optimistic Counter Increment

```zig
const attrs = try htmx.withCounterIncrement(allocator, "#like-count", 1);
defer allocator.free(attrs);

var html = std.ArrayListUnmanaged(u8){};
try html.appendSlice(allocator, "<button hx-post=\"/api/like\" ");
try html.appendSlice(allocator, attrs);
try html.appendSlice(allocator, ">Like</button>");
```

#### Optimistic Item Removal

```zig
const attrs = try htmx.withOptimisticRemove(allocator);
defer allocator.free(attrs);

var html = std.ArrayListUnmanaged(u8){};
try html.appendSlice(allocator, "<button hx-delete=\"/api/item/123\" ");
try html.appendSlice(allocator, attrs);
try html.appendSlice(allocator, ">Delete</button>");
```

#### Optimistic List Addition

```zig
const new_item_html = "<li class=\"temp-item\">New Item</li>";
const attrs = try htmx.withListItemAdd(allocator, "#item-list", new_item_html);
defer allocator.free(attrs);

var html = std.ArrayListUnmanaged(u8){};
try html.appendSlice(allocator, "<button hx-post=\"/api/items\" ");
try html.appendSlice(allocator, attrs);
try html.appendSlice(allocator, ">Add Item</button>");
```

### Fragment Caching

Automatic caching for rendered HTML fragments with ETag support.

#### Initialize Global Cache

```zig
// In your application startup
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // Initialize the global fragment cache
    htmx.initGlobalCache(allocator);
    defer htmx.deinitGlobalCache();
    
    // Start your application...
}
```

#### Cache a Fragment

```zig
pub fn handleExpensiveRender(request: *Request) Response {
    const cache_key = "dashboard:stats";
    
    // Try to get from cache
    if (htmx.getCachedResponse(cache_key)) |entry| {
        return Response.fragment(entry.html)
            .withHeader("ETag", entry.etag);
    }
    
    // Generate expensive HTML
    const html = try generateDashboardStats(allocator);
    
    // Cache for 5 minutes (300000 ms)
    try htmx.cacheResponse(cache_key, html, 300000);
    
    return Response.fragment(html);
}
```

#### Cache Invalidation

```zig
// Invalidate specific cache entry
pub fn handleUpdateStats(request: *Request) Response {
    // Update the stats...
    
    // Invalidate cache
    htmx.invalidateCache("dashboard:stats");
    
    return Response.ok();
}

// Invalidate by prefix (e.g., all user-related caches)
pub fn handleUserUpdate(request: *Request) Response {
    const user_id = request.param("id").asString();
    
    // Update user...
    
    // Invalidate all caches starting with "user:123:"
    const prefix = try std.fmt.allocPrint(allocator, "user:{s}:", .{user_id});
    defer allocator.free(prefix);
    
    htmx.invalidateCachePrefix(prefix);
    
    return Response.ok();
}
```

#### Using Cache with Custom Instance

```zig
// Create a custom cache instance
var cache = htmx.FragmentCache.init(allocator);
defer cache.deinit();

// Store fragment
try cache.put("my-key", "<div>Content</div>", 60000);

// Retrieve fragment
if (cache.get("my-key")) |entry| {
    std.debug.print("HTML: {s}\n", .{entry.html});
    std.debug.print("ETag: {s}\n", .{entry.etag});
}

// Check if exists and not expired
if (cache.has("my-key")) {
    std.debug.print("Cache hit!\n", .{});
}

// Clear expired entries
cache.clearExpired();

// Get statistics
const stats = cache.stats();
std.debug.print("Total: {}, Active: {}, Expired: {}\n", .{
    stats.total_entries,
    stats.active_entries,
    stats.expired_entries,
});
```

## Tier 4 Features (Architecture Improvements)

### Declarative Route Handlers

Simplify HTMX resource routing with a RESTful-style API.

#### Basic Usage

```zig
const htmx = @import("engine12").htmx;
const allocator = std.heap.page_allocator;

// Create an HTMX router
var router = htmx.createHtmxRouter(allocator);
defer router.deinit();

// Register a resource with CRUD handlers
try router.resource("/todos", .{
    .list = &handleListTodos,      // GET /todos
    .create = &handleCreateTodo,   // POST /todos
    .show = &handleShowTodo,       // GET /todos/:id
    .update = &handleUpdateTodo,   // PUT /todos/:id
    .delete = &handleDeleteTodo,   // DELETE /todos/:id
    .new_form = &handleNewForm,    // GET /todos/new
    .edit_form = &handleEditForm,  // GET /todos/:id/edit
});

// Get registered routes
const routes = router.getRoutes();
for (routes) |route| {
    std.debug.print("{s} {s}\n", .{route.method, route.path});
}
```

#### Partial Resources

Only register the handlers you need:

```zig
try router.resource("/comments", .{
    .list = &handleListComments,
    .create = &handleCreateComment,
    // Other handlers remain null
});
```

### Response Composition

Combine multiple fragments with OOB swaps using a fluent builder.

#### Basic Usage

```zig
const Response = @import("engine12").Response;
const allocator = std.heap.page_allocator;

pub fn handleCreateTodo(request: *Request) Response {
    var composer = Response.compose(allocator);
    defer composer.deinit();

    return composer
        .fragment("#todo-list", "<li>New Todo</li>")
        .oob("#stats", "<span>5 items</span>")
        .oob("#notifications", "<div>Todo created!</div>")
        .trigger("todosUpdated")
        .status(201)
        .build();
}
```

#### OOB Swap Strategies

```zig
var composer = Response.compose(allocator);
defer composer.deinit();

// Default innerHTML swap
_ = composer.oob("#stats", "<span>Content</span>");

// Custom swap type
_ = composer.oobWithSwap("#element", "<div>New</div>", "outerHTML");

// Multiple triggers
_ = composer.trigger("dataUpdated");
_ = composer.trigger("statsRefreshed");

// Custom headers
_ = composer.header("X-Custom-Header", "value");
```

### Template Integration

First-class template support with variable substitution.

#### Basic Rendering

```zig
const htmx = @import("engine12").htmx;
const allocator = std.heap.page_allocator;

pub fn handleShowTodo(request: *Request) Response {
    var ctx = htmx.TemplateContext.init(allocator);
    defer ctx.deinit();
    
    try ctx.set("title", "My Todo");
    try ctx.set("status", "completed");
    
    return try htmx.renderTemplate(allocator, "todo-item", ctx);
}
```

#### Custom Renderer Configuration

```zig
var renderer = htmx.createRendererWithConfig(allocator, .{
    .template_dir = "views",
    .extension = ".html",
    .cache_enabled = true,
    .cache_ttl_ms = 60000,
});

const response = try renderer.render("dashboard", ctx);
```

#### Template Format

Templates use `{{ variable }}` syntax:

```html
<!-- templates/todo-item.zt.html -->
<div class="todo">
    <h3>{{ title }}</h3>
    <span class="status">{{ status }}</span>
</div>
```

### Request Context Helpers

Type-safe access to HTMX request state.

#### Basic Usage

```zig
const htmx = @import("engine12").htmx;

pub fn handleRequest(request: *Request) Response {
    const ctx = htmx.htmx(request);
    
    // Check request type
    if (ctx.isHtmx()) {
        // This is an HTMX request
    }
    
    if (ctx.isBoosted()) {
        // This is a boosted navigation
    }
    
    // Conditional rendering
    if (ctx.shouldReturnPartial()) {
        return Response.fragment(partial_html);
    } else {
        return Response.html(full_page);
    }
}
```

#### Available Methods

```zig
const ctx = htmx.htmx(request);

ctx.isHtmx()           // true if HX-Request header present
ctx.isBoosted()        // true if HX-Boosted header present
ctx.isPartial()        // true if HTMX or boosted request
ctx.target()           // HX-Target header value
ctx.trigger()          // HX-Trigger header value
ctx.triggerName()      // HX-Trigger-Name header value
ctx.currentUrl()       // HX-Current-URL header value
ctx.prompt()           // HX-Prompt header value
ctx.isHistoryRestore() // true if history restore request
ctx.activeElement()    // HX-Active-Element header value
ctx.activeElementName()    // HX-Active-Element-Name value
ctx.activeElementValue()   // HX-Active-Element-Value value
ctx.shouldReturnPartial()  // true if should return fragment
ctx.shouldReturnFullPage() // true if should return full page
```

### Error Boundary Middleware

Catch handler errors and return consistent error fragments.

#### Basic Usage

```zig
const htmx = @import("engine12").htmx;
const allocator = std.heap.page_allocator;

pub fn handleRequest(request: *Request) Response {
    return htmx.catchError(allocator, myFallibleHandler, request);
}

fn myFallibleHandler(request: *Request) !Response {
    // This can return an error
    const data = try fetchData();
    return Response.fragment(data);
}
```

If `myFallibleHandler` returns an error, `catchError` returns an error fragment with status 500.

#### Custom Error Boundary

```zig
const boundary = htmx.createErrorBoundaryWithConfig(allocator, .{
    .show_stack_traces = false,  // Disable in production
    .log_errors = true,
    .include_request_details = false,
});

// Generate error fragment manually
const html = boundary.errorFragment(error.OutOfMemory, "Operation failed");
return Response.fragment(html).withStatus(500);
```

#### Handler Wrapping

```zig
const boundary = htmx.createErrorBoundary(allocator);

// Wrap a handler (for use with middleware chains)
const wrapped = boundary.wrap(myHandler);
```

---

## Best Practices

### 1. Combine Features

```zig
pub fn handleCreateItem(request: *Request) Response {
    // Validate with built-in validators
    var validator = htmx.FormValidator.init(parser, allocator);
    defer validator.deinit();
    
    validator.validate("title", htmx.validators.isRequiredTrimmed, "Title required");
    validator.validate("title", htmx.validators.minLength(3), "Too short");
    
    if (validator.hasErrors()) {
        return htmx.multipleValidationErrors(validator.getErrors());
    }
    
    // Create item...
    
    // Use OOB swaps + toast notification
    var builder = htmx.OobSwapBuilder.init(allocator);
    defer builder.deinit();
    
    const toast = try htmx.toast(allocator, "Item created!", .success);
    defer allocator.free(toast);
    
    return builder
        .primary("<li>New Item</li>")
        .swap("#toast", toast)
        .swap("#item-count", "<span>5 items</span>")
        .trigger("itemCreated")
        .build();
}
```

### 2. Cache Expensive Renders

```zig
pub fn handleUserProfile(request: *Request) Response {
    const user_id = request.param("id").asString();
    const cache_key = try std.fmt.allocPrint(allocator, "profile:{s}", .{user_id});
    defer allocator.free(cache_key);
    
    // Check cache first
    if (htmx.getCachedResponse(cache_key)) |entry| {
        return Response.fragment(entry.html);
    }
    
    // Generate profile HTML
    const html = try renderUserProfile(allocator, user_id);
    
    // Cache for 10 minutes
    try htmx.cacheResponse(cache_key, html, 600000);
    
    return Response.fragment(html);
}
```

### 3. Progressive Enhancement

```zig
// Start with basic pagination
const pagination = try htmx.numberedPages(allocator, "/items", 1, 10);

// Upgrade to infinite scroll for supported browsers
const trigger = try htmx.nextPageTrigger(allocator, "/items", 2);

// Provide both options
return Response.fragment(combined_html);
```

