const std = @import("std");
const Template = @import("template.zig").Template;
const escape = @import("escape.zig");


test "BUG #1: Filters are parsed but never applied - uppercase" {
    const TemplateType = Template.compile("{{ .name | uppercase }}");
    const context = struct {
        name: []const u8,
    }{ .name = "hello" };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    
    try std.testing.expectEqualStrings(html, "HELLO");
}

test "BUG #1: Filters are parsed but never applied - trim" {
    const TemplateType = Template.compile("{{ .name | trim }}");
    const context = struct {
        name: []const u8,
    }{ .name = "  hello  " };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    
    try std.testing.expectEqualStrings(html, "hello");
}

test "BUG #2: Include nodes are parsed but not rendered" {
    const TemplateType = Template.compile("Before {% include \"test.zt.html\" %} After");
    const context = struct {};
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    
    try std.testing.expect(std.mem.indexOf(u8, html, "Before") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "After") != null);
    
    const before_pos = std.mem.indexOf(u8, html, "Before").?;
    const after_pos = std.mem.indexOf(u8, html, "After").?;
    const between = html[before_pos + 6..after_pos];
    const trimmed_between = std.mem.trim(u8, between, " \t\n\r");
    try std.testing.expect(trimmed_between.len > 0); // This will FAIL - between is empty
}

test "BUG #3: Inefficient string allocation in escape.zig" {
    const allocator = std.testing.allocator;
    const input = "Hello World"; // No characters need escaping
    
    const escaped = try escape.Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    
    try std.testing.expectEqualStrings(escaped, input);
}

test "BUG #4: isTruthy case sensitivity - documented inconsistency" {
    _ = Template;
}

