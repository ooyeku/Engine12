# HTMX Guide

Complete guide to using HTMX with Engine12 for building dynamic, server-driven web applications.

## Table of Contents

- [Introduction](#introduction)
- [Getting Started](#getting-started)
- [Type-Safe Form Parsing](#type-safe-form-parsing)
- [Error Handling](#error-handling)
- [Security](#security)
- [Fluent Response Builder](#fluent-response-builder)
- [Testing](#testing)
- [Common Patterns](#common-patterns)
- [Best Practices](#best-practices)

## Introduction

HTMX is a library that allows you to access modern browser features directly from HTML, rather than using JavaScript. Engine12 provides comprehensive HTMX support with automatic script injection, type-safe form parsing, enhanced error handling, security utilities, and testing helpers.

### Key Benefits

- **No JavaScript Required**: Build dynamic web applications with all logic in Zig
- **Progressive Enhancement**: Works without JavaScript, enhanced with HTMX
- **Type Safety**: Compile-time guarantees for form parsing and validation
- **Server-Driven**: All logic on the server, simpler architecture
- **Automatic Injection**: HTMX scripts automatically injected into HTML responses

## Getting Started

### Basic Setup

HTMX is automatically enabled in development mode:

```zig
var app = try Engine12.initDevelopment();
// HTMX is now enabled - scripts are auto-injected
```

For production, enable HTMX explicitly:

```zig
var app = try Engine12.initProduction();
app.enableHtmx();
```

### Basic Example

**Handler:**

```zig
fn handleAddTodo(req: *Request) Response {
    var form = req.getFormParser();
    const title = form.getRequired("title") catch {
        return htmx.errors.validationErrorFragment("title", "Title is required");
    };
    defer req.allocator().free(title);
    
    // Create todo...
    
    return Response.fragment("<li>New todo</li>")
        .htmxTrigger("todoCreated");
}
```

**HTML:**

```html
<form hx-post="/todos" hx-target="#todo-list" hx-swap="beforeend">
    <input type="text" name="title" required>
    <button type="submit">Add</button>
</form>

<ul id="todo-list">
    <!-- Todos appear here -->
</ul>
```

## Type-Safe Form Parsing

The `FormValidator` provides type-safe form parsing directly into Zig structs, eliminating boilerplate and providing automatic validation.

### Basic Usage

```zig
const TodoForm = struct {
    title: []const u8,
    description: []const u8 = "",
    priority: []const u8 = "medium",
    completed: bool = false,
};

fn handleCreateTodo(req: *Request) Response {
    var form_parser = req.getFormParser();
    var validator = htmx.FormValidator.init(form_parser, req.allocator());
    defer validator.deinit();
    
    const form = validator.parseInto(TodoForm) catch |err| {
        if (validator.hasErrors()) {
            return htmx.errors.multipleValidationErrors(validator.getErrors());
        }
        return htmx.errors.errorFragment("Failed to parse form");
    };
    
    // Use form.title, form.priority, etc.
    // All fields are automatically parsed and validated
}
```

### Supported Field Types

- `[]const u8` - Required string field
- `?[]const u8` - Optional string field (defaults to `null`)
- `bool` - Required boolean field
- `?bool` - Optional boolean field (defaults to `false`)
- `i64` - Required integer field
- `?i64` - Optional integer field (defaults to `null`)

### Custom Validation

Add custom validators for fields:

```zig
var validator = htmx.FormValidator.init(form_parser, allocator);
defer validator.deinit();

// Validate email format
validator.validate("email", isValidEmail, "Invalid email format");

fn isValidEmail(value: []const u8) bool {
    return std.mem.indexOf(u8, value, "@") != null;
}

const form = validator.parseInto(UserForm) catch |err| {
    if (validator.hasErrors()) {
        return htmx.errors.multipleValidationErrors(validator.getErrors());
    }
    return htmx.errors.errorFragment("Failed to parse form");
};
```

### Error Handling

The validator collects all errors, allowing you to return multiple validation errors at once:

```zig
const form = validator.parseInto(TodoForm) catch |err| {
    if (validator.hasErrors()) {
        // Return all validation errors
        return htmx.errors.multipleValidationErrors(validator.getErrors());
    }
    return htmx.errors.errorFragment("Failed to parse form");
};
```

## Error Handling

Engine12 provides comprehensive error handling helpers for HTMX responses.

### Basic Error Fragments

```zig
// Simple error message
return htmx.errors.errorFragment("Something went wrong");

// Field-specific error
return htmx.errors.fieldErrorFragment("title", "Title is required");

// Multiple validation errors
const errors = [_]htmx.ValidationError{
    .{ .field = "title", .message = "Title is required" },
    .{ .field = "email", .message = "Invalid email format" },
};
return htmx.errors.multipleValidationErrors(&errors);
```

### Error with Retry

For recoverable errors, provide a retry button:

```zig
return htmx.errors.errorWithRetry("Failed to save", "/todos");
```

### Toast Notifications

For non-blocking errors or success messages:

```zig
return htmx.errors.toastError("Item deleted successfully");
```

### Inline Field Errors

For form validation, insert errors after fields:

```zig
return htmx.errors.inlineFieldError("email", "Invalid email format");
```

## Security

Engine12 provides security utilities to protect against XSS and validate HTMX requests.

### Request Validation

Validate HTMX request headers for security:

```zig
htmx.Security.validateRequest(req) catch |err| {
    return htmx.errors.errorFragment("Invalid request");
};
```

### HTML Sanitization

Sanitize user-generated HTML to prevent XSS:

```zig
const safe_html = try htmx.Security.sanitizeHtml(user_input, allocator);
defer allocator.free(safe_html);
return Response.fragment(safe_html);
```

### HTML Escaping

Escape HTML entities in user input:

```zig
const escaped = try htmx.Security.escapeHtml(user_input, allocator);
defer allocator.free(escaped);
return Response.fragment(escaped);
```

### Selector Validation

Validate CSS selectors to prevent script injection:

```zig
if (!htmx.Security.validateSelector(selector)) {
    return htmx.errors.errorFragment("Invalid selector");
}
```

## Fluent Response Builder

The `HtmxResponseBuilder` provides a fluent API for chaining HTMX response methods.

### Basic Usage

```zig
// Old way (still works):
return Response.fragment(html)
    .htmxTrigger("todoCreated")
    .htmxTarget("#todo-list")
    .htmxSwap("beforeend");

// New fluent way:
return htmx.HtmxResponseBuilder.init(html)
    .trigger("todoCreated")
    .target("#todo-list")
    .swap("beforeend")
    .build();
```

### Advanced Chaining

```zig
return htmx.HtmxResponseBuilder.init(html)
    .trigger("todoCreated")
    .triggerAfterSwap("updateCount")
    .pushUrl("/todos/new")
    .retarget("#todo-list")
    .swap("beforeend")
    .withStatus(201)
    .build();
```

### From Existing Response

```zig
var builder = htmx.HtmxResponseBuilder.fromResponse(existing_response);
return builder
    .trigger("updated")
    .build();
```

## Testing

Engine12 provides testing utilities for HTMX handlers.

### Mock HTMX Requests

Create mock HTMX requests for testing:

```zig
test "create todo" {
    const mock_req = try htmx.Testing.mockHtmxRequest(allocator, .{
        .method = "POST",
        .path = "/todos",
        .body = "title=Test&priority=high",
        .target = "#todo-list",
        .is_htmx = true,
    });
    defer mock_req.deinit();
    
    const resp = handleCreateTodo(&mock_req);
    
    // Assert HTMX headers
    try htmx.Testing.assertHtmxHeader(resp, "HX-Trigger", "todoCreated");
    try htmx.Testing.assertStatus(resp, 200);
    try htmx.Testing.assertFragment(resp);
}
```

### Assertion Helpers

```zig
// Assert HTMX header value
try htmx.Testing.assertHtmxHeader(resp, "HX-Trigger", "todoCreated");

// Assert status code
try htmx.Testing.assertStatus(resp, 200);

// Assert response is a fragment
try htmx.Testing.assertFragment(resp);
```

## Common Patterns

### CRUD Operations

**Create:**

```zig
fn handleCreate(req: *Request) Response {
    var form_parser = req.getFormParser();
    var validator = htmx.FormValidator.init(form_parser, req.allocator());
    defer validator.deinit();
    
    const form = validator.parseInto(ItemForm) catch |err| {
        if (validator.hasErrors()) {
            return htmx.errors.multipleValidationErrors(validator.getErrors());
        }
        return htmx.errors.errorFragment("Failed to parse form");
    };
    
    // Create item...
    
    return htmx.HtmxResponseBuilder.init(renderItem(item))
        .trigger("itemCreated")
        .target("#item-list")
        .swap("beforeend")
        .build();
}
```

**Update:**

```zig
fn handleUpdate(req: *Request) Response {
    const id = req.param("id").asInt() catch {
        return htmx.errors.errorFragment("Invalid ID");
    };
    
    var form_parser = req.getFormParser();
    var validator = htmx.FormValidator.init(form_parser, req.allocator());
    defer validator.deinit();
    
    const form = validator.parseInto(ItemUpdateForm) catch |err| {
        if (validator.hasErrors()) {
            return htmx.errors.multipleValidationErrors(validator.getErrors());
        }
        return htmx.errors.errorFragment("Failed to parse form");
    };
    
    // Update item...
    
    return Response.fragment(renderItem(item))
        .htmxTrigger("itemUpdated");
}
```

**Delete:**

```zig
fn handleDelete(req: *Request) Response {
    const id = req.param("id").asInt() catch {
        return htmx.errors.errorFragment("Invalid ID");
    };
    
    // Delete item...
    
    return Response.fragment("")
        .htmxTrigger("itemDeleted");
}
```

### Search with Debouncing

**Handler:**

```zig
fn handleSearch(req: *Request) Response {
    const query = req.queryParam("q").asString();
    
    // Search...
    
    return Response.fragment(renderResults(results));
}
```

**HTML:**

```html
<input type="search" 
       name="q"
       hx-get="/search"
       hx-target="#results"
       hx-trigger="keyup changed delay:500ms"
       hx-swap="innerHTML">
<div id="results"></div>
```

### Infinite Scroll

**Handler:**

```zig
fn handleLoadMore(req: *Request) Response {
    const page = req.queryParam("page").asInt() catch 1;
    
    // Load more items...
    
    return Response.fragment(renderItems(items))
        .htmxTrigger("itemsLoaded");
}
```

**HTML:**

```html
<div hx-get="/items?page=1" 
     hx-trigger="intersect"
     hx-target="#item-list"
     hx-swap="beforeend">
    Loading...
</div>
```

## Best Practices

### 1. Use Type-Safe Form Parsing

Always use `FormValidator` for form parsing to get compile-time type safety and automatic validation:

```zig
// Good
var validator = htmx.FormValidator.init(form_parser, allocator);
const form = validator.parseInto(TodoForm) catch {
    return htmx.errors.multipleValidationErrors(validator.getErrors());
};

// Avoid
const title = form_parser.getRequired("title") catch {
    return htmx.errors.errorFragment("Title required");
};
```

### 2. Return Appropriate Error Responses

Use specific error helpers for different scenarios:

```zig
// Field validation errors
return htmx.errors.fieldErrorFragment("title", "Title is required");

// Multiple validation errors
return htmx.errors.multipleValidationErrors(validator.getErrors());

// Server errors
return htmx.errors.errorFragmentWithStatus("Database error", 500);

// Not found
return htmx.errors.notFoundFragment("Todo");
```

### 3. Sanitize User Input

Always sanitize or escape user-generated HTML:

```zig
// For user-generated HTML
const safe_html = try htmx.Security.sanitizeHtml(user_input, allocator);

// For plain text
const escaped = try htmx.Security.escapeHtml(user_input, allocator);
```

### 4. Use Fluent Builder for Complex Responses

For responses with multiple HTMX headers, use the fluent builder:

```zig
// Good
return htmx.HtmxResponseBuilder.init(html)
    .trigger("created")
    .pushUrl("/items/new")
    .target("#list")
    .swap("beforeend")
    .build();

// Avoid (too many chained calls)
return Response.fragment(html)
    .htmxTrigger("created")
    .htmxPushUrl("/items/new")
    .htmxRetarget("#list")
    .htmxReswap("beforeend");
```

### 5. Test HTMX Handlers

Write tests for HTMX handlers using the testing utilities:

```zig
test "create todo" {
    const mock_req = try htmx.Testing.mockHtmxRequest(allocator, .{
        .method = "POST",
        .body = "title=Test",
        .is_htmx = true,
    });
    defer mock_req.deinit();
    
    const resp = handleCreateTodo(&mock_req);
    
    try htmx.Testing.assertStatus(resp, 200);
    try htmx.Testing.assertFragment(resp);
    try htmx.Testing.assertHtmxHeader(resp, "HX-Trigger", "todoCreated");
}
```

### 6. Handle Errors Gracefully

Always handle errors and return appropriate error responses:

```zig
fn handleCreate(req: *Request) Response {
    var validator = htmx.FormValidator.init(form_parser, allocator);
    defer validator.deinit();
    
    const form = validator.parseInto(TodoForm) catch |err| {
        if (validator.hasErrors()) {
            return htmx.errors.multipleValidationErrors(validator.getErrors());
        }
        return htmx.errors.errorFragment("Failed to parse form");
    };
    
    // Create todo...
    orm.create(Todo, todo) catch {
        return htmx.errors.errorFragmentWithStatus("Failed to create todo", 500);
    };
    
    return Response.fragment(renderTodo(todo))
        .htmxTrigger("todoCreated");
}
```

### 7. Use Appropriate Swap Methods

Choose the right swap method for your use case:

- `innerHTML` - Replace content inside element (default)
- `outerHTML` - Replace entire element
- `beforeend` - Append to end of element
- `afterbegin` - Prepend to beginning of element
- `beforebegin` - Insert before element
- `afterend` - Insert after element

### 8. Trigger Events for Side Effects

Use events to trigger side effects like updating counts or refreshing other parts of the page:

```zig
return Response.fragment(renderTodo(todo))
    .htmxTrigger("todoCreated");
```

**HTML:**

```html
<div hx-trigger="todoCreated from:body" hx-get="/todos/count">
    Count: <span id="count">0</span>
</div>
```

## Summary

Engine12's HTMX integration provides:

- **Type-Safe Form Parsing**: Parse forms directly into structs with automatic validation
- **Enhanced Error Handling**: Comprehensive error helpers for all scenarios
- **Security Utilities**: XSS protection and request validation
- **Fluent Response Builder**: Clean API for complex HTMX responses
- **Testing Utilities**: Mock requests and assertion helpers

Use these features to build robust, type-safe, server-driven web applications with minimal boilerplate.

