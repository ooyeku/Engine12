// Example of updated handlers using new HTMX features
// This shows the key improvements - integrate these into your htmx.zig

const std = @import("std");
const E12 = @import("engine12");
const Request = E12.Request;
const Response = E12.Response;
const htmx = E12.htmx;
const validators = htmx.validators;

const allocator = std.heap.page_allocator;

/// Example: Create todo with OOB swaps + validation + toast
pub fn handleCreateTodoImproved(req: *Request) Response {
    // Parse form data
    var form_parser = req.getFormParser();
    var validator = htmx.FormValidator.init(form_parser, req.allocator());
    defer validator.deinit();

    // Use built-in validators
    validator.validate("title", validators.isRequired, "Title is required");
    validator.validate("title", validators.minLength(3), "Title must be at least 3 characters");
    validator.validate("title", validators.maxLength(100), "Title too long (max 100 characters)");

    if (validator.hasErrors()) {
        // Return validation errors with toast
        const error_toast = htmx.toast(allocator, "Please fix validation errors", .err) catch "";
        return htmx.multipleValidationErrors(validator.getErrors())
            .withHeader("HX-Trigger", "validationFailed");
    }

    // Create the todo (simplified example)
    const todo_html = "<li id=\"todo-1\">New Todo Item</li>";
    const stats_html = try htmx.toast(allocator, "Todo created successfully!", .success);

    // Use OOB swaps to update multiple elements
    var builder = htmx.OobSwapBuilder.init(allocator);
    defer builder.deinit();

    return builder
        .primary(todo_html) // New todo item
        .swap("#toast", stats_html) // Success toast
        .swap("#stats", "<span>5 items</span>") // Update stats
        .trigger("todoCreated")
        .status(201)
        .build();
}

/// Example: Delete todo with confirmation modal
pub fn handleDeleteConfirmation(req: *Request) Response {
    const id_str = req.param("id").asString();

    // Generate delete confirmation modal
    const modal_html = htmx.deleteConfirm(allocator, "this todo", std.fmt.allocPrint(allocator, "/htmx/todos/{s}", .{id_str}) catch "/htmx/todos/0") catch {
        return Response.serverError("Failed to generate confirmation");
    };

    return Response.fragment(modal_html);
}

/// Example: Delete todo with toast notification
pub fn handleDeleteTodoImproved(req: *Request) Response {
    const id_str = req.param("id").asString();

    // Delete from database...
    // orm.delete(Todo, id) catch { ... };

    // Return success toast via OOB
    const success_toast = htmx.toast(allocator, "Todo deleted!", .success) catch "";
    const stats_updated = "<span>4 items</span>";

    var builder = htmx.OobSwapBuilder.init(allocator);
    defer builder.deinit();

    return builder
        .primary("") // Empty primary (item removed)
        .swap("#toast", success_toast) // Success notification
        .swap("#stats", stats_updated) // Update count
        .trigger("todoDeleted")
        .build();
}

/// Example: Form validation with multiple validators
pub fn validateTodoForm(req: *Request) Response {
    var form_parser = req.getFormParser();
    var validator = htmx.FormValidator.init(form_parser, req.allocator());
    defer validator.deinit();

    // Chain multiple validators
    validator.validate("title", validators.isRequiredTrimmed, "Title cannot be empty");
    validator.validate("title", validators.lengthBetween(3, 100), "Title must be 3-100 characters");

    // Validate email if provided
    if (form_parser.get("email") catch null) |email| {
        defer req.allocator().free(email);
        if (email.len > 0) {
            validator.validate("email", validators.isEmail, "Invalid email format");
        }
    }

    // Validate priority is one of allowed values
    validator.validate("priority", validators.oneOf(&.{ "low", "medium", "high" }), "Invalid priority");

    if (validator.hasErrors()) {
        return htmx.multipleValidationErrors(validator.getErrors());
    }

    return Response.ok();
}

/// Example: Using loading spinner and empty state
pub fn handleLoadingState(req: *Request) Response {
    _ = req;

    // Show loading spinner while fetching
    const spinner = htmx.loadingSpinnerWithText(allocator, "Loading todos...") catch "";

    return Response.fragment(spinner);
}

pub fn handleEmptyState(req: *Request) Response {
    _ = req;

    // Show empty state with action
    const empty = htmx.emptyStateWithAction(allocator, "No Todos Yet", "Get started by adding your first task above", "Add Todo", "#add-form") catch "";

    return Response.fragment(empty);
}

/// Example: Progress bar for completion percentage
pub fn handleProgressBar(req: *Request) Response {
    _ = req;

    // Calculate progress (example: 60%)
    const progress = htmx.progressBarWithLabel(allocator, 60, "60% Complete") catch "";

    return Response.fragment(progress);
}

/// Example: Using alert component for errors
pub fn handleError(req: *Request) Response {
    _ = req;

    const error_alert = htmx.alert(allocator, "Failed to save todo. Please try again.", .err) catch "";

    return Response.fragment(error_alert);
}
