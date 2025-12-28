# Engine12 HTMX Module

Engine12 provides comprehensive HTMX support for building modern, interactive web applications without JavaScript. This module includes helpers for common HTMX patterns, form validation, component fragments, and real-time updates.

## Table of Contents

- [Out-of-Band (OOB) Swaps](#out-of-band-oob-swaps)
- [Component Helpers](#component-helpers)
- [Form Validators](#form-validators)
- [Server-Sent Events (SSE)](#server-sent-events-sse)
- [CSRF Token Integration](#csrf-token-integration)

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
