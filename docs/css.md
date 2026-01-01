# CSS-in-Zig

Engine12 provides a type-safe, programmatic CSS generation system that allows you to write CSS directly in Zig code. This approach offers compile-time validation, reusable design tokens, and eliminates the need for external CSS preprocessors.

## Overview

The CSS-in-Zig system provides:

- **Type-safe CSS properties** - All CSS properties are validated at compile time
- **Design tokens** - Define colors, spacing, and typography as Zig constants
- **Keyframe animations** - Define CSS animations programmatically
- **Media queries** - Responsive styles with the `MediaRuleBuilder`
- **Component-based styling** - Reusable style patterns
- **Zero runtime overhead** - CSS is generated at build or request time

## Quick Start

```zig
const std = @import("std");
const E12 = @import("engine12");
const css = E12.css;

pub fn generateStyles(allocator: std.mem.Allocator) ![]const u8 {
    var sheet = css.Stylesheet.init(allocator);
    defer sheet.deinit();

    // Add CSS custom properties (CSS variables)
    try sheet.addCustomProperty("primary-color", "#4a9eff");
    try sheet.addCustomProperty("text-color", "#e0e0e0");

    // Add a style rule
    try sheet.addRule("body", .{
        .font_family = "-apple-system, sans-serif",
        .background_color = css.Color.fromHex("#0f0f0f"),
        .color = css.Color.fromHex("#e0e0e0"),
        .margin = .{ .all = .zero },
        .padding = .{ .all = css.rem(2) },
    });

    // Add a button style
    try sheet.addRule(".btn", .{
        .display = .inline_block,
        .padding = .{ .vertical_horizontal = .{
            .vertical = css.rem(0.75),
            .horizontal = css.rem(1.5),
        }},
        .background_color = css.Color.fromHex("#4a9eff"),
        .color = css.Color.white,
        .border_radius = .{ .all = css.px(8) },
        .cursor = .pointer,
        .transition_property = "all",
        .transition_duration = .{ .ms = 200 },
    });

    // Add hover state
    try sheet.addRule(".btn:hover", .{
        .background_color = css.Color.fromHex("#5baaff"),
        .transform = .{ .translateY = .{ .px = -2 } },
    });

    return try sheet.toCss();
}
```

## Core Types

### `css.Stylesheet`

The main container for CSS rules, keyframes, and media queries.

```zig
var sheet = css.Stylesheet.init(allocator);
defer sheet.deinit();

// Add rules
try sheet.addRule("selector", .{ .display = .flex });

// Add custom properties (CSS variables)
try sheet.addCustomProperty("name", "value");

// Add keyframes
try sheet.addKeyframes(myKeyframes);

// Add media rules
try sheet.addMediaRuleFromBuilder(&builder);

// Generate CSS
const css_output = try sheet.toCss();
const minified = try sheet.toMinifiedCss();
```

### `css.Style`

Represents a complete CSS rule with all properties. All fields are optional - only set properties are rendered.

```zig
const style = css.Style{
    // Layout
    .display = .flex,
    .position = .relative,
    .flex_direction = .column,
    .justify_content = .center,
    .align_items = .center,
    
    // Box Model
    .width = .{ .percent = 100 },
    .height = .{ .px = 200 },
    .padding = .{ .all = css.rem(1) },
    .margin = .{ .vertical_horizontal = .{
        .vertical = .zero,
        .horizontal = .auto,
    }},
    
    // Typography
    .font_family = "Inter, sans-serif",
    .font_size = css.rem(1.125),
    .font_weight = .{ .numeric = 600 },
    .line_height = .{ .number = 1.5 },
    .color = css.Color.fromHex("#333"),
    
    // Background & Border
    .background_color = css.Color.fromHex("#fff"),
    .border = css.Border{
        .width = .{ .px = 1 },
        .style = .solid,
        .color = css.Color.fromHex("#ddd"),
    },
    .border_radius = .{ .all = css.px(8) },
    
    // Effects
    .box_shadow = css.BoxShadow{
        .x = .zero,
        .y = .{ .px = 4 },
        .blur = .{ .px = 12 },
        .color = css.Color.rgba(0, 0, 0, 0.1),
    },
    .opacity = .{ .value = 0.9 },
    
    // Transitions & Animations
    .transition_property = "all",
    .transition_duration = .{ .ms = 200 },
    .animation = "fadeIn 0.3s ease-out",
};
```

### `css.Color`

Represents an RGBA color with various construction methods.

```zig
// From hex string (comptime)
const primary = css.Color.fromHex("#4a9eff");
const with_alpha = css.Color.fromHex("#4a9eff80");

// RGB/RGBA constructors
const red = css.Color.rgb(255, 0, 0);
const transparent_blue = css.Color.rgba(0, 0, 255, 0.5);

// Named colors
const white = css.Color.white;
const black = css.Color.black;
const transparent = css.Color.transparent;

// Color manipulation
const lighter = primary.lighten(0.2);  // 20% lighter
const darker = primary.darken(0.2);    // 20% darker
const faded = primary.withAlpha(0.5);  // 50% opacity
```

### `css.Length`

Represents CSS length values with various units.

```zig
// Convenience functions
const pixels = css.px(16);
const rems = css.rem(1.5);
const ems = css.em(2);
const percent = css.percent(100);

// Direct construction
const vh = css.Length{ .vh = 100 };
const vw = css.Length{ .vw = 50 };
const auto = css.Length.auto;
const zero = css.Length.zero;
```

### `css.Keyframes`

Define CSS keyframe animations.

```zig
pub fn fadeInKeyframes() css.Keyframes {
    return .{
        .name = "fadeIn",
        .frames = &[_]css.Keyframes.Frame{
            .{
                .position = .from,
                .style = .{
                    .opacity = .{ .value = 0 },
                    .transform = .{ .translateY = .{ .px = 10 } },
                },
            },
            .{
                .position = .to,
                .style = .{
                    .opacity = .{ .value = 1 },
                    .transform = .{ .translateY = .zero },
                },
            },
        },
    };
}

// Add to stylesheet
try sheet.addKeyframes(fadeInKeyframes());
```

### `css.MediaRuleBuilder`

Build responsive media queries with runtime-allocated styles (recommended approach).

```zig
// Create a media rule builder for mobile styles
var mobile = sheet.mediaRule(.{ .max_width = 640 });

// Add styles one by one
try mobile.addStyle("body", .{
    .padding = .{ .all = css.rem(1) },
});

try mobile.addStyle(".container", .{
    .flex_direction = .column,
});

try mobile.addStyle(".sidebar", .{
    .display = .none,
});

// Add the completed media rule to the stylesheet
try sheet.addMediaRuleFromBuilder(&mobile);
```

#### Available Media Query Types

```zig
// Viewport size
.{ .max_width = 640 }     // @media (max-width: 640px)
.{ .min_width = 768 }     // @media (min-width: 768px)
.{ .max_height = 800 }    // @media (max-height: 800px)
.{ .min_height = 600 }    // @media (min-height: 600px)

// Color scheme preference
.{ .prefers_color_scheme = .dark }   // @media (prefers-color-scheme: dark)
.{ .prefers_color_scheme = .light }  // @media (prefers-color-scheme: light)

// Motion preference
.{ .prefers_reduced_motion = .reduce }  // @media (prefers-reduced-motion: reduce)

// Device capabilities
.{ .hover = .hover }      // @media (hover: hover) - mouse/trackpad
.{ .hover = .none }       // @media (hover: none) - touch devices
.{ .pointer = .fine }     // @media (pointer: fine) - precise pointer
.{ .pointer = .coarse }   // @media (pointer: coarse) - touch/stylus

// Print styles
.print                    // @media print
```

#### Breakpoint Helpers

```zig
const Breakpoints = css.Breakpoints;

// Predefined breakpoints
Breakpoints.mobile()   // max-width: 639px
Breakpoints.tablet()   // min-width: 640px and max-width: 1023px
Breakpoints.desktop()  // min-width: 1024px

// Custom breakpoints
Breakpoints.up(768)    // min-width: 768px
Breakpoints.down(1024) // max-width: 1023px

// Combine queries
Breakpoints.darkMode()
Breakpoints.reducedMotion()
Breakpoints.retina()
```

## Design Tokens

Define your design system as Zig constants for type-safe, reusable styling.

```zig
// Color tokens
pub const colors = struct {
    pub const bg_primary = css.Color.fromHex("#0f0f0f");
    pub const bg_secondary = css.Color.fromHex("#1a1a1a");
    pub const text_primary = css.Color.fromHex("#e0e0e0");
    pub const text_secondary = css.Color.fromHex("#a0a0a0");
    pub const accent = css.Color.fromHex("#4a9eff");
    pub const success = css.Color.fromHex("#4ade80");
    pub const error_color = css.Color.fromHex("#f87171");
    pub const warning = css.Color.fromHex("#fbbf24");
};

// Spacing tokens
pub const spacing = struct {
    pub const xs = css.px(4);
    pub const sm = css.px(8);
    pub const md = css.px(16);
    pub const lg = css.px(24);
    pub const xl = css.px(32);
};

// Border radius tokens
pub const radii = struct {
    pub const sm = css.px(4);
    pub const md = css.px(8);
    pub const lg = css.px(12);
    pub const full = css.px(9999);
};

// Shadow presets
pub const shadows = struct {
    pub const card = css.BoxShadow{
        .x = .zero,
        .y = .{ .px = 2 },
        .blur = .{ .px = 8 },
        .color = css.Color.rgba(0, 0, 0, 0.2),
    };
};
```

Usage:

```zig
try sheet.addRule(".card", .{
    .background_color = colors.bg_secondary,
    .padding = .{ .all = spacing.md },
    .border_radius = .{ .all = radii.md },
    .box_shadow = shadows.card,
    .color = colors.text_primary,
});
```

## Serving Generated CSS

### HTTP Handler

Create a handler to serve the generated CSS:

```zig
const std = @import("std");
const E12 = @import("engine12");
const styles = @import("styles.zig");

pub fn handleCss(_: *E12.Request) E12.Response {
    const allocator = std.heap.page_allocator;

    const css_content = styles.generateCss(allocator) catch {
        return E12.Response.text("/* Error generating CSS */").withStatus(500);
    };

    var resp = E12.Response.text(css_content);
    resp = resp.withContentType("text/css; charset=utf-8");
    resp = resp.withHeader("Cache-Control", "public, max-age=3600");
    return resp;
}
```

### Route Registration

Register the CSS route in your main application:

```zig
try app.get("/css/style.css", handleCss);
```

### HTML Integration

Reference the generated CSS in your HTML:

```html
<link rel="stylesheet" href="/css/style.css">
```

## Complete Example

See the [Todo App Example](../examples/todo/src/styles.zig) for a complete implementation demonstrating:

- Design token definitions
- Keyframe animations
- Component styles
- Responsive media queries
- CSS custom properties

Example structure:

```
examples/todo/src/
├── styles.zig          # CSS definitions using Engine12 CSS API
├── handlers/
│   └── css.zig         # HTTP handler serving generated CSS
└── main.zig            # Route registration
```

## API Reference

### Stylesheet Methods

| Method | Description |
|--------|-------------|
| `init(allocator)` | Create a new stylesheet |
| `deinit()` | Free all allocated memory |
| `addRule(selector, style)` | Add a CSS rule |
| `addCustomProperty(name, value)` | Add a CSS variable to `:root` |
| `addScopedCustomProperty(selector, name, value)` | Add a scoped CSS variable |
| `addKeyframes(keyframes)` | Add a keyframe animation |
| `addMediaRule(rule)` | Add a media query rule (comptime) |
| `mediaRule(query)` | Create a MediaRuleBuilder |
| `addMediaRuleFromBuilder(builder)` | Add a media rule from builder |
| `toCss()` | Generate CSS string |
| `toMinifiedCss()` | Generate minified CSS string |

### Style Properties

The `Style` struct supports all common CSS properties:

**Layout**: `display`, `position`, `top`, `right`, `bottom`, `left`, `z_index`, `float`, `clear`

**Box Model**: `width`, `height`, `min_width`, `min_height`, `max_width`, `max_height`, `margin`, `padding`, `box_sizing`

**Flexbox**: `flex_direction`, `flex_wrap`, `justify_content`, `align_items`, `align_content`, `align_self`, `flex`, `flex_grow`, `flex_shrink`, `flex_basis`, `gap`

**Grid**: `grid_template_columns`, `grid_template_rows`, `grid_column`, `grid_row`, `grid_area`

**Typography**: `font_family`, `font_size`, `font_weight`, `font_style`, `line_height`, `letter_spacing`, `text_align`, `text_decoration`, `text_transform`, `color`

**Background**: `background_color`, `background_image`, `background_size`, `background_position`, `background_repeat`

**Border**: `border`, `border_top`, `border_right`, `border_bottom`, `border_left`, `border_radius`, `border_color`, `border_style`, `border_width`

**Effects**: `box_shadow`, `opacity`, `visibility`, `filter`, `backdrop_filter`, `transform`

**Transitions & Animations**: `transition`, `transition_property`, `transition_duration`, `animation`, `animation_name`, `animation_duration`

**Interaction**: `cursor`, `pointer_events`, `user_select`, `overflow`, `overflow_x`, `overflow_y`

## Best Practices

1. **Use design tokens** - Define colors, spacing, and typography as constants for consistency
2. **Use MediaRuleBuilder** - For responsive styles, use the builder pattern to avoid comptime memory issues
3. **Organize by component** - Group related styles together
4. **Cache generated CSS** - In production, cache the generated CSS at startup
5. **Use meaningful selectors** - Follow consistent naming conventions (BEM, etc.)

## Migration from Static CSS

To migrate from static CSS files:

1. Create a `styles.zig` file in your project
2. Define your design tokens (colors, spacing, etc.)
3. Translate CSS rules to `sheet.addRule()` calls
4. Translate keyframes to `Keyframes` structs
5. Use `MediaRuleBuilder` for responsive styles
6. Create an HTTP handler to serve the generated CSS
7. Update HTML to reference the new CSS route
