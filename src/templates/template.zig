const std = @import("std");
const ast = @import("ast.zig");
const escape = @import("escape.zig");
const type_checker = @import("type_checker.zig");

const codegen = @import("codegen.zig");
const filters = @import("filters.zig");

pub const Template = struct {
    pub fn compileFile(comptime file_path: []const u8) type {
        const content = @embedFile(file_path);
        return compile(content);
    }

    pub fn compile(comptime template_str: []const u8) type {
        const parsed_ast = comptime Parser.parseComptime(template_str);

        return struct {
            const template_ast = parsed_ast;

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

test "Filters: uppercase applied" {
    const TemplateType = Template.compile("{{ .name | uppercase }}");
    const context = struct {
        name: []const u8,
    }{ .name = "hello" };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);

    try std.testing.expectEqualStrings(html, "HELLO");
}

test "Filters: trim applied" {
    const TemplateType = Template.compile("{{ .name | trim }}");
    const context = struct {
        name: []const u8,
    }{ .name = "  hello  " };
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);

    try std.testing.expectEqualStrings(html, "hello");
}

test "Include nodes are parsed and rendered" {
    const TemplateType = Template.compile("Before {% include \"test.zt.html\" %} After");
    const context = struct {};
    const html = try TemplateType.render(@TypeOf(context), context, std.testing.allocator);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "Before") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Included Content") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "After") != null);
}
