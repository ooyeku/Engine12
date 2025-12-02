const std = @import("std");
const Response = @import("../response.zig").Response;

/// Create a standardized error fragment response
/// Matches the error format used in the todo app
pub fn errorFragment(message: []const u8) Response {
    var buf: [512]u8 = undefined;
    const html = std.fmt.bufPrint(&buf, "<li class=\"error\">{s}</li>", .{message}) catch {
        return Response.fragment("<li class=\"error\">Error</li>").withStatus(500);
    };
    return Response.fragment(html);
}

/// Create a validation error fragment for form fields
pub fn validationErrorFragment(field: []const u8, message: []const u8) Response {
    var buf: [512]u8 = undefined;
    const html = std.fmt.bufPrint(&buf, "<li class=\"error\"><strong>{s}:</strong> {s}</li>", .{ field, message }) catch {
        return Response.fragment("<li class=\"error\">Validation error</li>").withStatus(400);
    };
    return Response.fragment(html).withStatus(400);
}

/// Create a not found fragment response
pub fn notFoundFragment(resource: []const u8) Response {
    var buf: [256]u8 = undefined;
    const html = std.fmt.bufPrint(&buf, "<li class=\"error\">{s} not found</li>", .{resource}) catch {
        return Response.fragment("<li class=\"error\">Not found</li>").withStatus(404);
    };
    return Response.fragment(html).withStatus(404);
}

/// Create an error fragment with a specific status code
pub fn errorFragmentWithStatus(message: []const u8, status: u16) Response {
    return errorFragment(message).withStatus(status);
}

/// Field-specific error that can be swapped into form field
/// Returns error HTML that can be swapped into a specific field container
///
/// Example:
/// ```zig
/// return htmx.errors.fieldErrorFragment("title", "Title is required");
/// // Returns: <div class="field-error" data-field="title">Title is required</div>
/// ```
pub fn fieldErrorFragment(field: []const u8, message: []const u8) Response {
    var buf: [512]u8 = undefined;
    const html = std.fmt.bufPrint(&buf, "<div class=\"field-error\" data-field=\"{s}\">{s}</div>", .{ field, message }) catch {
        return Response.fragment("<div class=\"field-error\">Validation error</div>").withStatus(400);
    };
    return Response.fragment(html).withStatus(400);
}

/// Multiple validation errors in one response
/// Returns fragment with all validation errors listed
///
/// Example:
/// ```zig
/// const errors = [_]ValidationError{
///     .{ .field = "title", .message = "Title is required" },
///     .{ .field = "email", .message = "Invalid email format" },
/// };
/// return htmx.errors.multipleValidationErrors(&errors);
/// ```
pub fn multipleValidationErrors(errors: []const ValidationError) Response {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    writer.writeAll("<ul class=\"validation-errors\">") catch {
        return Response.fragment("<ul class=\"validation-errors\"><li>Validation errors occurred</li></ul>").withStatus(400);
    };

    for (errors) |err| {
        writer.print("<li><strong>{s}:</strong> {s}</li>", .{ err.field, err.message }) catch {
            break;
        };
    }

    writer.writeAll("</ul>") catch {};

    const html = fbs.getWritten();
    return Response.fragment(html).withStatus(400);
}

/// Validation error type for multipleValidationErrors
pub const ValidationError = struct {
    field: []const u8,
    message: []const u8,
};

/// Error with retry action button
/// Error fragment with retry button that triggers HTMX request
///
/// Example:
/// ```zig
/// return htmx.errors.errorWithRetry("Failed to save", "/todos");
/// ```
pub fn errorWithRetry(message: []const u8, retry_url: []const u8) Response {
    var buf: [512]u8 = undefined;
    const html = std.fmt.bufPrint(&buf,
        \\<div class="error-with-retry">
        \\  <p>{s}</p>
        \\  <button class="btn-retry" hx-post="{s}" hx-target="closest .error-with-retry" hx-swap="outerHTML">Retry</button>
        \\</div>
    , .{ message, retry_url }) catch {
        return Response.fragment("<div class=\"error\">Error occurred</div>").withStatus(500);
    };
    return Response.fragment(html).withStatus(500);
}

/// Toast notification error (for non-blocking errors)
/// Returns fragment that triggers toast notification event
///
/// Example:
/// ```zig
/// return htmx.errors.toastError("Item deleted successfully");
/// ```
pub fn toastError(message: []const u8) Response {
    // Escape message for JSON
    var buf: [512]u8 = undefined;
    var escaped_buf: [512]u8 = undefined;
    var escaped_len: usize = 0;
    for (message) |c| {
        if (escaped_len + 2 >= escaped_buf.len) break;
        switch (c) {
            '"' => {
                escaped_buf[escaped_len] = '\\';
                escaped_buf[escaped_len + 1] = '"';
                escaped_len += 2;
            },
            '\\' => {
                escaped_buf[escaped_len] = '\\';
                escaped_buf[escaped_len + 1] = '\\';
                escaped_len += 2;
            },
            else => {
                escaped_buf[escaped_len] = c;
                escaped_len += 1;
            },
        }
    }
    const escaped = escaped_buf[0..escaped_len];

    const event_json = std.fmt.bufPrint(&buf, "{{\"showToast\":{{\"message\":\"{s}\",\"type\":\"error\"}}}}", .{escaped}) catch {
        return Response.fragment("").withHeader("HX-Trigger", "{\"showToast\":{\"message\":\"Error\",\"type\":\"error\"}}");
    };
    return Response.fragment("").withHeader("HX-Trigger", event_json);
}

/// Inline field error (for form validation)
/// Returns error that can be inserted after form field
///
/// Example:
/// ```zig
/// return htmx.errors.inlineFieldError("email", "Invalid email format");
/// // Returns: <span class="inline-error" data-field="email">Invalid email format</span>
/// ```
pub fn inlineFieldError(field: []const u8, message: []const u8) Response {
    var buf: [512]u8 = undefined;
    const html = std.fmt.bufPrint(&buf, "<span class=\"inline-error\" data-field=\"{s}\">{s}</span>", .{ field, message }) catch {
        return Response.fragment("<span class=\"inline-error\">Error</span>").withStatus(400);
    };
    return Response.fragment(html).withStatus(400);
}

// Tests
test "errorFragment" {
    const resp = errorFragment("Test error");
    try std.testing.expect(resp.getBody().len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp.getBody(), "Test error") != null);
}

test "validationErrorFragment" {
    const resp = validationErrorFragment("title", "is required");
    try std.testing.expect(resp.getBody().len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp.getBody(), "title") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.getBody(), "is required") != null);
}

test "notFoundFragment" {
    const resp = notFoundFragment("Todo");
    try std.testing.expect(resp.getBody().len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp.getBody(), "Todo") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.getBody(), "not found") != null);
}

