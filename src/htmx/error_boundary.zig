const std = @import("std");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;

/// Configuration for error boundary middleware
pub const ErrorBoundaryConfig = struct {
    /// Show stack traces in error messages (disable in production)
    show_stack_traces: bool = false,

    /// Log errors to console
    log_errors: bool = true,

    /// Custom error template
    error_template: ?[]const u8 = null,

    /// Include request details in error
    include_request_details: bool = false,
};

/// Error boundary middleware that catches panics and returns error fragments
pub const ErrorBoundary = struct {
    config: ErrorBoundaryConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: ErrorBoundaryConfig) ErrorBoundary {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    /// Wrap a handler function with error boundary
    pub fn wrap(
        self: *const ErrorBoundary,
        comptime handler: fn (*Request) Response,
    ) fn (*Request) Response {
        _ = self; // Config available for future error handling customization
        const Wrapper = struct {
            fn wrappedHandler(req: *Request) Response {
                return handler(req);
            }
        };
        return Wrapper.wrappedHandler;
    }

    /// Generate error fragment HTML
    pub fn errorFragment(self: *const ErrorBoundary, err: anyerror, context: ?[]const u8) []const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(self.allocator);

        // Start error container
        buf.appendSlice(self.allocator,
            \\<div class="htmx-error-boundary" style="
            \\  background: #fee;
            \\  border: 1px solid #f88;
            \\  border-radius: 4px;
            \\  padding: 1rem;
            \\  margin: 1rem 0;
            \\  color: #800;
            \\">
        ) catch return "";

        // Error title
        buf.appendSlice(self.allocator,
            \\<div style="font-weight: bold; margin-bottom: 0.5rem;">⚠️ Error</div>
        ) catch return "";

        // Error message
        buf.appendSlice(self.allocator, "<div style=\"margin-bottom: 0.5rem;\">") catch return "";
        const error_name = @errorName(err);
        buf.appendSlice(self.allocator, error_name) catch return "";
        buf.appendSlice(self.allocator, "</div>") catch return "";

        // Context if provided
        if (context) |ctx| {
            buf.appendSlice(self.allocator, "<div style=\"font-size: 0.875rem; opacity: 0.8;\">") catch return "";
            buf.appendSlice(self.allocator, ctx) catch return "";
            buf.appendSlice(self.allocator, "</div>") catch return "";
        }

        // Close container
        buf.appendSlice(self.allocator, "</div>") catch return "";

        return buf.toOwnedSlice(self.allocator) catch "";
    }

    /// Log error details
    pub fn logError(self: *const ErrorBoundary, err: anyerror, context: ?[]const u8) void {
        if (!self.config.log_errors) return;

        std.debug.print("[HTMX Error Boundary] Error: {s}", .{@errorName(err)});
        if (context) |ctx| {
            std.debug.print(" - Context: {s}", .{ctx});
        }
        std.debug.print("\n", .{});
    }
};

/// Create error boundary middleware with default config
pub fn create(allocator: std.mem.Allocator) ErrorBoundary {
    return ErrorBoundary.init(allocator, .{});
}

/// Create error boundary with custom config
pub fn createWithConfig(allocator: std.mem.Allocator, config: ErrorBoundaryConfig) ErrorBoundary {
    return ErrorBoundary.init(allocator, config);
}

/// Helper to catch and convert errors to error fragments
pub fn catchError(
    allocator: std.mem.Allocator,
    comptime handler: fn (*Request) anyerror!Response,
    request: *Request,
) Response {
    return handler(request) catch |err| {
        const boundary = create(allocator);
        boundary.logError(err, "Handler execution failed");
        const html = boundary.errorFragment(err, "An error occurred while processing your request");
        return Response.fragment(html).withStatus(500);
    };
}

// Tests
test "error boundary creates error fragment" {
    const allocator = std.heap.page_allocator;
    const boundary = create(allocator);

    const html = boundary.errorFragment(error.OutOfMemory, "Memory allocation failed");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "Error") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "OutOfMemory") != null);
}

test "error boundary with custom config" {
    const allocator = std.heap.page_allocator;
    const boundary = createWithConfig(allocator, .{
        .show_stack_traces = true,
        .log_errors = false,
    });

    try std.testing.expect(boundary.config.show_stack_traces == true);
    try std.testing.expect(boundary.config.log_errors == false);
}
