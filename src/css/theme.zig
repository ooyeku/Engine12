const std = @import("std");
const values = @import("values.zig");

pub const Color = values.Color;
pub const Length = values.Length;
pub const BoxShadow = values.BoxShadow;
pub const Duration = values.Duration;

/// Design token system for consistent theming
pub fn Theme(comptime config: ThemeConfig) type {
    return struct {
        pub const colors = config.colors;
        pub const spacing = config.spacing;
        pub const typography = config.typography;
        pub const borders = config.borders;
        pub const shadows = config.shadows;
        pub const breakpoints = config.breakpoints;
        pub const transitions = config.transitions;
        pub const z_indices = config.z_indices;

        /// Get a color by name
        pub fn color(comptime name: []const u8) Color {
            return @field(colors, name);
        }

        /// Get spacing value
        pub fn space(comptime level: usize) Length {
            if (level >= spacing.scale.len) {
                return spacing.scale[spacing.scale.len - 1];
            }
            return spacing.scale[level];
        }

        /// Get font size
        pub fn fontSize(comptime name: []const u8) Length {
            return @field(typography.sizes, name);
        }

        /// Get font family
        pub fn fontFamily(comptime name: []const u8) []const u8 {
            return @field(typography.families, name);
        }

        /// Get border radius
        pub fn radius(comptime name: []const u8) Length {
            return @field(borders.radii, name);
        }

        /// Get shadow preset
        pub fn shadow(comptime name: []const u8) BoxShadow {
            return @field(shadows, name);
        }

        /// Get breakpoint value
        pub fn breakpoint(comptime name: []const u8) u32 {
            return @field(breakpoints, name);
        }

        /// Get transition duration
        pub fn transition(comptime name: []const u8) Duration {
            return @field(transitions, name);
        }

        /// Get z-index value
        pub fn zIndex(comptime name: []const u8) i32 {
            return @field(z_indices, name);
        }
    };
}

/// Theme configuration structure
pub const ThemeConfig = struct {
    colors: ColorTokens = .{},
    spacing: SpacingTokens = .{},
    typography: TypographyTokens = .{},
    borders: BorderTokens = .{},
    shadows: ShadowTokens = .{},
    breakpoints: BreakpointTokens = .{},
    transitions: TransitionTokens = .{},
    z_indices: ZIndexTokens = .{},
};

/// Color design tokens
pub const ColorTokens = struct {
    // Primary palette
    primary: Color = Color.fromHex("#3b82f6"),
    primary_light: Color = Color.fromHex("#60a5fa"),
    primary_dark: Color = Color.fromHex("#2563eb"),
    primary_contrast: Color = Color.white,

    // Secondary palette
    secondary: Color = Color.fromHex("#64748b"),
    secondary_light: Color = Color.fromHex("#94a3b8"),
    secondary_dark: Color = Color.fromHex("#475569"),
    secondary_contrast: Color = Color.white,

    // Accent palette
    accent: Color = Color.fromHex("#8b5cf6"),
    accent_light: Color = Color.fromHex("#a78bfa"),
    accent_dark: Color = Color.fromHex("#7c3aed"),
    accent_contrast: Color = Color.white,

    // Semantic colors
    success: Color = Color.fromHex("#10b981"),
    success_light: Color = Color.fromHex("#34d399"),
    success_dark: Color = Color.fromHex("#059669"),

    warning: Color = Color.fromHex("#f59e0b"),
    warning_light: Color = Color.fromHex("#fbbf24"),
    warning_dark: Color = Color.fromHex("#d97706"),

    danger: Color = Color.fromHex("#ef4444"),
    danger_light: Color = Color.fromHex("#f87171"),
    danger_dark: Color = Color.fromHex("#dc2626"),

    info: Color = Color.fromHex("#06b6d4"),
    info_light: Color = Color.fromHex("#22d3ee"),
    info_dark: Color = Color.fromHex("#0891b2"),

    // Neutral colors
    background: Color = Color.white,
    surface: Color = Color.fromHex("#f8fafc"),
    surface_alt: Color = Color.fromHex("#f1f5f9"),

    text: Color = Color.fromHex("#1e293b"),
    text_secondary: Color = Color.fromHex("#64748b"),
    text_muted: Color = Color.fromHex("#94a3b8"),
    text_inverse: Color = Color.white,

    border: Color = Color.fromHex("#e2e8f0"),
    border_focus: Color = Color.fromHex("#3b82f6"),

    // Overlay
    overlay: Color = Color.rgba(0, 0, 0, 0.5),
    overlay_light: Color = Color.rgba(255, 255, 255, 0.8),
};

/// Spacing design tokens
pub const SpacingTokens = struct {
    scale: []const Length = &[_]Length{
        .zero, // 0
        .{ .rem = 0.25 }, // 1: 4px
        .{ .rem = 0.5 }, // 2: 8px
        .{ .rem = 0.75 }, // 3: 12px
        .{ .rem = 1 }, // 4: 16px
        .{ .rem = 1.25 }, // 5: 20px
        .{ .rem = 1.5 }, // 6: 24px
        .{ .rem = 2 }, // 7: 32px
        .{ .rem = 2.5 }, // 8: 40px
        .{ .rem = 3 }, // 9: 48px
        .{ .rem = 4 }, // 10: 64px
        .{ .rem = 5 }, // 11: 80px
        .{ .rem = 6 }, // 12: 96px
        .{ .rem = 8 }, // 13: 128px
        .{ .rem = 10 }, // 14: 160px
        .{ .rem = 12 }, // 15: 192px
        .{ .rem = 16 }, // 16: 256px
    },

    // Named spacing
    none: Length = .zero,
    xs: Length = .{ .rem = 0.25 },
    sm: Length = .{ .rem = 0.5 },
    md: Length = .{ .rem = 1 },
    lg: Length = .{ .rem = 1.5 },
    xl: Length = .{ .rem = 2 },
    xxl: Length = .{ .rem = 3 },
};

/// Typography design tokens
pub const TypographyTokens = struct {
    families: FontFamilies = .{},
    sizes: FontSizes = .{},
    weights: FontWeights = .{},
    line_heights: LineHeights = .{},
    letter_spacings: LetterSpacings = .{},

    pub const FontFamilies = struct {
        sans: []const u8 = "ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, \"Helvetica Neue\", Arial, sans-serif",
        serif: []const u8 = "ui-serif, Georgia, Cambria, \"Times New Roman\", Times, serif",
        mono: []const u8 = "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, \"Liberation Mono\", \"Courier New\", monospace",
    };

    pub const FontSizes = struct {
        xs: Length = .{ .rem = 0.75 }, // 12px
        sm: Length = .{ .rem = 0.875 }, // 14px
        base: Length = .{ .rem = 1 }, // 16px
        lg: Length = .{ .rem = 1.125 }, // 18px
        xl: Length = .{ .rem = 1.25 }, // 20px
        xxl: Length = .{ .rem = 1.5 }, // 24px
        xxxl: Length = .{ .rem = 1.875 }, // 30px
        display_sm: Length = .{ .rem = 2.25 }, // 36px
        display_md: Length = .{ .rem = 3 }, // 48px
        display_lg: Length = .{ .rem = 3.75 }, // 60px
        display_xl: Length = .{ .rem = 4.5 }, // 72px
    };

    pub const FontWeights = struct {
        thin: u16 = 100,
        extra_light: u16 = 200,
        light: u16 = 300,
        normal: u16 = 400,
        medium: u16 = 500,
        semi_bold: u16 = 600,
        bold: u16 = 700,
        extra_bold: u16 = 800,
        black: u16 = 900,
    };

    pub const LineHeights = struct {
        none: f32 = 1,
        tight: f32 = 1.25,
        snug: f32 = 1.375,
        normal: f32 = 1.5,
        relaxed: f32 = 1.625,
        loose: f32 = 2,
    };

    pub const LetterSpacings = struct {
        tighter: Length = .{ .em = -0.05 },
        tight: Length = .{ .em = -0.025 },
        normal: Length = .zero,
        wide: Length = .{ .em = 0.025 },
        wider: Length = .{ .em = 0.05 },
        widest: Length = .{ .em = 0.1 },
    };
};

/// Border design tokens
pub const BorderTokens = struct {
    widths: BorderWidths = .{},
    radii: BorderRadii = .{},

    pub const BorderWidths = struct {
        none: Length = .zero,
        thin: Length = .{ .px = 1 },
        medium: Length = .{ .px = 2 },
        thick: Length = .{ .px = 4 },
    };

    pub const BorderRadii = struct {
        none: Length = .zero,
        sm: Length = .{ .rem = 0.125 }, // 2px
        md: Length = .{ .rem = 0.25 }, // 4px
        lg: Length = .{ .rem = 0.375 }, // 6px
        xl: Length = .{ .rem = 0.5 }, // 8px
        xxl: Length = .{ .rem = 0.75 }, // 12px
        xxxl: Length = .{ .rem = 1 }, // 16px
        full: Length = .{ .px = 9999 },
    };
};

/// Shadow design tokens
pub const ShadowTokens = struct {
    none: BoxShadow = BoxShadow.none,
    sm: BoxShadow = BoxShadow.sm,
    md: BoxShadow = BoxShadow.md,
    lg: BoxShadow = BoxShadow.lg,
    xl: BoxShadow = BoxShadow.xl,
    xxl: BoxShadow = BoxShadow.xxl,
    inner: BoxShadow = BoxShadow.inner,
};

/// Breakpoint design tokens
pub const BreakpointTokens = struct {
    xs: u32 = 0,
    sm: u32 = 640,
    md: u32 = 768,
    lg: u32 = 1024,
    xl: u32 = 1280,
    xxl: u32 = 1536,
};

/// Transition design tokens
pub const TransitionTokens = struct {
    none: Duration = .{ .ms = 0 },
    fast: Duration = .{ .ms = 75 },
    normal: Duration = .{ .ms = 150 },
    slow: Duration = .{ .ms = 300 },
    slower: Duration = .{ .ms = 500 },
    slowest: Duration = .{ .ms = 700 },
};

/// Z-index design tokens
pub const ZIndexTokens = struct {
    hide: i32 = -1,
    base: i32 = 0,
    dropdown: i32 = 1000,
    sticky: i32 = 1100,
    fixed: i32 = 1200,
    modal_backdrop: i32 = 1300,
    modal: i32 = 1400,
    popover: i32 = 1500,
    tooltip: i32 = 1600,
};

/// Default theme instance
pub const DefaultTheme = Theme(.{});

/// Dark theme preset
pub const DarkThemeConfig = ThemeConfig{
    .colors = .{
        .background = Color.fromHex("#0f172a"),
        .surface = Color.fromHex("#1e293b"),
        .surface_alt = Color.fromHex("#334155"),
        .text = Color.fromHex("#f1f5f9"),
        .text_secondary = Color.fromHex("#94a3b8"),
        .text_muted = Color.fromHex("#64748b"),
        .border = Color.fromHex("#334155"),
    },
};

pub const DarkTheme = Theme(DarkThemeConfig);

/// Create a custom theme by extending the default
pub fn extendTheme(comptime overrides: ThemeConfig) type {
    return Theme(.{
        .colors = mergeColors(ColorTokens{}, overrides.colors),
        .spacing = overrides.spacing,
        .typography = overrides.typography,
        .borders = overrides.borders,
        .shadows = overrides.shadows,
        .breakpoints = overrides.breakpoints,
        .transitions = overrides.transitions,
        .z_indices = overrides.z_indices,
    });
}

fn mergeColors(comptime base: ColorTokens, comptime overrides: ColorTokens) ColorTokens {
    var result = base;
    inline for (@typeInfo(ColorTokens).@"struct".fields) |field| {
        const override_value = @field(overrides, field.name);
        const default_value = @field(ColorTokens{}, field.name);
        // Check if override is different from default
        if (!colorEquals(override_value, default_value)) {
            @field(result, field.name) = override_value;
        }
    }
    return result;
}

fn colorEquals(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

// Tests
test "Theme color access" {
    const T = Theme(.{});
    const primary = T.color("primary");
    try std.testing.expectEqual(@as(u8, 59), primary.r);
}

test "Theme spacing access" {
    const T = Theme(.{});
    const spacing = T.space(4);
    try std.testing.expectEqual(Length{ .rem = 1 }, spacing);
}

test "Dark theme colors" {
    const bg = DarkTheme.colors.background;
    try std.testing.expectEqual(@as(u8, 15), bg.r);
}
