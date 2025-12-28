const std = @import("std");

/// Form builder for type-safe form generation
pub const FormBuilder = struct {
    allocator: std.mem.Allocator,
    html: std.ArrayListUnmanaged(u8),
    action: ?[]const u8 = null,
    method: []const u8 = "post",

    pub fn init(allocator: std.mem.Allocator) FormBuilder {
        return .{
            .allocator = allocator,
            .html = .{},
        };
    }

    pub fn deinit(self: *FormBuilder) void {
        self.html.deinit(self.allocator);
    }

    /// Start the form
    pub fn start(self: *FormBuilder, action: []const u8) !*FormBuilder {
        self.action = action;
        try self.html.appendSlice(self.allocator, "<form hx-post=\"");
        try self.html.appendSlice(self.allocator, action);
        try self.html.appendSlice(self.allocator, "\" hx-target=\"this\" hx-swap=\"outerHTML\">");
        return self;
    }

    /// Start form with custom method
    pub fn startWithMethod(self: *FormBuilder, action: []const u8, method: []const u8) !*FormBuilder {
        self.action = action;
        self.method = method;

        try self.html.appendSlice(self.allocator, "<form hx-");
        try self.html.appendSlice(self.allocator, method);
        try self.html.appendSlice(self.allocator, "=\"");
        try self.html.appendSlice(self.allocator, action);
        try self.html.appendSlice(self.allocator, "\" hx-target=\"this\" hx-swap=\"outerHTML\">");
        return self;
    }

    pub const TextOptions = struct {
        required: bool = false,
        min_length: ?usize = null,
        max_length: ?usize = null,
        pattern: ?[]const u8 = null,
        placeholder: ?[]const u8 = null,
        value: ?[]const u8 = null,
        class: ?[]const u8 = null,
    };

    /// Add a text input field
    pub fn text(self: *FormBuilder, name: []const u8, label: []const u8, opts: TextOptions) !*FormBuilder {
        try self.html.appendSlice(self.allocator, "<div class=\"form-group\">");
        try self.html.appendSlice(self.allocator, "<label for=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\">");
        try self.html.appendSlice(self.allocator, label);
        if (opts.required) {
            try self.html.appendSlice(self.allocator, " <span class=\"required\">*</span>");
        }
        try self.html.appendSlice(self.allocator, "</label>");

        try self.html.appendSlice(self.allocator, "<input type=\"text\" id=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\" name=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\"");

        if (opts.class) |class| {
            try self.html.appendSlice(self.allocator, " class=\"");
            try self.html.appendSlice(self.allocator, class);
            try self.html.appendSlice(self.allocator, "\"");
        }

        if (opts.placeholder) |placeholder| {
            try self.html.appendSlice(self.allocator, " placeholder=\"");
            try self.html.appendSlice(self.allocator, placeholder);
            try self.html.appendSlice(self.allocator, "\"");
        }

        if (opts.value) |value| {
            try self.html.appendSlice(self.allocator, " value=\"");
            try self.html.appendSlice(self.allocator, value);
            try self.html.appendSlice(self.allocator, "\"");
        }

        if (opts.required) {
            try self.html.appendSlice(self.allocator, " required");
        }

        if (opts.min_length) |min| {
            const min_str = try std.fmt.allocPrint(self.allocator, " minlength=\"{d}\"", .{min});
            defer self.allocator.free(min_str);
            try self.html.appendSlice(self.allocator, min_str);
        }

        if (opts.max_length) |max| {
            const max_str = try std.fmt.allocPrint(self.allocator, " maxlength=\"{d}\"", .{max});
            defer self.allocator.free(max_str);
            try self.html.appendSlice(self.allocator, max_str);
        }

        if (opts.pattern) |pattern| {
            try self.html.appendSlice(self.allocator, " pattern=\"");
            try self.html.appendSlice(self.allocator, pattern);
            try self.html.appendSlice(self.allocator, "\"");
        }

        try self.html.appendSlice(self.allocator, ">");
        try self.html.appendSlice(self.allocator, "</div>");

        return self;
    }

    /// Add an email input field
    pub fn email(self: *FormBuilder, name: []const u8, label: []const u8, required: bool) !*FormBuilder {
        try self.html.appendSlice(self.allocator, "<div class=\"form-group\">");
        try self.html.appendSlice(self.allocator, "<label for=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\">");
        try self.html.appendSlice(self.allocator, label);
        if (required) {
            try self.html.appendSlice(self.allocator, " <span class=\"required\">*</span>");
        }
        try self.html.appendSlice(self.allocator, "</label>");
        try self.html.appendSlice(self.allocator, "<input type=\"email\" id=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\" name=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\"");
        if (required) {
            try self.html.appendSlice(self.allocator, " required");
        }
        try self.html.appendSlice(self.allocator, ">");
        try self.html.appendSlice(self.allocator, "</div>");

        return self;
    }

    /// Add a password input field
    pub fn password(self: *FormBuilder, name: []const u8, label: []const u8, required: bool) !*FormBuilder {
        try self.html.appendSlice(self.allocator, "<div class=\"form-group\">");
        try self.html.appendSlice(self.allocator, "<label for=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\">");
        try self.html.appendSlice(self.allocator, label);
        if (required) {
            try self.html.appendSlice(self.allocator, " <span class=\"required\">*</span>");
        }
        try self.html.appendSlice(self.allocator, "</label>");
        try self.html.appendSlice(self.allocator, "<input type=\"password\" id=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\" name=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\"");
        if (required) {
            try self.html.appendSlice(self.allocator, " required");
        }
        try self.html.appendSlice(self.allocator, ">");
        try self.html.appendSlice(self.allocator, "</div>");

        return self;
    }

    pub const SelectOption = struct {
        value: []const u8,
        label: []const u8,
        selected: bool = false,
    };

    /// Add a select dropdown
    pub fn select(self: *FormBuilder, name: []const u8, label: []const u8, options: []const SelectOption) !*FormBuilder {
        try self.html.appendSlice(self.allocator, "<div class=\"form-group\">");
        try self.html.appendSlice(self.allocator, "<label for=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\">");
        try self.html.appendSlice(self.allocator, label);
        try self.html.appendSlice(self.allocator, "</label>");
        try self.html.appendSlice(self.allocator, "<select id=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\" name=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\">");

        for (options) |option| {
            try self.html.appendSlice(self.allocator, "<option value=\"");
            try self.html.appendSlice(self.allocator, option.value);
            try self.html.appendSlice(self.allocator, "\"");
            if (option.selected) {
                try self.html.appendSlice(self.allocator, " selected");
            }
            try self.html.appendSlice(self.allocator, ">");
            try self.html.appendSlice(self.allocator, option.label);
            try self.html.appendSlice(self.allocator, "</option>");
        }

        try self.html.appendSlice(self.allocator, "</select>");
        try self.html.appendSlice(self.allocator, "</div>");

        return self;
    }

    /// Add a textarea
    pub fn textarea(self: *FormBuilder, name: []const u8, label: []const u8, rows: usize) !*FormBuilder {
        try self.html.appendSlice(self.allocator, "<div class=\"form-group\">");
        try self.html.appendSlice(self.allocator, "<label for=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\">");
        try self.html.appendSlice(self.allocator, label);
        try self.html.appendSlice(self.allocator, "</label>");
        try self.html.appendSlice(self.allocator, "<textarea id=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\" name=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\" rows=\"");

        const rows_str = try std.fmt.allocPrint(self.allocator, "{d}", .{rows});
        defer self.allocator.free(rows_str);
        try self.html.appendSlice(self.allocator, rows_str);

        try self.html.appendSlice(self.allocator, "\"></textarea>");
        try self.html.appendSlice(self.allocator, "</div>");

        return self;
    }

    /// Add a checkbox
    pub fn checkbox(self: *FormBuilder, name: []const u8, label: []const u8, checked: bool) !*FormBuilder {
        try self.html.appendSlice(self.allocator, "<div class=\"form-group form-checkbox\">");
        try self.html.appendSlice(self.allocator, "<input type=\"checkbox\" id=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\" name=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\"");
        if (checked) {
            try self.html.appendSlice(self.allocator, " checked");
        }
        try self.html.appendSlice(self.allocator, ">");
        try self.html.appendSlice(self.allocator, "<label for=\"");
        try self.html.appendSlice(self.allocator, name);
        try self.html.appendSlice(self.allocator, "\">");
        try self.html.appendSlice(self.allocator, label);
        try self.html.appendSlice(self.allocator, "</label>");
        try self.html.appendSlice(self.allocator, "</div>");

        return self;
    }

    /// Add a submit button
    pub fn submit(self: *FormBuilder, button_text: []const u8) !*FormBuilder {
        try self.html.appendSlice(self.allocator, "<button type=\"submit\" class=\"btn btn-primary\">");
        try self.html.appendSlice(self.allocator, button_text);
        try self.html.appendSlice(self.allocator, "</button>");

        return self;
    }

    /// Add a cancel button
    pub fn cancel(self: *FormBuilder, button_text: []const u8, url: []const u8) !*FormBuilder {
        try self.html.appendSlice(self.allocator, "<button type=\"button\" class=\"btn btn-secondary\" hx-get=\"");
        try self.html.appendSlice(self.allocator, url);
        try self.html.appendSlice(self.allocator, "\">");
        try self.html.appendSlice(self.allocator, button_text);
        try self.html.appendSlice(self.allocator, "</button>");

        return self;
    }

    /// Build the final HTML
    pub fn build(self: *FormBuilder) ![]const u8 {
        try self.html.appendSlice(self.allocator, "</form>");
        return self.html.toOwnedSlice(self.allocator);
    }
};

/// Convenience function to create a simple text field
pub fn textField(allocator: std.mem.Allocator, name: []const u8, label: []const u8, opts: FormBuilder.TextOptions) ![]const u8 {
    var builder = FormBuilder.init(allocator);
    defer builder.deinit();

    _ = try builder.text(name, label, opts);
    const html = try builder.html.toOwnedSlice(allocator);
    builder.html = .{}; // Reset to avoid double-free
    return html;
}

// Tests
test "form builder creates basic form" {
    const allocator = std.heap.page_allocator;
    var builder = FormBuilder.init(allocator);
    defer builder.deinit();

    _ = try builder.start("/api/submit");
    _ = try builder.text("name", "Name", .{ .required = true });
    _ = try builder.submit("Submit");
    const html = try builder.build();
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<form hx-post=\"/api/submit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "required") != null);
}

test "form builder with select and options" {
    const allocator = std.heap.page_allocator;
    var builder = FormBuilder.init(allocator);
    defer builder.deinit();

    const options = [_]FormBuilder.SelectOption{
        .{ .value = "1", .label = "Option 1" },
        .{ .value = "2", .label = "Option 2", .selected = true },
    };

    _ = try builder.start("/api/submit");
    _ = try builder.select("priority", "Priority", &options);
    const html = try builder.build();
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<select") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Option 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "selected") != null);
}
