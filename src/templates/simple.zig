const std = @import("std");

/// Simple template rendering utility for runtime template processing
/// Reads template files from disk and performs basic variable replacement
/// Works without hot reload (production-safe)
/// Uses single-pass streaming rendering for O(n) performance
///
/// Example:
/// ```zig
/// const html = try renderSimple(
///     "src/templates/index.zt.html",
///     .{ .title = "Welcome", .message = "Hello" },
///     allocator
/// );
/// defer allocator.free(html);
/// ```
pub fn renderSimple(
    template_path: []const u8,
    variables: anytype,
    allocator: std.mem.Allocator,
) ![]u8 {
    // Read template file
    const file = std.fs.cwd().openFile(template_path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => error.TemplateNotFound,
            else => err,
        };
    };
    defer file.close();

    const template_content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| {
        return switch (err) {
            error.FileTooBig => error.TemplateTooLarge,
            else => err,
        };
    };
    defer allocator.free(template_content);

    // Get variable struct type info
    const VariableType = @TypeOf(variables);
    const type_info = @typeInfo(VariableType);
    if (type_info != .@"struct") {
        return error.InvalidVariableType;
    }

    // Use single-pass streaming rendering for O(n) performance
    return renderStreaming(template_content, variables, allocator);
}

/// Single-pass streaming template rendering
/// Scans template once, outputs literal segments and variable values directly
/// Avoids O(n*m) complexity of iterative string replacement
fn renderStreaming(
    template: []const u8,
    variables: anytype,
    allocator: std.mem.Allocator,
) ![]u8 {
    // Pre-allocate output buffer (estimate: template size + some extra for variable values)
    var output: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0, .allocator = allocator };
    errdefer output.deinit();
    try output.ensureTotalCapacity(template.len + 1024);

    var pos: usize = 0;

    while (pos < template.len) {
        // Look for start of variable placeholder: {{
        if (pos + 1 < template.len and
            template[pos] == '{' and
            template[pos + 1] == '{')
        {
            // Find the closing }}
            const var_start = pos + 2;
            var var_end = var_start;
            while (var_end + 1 < template.len) {
                if (template[var_end] == '}' and template[var_end + 1] == '}') {
                    break;
                }
                var_end += 1;
            }

            if (var_end + 1 < template.len) {
                // Extract variable name (trim whitespace and leading dot)
                var var_name = std.mem.trim(u8, template[var_start..var_end], " \t\n\r");
                if (var_name.len > 0 and var_name[0] == '.') {
                    var_name = var_name[1..];
                }

                // Look up variable value and append to output
                var found = false;
                inline for (@typeInfo(@TypeOf(variables)).@"struct".fields) |field| {
                    if (std.mem.eql(u8, field.name, var_name)) {
                        const field_value = @field(variables, field.name);
                        try appendFieldValue(&output, field_value, allocator);
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    // Variable not found - output placeholder as-is
                    try output.appendSlice(template[pos .. var_end + 2]);
                }

                pos = var_end + 2;
                continue;
            }
        }

        // Output literal character
        try output.append(template[pos]);
        pos += 1;
    }

    return output.toOwnedSlice();
}

/// Append a field value to the output buffer
fn appendFieldValue(output: *std.ArrayList(u8), field_value: anytype, allocator: std.mem.Allocator) !void {
    const T = @TypeOf(field_value);
    const type_info = @typeInfo(T);

    switch (type_info) {
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                // String - append directly (fast path)
                try output.appendSlice(field_value);
            } else {
                // Other slice types - format
                try std.fmt.format(output.writer(), "{}", .{field_value});
            }
        },
        .int, .comptime_int => {
            try std.fmt.format(output.writer(), "{d}", .{field_value});
        },
        .float, .comptime_float => {
            try std.fmt.format(output.writer(), "{d}", .{field_value});
        },
        .bool => {
            try output.appendSlice(if (field_value) "true" else "false");
        },
        .optional => {
            if (field_value) |val| {
                try appendFieldValue(output, val, allocator);
            }
            // null outputs nothing
        },
        else => {
            try std.fmt.format(output.writer(), "{}", .{field_value});
        },
    }
}

test "renderSimple with string variables" {
    const allocator = std.testing.allocator;

    // Create a temporary template file
    const test_template = "<h1>{{ .title }}</h1><p>{{ .message }}</p>";
    const test_file = "test_template_simple.zt.html";
    try std.fs.cwd().writeFile(test_file, test_template);
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const html = try renderSimple(
        test_file,
        .{ .title = "Test Title", .message = "Test Message" },
        allocator,
    );
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "Test Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Test Message") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "{{ .title }}") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "{{ .message }}") == null);
}

test "renderSimple with integer variable" {
    const allocator = std.testing.allocator;

    const test_template = "Count: {{ .count }}";
    const test_file = "test_template_int.zt.html";
    try std.fs.cwd().writeFile(test_file, test_template);
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const html = try renderSimple(
        test_file,
        .{ .count = 42 },
        allocator,
    );
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "42") != null);
}

test "renderSimple with boolean variable" {
    const allocator = std.testing.allocator;

    const test_template = "Active: {{ .is_active }}";
    const test_file = "test_template_bool.zt.html";
    try std.fs.cwd().writeFile(test_file, test_template);
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const html = try renderSimple(
        test_file,
        .{ .is_active = true },
        allocator,
    );
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "true") != null);
}
