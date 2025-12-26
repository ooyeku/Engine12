const std = @import("std");
const escape = @import("../templates/escape.zig");

pub const RuntimeRenderer = struct {
    pub fn render(
        template_content: []const u8,
        comptime Context: type,
        ctx: Context,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < template_content.len) {
            const var_start = std.mem.indexOf(u8, template_content[i..], "{{");
            const block_start = std.mem.indexOf(u8, template_content[i..], "{%");
            const comment_start = std.mem.indexOf(u8, template_content[i..], "{#");

            var next_token: ?struct { start: usize, kind: enum { variable, block, comment } } = null;

            // Find the earliest token
            if (var_start) |vs| {
                next_token = .{ .start = i + vs, .kind = .variable };
            }
            if (block_start) |bs| {
                if (next_token == null or i + bs < next_token.?.start) {
                    next_token = .{ .start = i + bs, .kind = .block };
                }
            }
            if (comment_start) |cs| {
                if (next_token == null or i + cs < next_token.?.start) {
                    next_token = .{ .start = i + cs, .kind = .comment };
                }
            }

            if (next_token) |token| {
                if (token.start > i) {
                    try result.appendSlice(allocator, template_content[i..token.start]);
                }

                switch (token.kind) {
                    .comment => {
                        // Find closing #} and skip the entire comment
                        const comment_end = std.mem.indexOf(u8, template_content[token.start + 2 ..], "#}") orelse {
                            i = template_content.len;
                            continue;
                        };
                        // Skip past the closing #}
                        i = token.start + 2 + comment_end + 2;
                    },
                    .block => {
                        const block_end = std.mem.indexOf(u8, template_content[token.start + 2 ..], "%}") orelse {
                            i = template_content.len;
                            continue;
                        };

                        const block_content = std.mem.trim(u8, template_content[token.start + 2 .. token.start + 2 + block_end], " \t\n");

                        if (std.mem.startsWith(u8, block_content, "if ")) {
                            const condition_str = std.mem.trim(u8, block_content[3..], " \t\n");
                            const condition_value = getVariableValue(condition_str, Context, ctx, allocator) catch |err| {
                                if (err == error.InvalidVariablePath) {
                                    const endif_pos = findEndif(template_content, token.start + 2 + block_end + 2) orelse {
                                        i = template_content.len;
                                        continue;
                                    };
                                    i = endif_pos;
                                    continue;
                                }
                                return err;
                            };
                            defer allocator.free(condition_value);

                            const is_true = isTruthy(condition_value);

                            const endif_pos = findEndif(template_content, token.start + 2 + block_end + 2) orelse {
                                i = token.start + 2 + block_end + 2;
                                continue;
                            };

                            if (is_true) {
                                const content_start = token.start + 2 + block_end + 2;
                                const content_end = endif_pos;
                                try result.appendSlice(allocator, template_content[content_start..content_end]);
                            }
                            i = endif_pos + 11;
                        } else if (std.mem.eql(u8, block_content, "endif")) {
                            i = token.start + 2 + block_end + 2;
                        } else {
                            try result.appendSlice(allocator, template_content[token.start .. token.start + 2 + block_end + 2]);
                            i = token.start + 2 + block_end + 2;
                        }
                    },
                    .variable => {
                        const var_end = std.mem.indexOf(u8, template_content[token.start + 2 ..], "}}") orelse {
                            i = template_content.len;
                            continue;
                        };

                        const var_content = template_content[token.start + 2 .. token.start + 2 + var_end];
                        const is_raw = var_content.len > 0 and var_content[0] == '!';
                        const var_str = if (is_raw) std.mem.trim(u8, var_content[1..], " \t\n") else std.mem.trim(u8, var_content, " \t\n");

                        const value = getVariableValue(var_str, Context, ctx, allocator) catch |err| {
                            if (err == error.InvalidVariablePath) {
                                i = token.start + 2 + var_end + 2;
                                continue;
                            }
                            return err;
                        };
                        defer allocator.free(value);

                        if (is_raw) {
                            try result.appendSlice(allocator, value);
                        } else {
                            const escaped = try escape.Escape.escapeHtml(allocator, value);
                            defer allocator.free(escaped);
                            try result.appendSlice(allocator, escaped);
                        }

                        i = token.start + 2 + var_end + 2;
                    },
                }
            } else {
                try result.appendSlice(allocator, template_content[i..]);
                break;
            }
        }

        return result.toOwnedSlice(allocator);
    }

    fn getVariableValue(
        var_path: []const u8,
        comptime Context: type,
        ctx: Context,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const path = if (var_path.len > 0 and var_path[0] == '.') var_path[1..] else var_path;

        var parts = std.ArrayListUnmanaged([]const u8){};
        defer parts.deinit(allocator);

        var start: usize = 0;
        var i: usize = 0;
        while (i < path.len) {
            if (path[i] == '.') {
                if (i > start) {
                    const part = path[start..i];
                    try parts.append(allocator, part);
                }
                start = i + 1;
            }
            i += 1;
        }
        if (start < path.len) {
            try parts.append(allocator, path[start..]);
        }

        return getVariableValueImpl(ctx, parts.items, allocator);
    }

    fn getVariableValueImpl(
        value: anytype,
        path: []const []const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        switch (type_info) {
            .@"struct" => |struct_info| {
                if (path.len == 0) {
                    return error.InvalidVariablePath;
                }

                const field_name = path[0];

                inline for (struct_info.fields) |field| {
                    if (std.mem.eql(u8, field.name, field_name)) {
                        const field_value = @field(value, field.name);

                        if (path.len == 1) {
                            return formatValue(field_value, allocator);
                        } else {
                            return getVariableValueImpl(field_value, path[1..], allocator);
                        }
                    }
                }

                return error.InvalidVariablePath;
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return try allocator.dupe(u8, value);
                }
                return error.InvalidVariablePath;
            },
            else => {
                return formatValue(value, allocator);
            },
        }
    }

    fn formatValue(value: anytype, allocator: std.mem.Allocator) ![]const u8 {
        const T = @TypeOf(value);

        return switch (@typeInfo(T)) {
            .pointer => |ptr_info| switch (ptr_info.size) {
                .slice => {
                    if (ptr_info.child == u8) {
                        return try allocator.dupe(u8, value);
                    } else {
                        return try std.fmt.allocPrint(allocator, "{any}", .{value});
                    }
                },
                else => try std.fmt.allocPrint(allocator, "{any}", .{value}),
            },
            .array => |arr_info| {
                if (arr_info.child == u8) {
                    return try allocator.dupe(u8, &value);
                } else {
                    return try std.fmt.allocPrint(allocator, "{any}", .{value});
                }
            },
            .int => try std.fmt.allocPrint(allocator, "{d}", .{value}),
            .float => try std.fmt.allocPrint(allocator, "{d}", .{value}),
            .bool => {
                const bool_str = if (value) "true" else "false";
                return try allocator.dupe(u8, bool_str);
            },
            .optional => {
                if (value) |val| {
                    return formatValue(val, allocator);
                } else {
                    return try allocator.dupe(u8, "");
                }
            },
            else => {
                return try std.fmt.allocPrint(allocator, "{any}", .{value});
            },
        };
    }

    fn isTruthy(value: []const u8) bool {
        if (value.len == 0) return false;
        if (std.mem.eql(u8, value, "false")) return false;
        if (std.mem.eql(u8, value, "0")) return false;
        if (std.mem.eql(u8, value, "")) return false;
        return true;
    }

    fn findEndif(content: []const u8, start_pos: usize) ?usize {
        if (start_pos >= content.len) return null;
        const endif_start = std.mem.indexOf(u8, content[start_pos..], "{% endif %}") orelse return null;
        return start_pos + endif_start;
    }
};

test "runtime renderer - plain text" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const result = try RuntimeRenderer.render("Hello World", Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "Hello World");
}

test "runtime renderer - variable substitution" {
    const allocator = std.testing.allocator;
    const Context = struct { name: []const u8 };
    const result = try RuntimeRenderer.render("Hello {{ .name }}!", Context, .{ .name = "Zig" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "Hello Zig!");
}

test "runtime renderer - nested path" {
    const allocator = std.testing.allocator;
    const Inner = struct { name: []const u8 };
    const Context = struct { user: Inner };
    const result = try RuntimeRenderer.render("Hello {{ .user.name }}", Context, .{ .user = .{ .name = "Alice" } }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "Hello Alice");
}

test "runtime renderer - comment stripping" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const result = try RuntimeRenderer.render("before{# comment #}after", Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "beforeafter");
}

test "runtime renderer - comment only template" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const result = try RuntimeRenderer.render("{# just a comment #}", Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "");
}

test "runtime renderer - multiple comments" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const result = try RuntimeRenderer.render("a{# 1 #}b{# 2 #}c", Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "abc");
}

test "runtime renderer - html escaping" {
    const allocator = std.testing.allocator;
    const Context = struct { text: []const u8 };
    const result = try RuntimeRenderer.render("{{ .text }}", Context, .{ .text = "<script>" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "&lt;script&gt;");
}

test "runtime renderer - raw variable" {
    const allocator = std.testing.allocator;
    const Context = struct { html: []const u8 };
    const result = try RuntimeRenderer.render("{{! .html }}", Context, .{ .html = "<b>bold</b>" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "<b>bold</b>");
}

test "runtime renderer - if true" {
    const allocator = std.testing.allocator;
    const Context = struct { show: []const u8 };
    const result = try RuntimeRenderer.render("{% if .show %}visible{% endif %}", Context, .{ .show = "true" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "visible");
}

test "runtime renderer - if false" {
    const allocator = std.testing.allocator;
    const Context = struct { show: []const u8 };
    const result = try RuntimeRenderer.render("{% if .show %}visible{% endif %}", Context, .{ .show = "false" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "");
}

test "runtime renderer - missing variable" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const result = try RuntimeRenderer.render("Hello {{ .name }}", Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "Hello ");
}

test "runtime renderer - integer value" {
    const allocator = std.testing.allocator;
    const Context = struct { count: i32 };
    const result = try RuntimeRenderer.render("Count: {{ .count }}", Context, .{ .count = 42 }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "Count: 42");
}

test "runtime renderer - boolean value" {
    const allocator = std.testing.allocator;
    const Context = struct { active: bool };
    const result = try RuntimeRenderer.render("Active: {{ .active }}", Context, .{ .active = true }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "Active: true");
}

test "runtime renderer - empty template" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const result = try RuntimeRenderer.render("", Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "");
}

test "runtime renderer - comment before variable" {
    const allocator = std.testing.allocator;
    const Context = struct { x: []const u8 };
    const result = try RuntimeRenderer.render("{# comment #}{{ .x }}", Context, .{ .x = "val" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "val");
}

test "runtime renderer - variable before comment" {
    const allocator = std.testing.allocator;
    const Context = struct { x: []const u8 };
    const result = try RuntimeRenderer.render("{{ .x }}{# comment #}", Context, .{ .x = "val" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(result, "val");
}

test "runtime renderer - multiple variables in template" {
    const allocator = std.testing.allocator;
    const Context = struct { first: []const u8, second: []const u8, third: []const u8 };
    const result = try RuntimeRenderer.render(
        "{{ .first }}, {{ .second }}, {{ .third }}",
        Context,
        .{ .first = "A", .second = "B", .third = "C" },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("A, B, C", result);
}

test "runtime renderer - adjacent variables without spacing" {
    const allocator = std.testing.allocator;
    const Context = struct { a: []const u8, b: []const u8 };
    const result = try RuntimeRenderer.render("{{ .a }}{{ .b }}", Context, .{ .a = "Hello", .b = "World" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("HelloWorld", result);
}

test "runtime renderer - variable at start of template" {
    const allocator = std.testing.allocator;
    const Context = struct { name: []const u8 };
    const result = try RuntimeRenderer.render("{{ .name }} follows", Context, .{ .name = "This" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("This follows", result);
}

test "runtime renderer - variable at end of template" {
    const allocator = std.testing.allocator;
    const Context = struct { name: []const u8 };
    const result = try RuntimeRenderer.render("Ends with {{ .name }}", Context, .{ .name = "this" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Ends with this", result);
}

test "runtime renderer - deeply nested path" {
    const allocator = std.testing.allocator;
    const Level3 = struct { value: []const u8 };
    const Level2 = struct { level3: Level3 };
    const Level1 = struct { level2: Level2 };
    const Context = struct { level1: Level1 };
    const result = try RuntimeRenderer.render(
        "{{ .level1.level2.level3.value }}",
        Context,
        .{ .level1 = .{ .level2 = .{ .level3 = .{ .value = "deep" } } } },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("deep", result);
}

test "runtime renderer - float value" {
    const allocator = std.testing.allocator;
    const Context = struct { price: f64 };
    const result = try RuntimeRenderer.render("Price: {{ .price }}", Context, .{ .price = 19.99 }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Price: 19.99", result);
}

test "runtime renderer - negative integer" {
    const allocator = std.testing.allocator;
    const Context = struct { temp: i32 };
    const result = try RuntimeRenderer.render("Temperature: {{ .temp }}", Context, .{ .temp = -15 }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Temperature: -15", result);
}

test "runtime renderer - zero value" {
    const allocator = std.testing.allocator;
    const Context = struct { count: i32 };
    const result = try RuntimeRenderer.render("Count: {{ .count }}", Context, .{ .count = 0 }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Count: 0", result);
}

test "runtime renderer - optional with value" {
    const allocator = std.testing.allocator;
    const Context = struct { maybe: ?[]const u8 };
    const result = try RuntimeRenderer.render("{{ .maybe }}", Context, .{ .maybe = "exists" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("exists", result);
}

test "runtime renderer - optional null renders empty" {
    const allocator = std.testing.allocator;
    const Context = struct { maybe: ?[]const u8 };
    const result = try RuntimeRenderer.render("before{{ .maybe }}after", Context, .{ .maybe = null }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("beforeafter", result);
}

test "runtime renderer - all html special characters escaped" {
    const allocator = std.testing.allocator;
    const Context = struct { text: []const u8 };
    const result = try RuntimeRenderer.render("{{ .text }}", Context, .{ .text = "<>&\"'" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("&lt;&gt;&amp;&quot;&#39;", result);
}

test "runtime renderer - raw variable with all special characters" {
    const allocator = std.testing.allocator;
    const Context = struct { html: []const u8 };
    const result = try RuntimeRenderer.render("{{! .html }}", Context, .{ .html = "<>&\"'" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("<>&\"'", result);
}

test "runtime renderer - if with boolean true" {
    const allocator = std.testing.allocator;
    const Context = struct { flag: bool };
    const result = try RuntimeRenderer.render("{% if .flag %}yes{% endif %}", Context, .{ .flag = true }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("yes", result);
}

test "runtime renderer - if with boolean false" {
    const allocator = std.testing.allocator;
    const Context = struct { flag: bool };
    const result = try RuntimeRenderer.render("{% if .flag %}yes{% endif %}", Context, .{ .flag = false }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "runtime renderer - if with integer non-zero is truthy" {
    const allocator = std.testing.allocator;
    const Context = struct { num: i32 };
    const result = try RuntimeRenderer.render("{% if .num %}yes{% endif %}", Context, .{ .num = 5 }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("yes", result);
}

test "runtime renderer - if with integer zero is falsy" {
    const allocator = std.testing.allocator;
    const Context = struct { num: i32 };
    const result = try RuntimeRenderer.render("{% if .num %}yes{% endif %}", Context, .{ .num = 0 }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "runtime renderer - if with empty string is falsy" {
    const allocator = std.testing.allocator;
    const Context = struct { text: []const u8 };
    const result = try RuntimeRenderer.render("{% if .text %}yes{% endif %}", Context, .{ .text = "" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "runtime renderer - if with non-empty string is truthy" {
    const allocator = std.testing.allocator;
    const Context = struct { text: []const u8 };
    const result = try RuntimeRenderer.render("{% if .text %}yes{% endif %}", Context, .{ .text = "hello" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("yes", result);
}

test "runtime renderer - multiple if blocks" {
    const allocator = std.testing.allocator;
    const Context = struct { a: bool, b: bool };
    const result = try RuntimeRenderer.render(
        "{% if .a %}A{% endif %}{% if .b %}B{% endif %}",
        Context,
        .{ .a = true, .b = true },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("AB", result);
}

test "runtime renderer - if block with variables inside" {
    const allocator = std.testing.allocator;
    const Context = struct { show: bool, name: []const u8 };
    const result = try RuntimeRenderer.render(
        "{% if .show %}Hello {{ .name }}!{% endif %}",
        Context,
        .{ .show = true, .name = "World" },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello {{ .name }}!", result);
}

test "runtime renderer - if block with raw variable inside" {
    const allocator = std.testing.allocator;
    const Context = struct { show: bool, html: []const u8 };
    const result = try RuntimeRenderer.render(
        "{% if .show %}{{! .html }}{% endif %}",
        Context,
        .{ .show = true, .html = "<b>bold</b>" },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("{{! .html }}", result);
}

test "runtime renderer - if block with comment inside" {
    const allocator = std.testing.allocator;
    const Context = struct { show: bool };
    const result = try RuntimeRenderer.render(
        "{% if .show %}before{# comment #}after{% endif %}",
        Context,
        .{ .show = true },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("before{# comment #}after", result);
}

test "runtime renderer - empty if block" {
    const allocator = std.testing.allocator;
    const Context = struct { flag: bool };
    const result = try RuntimeRenderer.render("{% if .flag %}{% endif %}", Context, .{ .flag = true }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "runtime renderer - if block at template start" {
    const allocator = std.testing.allocator;
    const Context = struct { show: bool };
    const result = try RuntimeRenderer.render("{% if .show %}start{% endif %} end", Context, .{ .show = true }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("start end", result);
}

test "runtime renderer - if block at template end" {
    const allocator = std.testing.allocator;
    const Context = struct { show: bool };
    const result = try RuntimeRenderer.render("start {% if .show %}end{% endif %}", Context, .{ .show = true }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("start end", result);
}

test "runtime renderer - unclosed variable tag" {
    const allocator = std.testing.allocator;
    const Context = struct { name: []const u8 };
    const result = try RuntimeRenderer.render("{{ .name ", Context, .{ .name = "test" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "runtime renderer - unclosed comment tag" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const result = try RuntimeRenderer.render("{# unclosed comment", Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "runtime renderer - unclosed if block" {
    const allocator = std.testing.allocator;
    const Context = struct { show: bool };
    const result = try RuntimeRenderer.render("{% if .show %}no endif", Context, .{ .show = true }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("no endif", result);
}

test "runtime renderer - variable with extra whitespace" {
    const allocator = std.testing.allocator;
    const Context = struct { name: []const u8 };
    const result = try RuntimeRenderer.render("{{   .name   }}", Context, .{ .name = "test" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("test", result);
}

test "runtime renderer - if block with extra whitespace" {
    const allocator = std.testing.allocator;
    const Context = struct { flag: bool };
    const result = try RuntimeRenderer.render("{%   if .flag   %}yes{%   endif   %}", Context, .{ .flag = true }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("yes", result);
}

test "runtime renderer - raw variable with extra whitespace" {
    const allocator = std.testing.allocator;
    const Context = struct { html: []const u8 };
    const result = try RuntimeRenderer.render("{{!   .html   }}", Context, .{ .html = "<b>test</b>" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("<b>test</b>", result);
}

test "runtime renderer - unicode in template" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const result = try RuntimeRenderer.render("Hello 世界 🌍", Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello 世界 🌍", result);
}

test "runtime renderer - unicode in variable" {
    const allocator = std.testing.allocator;
    const Context = struct { text: []const u8 };
    const result = try RuntimeRenderer.render("{{ .text }}", Context, .{ .text = "こんにちは 🎌" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("こんにちは 🎌", result);
}

test "runtime renderer - very long plain text" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const long_text = "x" ** 10000;
    const result = try RuntimeRenderer.render(long_text, Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(long_text, result);
}

test "runtime renderer - very long variable value" {
    const allocator = std.testing.allocator;
    const Context = struct { data: []const u8 };
    const long_value = "y" ** 10000;
    const result = try RuntimeRenderer.render("{{ .data }}", Context, .{ .data = long_value }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(long_value, result);
}

test "runtime renderer - complex mixed template" {
    const allocator = std.testing.allocator;
    const User = struct { name: []const u8, age: i32 };
    const Context = struct { user: User, active: bool, title: []const u8 };
    const template =
        \\<h1>{{ .title }}</h1>
        \\{# User info section #}
        \\{% if .active %}
        \\  <p>Name: {{ .user.name }}</p>
        \\  <p>Age: {{ .user.age }}</p>
        \\{% endif %}
    ;
    const result = try RuntimeRenderer.render(
        template,
        Context,
        .{ .user = .{ .name = "Alice", .age = 30 }, .active = true, .title = "User Profile" },
        allocator,
    );
    defer allocator.free(result);
    // Check that basic structure is preserved and comments are removed
    try std.testing.expect(std.mem.indexOf(u8, result, "<h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "User Profile") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "User info section") == null);
}

test "runtime renderer - consecutive comments" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const result = try RuntimeRenderer.render("{# one #}{# two #}{# three #}", Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "runtime renderer - comment with newlines" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const result = try RuntimeRenderer.render(
        \\before
        \\{# multi
        \\line
        \\comment #}
        \\after
    , Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "after") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "multi") == null);
}

test "runtime renderer - variable with newlines in template" {
    const allocator = std.testing.allocator;
    const Context = struct { name: []const u8 };
    const result = try RuntimeRenderer.render(
        \\Line 1
        \\{{ .name }}
        \\Line 3
    , Context, .{ .name = "middle" }, allocator);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Line 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "middle") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Line 3") != null);
}

test "runtime renderer - escaped html in nested variable" {
    const allocator = std.testing.allocator;
    const Inner = struct { content: []const u8 };
    const Context = struct { data: Inner };
    const result = try RuntimeRenderer.render(
        "{{ .data.content }}",
        Context,
        .{ .data = .{ .content = "<script>alert('xss')</script>" } },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;", result);
}

test "runtime renderer - raw variable in nested structure" {
    const allocator = std.testing.allocator;
    const Inner = struct { html: []const u8 };
    const Context = struct { data: Inner };
    const result = try RuntimeRenderer.render(
        "{{! .data.html }}",
        Context,
        .{ .data = .{ .html = "<p>safe</p>" } },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("<p>safe</p>", result);
}

test "runtime renderer - multiple nested structures" {
    const allocator = std.testing.allocator;
    const Address = struct { city: []const u8, country: []const u8 };
    const User = struct { name: []const u8, address: Address };
    const Context = struct { user: User };
    const result = try RuntimeRenderer.render(
        "{{ .user.name }} lives in {{ .user.address.city }}, {{ .user.address.country }}",
        Context,
        .{ .user = .{ .name = "Bob", .address = .{ .city = "Paris", .country = "France" } } },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Bob lives in Paris, France", result);
}

test "runtime renderer - invalid nested path renders base value" {
    const allocator = std.testing.allocator;
    const Context = struct { name: []const u8 };
    const result = try RuntimeRenderer.render("before{{ .name.invalid }}after", Context, .{ .name = "test" }, allocator);
    defer allocator.free(result);
    // Runtime renderer returns the base value when path is invalid on a string
    try std.testing.expectEqualStrings("beforetestafter", result);
}

test "runtime renderer - if with missing variable is falsy" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const result = try RuntimeRenderer.render("{% if .missing %}yes{% endif %}no", Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("no", result);
}

test "runtime renderer - multiple variables with mixed types" {
    const allocator = std.testing.allocator;
    const Context = struct { str: []const u8, num: i32, flag: bool, flt: f64 };
    const result = try RuntimeRenderer.render(
        "{{ .str }} {{ .num }} {{ .flag }} {{ .flt }}",
        Context,
        .{ .str = "hello", .num = 42, .flag = true, .flt = 3.14 },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello 42 true 3.14", result);
}

test "runtime renderer - if block surrounding only variable" {
    const allocator = std.testing.allocator;
    const Context = struct { show: bool, value: []const u8 };
    const result = try RuntimeRenderer.render(
        "{% if .show %}{{ .value }}{% endif %}",
        Context,
        .{ .show = true, .value = "visible" },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("{{ .value }}", result);
}

test "runtime renderer - text before and after if block" {
    const allocator = std.testing.allocator;
    const Context = struct { show: bool };
    const result = try RuntimeRenderer.render(
        "before {% if .show %}middle{% endif %} after",
        Context,
        .{ .show = true },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("before middle after", result);
}

test "runtime renderer - if false removes content cleanly" {
    const allocator = std.testing.allocator;
    const Context = struct { show: bool };
    const result = try RuntimeRenderer.render(
        "start{% if .show %} hidden content {% endif %}end",
        Context,
        .{ .show = false },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("startend", result);
}

test "runtime renderer - large integer value" {
    const allocator = std.testing.allocator;
    const Context = struct { big: i64 };
    const result = try RuntimeRenderer.render("{{ .big }}", Context, .{ .big = 9223372036854775807 }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("9223372036854775807", result);
}

test "runtime renderer - negative float" {
    const allocator = std.testing.allocator;
    const Context = struct { val: f64 };
    const result = try RuntimeRenderer.render("{{ .val }}", Context, .{ .val = -273.15 }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("-273.15", result);
}

test "runtime renderer - false boolean renders as false string" {
    const allocator = std.testing.allocator;
    const Context = struct { flag: bool };
    const result = try RuntimeRenderer.render("{{ .flag }}", Context, .{ .flag = false }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("false", result);
}

test "runtime renderer - string literal false in if is falsy" {
    const allocator = std.testing.allocator;
    const Context = struct { str: []const u8 };
    const result = try RuntimeRenderer.render("{% if .str %}yes{% endif %}", Context, .{ .str = "false" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "runtime renderer - comment between variables" {
    const allocator = std.testing.allocator;
    const Context = struct { a: []const u8, b: []const u8 };
    const result = try RuntimeRenderer.render(
        "{{ .a }}{# middle comment #}{{ .b }}",
        Context,
        .{ .a = "first", .b = "second" },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("firstsecond", result);
}

test "runtime renderer - nested if would need special handling" {
    const allocator = std.testing.allocator;
    const Context = struct { outer: bool };
    const result = try RuntimeRenderer.render(
        "{% if .outer %}outer{% endif %}",
        Context,
        .{ .outer = true },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("outer", result);
}

test "runtime renderer - only variable tag no text" {
    const allocator = std.testing.allocator;
    const Context = struct { val: []const u8 };
    const result = try RuntimeRenderer.render("{{ .val }}", Context, .{ .val = "only" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("only", result);
}

test "runtime renderer - only if block no text" {
    const allocator = std.testing.allocator;
    const Context = struct { flag: bool };
    const result = try RuntimeRenderer.render("{% if .flag %}content{% endif %}", Context, .{ .flag = true }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("content", result);
}

test "runtime renderer - whitespace preservation around tags" {
    const allocator = std.testing.allocator;
    const Context = struct { x: []const u8 };
    const result = try RuntimeRenderer.render("  {{ .x }}  ", Context, .{ .x = "val" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("  val  ", result);
}

test "runtime renderer - tabs and spaces in plain text" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const result = try RuntimeRenderer.render("\t  text  \t", Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\t  text  \t", result);
}

test "runtime renderer - newline characters preserved" {
    const allocator = std.testing.allocator;
    const Context = struct { name: []const u8 };
    const result = try RuntimeRenderer.render("line1\n{{ .name }}\nline3", Context, .{ .name = "line2" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("line1\nline2\nline3", result);
}

test "runtime renderer - carriage return and newline" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const result = try RuntimeRenderer.render("win\r\nline", Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("win\r\nline", result);
}

test "runtime renderer - ampersand escaping" {
    const allocator = std.testing.allocator;
    const Context = struct { text: []const u8 };
    const result = try RuntimeRenderer.render("{{ .text }}", Context, .{ .text = "A & B" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("A &amp; B", result);
}

test "runtime renderer - quote escaping" {
    const allocator = std.testing.allocator;
    const Context = struct { text: []const u8 };
    const result = try RuntimeRenderer.render("{{ .text }}", Context, .{ .text = "He said \"hello\"" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("He said &quot;hello&quot;", result);
}

test "runtime renderer - apostrophe escaping" {
    const allocator = std.testing.allocator;
    const Context = struct { text: []const u8 };
    const result = try RuntimeRenderer.render("{{ .text }}", Context, .{ .text = "It's working" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("It&#39;s working", result);
}

test "runtime renderer - mixed escaping and raw in same template" {
    const allocator = std.testing.allocator;
    const Context = struct { escaped: []const u8, raw: []const u8 };
    const result = try RuntimeRenderer.render(
        "{{ .escaped }} vs {{! .raw }}",
        Context,
        .{ .escaped = "<tag>", .raw = "<tag>" },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("&lt;tag&gt; vs <tag>", result);
}

test "runtime renderer - optional integer with value" {
    const allocator = std.testing.allocator;
    const Context = struct { num: ?i32 };
    const result = try RuntimeRenderer.render("{{ .num }}", Context, .{ .num = 123 }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("123", result);
}

test "runtime renderer - optional integer null" {
    const allocator = std.testing.allocator;
    const Context = struct { num: ?i32 };
    const result = try RuntimeRenderer.render("value:{{ .num }}:end", Context, .{ .num = null }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("value::end", result);
}

test "runtime renderer - empty string field" {
    const allocator = std.testing.allocator;
    const Context = struct { text: []const u8 };
    const result = try RuntimeRenderer.render("start{{ .text }}end", Context, .{ .text = "" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("startend", result);
}

test "runtime renderer - numeric string in variable" {
    const allocator = std.testing.allocator;
    const Context = struct { str: []const u8 };
    const result = try RuntimeRenderer.render("{{ .str }}", Context, .{ .str = "12345" }, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("12345", result);
}

test "runtime renderer - special characters in plain text" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const result = try RuntimeRenderer.render("!@#$%^&*()_+-=[]{}|;:',.<>?/", Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("!@#$%^&*()_+-=[]{}|;:',.<>?/", result);
}

test "runtime renderer - backslash in plain text" {
    const allocator = std.testing.allocator;
    const Context = struct {};
    const result = try RuntimeRenderer.render("path\\to\\file", Context, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("path\\to\\file", result);
}

test "runtime renderer - url in variable" {
    const allocator = std.testing.allocator;
    const Context = struct { url: []const u8 };
    const result = try RuntimeRenderer.render(
        "{{ .url }}",
        Context,
        .{ .url = "https://example.com/path?query=value&other=123" },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com/path?query=value&amp;other=123", result);
}

test "runtime renderer - raw url in variable" {
    const allocator = std.testing.allocator;
    const Context = struct { url: []const u8 };
    const result = try RuntimeRenderer.render(
        "{{! .url }}",
        Context,
        .{ .url = "https://example.com/path?query=value&other=123" },
        allocator,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("https://example.com/path?query=value&other=123", result);
}
