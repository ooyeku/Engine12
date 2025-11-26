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

