const std = @import("std");
const style_mod = @import("style.zig");
const theme_mod = @import("theme.zig");

pub const Style = style_mod.Style;
pub const Length = style_mod.Length;

/// Media query condition types
pub const MediaQuery = union(enum) {
    min_width: u32,
    max_width: u32,
    min_height: u32,
    max_height: u32,
    orientation: Orientation,
    prefers_color_scheme: ColorScheme,
    prefers_reduced_motion: ReducedMotion,
    prefers_contrast: Contrast,
    hover: HoverCapability,
    pointer: PointerType,
    display_mode: DisplayMode,
    aspect_ratio: struct { width: u32, height: u32 },
    min_aspect_ratio: struct { width: u32, height: u32 },
    max_aspect_ratio: struct { width: u32, height: u32 },
    resolution: Resolution,
    print,
    screen,
    all,
    custom: []const u8,
    and_query: struct { left: *const MediaQuery, right: *const MediaQuery },
    or_query: struct { left: *const MediaQuery, right: *const MediaQuery },
    not_query: *const MediaQuery,

    pub const Orientation = enum { portrait, landscape };
    pub const ColorScheme = enum { light, dark };
    pub const ReducedMotion = enum { reduce, no_preference };
    pub const Contrast = enum { no_preference, more, less, custom };
    pub const HoverCapability = enum { none, hover };
    pub const PointerType = enum { none, coarse, fine };
    pub const DisplayMode = enum { fullscreen, standalone, minimal_ui, browser };
    pub const Resolution = union(enum) { dpi: u32, dppx: f32, dpcm: u32 };

    pub fn format(self: MediaQuery, writer: anytype) !void {
        switch (self) {
            .min_width => |w| try writer.print("(min-width:{d}px)", .{w}),
            .max_width => |w| try writer.print("(max-width:{d}px)", .{w}),
            .min_height => |h| try writer.print("(min-height:{d}px)", .{h}),
            .max_height => |h| try writer.print("(max-height:{d}px)", .{h}),
            .orientation => |o| try writer.print("(orientation:{s})", .{@tagName(o)}),
            .prefers_color_scheme => |c| try writer.print("(prefers-color-scheme:{s})", .{@tagName(c)}),
            .prefers_reduced_motion => |m| try writer.print("(prefers-reduced-motion:{s})", .{if (m == .reduce) "reduce" else "no-preference"}),
            .prefers_contrast => |c| try writer.print("(prefers-contrast:{s})", .{@tagName(c)}),
            .hover => |h| try writer.print("(hover:{s})", .{@tagName(h)}),
            .pointer => |p| try writer.print("(pointer:{s})", .{@tagName(p)}),
            .display_mode => |d| try writer.print("(display-mode:{s})", .{@tagName(d)}),
            .aspect_ratio => |r| try writer.print("(aspect-ratio:{d}/{d})", .{ r.width, r.height }),
            .min_aspect_ratio => |r| try writer.print("(min-aspect-ratio:{d}/{d})", .{ r.width, r.height }),
            .max_aspect_ratio => |r| try writer.print("(max-aspect-ratio:{d}/{d})", .{ r.width, r.height }),
            .resolution => |r| switch (r) {
                .dpi => |d| try writer.print("(resolution:{d}dpi)", .{d}),
                .dppx => |d| try writer.print("(resolution:{d}dppx)", .{d}),
                .dpcm => |d| try writer.print("(resolution:{d}dpcm)", .{d}),
            },
            .print => try writer.writeAll("print"),
            .screen => try writer.writeAll("screen"),
            .all => try writer.writeAll("all"),
            .custom => |c| try writer.writeAll(c),
            .and_query => |q| {
                try q.left.format(writer);
                try writer.writeAll(" and ");
                try q.right.format(writer);
            },
            .or_query => |q| {
                try q.left.format(writer);
                try writer.writeAll(", ");
                try q.right.format(writer);
            },
            .not_query => |q| {
                try writer.writeAll("not ");
                try q.format(writer);
            },
        }
    }

    pub fn toCss(self: MediaQuery, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try self.format(buf.writer(allocator));
        return try buf.toOwnedSlice(allocator);
    }

    /// Combine with AND
    pub fn @"and"(self: MediaQuery, other: MediaQuery) MediaQuery {
        return .{ .and_query = .{ .left = &self, .right = &other } };
    }

    /// Combine with OR (comma in CSS)
    pub fn @"or"(self: MediaQuery, other: MediaQuery) MediaQuery {
        return .{ .or_query = .{ .left = &self, .right = &other } };
    }

    /// Negate the query
    pub fn not(self: MediaQuery) MediaQuery {
        return .{ .not_query = &self };
    }
};

/// Responsive style wrapper that applies different styles at different breakpoints
pub fn ResponsiveStyle(comptime breakpoints: type) type {
    return struct {
        base: Style = .{},
        sm: ?Style = null,
        md: ?Style = null,
        lg: ?Style = null,
        xl: ?Style = null,
        xxl: ?Style = null,

        const Self = @This();

        /// Generate CSS with media queries
        pub fn toCss(self: Self, allocator: std.mem.Allocator) ![]const u8 {
            var buf = std.ArrayListUnmanaged(u8){};
            errdefer buf.deinit(allocator);
            const writer = buf.writer(allocator);

            // Base styles
            try self.base.writeCss(writer);

            // Responsive overrides
            if (self.sm) |s| {
                try writer.print("@media(min-width:{d}px){{", .{breakpoints.sm});
                try s.writeCss(writer);
                try writer.writeAll("}");
            }

            if (self.md) |s| {
                try writer.print("@media(min-width:{d}px){{", .{breakpoints.md});
                try s.writeCss(writer);
                try writer.writeAll("}");
            }

            if (self.lg) |s| {
                try writer.print("@media(min-width:{d}px){{", .{breakpoints.lg});
                try s.writeCss(writer);
                try writer.writeAll("}");
            }

            if (self.xl) |s| {
                try writer.print("@media(min-width:{d}px){{", .{breakpoints.xl});
                try s.writeCss(writer);
                try writer.writeAll("}");
            }

            if (self.xxl) |s| {
                try writer.print("@media(min-width:{d}px){{", .{breakpoints.xxl});
                try s.writeCss(writer);
                try writer.writeAll("}");
            }

            return try buf.toOwnedSlice(allocator);
        }
    };
}

/// Container query support
pub const ContainerQuery = struct {
    name: ?[]const u8 = null,
    condition: Condition,

    pub const Condition = union(enum) {
        min_width: Length,
        max_width: Length,
        min_height: Length,
        max_height: Length,
        aspect_ratio: struct { width: u32, height: u32 },
        orientation: MediaQuery.Orientation,
        custom: []const u8,
    };

    pub fn format(self: ContainerQuery, writer: anytype) !void {
        try writer.writeAll("@container ");
        if (self.name) |n| {
            try writer.writeAll(n);
            try writer.writeAll(" ");
        }
        switch (self.condition) {
            .min_width => |w| {
                try writer.writeAll("(min-width:");
                try w.format(writer);
                try writer.writeAll(")");
            },
            .max_width => |w| {
                try writer.writeAll("(max-width:");
                try w.format(writer);
                try writer.writeAll(")");
            },
            .min_height => |h| {
                try writer.writeAll("(min-height:");
                try h.format(writer);
                try writer.writeAll(")");
            },
            .max_height => |h| {
                try writer.writeAll("(max-height:");
                try h.format(writer);
                try writer.writeAll(")");
            },
            .aspect_ratio => |r| try writer.print("(aspect-ratio:{d}/{d})", .{ r.width, r.height }),
            .orientation => |o| try writer.print("(orientation:{s})", .{@tagName(o)}),
            .custom => |c| try writer.writeAll(c),
        }
    }
};

/// Media query rule that wraps styles
pub const MediaRule = struct {
    query: MediaQuery,
    styles: []const SelectorStyle,

    pub const SelectorStyle = struct {
        selector: []const u8,
        style: Style,
    };

    pub fn toCss(self: MediaRule, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(allocator);
        const writer = buf.writer(allocator);

        try writer.writeAll("@media ");
        try self.query.format(writer);
        try writer.writeAll("{");

        for (self.styles) |ss| {
            try writer.writeAll(ss.selector);
            try writer.writeAll("{");
            try ss.style.writeCss(writer);
            try writer.writeAll("}");
        }

        try writer.writeAll("}");
        return try buf.toOwnedSlice(allocator);
    }
};

/// Predefined breakpoint helpers using default theme
pub const Breakpoints = struct {
    pub const xs = 0;
    pub const sm = 640;
    pub const md = 768;
    pub const lg = 1024;
    pub const xl = 1280;
    pub const xxl = 1536;

    /// Mobile-first media query
    pub fn up(width: u32) MediaQuery {
        return .{ .min_width = width };
    }

    /// Desktop-first media query
    pub fn down(width: u32) MediaQuery {
        return .{ .max_width = width - 1 };
    }

    /// Range between two breakpoints
    pub fn between(min: u32, max: u32) MediaQuery {
        const min_q = MediaQuery{ .min_width = min };
        const max_q = MediaQuery{ .max_width = max - 1 };
        return min_q.@"and"(max_q);
    }

    /// Only at specific breakpoint
    pub fn only(width: u32, next_width: u32) MediaQuery {
        return between(width, next_width);
    }

    // Convenient shortcuts
    pub fn mobile() MediaQuery {
        return down(sm);
    }

    pub fn tablet() MediaQuery {
        return between(sm, lg);
    }

    pub fn desktop() MediaQuery {
        return up(lg);
    }

    pub fn touch() MediaQuery {
        return .{ .hover = .none };
    }

    pub fn mouse() MediaQuery {
        return .{ .hover = .hover };
    }

    pub fn darkMode() MediaQuery {
        return .{ .prefers_color_scheme = .dark };
    }

    pub fn lightMode() MediaQuery {
        return .{ .prefers_color_scheme = .light };
    }

    pub fn reducedMotion() MediaQuery {
        return .{ .prefers_reduced_motion = .reduce };
    }

    pub fn highContrast() MediaQuery {
        return .{ .prefers_contrast = .more };
    }

    pub fn printMedia() MediaQuery {
        return .print;
    }

    pub fn retina() MediaQuery {
        return .{ .resolution = .{ .dppx = 2 } };
    }
};

/// Default responsive style type using standard breakpoints
pub const DefaultResponsiveStyle = ResponsiveStyle(Breakpoints);

// Tests
test "MediaQuery format - min-width" {
    const query = MediaQuery{ .min_width = 768 };
    const allocator = std.testing.allocator;
    const css = try query.toCss(allocator);
    defer allocator.free(css);
    try std.testing.expectEqualStrings("(min-width:768px)", css);
}

test "MediaQuery format - prefers-color-scheme" {
    const query = MediaQuery{ .prefers_color_scheme = .dark };
    const allocator = std.testing.allocator;
    const css = try query.toCss(allocator);
    defer allocator.free(css);
    try std.testing.expectEqualStrings("(prefers-color-scheme:dark)", css);
}

test "Breakpoints helpers" {
    const allocator = std.testing.allocator;

    const mobile = Breakpoints.mobile();
    const css = try mobile.toCss(allocator);
    defer allocator.free(css);
    try std.testing.expectEqualStrings("(max-width:639px)", css);
}

test "ResponsiveStyle generation" {
    const TestBreakpoints = struct {
        pub const sm: u32 = 640;
        pub const md: u32 = 768;
        pub const lg: u32 = 1024;
        pub const xl: u32 = 1280;
        pub const xxl: u32 = 1536;
    };

    const RS = ResponsiveStyle(TestBreakpoints);
    const responsive = RS{
        .base = .{ .display = .block },
        .md = .{ .display = .flex },
    };

    const allocator = std.testing.allocator;
    const css = try responsive.toCss(allocator);
    defer allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, "display:block") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "@media(min-width:768px)") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "display:flex") != null);
}
