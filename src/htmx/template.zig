const std = @import("std");
const Response = @import("../http/response.zig").Response;

/// Template rendering configuration
pub const TemplateConfig = struct {
    /// Base directory for templates
    template_dir: []const u8 = "templates",

    /// File extension for templates
    extension: []const u8 = ".zt.html",

    /// Enable template caching
    cache_enabled: bool = true,

    /// Cache TTL in milliseconds
    cache_ttl_ms: i64 = 60000,
};

/// Template context for rendering
pub const TemplateContext = struct {
    allocator: std.mem.Allocator,
    data: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) TemplateContext {
        return .{
            .allocator = allocator,
            .data = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *TemplateContext) void {
        self.data.deinit();
    }

    /// Set a template variable
    pub fn set(self: *TemplateContext, key: []const u8, value: []const u8) !void {
        try self.data.put(key, value);
    }

    /// Get a template variable
    pub fn get(self: *const TemplateContext, key: []const u8) ?[]const u8 {
        return self.data.get(key);
    }
};

/// Template renderer for HTMX fragments
pub const TemplateRenderer = struct {
    allocator: std.mem.Allocator,
    config: TemplateConfig,

    pub fn init(allocator: std.mem.Allocator, config: TemplateConfig) TemplateRenderer {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Render a template to a response
    pub fn render(self: *TemplateRenderer, template_name: []const u8, context: TemplateContext) !Response {
        const html = try self.renderToString(template_name, context);
        return Response.fragment(html);
    }

    /// Render a template to a string
    pub fn renderToString(self: *TemplateRenderer, template_name: []const u8, context: TemplateContext) ![]const u8 {
        // Build template path
        const path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}{s}",
            .{ self.config.template_dir, template_name, self.config.extension },
        );
        defer self.allocator.free(path);

        // Read template file
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB max
        defer self.allocator.free(content);

        // Simple variable substitution
        return try self.substituteVariables(content, context);
    }

    /// Render a partial template (fragment)
    pub fn renderPartial(self: *TemplateRenderer, template_name: []const u8, context: TemplateContext) !Response {
        return self.render(template_name, context);
    }

    /// Simple variable substitution
    fn substituteVariables(self: *TemplateRenderer, template: []const u8, context: TemplateContext) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < template.len) {
            // Look for {{ variable }}
            if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '{') {
                // Find closing }}
                var end: usize = i + 2;
                while (end + 1 < template.len) {
                    if (template[end] == '}' and template[end + 1] == '}') {
                        // Extract variable name
                        const var_name = std.mem.trim(u8, template[i + 2 .. end], " \t\n");

                        // Substitute with value from context
                        if (context.get(var_name)) |value| {
                            try result.appendSlice(self.allocator, value);
                        } else {
                            // Keep original if variable not found
                            try result.appendSlice(self.allocator, template[i .. end + 2]);
                        }

                        i = end + 2;
                        break;
                    }
                    end += 1;
                } else {
                    // No closing found, just append the character
                    try result.append(self.allocator, template[i]);
                    i += 1;
                }
            } else {
                try result.append(self.allocator, template[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(self.allocator);
    }
};

/// Create a template renderer with default config
pub fn createRenderer(allocator: std.mem.Allocator) TemplateRenderer {
    return TemplateRenderer.init(allocator, .{});
}

/// Create a template renderer with custom config
pub fn createRendererWithConfig(allocator: std.mem.Allocator, config: TemplateConfig) TemplateRenderer {
    return TemplateRenderer.init(allocator, config);
}

/// Quick render helper
pub fn renderTemplate(allocator: std.mem.Allocator, template_name: []const u8, context: TemplateContext) !Response {
    var renderer = createRenderer(allocator);
    return renderer.render(template_name, context);
}

// Tests
test "template context set and get" {
    const allocator = std.heap.page_allocator;
    var ctx = TemplateContext.init(allocator);
    defer ctx.deinit();

    try ctx.set("name", "World");
    const value = ctx.get("name");

    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("World", value.?);
}

test "template variable substitution" {
    const allocator = std.heap.page_allocator;
    var renderer = createRenderer(allocator);

    var ctx = TemplateContext.init(allocator);
    defer ctx.deinit();
    try ctx.set("title", "Test Page");
    try ctx.set("content", "Hello World");

    const template = "<h1>{{ title }}</h1><p>{{ content }}</p>";
    const result = try renderer.substituteVariables(template, ctx);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Test Page") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Hello World") != null);
}

test "template substitution with missing variable" {
    const allocator = std.heap.page_allocator;
    var renderer = createRenderer(allocator);

    var ctx = TemplateContext.init(allocator);
    defer ctx.deinit();
    try ctx.set("title", "Test");

    const template = "<h1>{{ title }}</h1><p>{{ missing }}</p>";
    const result = try renderer.substituteVariables(template, ctx);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Test") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "{{ missing }}") != null);
}
