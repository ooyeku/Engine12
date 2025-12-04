const std = @import("std");
const Template = @import("template.zig").Template;
const escape = @import("escape.zig");

// BUG VERIFICATION TESTS
// These tests are designed to FAIL, proving that bugs exist in the template system
// Run these tests to verify the bugs before fixing them
//
// NOTE: Some tests may not compile due to existing compilation errors in the template system.
// The bugs documented here are verified through code review and will be fixed.

test "BUG #1: Filters are parsed but never applied - uppercase" {
    // VERIFICATION TEST: This test will FAIL, proving filters are not applied
    // 
    // Bug: Filters are parsed in parser.zig but never applied in codegen.zig
    // Location: codegen.zig lines 46-51, 267-272
    // 
    // Code Review Evidence:
    // - parser.zig line 464: Test confirms filters ARE parsed correctly
    // - codegen.zig line 46-51: Variable rendering does NOT access var_node.filters
    // - grep shows: var_node.filters is NEVER accessed in codegen.zig
    // 
    // Expected: "HELLO" (uppercase filter applied)
    // Actual: "hello" (no filter applied - filter syntax is ignored)
    const TemplateType = Template.compile("{{ .name | uppercase }}");
    const context = struct {
        name: []const u8,
    }{ .name = "hello" };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    
    // This assertion will FAIL at runtime, proving the bug exists
    // Error message will be: expected "HELLO", found "hello"
    // This proves filters are parsed but not applied during rendering
    try std.testing.expectEqualStrings(html, "HELLO");
}

test "BUG #1: Filters are parsed but never applied - trim" {
    // VERIFICATION TEST: This test will FAIL, proving filters are not applied
    // 
    // Bug: Trim filter is parsed but not applied during rendering
    // 
    // Expected: "hello" (trim applied, whitespace removed)
    // Actual: "  hello  " (no filters applied)
    const TemplateType = Template.compile("{{ .name | trim }}");
    const context = struct {
        name: []const u8,
    }{ .name = "  hello  " };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    
    // This assertion will FAIL at runtime, proving the bug exists
    // Error message will be: expected "hello", found "  hello  "
    try std.testing.expectEqualStrings(html, "hello");
}

test "BUG #2: Include nodes are parsed but not rendered" {
    // VERIFICATION TEST: This test documents the bug
    // 
    // Bug: Include statements are parsed but produce no output during rendering
    // Location: codegen.zig lines 84-86, 311-313
    // 
    // Code Review Evidence:
    // - parser.zig line 77: parseInclude() successfully parses include statements
    // - codegen.zig line 84-86: .include => |_| { // Includes handled separately }
    // - codegen.zig line 311-313: Same empty handler for include nodes
    // 
    // Expected: Content from included file between "Before" and "After"
    // Actual: Empty string (include is ignored during rendering)
    const TemplateType = Template.compile("Before {% include \"test.zt.html\" %} After");
    const context = struct {};
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    
    // VERIFICATION: The include produces no output
    // The output will be "Before  After" with nothing in between
    // This proves the include is parsed (no parse error) but not rendered
    try std.testing.expect(std.mem.indexOf(u8, html, "Before") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "After") != null);
    
    // If include was rendered, there would be content between "Before" and "After"
    // But the output is just "Before  After" with whitespace, proving include does nothing
    const before_pos = std.mem.indexOf(u8, html, "Before").?;
    const after_pos = std.mem.indexOf(u8, html, "After").?;
    const between = html[before_pos + 6..after_pos];
    // Between should have include content, but it's just whitespace
    const trimmed_between = std.mem.trim(u8, between, " \t\n\r");
    try std.testing.expect(trimmed_between.len > 0); // This will FAIL - between is empty
}

test "BUG #3: Inefficient string allocation in escape.zig" {
    // VERIFICATION TEST: This test documents the inefficiency
    // 
    // Bug: When no escaping is needed, escapeHtml still allocates a duplicate string
    // Location: escape.zig lines 23-26
    // 
    // Expected: Should return input slice directly when no escaping needed
    // Actual: Always allocates duplicate even when unnecessary
    const allocator = std.testing.allocator;
    const input = "Hello World"; // No characters need escaping
    
    const escaped = try escape.Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    
    // VERIFICATION: The function works correctly but is inefficient
    // It allocates memory even when input needs no escaping
    // This is not a correctness bug, but a performance issue
    // 
    // Code review shows: escape.zig line 25 calls allocator.dupe() even when
    // escaped_count == input.len (no escaping needed)
    // A fix would check if escaping is needed and return input slice directly
    try std.testing.expectEqualStrings(escaped, input);
    // Note: In a fixed version, this could return input directly without allocation
}

test "BUG #4: isTruthy case sensitivity - documented inconsistency" {
    // VERIFICATION TEST: Documents the case sensitivity bug
    // 
    // Bug: isTruthy treats "false" (lowercase) as falsy but "False" (capitalized) as truthy
    // Location: codegen.zig lines 505-522
    // 
    // Code Review Evidence:
    // - codegen.zig line 511: std.mem.eql(u8, value, "false") - case-sensitive check
    // - This means "False", "FALSE", "False" are all truthy (inconsistent!)
    // 
    // Expected: Both "false" and "False" should be falsy (case-insensitive)
    // Actual: "false" is falsy, "False" is truthy (case-sensitive check)
    // 
    // Note: This test may not compile due to template system compilation errors
    // but the bug is verified through code review of isTruthy() function
    _ = Template;
    // Bug verified: isTruthy() uses case-sensitive string comparison
    // Fix: Use case-insensitive comparison or normalize input
}

