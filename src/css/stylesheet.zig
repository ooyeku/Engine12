const std = @import("std");
const style_mod = @import("style.zig");
const responsive = @import("responsive.zig");
const animation = @import("animation.zig");
const theme = @import("theme.zig");
const values = @import("values.zig");

pub const Style = style_mod.Style;
pub const MediaQuery = responsive.MediaQuery;
pub const MediaRule = responsive.MediaRule;
pub const Keyframes = animation.Keyframes;
pub const Color = values.Color;
pub const Length = values.Length;

/// A complete stylesheet containing multiple rules
pub const Stylesheet = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayListUnmanaged(Rule),
    media_rules: std.ArrayListUnmanaged(MediaRule),
    keyframes: std.ArrayListUnmanaged(Keyframes),
    imports: std.ArrayListUnmanaged([]const u8),
    font_faces: std.ArrayListUnmanaged(FontFace),
    custom_properties: std.ArrayListUnmanaged(CustomProperty),

    pub const Rule = struct {
        selector: []const u8,
        style: Style,
    };

    pub const FontFace = struct {
        family: []const u8,
        src: []const u8,
        weight: ?[]const u8 = null,
        style: ?[]const u8 = null,
        display: FontDisplay = .swap,

        pub const FontDisplay = enum {
            auto,
            block,
            swap,
            fallback,
            optional,
        };
    };

    pub const CustomProperty = struct {
        name: []const u8,
        value: []const u8,
        selector: []const u8 = ":root",
    };

    pub fn init(allocator: std.mem.Allocator) Stylesheet {
        return .{
            .allocator = allocator,
            .rules = std.ArrayListUnmanaged(Rule){},
            .media_rules = std.ArrayListUnmanaged(MediaRule){},
            .keyframes = std.ArrayListUnmanaged(Keyframes){},
            .imports = std.ArrayListUnmanaged([]const u8){},
            .font_faces = std.ArrayListUnmanaged(FontFace){},
            .custom_properties = std.ArrayListUnmanaged(CustomProperty){},
        };
    }

    pub fn deinit(self: *Stylesheet) void {
        self.rules.deinit(self.allocator);
        self.media_rules.deinit(self.allocator);
        self.keyframes.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.font_faces.deinit(self.allocator);
        self.custom_properties.deinit(self.allocator);
    }

    /// Add a rule to the stylesheet
    pub fn addRule(self: *Stylesheet, selector: []const u8, style: Style) !void {
        try self.rules.append(self.allocator, .{ .selector = selector, .style = style });
    }

    /// Add a media query rule
    pub fn addMediaRule(self: *Stylesheet, rule: MediaRule) !void {
        try self.media_rules.append(self.allocator, rule);
    }

    /// Builder for creating media rules with runtime-allocated style arrays.
    /// This avoids comptime memory issues with large Style struct arrays.
    pub const MediaRuleBuilder = struct {
        allocator: std.mem.Allocator,
        query: MediaQuery,
        styles: std.ArrayListUnmanaged(MediaRule.SelectorStyle),

        pub fn init(allocator: std.mem.Allocator, query: MediaQuery) MediaRuleBuilder {
            return .{
                .allocator = allocator,
                .query = query,
                .styles = std.ArrayListUnmanaged(MediaRule.SelectorStyle){},
            };
        }

        pub fn deinit(self: *MediaRuleBuilder) void {
            self.styles.deinit(self.allocator);
        }

        /// Add a selector and style to the media rule
        pub fn addStyle(self: *MediaRuleBuilder, selector: []const u8, style: Style) !void {
            try self.styles.append(self.allocator, .{
                .selector = selector,
                .style = style,
            });
        }

        /// Build the MediaRule with the collected styles
        pub fn build(self: *MediaRuleBuilder) MediaRule {
            return .{
                .query = self.query,
                .styles = self.styles.items,
            };
        }
    };

    /// Create a media rule builder for the given query
    pub fn mediaRule(self: *Stylesheet, query: MediaQuery) MediaRuleBuilder {
        return MediaRuleBuilder.init(self.allocator, query);
    }

    /// Add a completed media rule from a builder
    pub fn addMediaRuleFromBuilder(self: *Stylesheet, builder: *MediaRuleBuilder) !void {
        try self.media_rules.append(self.allocator, builder.build());
    }

    /// Add keyframes animation
    pub fn addKeyframes(self: *Stylesheet, kf: Keyframes) !void {
        try self.keyframes.append(self.allocator, kf);
    }

    /// Add an @import rule
    pub fn addImport(self: *Stylesheet, url: []const u8) !void {
        try self.imports.append(self.allocator, url);
    }

    /// Add a @font-face rule
    pub fn addFontFace(self: *Stylesheet, font: FontFace) !void {
        try self.font_faces.append(self.allocator, font);
    }

    /// Add a CSS custom property (variable)
    pub fn addCustomProperty(self: *Stylesheet, name: []const u8, value: []const u8) !void {
        try self.custom_properties.append(self.allocator, .{ .name = name, .value = value });
    }

    /// Add a custom property scoped to a selector
    pub fn addScopedCustomProperty(self: *Stylesheet, selector: []const u8, name: []const u8, value: []const u8) !void {
        try self.custom_properties.append(self.allocator, .{
            .name = name,
            .value = value,
            .selector = selector,
        });
    }

    /// Generate complete CSS output
    pub fn toCss(self: Stylesheet) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        // @import rules first
        for (self.imports.items) |url| {
            try writer.print("@import url(\"{s}\");\n", .{url});
        }

        // @font-face rules
        for (self.font_faces.items) |font| {
            try writer.writeAll("@font-face{");
            try writer.print("font-family:\"{s}\";", .{font.family});
            try writer.print("src:{s};", .{font.src});
            if (font.weight) |w| try writer.print("font-weight:{s};", .{w});
            if (font.style) |s| try writer.print("font-style:{s};", .{s});
            try writer.print("font-display:{s};", .{@tagName(font.display)});
            try writer.writeAll("}\n");
        }

        // Custom properties grouped by selector
        var props_by_selector = std.StringHashMap(std.ArrayListUnmanaged(CustomProperty)).init(self.allocator);
        defer {
            var iter = props_by_selector.valueIterator();
            while (iter.next()) |list| {
                list.deinit(self.allocator);
            }
            props_by_selector.deinit();
        }

        for (self.custom_properties.items) |prop| {
            const result = try props_by_selector.getOrPut(prop.selector);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayListUnmanaged(CustomProperty){};
            }
            try result.value_ptr.append(self.allocator, prop);
        }

        var selector_iter = props_by_selector.iterator();
        while (selector_iter.next()) |entry| {
            try writer.print("{s}{{", .{entry.key_ptr.*});
            for (entry.value_ptr.items) |prop| {
                try writer.print("--{s}:{s};", .{ prop.name, prop.value });
            }
            try writer.writeAll("}\n");
        }

        // @keyframes rules
        for (self.keyframes.items) |kf| {
            const kf_css = try kf.toCss(self.allocator);
            defer self.allocator.free(kf_css);
            try writer.writeAll(kf_css);
            try writer.writeAll("\n");
        }

        // Regular rules
        for (self.rules.items) |rule| {
            try writer.print("{s}{{", .{rule.selector});
            try rule.style.writeCss(writer);
            try writer.writeAll("}\n");
        }

        // Media rules
        for (self.media_rules.items) |mr| {
            const mr_css = try mr.toCss(self.allocator);
            defer self.allocator.free(mr_css);
            try writer.writeAll(mr_css);
            try writer.writeAll("\n");
        }

        return try buf.toOwnedSlice(self.allocator);
    }

    /// Generate minified CSS output
    pub fn toMinifiedCss(self: Stylesheet) ![]const u8 {
        const css = try self.toCss();
        defer self.allocator.free(css);

        // Simple minification: remove newlines and extra spaces
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(self.allocator);

        var prev_char: u8 = 0;
        for (css) |c| {
            if (c == '\n' or c == '\r') continue;
            if (c == ' ' and (prev_char == '{' or prev_char == '}' or prev_char == ';' or prev_char == ':' or prev_char == ',')) continue;
            if (prev_char == ' ' and (c == '{' or c == '}' or c == ';' or c == ':' or c == ',')) {
                // Remove trailing space
                if (buf.items.len > 0) {
                    _ = buf.pop();
                }
            }
            try buf.append(self.allocator, c);
            prev_char = c;
        }

        return try buf.toOwnedSlice(self.allocator);
    }
};

/// Cached stylesheet for production use - generates CSS once and caches it
/// Use this in production to avoid regenerating CSS on every request.
pub const CachedStylesheet = struct {
    allocator: std.mem.Allocator,
    generator: *const fn (std.mem.Allocator) anyerror!Stylesheet,
    cached_css: ?[]const u8 = null,
    cached_minified: ?[]const u8 = null,
    is_dirty: bool = true,

    /// Initialize with a stylesheet generator function
    pub fn init(allocator: std.mem.Allocator, generator: *const fn (std.mem.Allocator) anyerror!Stylesheet) CachedStylesheet {
        return .{
            .allocator = allocator,
            .generator = generator,
        };
    }

    /// Free cached CSS
    pub fn deinit(self: *CachedStylesheet) void {
        if (self.cached_css) |css| {
            self.allocator.free(css);
            self.cached_css = null;
        }
        if (self.cached_minified) |min| {
            self.allocator.free(min);
            self.cached_minified = null;
        }
    }

    /// Get CSS output, generating and caching if needed
    pub fn getCss(self: *CachedStylesheet) ![]const u8 {
        if (!self.is_dirty) {
            if (self.cached_css) |css| return css;
        }

        // Generate fresh CSS
        var sheet = try self.generator(self.allocator);
        defer sheet.deinit();

        // Free old cache
        if (self.cached_css) |old| {
            self.allocator.free(old);
        }

        self.cached_css = try sheet.toCss();
        self.is_dirty = false;
        return self.cached_css.?;
    }

    /// Get minified CSS output, generating and caching if needed
    pub fn getMinifiedCss(self: *CachedStylesheet) ![]const u8 {
        if (!self.is_dirty) {
            if (self.cached_minified) |min| return min;
        }

        // Generate fresh CSS
        var sheet = try self.generator(self.allocator);
        defer sheet.deinit();

        // Free old cache
        if (self.cached_minified) |old| {
            self.allocator.free(old);
        }

        self.cached_minified = try sheet.toMinifiedCss();
        self.is_dirty = false;
        return self.cached_minified.?;
    }

    /// Mark cache as dirty - next getCss() will regenerate
    pub fn invalidate(self: *CachedStylesheet) void {
        self.is_dirty = true;
    }

    /// Check if cache is valid
    pub fn isCached(self: *const CachedStylesheet) bool {
        return !self.is_dirty and (self.cached_css != null or self.cached_minified != null);
    }
};

/// CSS class generator with automatic unique naming
pub const ClassGenerator = struct {
    allocator: std.mem.Allocator,
    prefix: []const u8,
    counter: usize,
    classes: std.StringHashMap(Style),

    pub fn init(allocator: std.mem.Allocator, prefix: []const u8) ClassGenerator {
        return .{
            .allocator = allocator,
            .prefix = prefix,
            .counter = 0,
            .classes = std.StringHashMap(Style).init(allocator),
        };
    }

    pub fn deinit(self: *ClassGenerator) void {
        self.classes.deinit();
    }

    /// Create a new class with the given style, returns the class name
    pub fn addClass(self: *ClassGenerator, style: Style) ![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "{s}{d}", .{ self.prefix, self.counter });
        self.counter += 1;
        try self.classes.put(name, style);
        return name;
    }

    /// Generate stylesheet from all classes
    pub fn toStylesheet(self: ClassGenerator) !Stylesheet {
        var sheet = Stylesheet.init(self.allocator);
        var iter = self.classes.iterator();
        while (iter.next()) |entry| {
            const selector = try std.fmt.allocPrint(self.allocator, ".{s}", .{entry.key_ptr.*});
            defer self.allocator.free(selector);
            try sheet.addRule(selector, entry.value_ptr.*);
        }
        return sheet;
    }
};

/// Component-based styling with encapsulated styles
pub fn Component(comptime name: []const u8) type {
    return struct {
        pub const component_name = name;

        /// Base styles for the component
        base: Style = .{},

        /// Variant styles (e.g., primary, secondary)
        variants: []const Variant = &.{},

        /// Size variants
        sizes: []const SizeVariant = &.{},

        /// State styles
        states: States = .{},

        pub const Variant = struct {
            name: []const u8,
            style: Style,
        };

        pub const SizeVariant = struct {
            name: []const u8,
            style: Style,
        };

        pub const States = struct {
            hover: ?Style = null,
            focus: ?Style = null,
            active: ?Style = null,
            disabled: ?Style = null,
        };

        const Self = @This();

        /// Get the class name for this component
        pub fn className() []const u8 {
            return name;
        }

        /// Get class name with variant
        pub fn variantClassName(variant: []const u8) []const u8 {
            _ = variant;
            // In a real implementation, this would generate or return a stored class name
            return name;
        }

        /// Generate CSS for this component
        pub fn toCss(self: Self, allocator: std.mem.Allocator) ![]const u8 {
            var sheet = Stylesheet.init(allocator);
            defer sheet.deinit();

            // Track allocated selectors to free after toCss() completes
            var selectors_to_free = std.ArrayListUnmanaged([]const u8){};
            defer {
                for (selectors_to_free.items) |sel| {
                    allocator.free(sel);
                }
                selectors_to_free.deinit(allocator);
            }

            // Base style
            const base_selector = try std.fmt.allocPrint(allocator, ".{s}", .{name});
            try selectors_to_free.append(allocator, base_selector);
            try sheet.addRule(base_selector, self.base);

            // Variants
            for (self.variants) |v| {
                const variant_selector = try std.fmt.allocPrint(allocator, ".{s}--{s}", .{ name, v.name });
                try selectors_to_free.append(allocator, variant_selector);
                try sheet.addRule(variant_selector, v.style);
            }

            // Sizes
            for (self.sizes) |s| {
                const size_selector = try std.fmt.allocPrint(allocator, ".{s}--{s}", .{ name, s.name });
                try selectors_to_free.append(allocator, size_selector);
                try sheet.addRule(size_selector, s.style);
            }

            // States
            if (self.states.hover) |hover| {
                const hover_selector = try std.fmt.allocPrint(allocator, ".{s}:hover", .{name});
                try selectors_to_free.append(allocator, hover_selector);
                try sheet.addRule(hover_selector, hover);
            }

            if (self.states.focus) |focus| {
                const focus_selector = try std.fmt.allocPrint(allocator, ".{s}:focus", .{name});
                try selectors_to_free.append(allocator, focus_selector);
                try sheet.addRule(focus_selector, focus);
            }

            if (self.states.active) |active| {
                const active_selector = try std.fmt.allocPrint(allocator, ".{s}:active", .{name});
                try selectors_to_free.append(allocator, active_selector);
                try sheet.addRule(active_selector, active);
            }

            if (self.states.disabled) |disabled| {
                const disabled_selector = try std.fmt.allocPrint(allocator, ".{s}:disabled,.{s}[disabled]", .{ name, name });
                try selectors_to_free.append(allocator, disabled_selector);
                try sheet.addRule(disabled_selector, disabled);
            }

            return sheet.toCss();
        }
    };
}

/// CSS Reset/Normalize styles
pub const Reset = struct {
    /// Modern CSS reset
    pub fn modern(allocator: std.mem.Allocator) !Stylesheet {
        var sheet = Stylesheet.init(allocator);

        // Box sizing
        try sheet.addRule("*, *::before, *::after", .{
            .box_sizing = .border_box,
        });

        // Remove default margin
        try sheet.addRule("body, h1, h2, h3, h4, h5, h6, p, figure, blockquote, dl, dd", .{
            .margin = .{ .all = .zero },
        });

        // Remove list styles
        try sheet.addRule("ul[role='list'], ol[role='list']", .{
            .list_style = "none",
        });

        // Core body defaults
        try sheet.addRule("body", .{
            .min_height = .{ .vh = 100 },
            .line_height = .{ .number = 1.5 },
            .text_rendering = null, // text-rendering not in our Style yet
        });

        // Anchor elements
        try sheet.addRule("a:not([class])", .{
            .text_decoration_skip_ink = null, // Not in our Style yet
        });

        // Make images easier to work with
        try sheet.addRule("img, picture, video, canvas, svg", .{
            .display = .block,
            .max_width = .{ .percent = 100 },
        });

        // Inherit fonts for inputs and buttons
        try sheet.addRule("input, button, textarea, select", .{
            .font_family = "inherit",
            .font_size = .inherit,
        });

        // Remove animations for people who prefer not to see them
        try sheet.addMediaRule(.{
            .query = .{ .prefers_reduced_motion = .reduce },
            .styles = &[_]MediaRule.SelectorStyle{
                .{
                    .selector = "*, *::before, *::after",
                    .style = .{
                        .animation_duration = .{ .ms = 1 },
                        .animation_iteration_count = .{ .count = 1 },
                        .transition_duration = .{ .ms = 1 },
                    },
                },
            },
        });

        return sheet;
    }

    /// Minimal reset
    pub fn minimal(allocator: std.mem.Allocator) !Stylesheet {
        var sheet = Stylesheet.init(allocator);

        try sheet.addRule("*, *::before, *::after", .{
            .box_sizing = .border_box,
            .margin = .{ .all = .zero },
            .padding = .{ .all = .zero },
        });

        try sheet.addRule("html, body", .{
            .height = .{ .percent = 100 },
        });

        return sheet;
    }
};

/// Utility for combining multiple stylesheets
pub fn combineStylesheets(allocator: std.mem.Allocator, sheets: []const Stylesheet) !Stylesheet {
    var combined = Stylesheet.init(allocator);

    for (sheets) |sheet| {
        for (sheet.rules.items) |rule| {
            try combined.addRule(rule.selector, rule.style);
        }
        for (sheet.media_rules.items) |mr| {
            try combined.addMediaRule(mr);
        }
        for (sheet.keyframes.items) |kf| {
            try combined.addKeyframes(kf);
        }
        for (sheet.imports.items) |imp| {
            try combined.addImport(imp);
        }
        for (sheet.font_faces.items) |ff| {
            try combined.addFontFace(ff);
        }
        for (sheet.custom_properties.items) |cp| {
            try combined.custom_properties.append(cp);
        }
    }

    return combined;
}

// Tests
test "Stylesheet basic generation" {
    const allocator = std.testing.allocator;
    var sheet = Stylesheet.init(allocator);
    defer sheet.deinit();

    try sheet.addRule(".button", .{
        .display = .inline_flex,
        .padding = .{ .all = .{ .px = 12 } },
        .background_color = Color.fromHex("#3b82f6"),
    });

    const css = try sheet.toCss();
    defer allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, ".button{") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "display:inline-flex") != null);
}

test "Stylesheet with keyframes" {
    const allocator = std.testing.allocator;
    var sheet = Stylesheet.init(allocator);
    defer sheet.deinit();

    try sheet.addKeyframes(Keyframes.fadeIn());

    const css = try sheet.toCss();
    defer allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, "@keyframes fadeIn") != null);
}

test "Stylesheet custom properties" {
    const allocator = std.testing.allocator;
    var sheet = Stylesheet.init(allocator);
    defer sheet.deinit();

    try sheet.addCustomProperty("primary-color", "#3b82f6");
    try sheet.addCustomProperty("spacing-md", "1rem");

    const css = try sheet.toCss();
    defer allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, ":root{") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "--primary-color:#3b82f6") != null);
}

test "Component styling" {
    const Button = Component("btn");
    const btn = Button{
        .base = .{
            .display = .inline_flex,
            .padding = .{ .all = .{ .px = 12 } },
        },
        .variants = &[_]Button.Variant{
            .{ .name = "primary", .style = .{ .background_color = Color.fromHex("#3b82f6") } },
        },
        .states = .{
            .hover = .{ .opacity = .{ .value = 0.9 } },
        },
    };

    const allocator = std.testing.allocator;
    const css = try btn.toCss(allocator);
    defer allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, ".btn{") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".btn--primary{") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".btn:hover{") != null);
}
