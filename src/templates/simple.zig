const std = @import("std");

pub fn renderSimple(
    template_path: []const u8,
    variables: anytype,
    allocator: std.mem.Allocator,
) ![]u8 {
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

    const VariableType = @TypeOf(variables);
    const type_info = @typeInfo(VariableType);
    if (type_info != .@"struct") {
        return error.InvalidVariableType;
    }

    return renderStreaming(template_content, variables, allocator);
}

fn renderStreaming(
    template: []const u8,
    variables: anytype,
    allocator: std.mem.Allocator,
) ![]u8 {
    var output: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0, .allocator = allocator };
    errdefer output.deinit();
    try output.ensureTotalCapacity(template.len + 1024);

    var pos: usize = 0;

    while (pos < template.len) {
        if (pos + 1 < template.len and
            template[pos] == '{' and
            template[pos + 1] == '{')
        {
            const var_start = pos + 2;
            var var_end = var_start;
            while (var_end + 1 < template.len) {
                if (template[var_end] == '}' and template[var_end + 1] == '}') {
                    break;
                }
                var_end += 1;
            }

            if (var_end + 1 < template.len) {
                var var_name = std.mem.trim(u8, template[var_start..var_end], " \t\n\r");
                if (var_name.len > 0 and var_name[0] == '.') {
                    var_name = var_name[1..];
                }

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
                    try output.appendSlice(template[pos .. var_end + 2]);
                }

                pos = var_end + 2;
                continue;
            }
        }

        try output.append(template[pos]);
        pos += 1;
    }

    return output.toOwnedSlice();
}

fn appendFieldValue(output: *std.ArrayList(u8), field_value: anytype, allocator: std.mem.Allocator) !void {
    const T = @TypeOf(field_value);
    const type_info = @typeInfo(T);

    switch (type_info) {
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                try output.appendSlice(field_value);
            } else {
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
        },
        else => {
            try std.fmt.format(output.writer(), "{}", .{field_value});
        },
    }
}

test "renderSimple with string variables" {
    const allocator = std.testing.allocator;

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
