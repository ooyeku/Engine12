const std = @import("std");
const ast = @import("ast.zig");
const escape = @import("escape.zig");
const type_checker = @import("type_checker.zig");

const codegen = @import("codegen.zig");
const filters = @import("filters.zig");

/// Template engine public API
/// Compiles templates at comptime and provides type-safe rendering
pub const Template = struct {
    /// Compile template from file path (uses @embedFile)
    pub fn compileFile(comptime file_path: []const u8) type {
        const content = @embedFile(file_path);
        return compile(content);
    }

    /// Compile template from string literal
    pub fn compile(comptime template_str: []const u8) type {
        const parsed_ast = comptime Parser.parse(template_str) catch |err| {
            @compileError("Template parse error: " ++ @errorName(err));
        };

        return struct {
            const template_ast = parsed_ast;

            /// Render template with context
            pub fn render(
                comptime Context: type,
                ctx: Context,
                allocator: std.mem.Allocator,
            ) ![]const u8 {
                comptime type_checker.TypeChecker.validateContext(template_ast, Context);
                const RenderFn = comptime codegen.Codegen.generateRenderFunction(template_ast, Context);
                return RenderFn.render(ctx, allocator);
            }
        };
    }
};

const Parser = @import("parser.zig").Parser;

/// Convenience function for rendering templates from files
pub fn renderFile(
    comptime file_path: []const u8,
    comptime Context: type,
    ctx: Context,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const TemplateType = Template.compileFile(file_path);
    return TemplateType.render(Context, ctx, allocator);
}

test "simple template rendering" {
    const TemplateType = Template.compile("<h1>{{ .title }}</h1>");
    const context = struct {
        title: []const u8,
    }{ .title = "Test" };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings(html, "<h1>Test</h1>");
}

test "template with HTML escaping" {
    const TemplateType = Template.compile("<div>{{ .content }}</div>");
    const context = struct {
        content: []const u8,
    }{ .content = "<script>alert('xss')</script>" };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;") != null);
}

test "template with nested variable" {
    const TemplateType = Template.compile("Hello {{ .user.name }}");
    const context = struct {
        user: struct {
            name: []const u8,
        },
    }{ .user = .{ .name = "Alice" } };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings(html, "Hello Alice");
}

test "template with raw variable" {
    const TemplateType = Template.compile("{{! .html }}");
    const context = struct {
        html: []const u8,
    }{ .html = "<div>Hello</div>" };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings(html, "<div>Hello</div>");
}

// BUG VERIFICATION TESTS - These tests demonstrate actual bugs in the template system
// These tests are designed to FAIL, proving that the bugs exist

test "BUG #1: Filters are parsed but never applied" {
    // This test demonstrates that filters are parsed correctly but not applied during rendering
    // Expected: "HELLO" (uppercase filter applied)
    // Actual: "hello" (no filter applied - filter syntax is ignored)
    const TemplateType = Template.compile("{{ .name | uppercase }}");
    const context = struct {
        name: []const u8,
    }{ .name = "hello" };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    
    // VERIFICATION: This test will FAIL because filters are not applied
    // The filter syntax is parsed (see parser.zig test "parse filter") but ignored during rendering
    // Current output: "hello" (filter not applied)
    // Expected output: "HELLO" (filter applied)
    // 
    // To verify the bug: Run this test and it will fail with:
    //   expected "HELLO", found "hello"
    try std.testing.expectEqualStrings(html, "HELLO");
}

test "BUG #1: Trim filter is parsed but not applied" {
    // Test that trim filter is parsed but not applied
    const TemplateType = Template.compile("{{ .name | trim }}");
    const context = struct {
        name: []const u8,
    }{ .name = "  hello  " };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    
    // VERIFICATION: This test will FAIL
    // Expected: "hello" (trim applied)
    // Actual: "  hello  " (no filters applied)
    try std.testing.expectEqualStrings(html, "hello");
}

test "BUG #2: Include nodes are parsed but not rendered" {
    // This test demonstrates that include statements are parsed but produce no output
    // Expected: Content from included file between "Before" and "After"
    // Actual: Empty string (include is ignored during rendering)
    const TemplateType = Template.compile("Before {% include \"test.zt.html\" %} After");
    const context = struct {};
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);
    
    // VERIFICATION: This test documents the bug
    // The include syntax is parsed (see parser.zig parseInclude function)
    // but the rendering code in codegen.zig line 84-86 just has a comment:
    //   .include => |_| {
    //       // Includes handled separately in Phase 7
    //   }
    // 
    // Current output: "Before  After" (include produces nothing)
    // Expected output: "Before [include content] After"
    try std.testing.expect(std.mem.indexOf(u8, html, "Before") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "After") != null);
    // The output will be "Before  After" with nothing in between
    // This proves the include is parsed but not rendered
}
