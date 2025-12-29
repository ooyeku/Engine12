const std = @import("std");
const Response = @import("../http/response.zig").Response;

pub const ToastType = enum {
    success,
    err,
    warning,
    info,

    pub fn toClass(self: ToastType) []const u8 {
        return switch (self) {
            .success => "toast success",
            .err => "toast error",
            .warning => "toast warning",
            .info => "toast info",
        };
    }

    pub fn toIcon(self: ToastType) []const u8 {
        return switch (self) {
            .success => "&#10003;", // checkmark
            .err => "&#10007;", // x mark
            .warning => "&#9888;", // warning triangle
            .info => "&#8505;", // info circle
        };
    }
};

/// Generate a toast notification fragment
/// Auto-dismisses after the specified duration (default 5000ms)
pub fn toast(allocator: std.mem.Allocator, message: []const u8, toast_type: ToastType) ![]const u8 {
    return toastWithDuration(allocator, message, toast_type, 5000);
}

/// Generate a toast notification with custom duration
pub fn toastWithDuration(allocator: std.mem.Allocator, message: []const u8, toast_type: ToastType, duration_ms: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<div id="toast" class="{s}" hx-swap-oob="true"
        \\     hx-trigger="load delay:{d}ms" hx-get="/htmx/dismiss-toast" hx-swap="outerHTML">
        \\  <span class="toast-icon">{s}</span>
        \\  <span class="toast-message">{s}</span>
        \\  <button class="toast-close" hx-get="/htmx/dismiss-toast" hx-target="#toast" hx-swap="outerHTML">&times;</button>
        \\</div>
    , .{ toast_type.toClass(), duration_ms, toast_type.toIcon(), message });
}

/// Generate an empty toast placeholder (for dismissing)
pub fn toastDismiss(allocator: std.mem.Allocator) ![]const u8 {
    _ = allocator;
    // Return just an empty div - the outerHTML swap will replace the toast entirely
    return "<div id=\"toast\"></div>";
}

/// Return a toast response
pub fn toastResponse(allocator: std.mem.Allocator, message: []const u8, toast_type: ToastType) Response {
    const html = toast(allocator, message, toast_type) catch {
        return Response.serverError("Failed to generate toast");
    };
    return Response.fragment(html);
}

// ============================================================================
// Modal Dialogs
// ============================================================================

pub const ModalSize = enum {
    small,
    medium,
    large,
    fullscreen,

    pub fn toClass(self: ModalSize) []const u8 {
        return switch (self) {
            .small => "modal modal-sm",
            .medium => "modal modal-md",
            .large => "modal modal-lg",
            .fullscreen => "modal modal-fullscreen",
        };
    }
};

/// Generate a modal dialog
pub fn modal(allocator: std.mem.Allocator, title: []const u8, content: []const u8) ![]const u8 {
    return modalWithOptions(allocator, title, content, .medium, true);
}

/// Generate a modal dialog with options
pub fn modalWithOptions(allocator: std.mem.Allocator, title: []const u8, content: []const u8, size: ModalSize, closable: bool) ![]const u8 {
    const close_button = if (closable)
        \\<button class="modal-close" hx-get="/htmx/close-modal" hx-target="#modal-container" hx-swap="innerHTML">&times;</button>
    else
        "";

    const backdrop_close = if (closable)
        \\ hx-get="/htmx/close-modal" hx-target="#modal-container" hx-swap="innerHTML"
    else
        "";

    return std.fmt.allocPrint(allocator,
        \\<div id="modal-container" class="modal-backdrop"{s}>
        \\  <div class="{s}" onclick="event.stopPropagation()">
        \\    <div class="modal-header">
        \\      <h3 class="modal-title">{s}</h3>
        \\      {s}
        \\    </div>
        \\    <div class="modal-body">
        \\      {s}
        \\    </div>
        \\  </div>
        \\</div>
    , .{ backdrop_close, size.toClass(), title, close_button, content });
}

/// Generate a modal with action buttons
pub fn modalWithActions(allocator: std.mem.Allocator, title: []const u8, content: []const u8, actions: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<div id="modal-container" class="modal-backdrop" hx-get="/htmx/close-modal" hx-target="#modal-container" hx-swap="innerHTML">
        \\  <div class="modal modal-md" onclick="event.stopPropagation()">
        \\    <div class="modal-header">
        \\      <h3 class="modal-title">{s}</h3>
        \\      <button class="modal-close" hx-get="/htmx/close-modal" hx-target="#modal-container" hx-swap="innerHTML">&times;</button>
        \\    </div>
        \\    <div class="modal-body">
        \\      {s}
        \\    </div>
        \\    <div class="modal-footer">
        \\      {s}
        \\    </div>
        \\  </div>
        \\</div>
    , .{ title, content, actions });
}

/// Generate an empty modal container (for closing)
pub fn modalClose(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "<div id=\"modal-container\"></div>", .{});
}

/// Return a modal response
pub fn modalResponse(allocator: std.mem.Allocator, title: []const u8, content: []const u8) Response {
    const html = modal(allocator, title, content) catch {
        return Response.serverError("Failed to generate modal");
    };
    return Response.fragment(html);
}

// ============================================================================
// Confirm Dialog
// ============================================================================

/// Generate a confirmation dialog
pub fn confirmDialog(allocator: std.mem.Allocator, message: []const u8, confirm_url: []const u8, confirm_method: []const u8) ![]const u8 {
    return confirmDialogWithLabels(allocator, message, confirm_url, confirm_method, "Confirm", "Cancel");
}

/// Generate a confirmation dialog with custom labels
pub fn confirmDialogWithLabels(
    allocator: std.mem.Allocator,
    message: []const u8,
    confirm_url: []const u8,
    confirm_method: []const u8,
    confirm_label: []const u8,
    cancel_label: []const u8,
) ![]const u8 {
    const hx_method = if (std.mem.eql(u8, confirm_method, "DELETE"))
        "hx-delete"
    else if (std.mem.eql(u8, confirm_method, "POST"))
        "hx-post"
    else if (std.mem.eql(u8, confirm_method, "PUT"))
        "hx-put"
    else
        "hx-get";

    return std.fmt.allocPrint(allocator,
        \\<div id="modal-container" class="modal-backdrop">
        \\  <div class="modal modal-sm confirm-dialog" onclick="event.stopPropagation()">
        \\    <div class="modal-body">
        \\      <p class="confirm-message">{s}</p>
        \\    </div>
        \\    <div class="modal-footer">
        \\      <button class="btn btn-secondary" hx-get="/htmx/close-modal" hx-target="#modal-container" hx-swap="innerHTML">{s}</button>
        \\      <button class="btn btn-danger" {s}="{s}" hx-target="#modal-container" hx-swap="innerHTML">{s}</button>
        \\    </div>
        \\  </div>
        \\</div>
    , .{ message, cancel_label, hx_method, confirm_url, confirm_label });
}

/// Generate a delete confirmation dialog
pub fn deleteConfirm(allocator: std.mem.Allocator, item_name: []const u8, delete_url: []const u8) ![]const u8 {
    const message = try std.fmt.allocPrint(allocator, "Are you sure you want to delete \"{s}\"? This action cannot be undone.", .{item_name});
    defer allocator.free(message);
    return confirmDialogWithLabels(allocator, message, delete_url, "DELETE", "Delete", "Cancel");
}

// ============================================================================
// Loading Indicators
// ============================================================================

pub const SpinnerSize = enum {
    small,
    medium,
    large,

    pub fn toClass(self: SpinnerSize) []const u8 {
        return switch (self) {
            .small => "spinner spinner-sm",
            .medium => "spinner spinner-md",
            .large => "spinner spinner-lg",
        };
    }
};

/// Generate a loading spinner
pub fn loadingSpinner(allocator: std.mem.Allocator) ![]const u8 {
    return loadingSpinnerWithSize(allocator, .medium);
}

/// Generate a loading spinner with custom size
pub fn loadingSpinnerWithSize(allocator: std.mem.Allocator, size: SpinnerSize) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<div class="{s}" aria-label="Loading...">
        \\  <div class="spinner-circle"></div>
        \\</div>
    , .{size.toClass()});
}

/// Generate a loading spinner with text
pub fn loadingSpinnerWithText(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<div class="loading-container">
        \\  <div class="spinner spinner-md">
        \\    <div class="spinner-circle"></div>
        \\  </div>
        \\  <span class="loading-text">{s}</span>
        \\</div>
    , .{text});
}

/// Generate a skeleton loader for content
pub fn skeleton(allocator: std.mem.Allocator, lines: u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "<div class=\"skeleton-container\">\n");
    var i: u8 = 0;
    while (i < lines) : (i += 1) {
        try result.appendSlice(allocator, "  <div class=\"skeleton-line\"></div>\n");
    }
    try result.appendSlice(allocator, "</div>");

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// Empty State
// ============================================================================

/// Generate an empty state placeholder
pub fn emptyState(allocator: std.mem.Allocator, title: []const u8, message: []const u8) ![]const u8 {
    return emptyStateWithAction(allocator, title, message, null, null);
}

/// Generate an empty state with action button
pub fn emptyStateWithAction(
    allocator: std.mem.Allocator,
    title: []const u8,
    message: []const u8,
    action_label: ?[]const u8,
    action_url: ?[]const u8,
) ![]const u8 {
    const action_html = if (action_label != null and action_url != null)
        try std.fmt.allocPrint(allocator,
            \\<button class="btn btn-primary" hx-get="{s}" hx-target="body" hx-swap="innerHTML">{s}</button>
        , .{ action_url.?, action_label.? })
    else
        "";
    defer if (action_label != null and action_url != null) allocator.free(action_html);

    return std.fmt.allocPrint(allocator,
        \\<div class="empty-state">
        \\  <div class="empty-state-icon">&#128466;</div>
        \\  <h3 class="empty-state-title">{s}</h3>
        \\  <p class="empty-state-message">{s}</p>
        \\  {s}
        \\</div>
    , .{ title, message, action_html });
}

// ============================================================================
// Inline Alerts
// ============================================================================

pub const AlertType = enum {
    success,
    err,
    warning,
    info,

    pub fn toClass(self: AlertType) []const u8 {
        return switch (self) {
            .success => "alert alert-success",
            .err => "alert alert-error",
            .warning => "alert alert-warning",
            .info => "alert alert-info",
        };
    }
};

/// Generate an inline alert
pub fn alert(allocator: std.mem.Allocator, message: []const u8, alert_type: AlertType) ![]const u8 {
    return alertWithDismiss(allocator, message, alert_type, true);
}

/// Generate an inline alert with dismiss option
pub fn alertWithDismiss(allocator: std.mem.Allocator, message: []const u8, alert_type: AlertType, dismissable: bool) ![]const u8 {
    const dismiss_button = if (dismissable)
        \\<button class="alert-close" onclick="this.parentElement.remove()">&times;</button>
    else
        "";

    return std.fmt.allocPrint(allocator,
        \\<div class="{s}">
        \\  <span class="alert-message">{s}</span>
        \\  {s}
        \\</div>
    , .{ alert_type.toClass(), message, dismiss_button });
}

// ============================================================================
// Progress Bar
// ============================================================================

/// Generate a progress bar
pub fn progressBar(allocator: std.mem.Allocator, percent: u8) ![]const u8 {
    const clamped = @min(percent, 100);
    return std.fmt.allocPrint(allocator,
        \\<div class="progress-bar" role="progressbar" aria-valuenow="{d}" aria-valuemin="0" aria-valuemax="100">
        \\  <div class="progress-fill" style="width: {d}%"></div>
        \\</div>
    , .{ clamped, clamped });
}

/// Generate a progress bar with label
pub fn progressBarWithLabel(allocator: std.mem.Allocator, percent: u8, label: []const u8) ![]const u8 {
    const clamped = @min(percent, 100);
    return std.fmt.allocPrint(allocator,
        \\<div class="progress-container">
        \\  <div class="progress-label">{s}</div>
        \\  <div class="progress-bar" role="progressbar" aria-valuenow="{d}" aria-valuemin="0" aria-valuemax="100">
        \\    <div class="progress-fill" style="width: {d}%"></div>
        \\  </div>
        \\</div>
    , .{ label, clamped, clamped });
}

// ============================================================================
// Pagination
// ============================================================================

/// Generate pagination controls
pub fn pagination(allocator: std.mem.Allocator, current_page: u32, total_pages: u32, base_url: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "<nav class=\"pagination\" aria-label=\"Pagination\">\n");

    // Previous button
    if (current_page > 1) {
        const prev = try std.fmt.allocPrint(allocator, "  <a class=\"page-link\" hx-get=\"{s}?page={d}\" hx-target=\"#content\">&laquo; Prev</a>\n", .{ base_url, current_page - 1 });
        defer allocator.free(prev);
        try result.appendSlice(allocator, prev);
    } else {
        try result.appendSlice(allocator, "  <span class=\"page-link disabled\">&laquo; Prev</span>\n");
    }

    // Page numbers (show 5 pages centered on current)
    const start = if (current_page > 2) current_page - 2 else 1;
    const end = @min(start + 4, total_pages);

    var page = start;
    while (page <= end) : (page += 1) {
        if (page == current_page) {
            const active = try std.fmt.allocPrint(allocator, "  <span class=\"page-link active\">{d}</span>\n", .{page});
            defer allocator.free(active);
            try result.appendSlice(allocator, active);
        } else {
            const link = try std.fmt.allocPrint(allocator, "  <a class=\"page-link\" hx-get=\"{s}?page={d}\" hx-target=\"#content\">{d}</a>\n", .{ base_url, page, page });
            defer allocator.free(link);
            try result.appendSlice(allocator, link);
        }
    }

    // Next button
    if (current_page < total_pages) {
        const next = try std.fmt.allocPrint(allocator, "  <a class=\"page-link\" hx-get=\"{s}?page={d}\" hx-target=\"#content\">Next &raquo;</a>\n", .{ base_url, current_page + 1 });
        defer allocator.free(next);
        try result.appendSlice(allocator, next);
    } else {
        try result.appendSlice(allocator, "  <span class=\"page-link disabled\">Next &raquo;</span>\n");
    }

    try result.appendSlice(allocator, "</nav>");

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "toast generation" {
    const allocator = std.testing.allocator;
    const html = try toast(allocator, "Item saved!", .success);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "toast success") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Item saved!") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hx-swap-oob") != null);
}

test "toast with duration" {
    const allocator = std.testing.allocator;
    const html = try toastWithDuration(allocator, "Warning!", .warning, 3000);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "delay:3000ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "toast warning") != null);
}

test "modal generation" {
    const allocator = std.testing.allocator;
    const html = try modal(allocator, "Edit Item", "<form>...</form>");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "modal-backdrop") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Edit Item") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "modal-close") != null);
}

test "modal with options" {
    const allocator = std.testing.allocator;
    const html = try modalWithOptions(allocator, "Title", "Content", .large, false);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "modal-lg") != null);
    // No close button when closable is false
    try std.testing.expect(std.mem.indexOf(u8, html, "modal-close") == null);
}

test "confirm dialog" {
    const allocator = std.testing.allocator;
    const html = try confirmDialog(allocator, "Delete this item?", "/items/1", "DELETE");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "confirm-dialog") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hx-delete") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/items/1") != null);
}

test "delete confirm" {
    const allocator = std.testing.allocator;
    const html = try deleteConfirm(allocator, "My Item", "/items/1");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "My Item") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "cannot be undone") != null);
}

test "loading spinner" {
    const allocator = std.testing.allocator;
    const html = try loadingSpinner(allocator);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "spinner") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "aria-label") != null);
}

test "loading spinner with text" {
    const allocator = std.testing.allocator;
    const html = try loadingSpinnerWithText(allocator, "Loading items...");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "Loading items...") != null);
}

test "skeleton loader" {
    const allocator = std.testing.allocator;
    const html = try skeleton(allocator, 3);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "skeleton-container") != null);
    // Count skeleton lines
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOf(u8, html[i..], "skeleton-line")) |pos| {
        count += 1;
        i += pos + 1;
    }
    try std.testing.expect(count == 3);
}

test "empty state" {
    const allocator = std.testing.allocator;
    const html = try emptyState(allocator, "No items", "Add your first item");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "empty-state") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "No items") != null);
}

test "empty state with action" {
    const allocator = std.testing.allocator;
    const html = try emptyStateWithAction(allocator, "No items", "Get started", "Add Item", "/items/new");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "Add Item") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hx-get") != null);
}

test "alert generation" {
    const allocator = std.testing.allocator;
    const html = try alert(allocator, "Success!", .success);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "alert-success") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Success!") != null);
}

test "progress bar" {
    const allocator = std.testing.allocator;
    const html = try progressBar(allocator, 75);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "progress-bar") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "width: 75%") != null);
}

test "progress bar clamped" {
    const allocator = std.testing.allocator;
    const html = try progressBar(allocator, 150); // Should clamp to 100
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "width: 100%") != null);
}

test "pagination" {
    const allocator = std.testing.allocator;
    const html = try pagination(allocator, 3, 10, "/items");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "pagination") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "page=2") != null); // Prev
    try std.testing.expect(std.mem.indexOf(u8, html, "page=4") != null); // Next
    try std.testing.expect(std.mem.indexOf(u8, html, "active") != null); // Current page
}
