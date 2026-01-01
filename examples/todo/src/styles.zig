//! Todo App Styles - Using Engine12's CSS-in-Zig API
//! This file generates the same styles as static/css/style.css but using Engine12's type-safe CSS system.
const std = @import("std");
const E12 = @import("engine12");
const css = E12.css;

// Re-export key types for convenience
pub const Style = css.Style;
pub const Stylesheet = css.Stylesheet;
pub const Color = css.Color;
pub const Length = css.Length;
pub const MediaQuery = css.MediaQuery;
pub const MediaRule = css.MediaRule;
pub const Keyframes = css.Keyframes;
pub const Breakpoints = css.Breakpoints;
pub const BoxShadow = css.BoxShadow;
pub const Border = css.Border;

// ============================================================================
// COLOR TOKENS - Dark Theme
// ============================================================================
pub const colors = struct {
    pub const bg_primary = Color.fromHex("#0f0f0f");
    pub const bg_secondary = Color.fromHex("#1a1a1a");
    pub const bg_tertiary = Color.fromHex("#252525");
    pub const text_primary = Color.fromHex("#e0e0e0");
    pub const text_secondary = Color.fromHex("#a0a0a0");
    pub const accent = Color.fromHex("#4a9eff");
    pub const accent_hover = Color.fromHex("#5baaff");
    pub const border = Color.fromHex("#2a2a2a");
    pub const success = Color.fromHex("#4ade80");
    pub const error_color = Color.fromHex("#f87171");
    pub const warning = Color.fromHex("#fbbf24");
    pub const shadow = Color.rgba(0, 0, 0, 0.3);
};

// ============================================================================
// SPACING TOKENS
// ============================================================================
pub const spacing = struct {
    pub const xs = css.px(4);
    pub const sm = css.px(8);
    pub const md = css.px(16);
    pub const lg = css.px(24);
    pub const xl = css.px(32);
    pub const xxl = css.px(48);
};

// ============================================================================
// BORDER RADIUS TOKENS
// ============================================================================
pub const radii = struct {
    pub const sm = css.px(4);
    pub const md = css.px(8);
    pub const lg = css.px(12);
};

// ============================================================================
// CUSTOM KEYFRAME ANIMATIONS
// ============================================================================
pub fn fadeInKeyframes() Keyframes {
    return .{
        .name = "fadeIn",
        .frames = &[_]Keyframes.Frame{
            .{ .position = .from, .style = .{
                .opacity = .{ .value = 0 },
                .transform = .{ .translateY = .{ .px = 10 } },
            } },
            .{ .position = .to, .style = .{
                .opacity = .{ .value = 1 },
                .transform = .{ .translateY = .zero },
            } },
        },
    };
}

pub fn fadeOutKeyframes() Keyframes {
    return .{
        .name = "fadeOut",
        .frames = &[_]Keyframes.Frame{
            .{ .position = .from, .style = .{
                .opacity = .{ .value = 1 },
                .transform = .{ .translateY = .zero },
            } },
            .{ .position = .to, .style = .{
                .opacity = .{ .value = 0 },
                .transform = .{ .translateY = .{ .px = -10 } },
            } },
        },
    };
}

pub fn slideDownKeyframes() Keyframes {
    return .{
        .name = "slideDown",
        .frames = &[_]Keyframes.Frame{
            .{ .position = .from, .style = .{
                .opacity = .{ .value = 0 },
                .transform = .{ .translateY = .{ .px = -10 } },
            } },
            .{ .position = .to, .style = .{
                .opacity = .{ .value = 1 },
                .transform = .{ .translateY = .zero },
            } },
        },
    };
}

pub fn slideInKeyframes() Keyframes {
    return .{
        .name = "slideIn",
        .frames = &[_]Keyframes.Frame{
            .{ .position = .from, .style = .{
                .opacity = .{ .value = 0 },
                .transform = .{ .translateX = .{ .px = 400 } },
            } },
            .{ .position = .to, .style = .{
                .opacity = .{ .value = 1 },
                .transform = .{ .translateX = .zero },
            } },
        },
    };
}

// ============================================================================
// SHADOW PRESETS
// ============================================================================
pub const shadows = struct {
    pub const card = BoxShadow{
        .x = .zero,
        .y = .{ .px = 2 },
        .blur = .{ .px = 8 },
        .color = colors.shadow,
    };
    pub const card_hover = BoxShadow{
        .x = .zero,
        .y = .{ .px = 4 },
        .blur = .{ .px = 12 },
        .color = colors.shadow,
    };
    pub const button = BoxShadow{
        .x = .zero,
        .y = .{ .px = 4 },
        .blur = .{ .px = 12 },
        .color = Color.rgba(74, 158, 255, 0.3),
    };
    pub const focus = BoxShadow{
        .x = .zero,
        .y = .zero,
        .blur = .zero,
        .spread = .{ .px = 3 },
        .color = Color.rgba(74, 158, 255, 0.2),
    };
};

// ============================================================================
// GENERATE COMPLETE STYLESHEET
// ============================================================================
pub fn generateStylesheet(allocator: std.mem.Allocator) !Stylesheet {
    var sheet = Stylesheet.init(allocator);
    errdefer sheet.deinit();

    // CSS Custom Properties (CSS Variables)
    try sheet.addCustomProperty("bg-primary", "#0f0f0f");
    try sheet.addCustomProperty("bg-secondary", "#1a1a1a");
    try sheet.addCustomProperty("bg-tertiary", "#252525");
    try sheet.addCustomProperty("text-primary", "#e0e0e0");
    try sheet.addCustomProperty("text-secondary", "#a0a0a0");
    try sheet.addCustomProperty("accent", "#4a9eff");
    try sheet.addCustomProperty("accent-hover", "#5baaff");
    try sheet.addCustomProperty("border", "#2a2a2a");
    try sheet.addCustomProperty("success", "#4ade80");
    try sheet.addCustomProperty("error", "#f87171");
    try sheet.addCustomProperty("shadow", "rgba(0, 0, 0, 0.3)");

    // Add keyframes
    try sheet.addKeyframes(fadeInKeyframes());
    try sheet.addKeyframes(fadeOutKeyframes());
    try sheet.addKeyframes(slideDownKeyframes());
    try sheet.addKeyframes(slideInKeyframes());

    // ========== RESET STYLES ==========
    try sheet.addRule("*", .{
        .margin = .{ .all = .zero },
        .padding = .{ .all = .zero },
        .box_sizing = .border_box,
    });

    // ========== BODY STYLES ==========
    try sheet.addRule("body", .{
        .font_family = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif",
        .background_color = colors.bg_primary,
        .color = colors.text_primary,
        .line_height = .{ .number = 1.6 },
        .min_height = .{ .vh = 100 },
        .padding = .{ .vertical_horizontal = .{ .vertical = css.rem(2), .horizontal = css.rem(1) } },
    });

    // ========== CONTAINER ==========
    try sheet.addRule(".container", .{
        .max_width = .{ .px = 800 },
        .margin = .{ .vertical_horizontal = .{ .vertical = .zero, .horizontal = .auto } },
    });

    // ========== HEADER ==========
    try sheet.addRule("header", .{
        .text_align = .center,
        .margin_bottom = css.rem(2),
    });

    try sheet.addRule("header h1", .{
        .font_size = css.rem(2.5),
        .font_weight = .{ .numeric = 700 },
        .margin_bottom = css.rem(0.5),
        .color = colors.accent,
    });

    try sheet.addRule(".subtitle", .{
        .color = colors.text_secondary,
        .font_size = css.rem(1),
    });

    // ========== TAB NAVIGATION ==========
    try sheet.addRule(".tab-navigation", .{
        .display = .flex,
        .gap = .{ .single = css.rem(0.5) },
        .margin_bottom = css.rem(2),
        .padding = .{ .all = css.rem(0.5) },
        .background_color = colors.bg_secondary,
        .border_radius = .{ .all = radii.lg },
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .overflow = .auto,
    });

    try sheet.addRule(".tab-btn", .{
        .flex_grow = 1,
        .min_width = .{ .px = 120 },
        .padding = .{ .vertical_horizontal = .{ .vertical = css.rem(0.875), .horizontal = css.rem(1.5) } },
        .background_color = Color.transparent,
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = Color.transparent },
        .border_radius = .{ .all = radii.md },
        .color = colors.text_secondary,
        .font_size = css.rem(0.9375),
        .font_weight = .{ .numeric = 500 },
        .cursor = .pointer,
        .transition_property = "all",
        .transition_duration = .{ .ms = 200 },
        .white_space = .nowrap,
        .font_family = "inherit",
    });

    try sheet.addRule(".tab-btn:hover", .{
        .background_color = colors.bg_tertiary,
        .color = colors.text_primary,
    });

    try sheet.addRule(".tab-btn.active", .{
        .background_color = colors.accent,
        .color = Color.white,
        .border_color = colors.accent,
        .box_shadow = shadows.button,
    });

    try sheet.addRule(".tab-btn:focus", .{
        .outline_style = .none,
        .box_shadow = shadows.focus,
    });

    // ========== PAGE CONTAINERS ==========
    try sheet.addRule(".page-container", .{
        .display = .none,
        .animation = "fadeIn 0.3s ease-in-out",
    });

    try sheet.addRule(".page-container.active", .{
        .display = .block,
    });

    try sheet.addRule(".page-container.fade-out", .{
        .animation = "fadeOut 0.2s ease-in-out",
    });

    // ========== STATS BAR ==========
    try sheet.addRule(".stats-bar", .{
        .display = .grid,
        .grid_template_columns = "repeat(auto-fit, minmax(120px, 1fr))",
        .gap = .{ .single = css.rem(1) },
        .margin_bottom = css.rem(2),
        .padding = .{ .all = css.rem(1.5) },
        .background_color = colors.bg_secondary,
        .border_radius = .{ .all = radii.lg },
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .box_shadow = shadows.card,
    });

    try sheet.addRule(".stat", .{
        .text_align = .center,
    });

    try sheet.addRule(".stat-label", .{
        .display = .block,
        .font_size = css.rem(0.875),
        .color = colors.text_secondary,
        .margin_bottom = css.rem(0.5),
        .text_transform = .uppercase,
        .letter_spacing = .{ .px = 0.5 },
    });

    try sheet.addRule(".stat-value", .{
        .display = .block,
        .font_size = css.rem(1.5),
        .font_weight = .{ .numeric = 600 },
        .color = colors.text_primary,
    });

    // ========== BUTTONS ==========
    try sheet.addRule(".btn", .{
        .padding = .{ .vertical_horizontal = .{ .vertical = css.rem(0.875), .horizontal = css.rem(1.5) } },
        .border = Border.none,
        .border_radius = .{ .all = radii.md },
        .font_size = css.rem(1),
        .font_weight = .{ .numeric = 500 },
        .cursor = .pointer,
        .transition_property = "all",
        .transition_duration = .{ .ms = 200 },
        .font_family = "inherit",
    });

    try sheet.addRule(".btn-primary", .{
        .background_color = colors.accent,
        .color = Color.white,
    });

    try sheet.addRule(".btn-primary:hover", .{
        .background_color = colors.accent_hover,
        .transform = .{ .translateY = .{ .px = -1 } },
        .box_shadow = shadows.button,
    });

    try sheet.addRule(".btn-primary:active", .{
        .transform = .{ .translateY = .zero },
    });

    try sheet.addRule(".btn-secondary", .{
        .padding = .{ .vertical_horizontal = .{ .vertical = css.rem(0.75), .horizontal = css.rem(1) } },
        .background_color = colors.bg_secondary,
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .border_radius = .{ .all = radii.md },
        .color = colors.text_secondary,
        .font_size = css.rem(0.875),
        .cursor = .pointer,
        .transition_property = "all",
        .transition_duration = .{ .ms = 200 },
    });

    try sheet.addRule(".btn-secondary:hover", .{
        .border_color = colors.accent,
        .color = colors.text_primary,
    });

    // ========== FILTERS ==========
    try sheet.addRule(".filters", .{
        .display = .flex,
        .gap = .{ .single = css.rem(0.5) },
        .margin_bottom = css.rem(1.5),
        .flex_wrap = .wrap,
    });

    try sheet.addRule(".filter-btn", .{
        .padding = .{ .vertical_horizontal = .{ .vertical = css.rem(0.5), .horizontal = css.rem(1) } },
        .background_color = colors.bg_secondary,
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .border_radius = .{ .all = radii.md },
        .color = colors.text_secondary,
        .font_size = css.rem(0.875),
        .cursor = .pointer,
        .transition_property = "all",
        .transition_duration = .{ .ms = 200 },
    });

    try sheet.addRule(".filter-btn:hover", .{
        .border_color = colors.accent,
        .color = colors.text_primary,
    });

    try sheet.addRule(".filter-btn.active", .{
        .background_color = colors.accent,
        .color = Color.white,
        .border_color = colors.accent,
    });

    // ========== TODO LIST ==========
    try sheet.addRule(".todo-list", .{
        .min_height = .{ .px = 200 },
    });

    try sheet.addRule(".todo-item", .{
        .padding = .{ .all = css.rem(1.5) },
        .margin_bottom = css.rem(1),
        .background_color = colors.bg_secondary,
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .border_radius = .{ .all = radii.lg },
        .box_shadow = shadows.card,
        .transition_property = "transform, box-shadow",
        .transition_duration = .{ .ms = 200 },
    });

    try sheet.addRule(".todo-item:hover", .{
        .transform = .{ .translateY = .{ .px = -2 } },
        .box_shadow = shadows.card_hover,
    });

    try sheet.addRule(".todo-item.completed", .{
        .opacity = .{ .value = 0.7 },
    });

    try sheet.addRule(".todo-header", .{
        .display = .flex,
        .align_items = .flex_start,
        .gap = .{ .single = css.rem(1) },
        .margin_bottom = css.rem(0.75),
    });

    try sheet.addRule(".todo-checkbox", .{
        .width = .{ .px = 24 },
        .height = .{ .px = 24 },
        .margin_top = .{ .px = 2 },
        .cursor = .pointer,
    });

    try sheet.addRule(".todo-title", .{
        .flex_grow = 1,
        .font_size = css.rem(1.125),
        .font_weight = .{ .numeric = 500 },
        .color = colors.text_primary,
    });

    try sheet.addRule(".todo-item.completed .todo-title", .{
        .text_decoration = .line_through,
        .color = colors.text_secondary,
    });

    try sheet.addRule(".todo-description", .{
        .margin_left = css.rem(2),
        .margin_bottom = css.rem(1),
        .color = colors.text_secondary,
        .font_size = css.rem(0.9375),
        .line_height = .{ .number = 1.5 },
    });

    try sheet.addRule(".todo-meta", .{
        .display = .flex,
        .justify_content = .space_between,
        .align_items = .center,
        .margin_top = css.rem(1),
        .padding_top = css.rem(1),
        .border_top = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .font_size = css.rem(0.875),
        .color = colors.text_secondary,
    });

    try sheet.addRule(".todo-actions", .{
        .display = .flex,
        .gap = .{ .single = css.rem(0.5) },
    });

    try sheet.addRule(".todo-actions button", .{
        .padding = .{ .vertical_horizontal = .{ .vertical = css.rem(0.5), .horizontal = css.rem(1) } },
        .background_color = colors.bg_tertiary,
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .border_radius = .{ .all = css.px(6) },
        .color = colors.text_secondary,
        .font_size = css.rem(0.875),
        .cursor = .pointer,
        .transition_property = "all",
        .transition_duration = .{ .ms = 200 },
    });

    try sheet.addRule(".todo-actions button:hover", .{
        .border_color = colors.accent,
        .color = colors.text_primary,
    });

    try sheet.addRule(".todo-actions .btn-delete:hover", .{
        .border_color = colors.error_color,
        .color = colors.error_color,
    });

    // ========== EMPTY STATE ==========
    try sheet.addRule(".empty-state", .{
        .text_align = .center,
        .padding = .{ .vertical_horizontal = .{ .vertical = css.rem(4), .horizontal = css.rem(2) } },
        .color = colors.text_secondary,
    });

    // ========== ERROR MESSAGE ==========
    try sheet.addRule(".error-message", .{
        .position = .fixed,
        .bottom = css.rem(2),
        .right = css.rem(2),
        .padding = .{ .vertical_horizontal = .{ .vertical = css.rem(1), .horizontal = css.rem(1.5) } },
        .background_color = colors.error_color,
        .color = Color.white,
        .border_radius = .{ .all = radii.md },
        .box_shadow = BoxShadow{
            .x = .zero,
            .y = .{ .px = 4 },
            .blur = .{ .px = 12 },
            .color = Color.rgba(248, 113, 113, 0.3),
        },
        .display = .none,
        .max_width = .{ .px = 400 },
        .z_index = .{ .value = 1000 },
    });

    try sheet.addRule(".error-message.show", .{
        .display = .block,
        .animation = "slideIn 0.3s ease-out",
    });

    // ========== TOOLBAR ==========
    try sheet.addRule(".toolbar", .{
        .display = .flex,
        .gap = .{ .single = css.rem(1) },
        .margin_bottom = css.rem(1.5),
        .flex_wrap = .wrap,
        .align_items = .center,
    });

    try sheet.addRule(".search-bar", .{
        .flex_grow = 1,
        .min_width = .{ .px = 200 },
        .position = .relative,
        .display = .flex,
        .align_items = .center,
    });

    try sheet.addRule(".search-bar input", .{
        .width = .{ .percent = 100 },
        .padding = .{ .all = css.rem(0.75) },
        .padding_right = css.rem(2.5),
        .background_color = colors.bg_secondary,
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .border_radius = .{ .all = radii.md },
        .color = colors.text_primary,
        .font_size = css.rem(0.9375),
    });

    try sheet.addRule(".btn-icon", .{
        .position = .absolute,
        .right = css.rem(0.5),
        .background_color = Color.transparent,
        .border = Border.none,
        .color = colors.text_secondary,
        .cursor = .pointer,
        .padding = .{ .all = css.rem(0.25) },
        .font_size = css.rem(1.2),
    });

    try sheet.addRule(".toolbar-actions", .{
        .display = .flex,
        .gap = .{ .single = css.rem(0.5) },
        .flex_wrap = .wrap,
    });

    try sheet.addRule(".select-input", .{
        .padding = .{ .all = css.rem(0.75) },
        .background_color = colors.bg_secondary,
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .border_radius = .{ .all = radii.md },
        .color = colors.text_primary,
        .font_size = css.rem(0.875),
    });

    // ========== ADD TODO SECTION ==========
    try sheet.addRule(".add-todo-section", .{
        .margin_bottom = css.rem(1.5),
    });

    try sheet.addRule(".toggle-form-btn", .{
        .width = .{ .percent = 100 },
        .padding = .{ .all = css.rem(1) },
        .background_color = colors.bg_secondary,
        .border = Border{ .width = .{ .px = 2 }, .style = .dashed, .color = colors.border },
        .border_radius = .{ .all = radii.lg },
        .color = colors.text_secondary,
        .font_size = css.rem(1),
        .font_weight = .{ .numeric = 500 },
        .cursor = .pointer,
        .transition_property = "all",
        .transition_duration = .{ .ms = 200 },
        .display = .flex,
        .align_items = .center,
        .justify_content = .center,
        .gap = .{ .single = css.rem(0.5) },
        .font_family = "inherit",
    });

    try sheet.addRule(".toggle-form-btn:hover", .{
        .border_color = colors.accent,
        .background_color = colors.bg_tertiary,
        .color = colors.text_primary,
        .transform = .{ .translateY = .{ .px = -1 } },
    });

    try sheet.addRule(".toggle-form-btn #toggle-form-icon", .{
        .font_size = css.rem(1.5),
        .font_weight = .{ .numeric = 300 },
        .line_height = .{ .number = 1 },
    });

    // ========== TODO FORM ==========
    try sheet.addRule(".todo-form", .{
        .margin_top = css.rem(1),
        .padding = .{ .all = css.rem(1.5) },
        .background_color = colors.bg_secondary,
        .border_radius = .{ .all = radii.lg },
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .box_shadow = shadows.card,
        .animation = "slideDown 0.3s ease-out",
    });

    try sheet.addRule(".todo-form input, .todo-form textarea", .{
        .width = .{ .percent = 100 },
        .padding = .{ .all = css.rem(0.875) },
        .margin_bottom = css.rem(1),
        .background_color = colors.bg_tertiary,
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .border_radius = .{ .all = radii.md },
        .color = colors.text_primary,
        .font_size = css.rem(1),
        .font_family = "inherit",
        .transition_property = "border-color, box-shadow",
        .transition_duration = .{ .ms = 200 },
    });

    try sheet.addRule(".todo-form input:focus, .todo-form textarea:focus", .{
        .outline_style = .none,
        .border_color = colors.accent,
        .box_shadow = BoxShadow{
            .x = .zero,
            .y = .zero,
            .blur = .zero,
            .spread = .{ .px = 3 },
            .color = Color.rgba(74, 158, 255, 0.1),
        },
    });

    try sheet.addRule(".todo-form textarea", .{
        .min_height = .{ .px = 80 },
        .resize = .vertical,
    });

    try sheet.addRule(".form-row", .{
        .display = .flex,
        .gap = .{ .single = css.rem(1) },
        .margin_bottom = css.rem(1),
    });

    try sheet.addRule(".priority-select, .date-input, .tags-input", .{
        .padding = .{ .all = css.rem(0.875) },
        .background_color = colors.bg_tertiary,
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .border_radius = .{ .all = radii.md },
        .color = colors.text_primary,
        .font_size = css.rem(0.9375),
    });

    try sheet.addRule(".date-input", .{
        .flex_grow = 1,
        .min_width = .{ .px = 150 },
    });

    try sheet.addRule(".tags-input", .{
        .flex_grow = 1,
    });

    try sheet.addRule(".form-actions", .{
        .display = .flex,
        .gap = .{ .single = css.rem(0.75) },
        .justify_content = .flex_end,
        .margin_top = css.rem(0.5),
    });

    try sheet.addRule(".form-actions .btn", .{
        .min_width = .{ .px = 100 },
    });

    // ========== PRIORITY BADGES ==========
    try sheet.addRule(".priority-badge", .{
        .display = .inline_block,
        .padding = .{ .vertical_horizontal = .{ .vertical = css.rem(0.25), .horizontal = css.rem(0.5) } },
        .border_radius = .{ .all = radii.sm },
        .font_size = css.rem(0.75),
        .font_weight = .{ .numeric = 600 },
        .text_transform = .uppercase,
        .margin_left = css.rem(0.5),
    });

    try sheet.addRule(".priority-high", .{
        .background_color = Color.rgba(248, 113, 113, 0.2),
        .color = colors.error_color,
    });

    try sheet.addRule(".priority-medium", .{
        .background_color = Color.rgba(251, 191, 36, 0.2),
        .color = colors.warning,
    });

    try sheet.addRule(".priority-low", .{
        .background_color = Color.rgba(74, 222, 128, 0.2),
        .color = colors.success,
    });

    try sheet.addRule(".todo-item.priority-high", .{
        .border_left = Border{ .width = .{ .px = 3 }, .style = .solid, .color = colors.error_color },
    });

    try sheet.addRule(".todo-item.priority-medium", .{
        .border_left = Border{ .width = .{ .px = 3 }, .style = .solid, .color = colors.warning },
    });

    try sheet.addRule(".todo-item.priority-low", .{
        .border_left = Border{ .width = .{ .px = 3 }, .style = .solid, .color = colors.success },
    });

    // ========== TAGS ==========
    try sheet.addRule(".todo-tags", .{
        .margin_left = css.rem(2),
        .margin_bottom = css.rem(0.75),
        .display = .flex,
        .flex_wrap = .wrap,
        .gap = .{ .single = css.rem(0.5) },
    });

    try sheet.addRule(".tag", .{
        .display = .inline_block,
        .padding = .{ .vertical_horizontal = .{ .vertical = css.rem(0.25), .horizontal = css.rem(0.5) } },
        .background_color = colors.bg_tertiary,
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .border_radius = .{ .all = radii.lg },
        .font_size = css.rem(0.75),
        .color = colors.text_secondary,
    });

    // ========== DUE DATES ==========
    try sheet.addRule(".due-date", .{
        .font_weight = .{ .numeric = 500 },
    });

    try sheet.addRule(".due-date.overdue", .{
        .color = colors.error_color,
        .font_weight = .{ .numeric = 600 },
    });

    try sheet.addRule(".todo-item.overdue", .{
        .border_left = Border{ .width = .{ .px = 3 }, .style = .solid, .color = colors.error_color },
    });

    try sheet.addRule(".todo-dates", .{
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .single = css.rem(0.25) },
    });

    try sheet.addRule(".todo-title-wrapper", .{
        .flex_grow = 1,
        .display = .flex,
        .align_items = .center,
        .flex_wrap = .wrap,
        .gap = .{ .single = css.rem(0.5) },
    });

    // ========== QUICK ADD FORM ==========
    try sheet.addRule(".quick-add-form", .{
        .margin_bottom = css.rem(2),
        .padding = .{ .all = css.rem(1.5) },
        .background_color = colors.bg_secondary,
        .border_radius = .{ .all = radii.lg },
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .box_shadow = shadows.card,
    });

    try sheet.addRule(".quick-add-form input", .{
        .width = .{ .percent = 100 },
        .padding = .{ .all = css.rem(0.875) },
        .margin_bottom = css.rem(1),
        .background_color = colors.bg_tertiary,
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .border_radius = .{ .all = radii.md },
        .color = colors.text_primary,
        .font_size = css.rem(1),
        .font_family = "inherit",
        .transition_property = "border-color, box-shadow",
        .transition_duration = .{ .ms = 200 },
    });

    try sheet.addRule(".quick-add-form input:focus", .{
        .outline_style = .none,
        .border_color = colors.accent,
        .box_shadow = BoxShadow{
            .x = .zero,
            .y = .zero,
            .blur = .zero,
            .spread = .{ .px = 3 },
            .color = Color.rgba(74, 158, 255, 0.1),
        },
    });

    try sheet.addRule(".section-title", .{
        .font_size = css.rem(1.25),
        .font_weight = .{ .numeric = 600 },
        .color = colors.text_primary,
        .margin_bottom = css.rem(1),
        .padding_bottom = css.rem(0.5),
        .border_bottom = Border{ .width = .{ .px = 2 }, .style = .solid, .color = colors.border },
    });

    // ========== ANALYTICS CHARTS ==========
    try sheet.addRule(".analytics-grid", .{
        .display = .grid,
        .grid_template_columns = "repeat(auto-fit, minmax(300px, 1fr))",
        .gap = .{ .single = css.rem(1.5) },
        .margin_bottom = css.rem(2),
    });

    try sheet.addRule(".chart-card", .{
        .padding = .{ .all = css.rem(1.5) },
        .background_color = colors.bg_secondary,
        .border_radius = .{ .all = radii.lg },
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .box_shadow = shadows.card,
    });

    try sheet.addRule(".chart-title", .{
        .font_size = css.rem(1.125),
        .font_weight = .{ .numeric = 600 },
        .color = colors.text_primary,
        .margin_bottom = css.rem(1),
    });

    try sheet.addRule(".chart-content", .{
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .single = css.rem(0.75) },
    });

    try sheet.addRule(".chart-bar", .{
        .display = .flex,
        .align_items = .center,
        .gap = .{ .single = css.rem(1) },
    });

    try sheet.addRule(".chart-label", .{
        .min_width = .{ .px = 80 },
        .font_size = css.rem(0.875),
        .color = colors.text_secondary,
    });

    try sheet.addRule(".chart-bar-container", .{
        .flex_grow = 1,
        .height = .{ .px = 24 },
        .background_color = colors.bg_tertiary,
        .border_radius = .{ .all = radii.sm },
        .overflow = .hidden,
        .position = .relative,
    });

    try sheet.addRule(".chart-bar-fill", .{
        .height = .{ .percent = 100 },
        .background_color = colors.accent,
        .border_radius = .{ .all = radii.sm },
        .transition_property = "width",
        .transition_duration = .{ .ms = 500 },
        .display = .flex,
        .align_items = .center,
        .justify_content = .flex_end,
        .padding_right = css.rem(0.5),
    });

    try sheet.addRule(".chart-bar-value", .{
        .font_size = css.rem(0.75),
        .font_weight = .{ .numeric = 600 },
        .color = Color.white,
    });

    try sheet.addRule(".chart-bar-fill.priority-high", .{
        .background_color = colors.error_color,
    });

    try sheet.addRule(".chart-bar-fill.priority-medium", .{
        .background_color = colors.warning,
    });

    try sheet.addRule(".chart-bar-fill.priority-low", .{
        .background_color = colors.success,
    });

    // ========== BULK ACTIONS ==========
    try sheet.addRule(".bulk-actions", .{
        .display = .flex,
        .gap = .{ .single = css.rem(0.5) },
        .margin_bottom = css.rem(1.5),
        .padding = .{ .all = css.rem(1) },
        .background_color = colors.bg_secondary,
        .border_radius = .{ .all = radii.md },
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .flex_wrap = .wrap,
    });

    try sheet.addRule(".bulk-actions button", .{
        .padding = .{ .vertical_horizontal = .{ .vertical = css.rem(0.5), .horizontal = css.rem(1) } },
        .background_color = colors.bg_tertiary,
        .border = Border{ .width = .{ .px = 1 }, .style = .solid, .color = colors.border },
        .border_radius = .{ .all = css.px(6) },
        .color = colors.text_secondary,
        .font_size = css.rem(0.875),
        .cursor = .pointer,
        .transition_property = "all",
        .transition_duration = .{ .ms = 200 },
    });

    try sheet.addRule(".bulk-actions button:hover", .{
        .border_color = colors.accent,
        .color = colors.text_primary,
    });

    try sheet.addRule(".bulk-actions button.danger:hover", .{
        .border_color = colors.error_color,
        .color = colors.error_color,
    });

    // ========== RESPONSIVE STYLES ==========
    // Using MediaRuleBuilder to avoid comptime memory issues with large Style struct arrays
    var mobile_styles = sheet.mediaRule(.{ .max_width = 640 });

    try mobile_styles.addStyle("body", .{
        .padding = .{ .vertical_horizontal = .{ .vertical = css.rem(1), .horizontal = css.rem(0.5) } },
    });

    try mobile_styles.addStyle("header h1", .{
        .font_size = css.rem(2),
    });

    try mobile_styles.addStyle(".tab-navigation", .{
        .padding = .{ .all = css.rem(0.25) },
        .gap = .{ .single = css.rem(0.25) },
    });

    try mobile_styles.addStyle(".tab-btn", .{
        .min_width = .{ .px = 90 },
        .padding = .{ .vertical_horizontal = .{ .vertical = css.rem(0.625), .horizontal = css.rem(1) } },
        .font_size = css.rem(0.875),
    });

    try mobile_styles.addStyle(".stats-bar", .{
        .grid_template_columns = "repeat(2, 1fr)",
        .padding = .{ .all = css.rem(1) },
    });

    try mobile_styles.addStyle(".todo-form", .{
        .padding = .{ .all = css.rem(1) },
    });

    try mobile_styles.addStyle(".quick-add-form", .{
        .padding = .{ .all = css.rem(1) },
    });

    try mobile_styles.addStyle(".todo-item", .{
        .padding = .{ .all = css.rem(1) },
    });

    try mobile_styles.addStyle(".todo-meta", .{
        .flex_direction = .column,
        .align_items = .flex_start,
        .gap = .{ .single = css.rem(0.5) },
    });

    try mobile_styles.addStyle(".toolbar", .{
        .flex_direction = .column,
    });

    try mobile_styles.addStyle(".search-bar", .{
        .width = .{ .percent = 100 },
    });

    try mobile_styles.addStyle(".toolbar-actions", .{
        .width = .{ .percent = 100 },
        .justify_content = .space_between,
    });

    try mobile_styles.addStyle(".form-row", .{
        .flex_direction = .column,
    });

    try mobile_styles.addStyle(".analytics-grid", .{
        .grid_template_columns = "1fr",
    });

    try mobile_styles.addStyle(".bulk-actions", .{
        .flex_direction = .column,
    });

    try mobile_styles.addStyle(".bulk-actions button", .{
        .width = .{ .percent = 100 },
    });

    try sheet.addMediaRuleFromBuilder(&mobile_styles);

    return sheet;
}

/// Generate CSS string for the todo app
pub fn generateCss(allocator: std.mem.Allocator) ![]const u8 {
    var sheet = try generateStylesheet(allocator);
    defer sheet.deinit();
    return try sheet.toCss();
}

/// Generate minified CSS string for production
pub fn generateMinifiedCss(allocator: std.mem.Allocator) ![]const u8 {
    var sheet = try generateStylesheet(allocator);
    defer sheet.deinit();
    return try sheet.toMinifiedCss();
}

// ============================================================================
// TESTS
// ============================================================================
test "generate stylesheet" {
    const allocator = std.testing.allocator;
    const generated_css = try generateCss(allocator);
    defer allocator.free(generated_css);

    // Verify critical selectors are present
    try std.testing.expect(std.mem.indexOf(u8, generated_css, ".todo-item{") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_css, ".btn-primary{") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_css, ".tab-navigation{") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_css, "@keyframes fadeIn") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated_css, "@media") != null);
}

test "color tokens" {
    try std.testing.expectEqual(@as(u8, 15), colors.bg_primary.r);
    try std.testing.expectEqual(@as(u8, 15), colors.bg_primary.g);
    try std.testing.expectEqual(@as(u8, 15), colors.bg_primary.b);
}
