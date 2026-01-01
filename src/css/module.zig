//! # Engine12 CSS-in-Zig Styling System
//!
//! A comprehensive, type-safe CSS styling system for Zig web applications.
//! All styles are compile-time validated and generate optimized CSS output.
//!
//! ## Quick Start
//!
//! ```zig
//! const css = @import("engine12").css;
//!
//! // Create a simple style
//! const buttonStyle = css.Style{
//!     .display = .inline_flex,
//!     .padding = .{ .all = .{ .px = 12 } },
//!     .background_color = css.Color.fromHex("#3b82f6"),
//!     .border_radius = .{ .all = .{ .px = 8 } },
//!     .color = css.Color.white,
//! };
//!
//! // Generate CSS
//! const cssText = try buttonStyle.toCss(allocator);
//! ```
//!
//! ## Features
//!
//! - **Type-safe properties**: All CSS properties are strongly typed
//! - **Design tokens**: Centralized theme configuration
//! - **Responsive design**: Built-in media query support
//! - **Animations**: Keyframes and transitions
//! - **Component styling**: Encapsulated component-based CSS
//! - **Zero runtime overhead**: CSS is generated at build/request time
//!

const std = @import("std");

// Core modules
pub const values = @import("values.zig");
pub const properties = @import("properties.zig");
pub const style = @import("style.zig");
pub const theme = @import("theme.zig");
pub const responsive = @import("responsive.zig");
pub const animation = @import("animation.zig");
pub const stylesheet = @import("stylesheet.zig");

// Re-export core types for convenience

// Values
pub const Length = values.Length;
pub const Color = values.Color;
pub const Duration = values.Duration;
pub const Angle = values.Angle;
pub const BoxShadow = values.BoxShadow;
pub const TextShadow = values.TextShadow;
pub const Border = values.Border;
pub const Gradient = values.Gradient;
pub const Transform = values.Transform;
pub const TimingFunction = values.TimingFunction;
pub const Filter = values.Filter;

// Properties
pub const Display = properties.Display;
pub const Position = properties.Position;
pub const FlexDirection = properties.FlexDirection;
pub const FlexWrap = properties.FlexWrap;
pub const JustifyContent = properties.JustifyContent;
pub const AlignItems = properties.AlignItems;
pub const AlignContent = properties.AlignContent;
pub const AlignSelf = properties.AlignSelf;
pub const TextAlign = properties.TextAlign;
pub const TextDecoration = properties.TextDecoration;
pub const TextTransform = properties.TextTransform;
pub const FontWeight = properties.FontWeight;
pub const FontStyle = properties.FontStyle;
pub const Overflow = properties.Overflow;
pub const Visibility = properties.Visibility;
pub const Cursor = properties.Cursor;
pub const PointerEvents = properties.PointerEvents;
pub const UserSelect = properties.UserSelect;
pub const WhiteSpace = properties.WhiteSpace;
pub const WordBreak = properties.WordBreak;
pub const ObjectFit = properties.ObjectFit;
pub const BackgroundSize = properties.BackgroundSize;
pub const BackgroundPosition = properties.BackgroundPosition;
pub const BackgroundRepeat = properties.BackgroundRepeat;
pub const BoxSizing = properties.BoxSizing;
pub const Transition = properties.Transition;
pub const Gap = properties.Gap;
pub const AspectRatio = properties.AspectRatio;
pub const ZIndex = properties.ZIndex;
pub const Opacity = properties.Opacity;
pub const Flex = properties.Flex;

// Style
pub const Style = style.Style;

// Theme
pub const Theme = theme.Theme;
pub const ThemeConfig = theme.ThemeConfig;
pub const ColorTokens = theme.ColorTokens;
pub const SpacingTokens = theme.SpacingTokens;
pub const TypographyTokens = theme.TypographyTokens;
pub const BorderTokens = theme.BorderTokens;
pub const ShadowTokens = theme.ShadowTokens;
pub const BreakpointTokens = theme.BreakpointTokens;
pub const TransitionTokens = theme.TransitionTokens;
pub const ZIndexTokens = theme.ZIndexTokens;
pub const DefaultTheme = theme.DefaultTheme;
pub const DarkTheme = theme.DarkTheme;
pub const extendTheme = theme.extendTheme;

// Responsive
pub const MediaQuery = responsive.MediaQuery;
pub const ResponsiveStyle = responsive.ResponsiveStyle;
pub const ContainerQuery = responsive.ContainerQuery;
pub const MediaRule = responsive.MediaRule;
pub const Breakpoints = responsive.Breakpoints;
pub const DefaultResponsiveStyle = responsive.DefaultResponsiveStyle;

// Animation
pub const Keyframes = animation.Keyframes;
pub const Animation = animation.Animation;
pub const TransitionBuilder = animation.TransitionBuilder;
pub const Transitions = animation.Transitions;

// Stylesheet
pub const Stylesheet = stylesheet.Stylesheet;
pub const ClassGenerator = stylesheet.ClassGenerator;
pub const Component = stylesheet.Component;
pub const Reset = stylesheet.Reset;
pub const MediaRuleBuilder = stylesheet.Stylesheet.MediaRuleBuilder;
pub const combineStylesheets = stylesheet.combineStylesheets;

/// Convenience function to create a length in pixels
pub fn px(value: f32) Length {
    return .{ .px = value };
}

/// Convenience function to create a length in rem
pub fn rem(value: f32) Length {
    return .{ .rem = value };
}

/// Convenience function to create a length in em
pub fn em(value: f32) Length {
    return .{ .em = value };
}

/// Convenience function to create a length in percent
pub fn percent(value: f32) Length {
    return .{ .percent = value };
}

/// Convenience function to create a length in viewport width
pub fn vw(value: f32) Length {
    return .{ .vw = value };
}

/// Convenience function to create a length in viewport height
pub fn vh(value: f32) Length {
    return .{ .vh = value };
}

/// Convenience function to create a color from hex
pub fn hex(comptime h: []const u8) Color {
    return Color.fromHex(h);
}

/// Convenience function to create an RGB color
pub fn rgb(r: u8, g: u8, b: u8) Color {
    return Color.rgb(r, g, b);
}

/// Convenience function to create an RGBA color
pub fn rgba(r: u8, g: u8, b: u8, a: f32) Color {
    return Color.rgba(r, g, b, a);
}

/// Convenience function for duration in milliseconds
pub fn ms(value: u32) Duration {
    return .{ .ms = value };
}

/// Convenience function for duration in seconds
pub fn s(value: f32) Duration {
    return .{ .s = value };
}

/// Convenience function for angle in degrees
pub fn deg(value: f32) Angle {
    return .{ .deg = value };
}

/// Create a simple stylesheet with a single rule
pub fn createStylesheet(allocator: std.mem.Allocator) Stylesheet {
    return Stylesheet.init(allocator);
}

/// Common style presets
pub const presets = struct {
    /// Flexbox center alignment
    pub const flexCenter = Style{
        .display = .flex,
        .justify_content = .center,
        .align_items = .center,
    };

    /// Flexbox column layout
    pub const flexColumn = Style{
        .display = .flex,
        .flex_direction = .column,
    };

    /// Flexbox row layout
    pub const flexRow = Style{
        .display = .flex,
        .flex_direction = .row,
    };

    /// Flexbox with space between
    pub const flexSpaceBetween = Style{
        .display = .flex,
        .justify_content = .space_between,
        .align_items = .center,
    };

    /// Grid center alignment
    pub const gridCenter = Style{
        .display = .grid,
        .place_items = .center,
    };

    /// Absolute fill parent
    pub const absoluteFill = Style{
        .position = .absolute,
        .inset = .zero,
    };

    /// Fixed fill viewport
    pub const fixedFill = Style{
        .position = .fixed,
        .inset = .zero,
    };

    /// Visually hidden but accessible
    pub const srOnly = Style{
        .position = .absolute,
        .width = .{ .px = 1 },
        .height = .{ .px = 1 },
        .padding = .{ .all = .zero },
        .margin = .{ .all = .{ .px = -1 } },
        .overflow = .hidden,
        .clip_path = "inset(50%)",
        .white_space = .nowrap,
        .border_width = .zero,
    };

    /// Truncate text with ellipsis
    pub const truncate = Style{
        .overflow = .hidden,
        .text_overflow = .ellipsis,
        .white_space = .nowrap,
    };

    /// Reset button styles
    pub const buttonReset = Style{
        .background = .{ .color = Color.transparent },
        .border = Border.none,
        .padding = .{ .all = .zero },
        .cursor = .pointer,
        .font_family = "inherit",
        .font_size = .inherit,
    };

    /// Reset list styles
    pub const listReset = Style{
        .list_style = "none",
        .margin = .{ .all = .zero },
        .padding = .{ .all = .zero },
    };
};

// Tests
test "Module exports" {
    // Verify all exports are accessible
    _ = Style{};
    _ = Color.black;
    _ = Length{ .px = 10 };
    _ = Display.flex;
    _ = DefaultTheme.colors.primary;
    _ = Keyframes.fadeIn();
    _ = presets.flexCenter;
}

test "Convenience functions" {
    const l = px(16);
    try std.testing.expectEqual(Length{ .px = 16 }, l);

    const c = hex("#ff0000");
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 0), c.g);

    const d = ms(300);
    try std.testing.expectEqual(Duration{ .ms = 300 }, d);
}

test "Complete workflow" {
    const allocator = std.testing.allocator;

    // Create a stylesheet
    var sheet = createStylesheet(allocator);
    defer sheet.deinit();

    // Add CSS custom properties
    try sheet.addCustomProperty("primary", "#3b82f6");
    try sheet.addCustomProperty("spacing", "1rem");

    // Add keyframes
    try sheet.addKeyframes(Keyframes.fadeIn());

    // Add component styles
    try sheet.addRule(".btn", Style{
        .display = .inline_flex,
        .padding = .{ .vertical_horizontal = .{ .vertical = px(12), .horizontal = px(24) } },
        .background_color = hex("#3b82f6"),
        .color = Color.white,
        .border_radius = .{ .all = px(8) },
        .cursor = .pointer,
        .transition = Transitions.interactive(),
    });

    // Add hover state
    try sheet.addRule(".btn:hover", Style{
        .background_color = hex("#2563eb"),
    });

    // Add responsive styles
    try sheet.addMediaRule(.{
        .query = Breakpoints.mobile(),
        .styles = &[_]MediaRule.SelectorStyle{
            .{
                .selector = ".btn",
                .style = .{
                    .width = .{ .percent = 100 },
                },
            },
        },
    });

    // Generate CSS
    const css = try sheet.toCss();
    defer allocator.free(css);

    try std.testing.expect(css.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, css, ".btn{") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "@keyframes fadeIn") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "@media") != null);
}
