const std = @import("std");
const css = @import("engine12").css;

const Style = css.Style;
const Stylesheet = css.Stylesheet;
const Color = css.Color;
const Length = css.Length;
const Duration = css.Duration;
const Border = css.Border;
const BoxShadow = css.BoxShadow;
const Keyframes = css.Keyframes;
const Transition = css.Transition;
const TimingFunction = css.TimingFunction;
const MediaQuery = css.MediaQuery;
const MediaRule = css.MediaRule;
const FontWeight = css.FontWeight;

// Re-export CachedStylesheet for the CSS handler
pub const CachedStylesheet = css.CachedStylesheet;

// ============================================================================
// Design Tokens - Todo App Theme
// ============================================================================

pub const tokens = struct {
    // Core Colors
    pub const black = Color.fromHex("#0a0a0a");
    pub const black_light = Color.fromHex("#111111");
    pub const black_lighter = Color.fromHex("#181818");
    pub const black_surface = Color.fromHex("#1f1f1f");
    pub const black_elevated = Color.fromHex("#262626");
    pub const border_color = Color.fromHex("#2a2a2a");
    pub const border_light = Color.fromHex("#333333");

    // Brand Colors
    pub const gold = Color.fromHex("#f7a41d");
    pub const gold_light = Color.fromHex("#ffc857");
    pub const gold_dim = Color.rgba(247, 164, 29, 31); // ~0.12 alpha = 31/255
    pub const gold_glow = Color.rgba(247, 164, 29, 64); // ~0.25 alpha

    // Neutral Colors
    pub const white = Color.fromHex("#fafafa");
    pub const gray_100 = Color.fromHex("#e5e5e5");
    pub const gray_200 = Color.fromHex("#cccccc");
    pub const gray_300 = Color.fromHex("#a3a3a3");
    pub const gray_400 = Color.fromHex("#737373");
    pub const gray_500 = Color.fromHex("#525252");

    // Semantic Colors
    pub const green = Color.fromHex("#22c55e");
    pub const red = Color.fromHex("#ef4444");

    // Font families
    pub const font_family = "'Inter', -apple-system, BlinkMacSystemFont, sans-serif";
    pub const font_mono = "'JetBrains Mono', monospace";
};

// ============================================================================
// Animations
// ============================================================================

pub const animations = struct {
    pub const spin = Keyframes.spin();
    pub const fade_in = Keyframes.fadeIn();
    pub const slide_in_right = Keyframes{
        .name = "slideIn",
        .frames = &[_]Keyframes.Frame{
            .{ .position = .from, .style = .{
                .opacity = .{ .value = 0 },
                .transform = .{ .translateX = .{ .px = 20 } },
            } },
            .{ .position = .to, .style = .{
                .opacity = .{ .value = 1 },
                .transform = .{ .translateX = .zero },
            } },
        },
    };
};

// ============================================================================
// Transitions
// ============================================================================

pub const transitions = struct {
    pub const fast = Transition{
        .property = "all",
        .duration = .{ .ms = 150 },
        .timing_function = .ease,
        .delay = .{ .ms = 0 },
    };

    pub const normal = Transition{
        .property = "all",
        .duration = .{ .ms = 200 },
        .timing_function = .ease,
        .delay = .{ .ms = 0 },
    };

    pub const opacity = Transition{
        .property = "opacity",
        .duration = .{ .ms = 150 },
        .timing_function = .ease,
        .delay = .{ .ms = 0 },
    };
};

// ============================================================================
// Base Styles
// ============================================================================

pub const base = struct {
    /// Reset - *
    pub const reset: Style = .{
        .margin = .{ .all = .zero },
        .padding = .{ .all = .zero },
        .box_sizing = .border_box,
    };

    /// Body styles
    pub const body: Style = .{
        .font_family = tokens.font_family,
        .background_color = tokens.black,
        .color = tokens.white,
        .min_height = .{ .vh = 100 },
        .line_height = .{ .number = 1.5 },
        .font_size = .{ .px = 14 },
    };
};

// ============================================================================
// Layout Components
// ============================================================================

pub const layout = struct {
    /// .app - Main container
    pub const app: Style = .{
        .max_width = .{ .px = 1400 },
        .margin = .{ .vertical_horizontal = .{ .vertical = .zero, .horizontal = .auto } },
        .padding = .{ .each = .{ .top = .{ .px = 48 }, .right = .{ .px = 40 }, .bottom = .{ .px = 48 }, .left = .{ .px = 40 } } },
    };

    /// .main-grid
    pub const main_grid: Style = .{
        .display = .grid,
        .gap = .{ .single = .{ .px = 32 } },
    };

    /// .main-column
    pub const main_column: Style = .{
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .single = .{ .px = 24 } },
    };

    /// .sidebar
    pub const sidebar: Style = .{
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .single = .{ .px = 24 } },
    };
};

// ============================================================================
// Header Styles
// ============================================================================

pub const header = struct {
    /// .header
    pub const container: Style = .{
        .display = .flex,
        .align_items = .flex_start,
        .justify_content = .space_between,
        .margin_bottom = .{ .px = 48 },
        .padding_bottom = .{ .px = 32 },
        .border_bottom = Border.solid(.{ .px = 1 }, tokens.border_color),
    };

    /// .brand
    pub const brand: Style = .{
        .display = .flex,
        .align_items = .center,
        .gap = .{ .single = .{ .px = 16 } },
    };

    /// .logo
    pub const logo: Style = .{
        .font_family = tokens.font_mono,
        .font_size = .{ .px = 13 },
        .font_weight = .{ .numeric = 600 },
        .color = tokens.black,
        .background_color = tokens.gold,
        .padding = .{ .each = .{ .top = .{ .px = 8 }, .right = .{ .px = 12 }, .bottom = .{ .px = 8 }, .left = .{ .px = 12 } } },
        .border_radius = .{ .all = .{ .px = 6 } },
        .letter_spacing = .{ .em = -0.02 },
    };

    /// .title-group h1
    pub const title: Style = .{
        .font_size = .{ .px = 28 },
        .font_weight = .{ .numeric = 600 },
        .letter_spacing = .{ .em = -0.03 },
        .color = tokens.white,
    };

    /// .title-group p
    pub const subtitle: Style = .{
        .font_size = .{ .px = 14 },
        .color = tokens.gray_400,
        .margin_top = .{ .px = 4 },
    };

    /// .header-stats
    pub const stats: Style = .{
        .display = .flex,
        .gap = .{ .single = .{ .px = 40 } },
    };

    /// .header-stat
    pub const stat: Style = .{
        .text_align = .right,
    };

    /// .header-stat-value
    pub const stat_value: Style = .{
        .font_family = tokens.font_mono,
        .font_size = .{ .px = 32 },
        .font_weight = .{ .numeric = 600 },
        .color = tokens.white,
        .letter_spacing = .{ .em = -0.02 },
    };

    /// .header-stat-value.gold
    pub const stat_value_gold: Style = .{
        .font_family = tokens.font_mono,
        .font_size = .{ .px = 32 },
        .font_weight = .{ .numeric = 600 },
        .color = tokens.gold,
        .letter_spacing = .{ .em = -0.02 },
    };

    /// .header-stat-label
    pub const stat_label: Style = .{
        .font_size = .{ .px = 11 },
        .font_weight = .{ .numeric = 500 },
        .text_transform = .uppercase,
        .letter_spacing = .{ .em = 0.08 },
        .color = tokens.gray_500,
        .margin_top = .{ .px = 4 },
    };
};

// ============================================================================
// Card Styles
// ============================================================================

pub const card = struct {
    /// .card
    pub const container: Style = .{
        .background_color = tokens.black_light,
        .border = Border.solid(.{ .px = 1 }, tokens.border_color),
        .border_radius = .{ .all = .{ .px = 12 } },
        .padding = .{ .all = .{ .px = 24 } },
    };

    /// .card + .card
    pub const container_adjacent: Style = .{
        .margin_top = .{ .px = 24 },
    };

    /// .card-header
    pub const card_header: Style = .{
        .display = .flex,
        .align_items = .center,
        .justify_content = .space_between,
        .margin_bottom = .{ .px = 20 },
    };

    /// .card-title
    pub const title: Style = .{
        .font_size = .{ .px = 11 },
        .font_weight = .{ .numeric = 600 },
        .text_transform = .uppercase,
        .letter_spacing = .{ .em = 0.1 },
        .color = tokens.gray_500,
    };

    /// .card-badge
    pub const badge: Style = .{
        .font_family = tokens.font_mono,
        .font_size = .{ .px = 10 },
        .font_weight = .{ .numeric = 500 },
        .padding = .{ .each = .{ .top = .{ .px = 4 }, .right = .{ .px = 8 }, .bottom = .{ .px = 4 }, .left = .{ .px = 8 } } },
        .background_color = tokens.gold_dim,
        .color = tokens.gold,
        .border_radius = .{ .all = .{ .px = 4 } },
        .letter_spacing = .{ .em = 0.02 },
    };

    /// .progress-card
    pub const progress: Style = .{
        .display = .flex,
        .flex_direction = .column,
        .align_items = .center,
        .background_color = tokens.black_light,
        .border = Border.solid(.{ .px = 1 }, tokens.border_color),
        .border_radius = .{ .all = .{ .px = 12 } },
        .padding = .{ .each = .{ .top = .{ .px = 32 }, .right = .{ .px = 24 }, .bottom = .{ .px = 32 }, .left = .{ .px = 24 } } },
    };
};

// ============================================================================
// Form Styles
// ============================================================================

pub const form = struct {
    /// .form-grid
    pub const grid: Style = .{
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .single = .{ .px = 16 } },
    };

    /// .form-row
    pub const row: Style = .{
        .display = .flex,
        .gap = .{ .single = .{ .px = 12 } },
    };

    /// .form-group
    pub const group: Style = .{
        .margin_bottom = .{ .px = 16 },
    };

    /// .form-actions
    pub const actions: Style = .{
        .display = .flex,
        .gap = .{ .single = .{ .px = 10 } },
        .justify_content = .flex_end,
        .margin_top = .{ .px = 20 },
        .padding_top = .{ .px = 16 },
        .border_top = Border.solid(.{ .px = 1 }, tokens.border_color),
    };

    /// input, select base styles
    pub const input_base: Style = .{
        .flex = .{ .value = .{ .grow = 1, .shrink = 1, .basis = .zero } },
        .padding = .{ .each = .{ .top = .{ .px = 12 }, .right = .{ .px = 16 }, .bottom = .{ .px = 12 }, .left = .{ .px = 16 } } },
        .background_color = tokens.black_surface,
        .border = Border.solid(.{ .px = 1 }, tokens.border_color),
        .border_radius = .{ .all = .{ .px = 8 } },
        .color = tokens.white,
        .font_family = tokens.font_family,
        .font_size = .{ .px = 14 },
        .transition = transitions.fast,
    };

    /// input:focus, select:focus
    pub const input_focus: Style = .{
        .border_color = tokens.gold,
        .box_shadow = BoxShadow{
            .x = .zero,
            .y = .zero,
            .blur = .zero,
            .spread = .{ .px = 3 },
            .color = tokens.gold_dim,
            .inset = false,
        },
    };

    /// textarea
    pub const textarea: Style = .{
        .flex = .{ .value = .{ .grow = 1, .shrink = 1, .basis = .zero } },
        .padding = .{ .each = .{ .top = .{ .px = 12 }, .right = .{ .px = 16 }, .bottom = .{ .px = 12 }, .left = .{ .px = 16 } } },
        .background_color = tokens.black_surface,
        .border = Border.solid(.{ .px = 1 }, tokens.border_color),
        .border_radius = .{ .all = .{ .px = 8 } },
        .color = tokens.white,
        .font_family = tokens.font_family,
        .font_size = .{ .px = 14 },
        .min_height = .{ .px = 80 },
        .line_height = .{ .number = 1.5 },
        .transition = transitions.fast,
    };

    /// label
    pub const label: Style = .{
        .display = .block,
        .font_size = .{ .px = 10 },
        .font_weight = .{ .numeric = 600 },
        .text_transform = .uppercase,
        .letter_spacing = .{ .em = 0.08 },
        .color = tokens.gray_500,
        .margin_bottom = .{ .px = 8 },
    };

    /// .search-wrapper
    pub const search_wrapper: Style = .{
        .margin_bottom = .{ .px = 16 },
    };
};

// ============================================================================
// Button Styles
// ============================================================================

pub const button = struct {
    /// .btn base
    pub const base: Style = .{
        .padding = .{ .each = .{ .top = .{ .px = 12 }, .right = .{ .px = 24 }, .bottom = .{ .px = 12 }, .left = .{ .px = 24 } } },
        .border = Border.none,
        .border_radius = .{ .all = .{ .px = 8 } },
        .font_family = tokens.font_family,
        .font_size = .{ .px = 14 },
        .font_weight = .{ .numeric = 500 },
        .cursor = .pointer,
        .transition = transitions.fast,
    };

    /// .btn-primary
    pub const primary: Style = .{
        .padding = .{ .each = .{ .top = .{ .px = 12 }, .right = .{ .px = 24 }, .bottom = .{ .px = 12 }, .left = .{ .px = 24 } } },
        .border = Border.none,
        .border_radius = .{ .all = .{ .px = 8 } },
        .font_family = tokens.font_family,
        .font_size = .{ .px = 14 },
        .font_weight = .{ .numeric = 500 },
        .cursor = .pointer,
        .transition = transitions.fast,
        .background_color = tokens.gold,
        .color = tokens.black,
    };

    /// .btn-primary:hover
    pub const primary_hover: Style = .{
        .background_color = tokens.gold_light,
    };

    /// .btn-secondary
    pub const secondary: Style = .{
        .padding = .{ .each = .{ .top = .{ .px = 12 }, .right = .{ .px = 24 }, .bottom = .{ .px = 12 }, .left = .{ .px = 24 } } },
        .border = Border.solid(.{ .px = 1 }, tokens.border_color),
        .border_radius = .{ .all = .{ .px = 8 } },
        .font_family = tokens.font_family,
        .font_size = .{ .px = 14 },
        .font_weight = .{ .numeric = 500 },
        .cursor = .pointer,
        .transition = transitions.fast,
        .background_color = tokens.black_surface,
        .color = tokens.gray_300,
    };

    /// .btn-secondary:hover
    pub const secondary_hover: Style = .{
        .background_color = tokens.black_elevated,
        .color = tokens.white,
        .border_color = tokens.border_light,
    };

    /// .btn-sm
    pub const small: Style = .{
        .padding = .{ .each = .{ .top = .{ .px = 8 }, .right = .{ .px = 14 }, .bottom = .{ .px = 8 }, .left = .{ .px = 14 } } },
        .font_size = .{ .px = 13 },
    };

    /// .btn-cancel
    pub const cancel: Style = .{
        .padding = .{ .each = .{ .top = .{ .px = 12 }, .right = .{ .px = 24 }, .bottom = .{ .px = 12 }, .left = .{ .px = 24 } } },
        .border = Border.solid(.{ .px = 1 }, tokens.border_color),
        .border_radius = .{ .all = .{ .px = 8 } },
        .font_family = tokens.font_family,
        .font_size = .{ .px = 14 },
        .font_weight = .{ .numeric = 500 },
        .cursor = .pointer,
        .transition = transitions.fast,
        .background_color = tokens.black_surface,
        .color = tokens.gray_300,
    };

    /// .btn-save
    pub const save: Style = .{
        .padding = .{ .each = .{ .top = .{ .px = 12 }, .right = .{ .px = 24 }, .bottom = .{ .px = 12 }, .left = .{ .px = 24 } } },
        .border = Border.none,
        .border_radius = .{ .all = .{ .px = 8 } },
        .font_family = tokens.font_family,
        .font_size = .{ .px = 14 },
        .font_weight = .{ .numeric = 500 },
        .cursor = .pointer,
        .transition = transitions.fast,
        .background_color = tokens.gold,
        .color = tokens.black,
    };

    /// .action-btn
    pub const action: Style = .{
        .padding = .{ .each = .{ .top = .{ .px = 6 }, .right = .{ .px = 10 }, .bottom = .{ .px = 6 }, .left = .{ .px = 10 } } },
        .background_color = Color.transparent,
        .border = Border.solid(.{ .px = 1 }, tokens.border_color),
        .border_radius = .{ .all = .{ .px = 4 } },
        .color = tokens.gray_400,
        .font_size = .{ .px = 12 },
        .cursor = .pointer,
        .transition = transitions.fast,
    };

    /// .action-btn:hover
    pub const action_hover: Style = .{
        .background_color = tokens.black_elevated,
        .color = tokens.white,
    };

    /// .action-btn.delete:hover
    pub const action_delete_hover: Style = .{
        .border_color = tokens.red,
        .color = tokens.red,
    };
};

// ============================================================================
// Task List Styles
// ============================================================================

pub const task = struct {
    /// .task-list (ul)
    pub const list: Style = .{
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .single = .{ .px = 12 } },
        .max_height = .{ .px = 440 },
        .overflow_y = .auto,
        .padding = .{ .each = .{ .top = .{ .px = 4 }, .right = .zero, .bottom = .{ .px = 4 }, .left = .zero } },
    };

    /// .task-item (li)
    pub const item: Style = .{
        .display = .flex,
        .align_items = .flex_start,
        .gap = .{ .single = .{ .px = 14 } },
        .padding = .{ .each = .{ .top = .{ .px = 16 }, .right = .{ .px = 18 }, .bottom = .{ .px = 16 }, .left = .{ .px = 18 } } },
        .background_color = tokens.black_surface,
        .border = Border.solid(.{ .px = 1 }, tokens.border_color),
        .border_radius = .{ .all = .{ .px = 8 } },
        .transition = transitions.fast,
    };

    /// .task-item:hover
    pub const item_hover: Style = .{
        .background_color = tokens.black_elevated,
        .border_color = tokens.border_color,
    };

    /// .task-item.priority-high
    pub const priority_high: Style = .{
        .border_left = Border.solid(.{ .px = 3 }, tokens.red),
    };

    /// .task-item.priority-medium
    pub const priority_medium: Style = .{
        .border_left = Border.solid(.{ .px = 3 }, tokens.gold),
    };

    /// .task-item.priority-low
    pub const priority_low: Style = .{
        .border_left = Border.solid(.{ .px = 3 }, tokens.green),
    };

    /// .task-item.completed
    pub const completed: Style = .{
        .opacity = .{ .value = 0.5 },
    };

    /// .task-item.completed .task-title
    pub const title_completed: Style = .{
        .text_decoration = .line_through,
    };

    /// .task-checkbox
    pub const checkbox: Style = .{
        .width = .{ .px = 18 },
        .height = .{ .px = 18 },
        .min_width = .{ .px = 18 },
        .min_height = .{ .px = 18 },
        .flex = .{ .value = .{ .grow = 0, .shrink = 0, .basis = .{ .px = 18 } } },
        .border = Border.solid(.{ .px = 1.5 }, tokens.border_light),
        .border_radius = .{ .all = .{ .px = 4 } },
        .cursor = .pointer,
        .margin_top = .{ .px = 2 },
        .background_color = Color.transparent,
        .transition = transitions.fast,
    };

    /// .task-checkbox:hover
    pub const checkbox_hover: Style = .{
        .border_color = tokens.gold,
    };

    /// .task-checkbox:checked
    pub const checkbox_checked: Style = .{
        .background_color = tokens.gold,
        .border_color = tokens.gold,
    };

    /// .task-content
    pub const content: Style = .{
        .flex = .{ .value = .{ .grow = 1, .shrink = 1, .basis = .zero } },
        .min_width = .zero,
    };

    /// .task-title
    pub const title: Style = .{
        .font_size = .{ .px = 14 },
        .font_weight = .{ .numeric = 500 },
        .color = tokens.white,
        .margin_bottom = .{ .px = 4 },
    };

    /// .task-desc
    pub const desc: Style = .{
        .font_size = .{ .px = 13 },
        .color = tokens.gray_400,
        .margin_bottom = .{ .px = 8 },
    };

    /// .task-meta
    pub const meta: Style = .{
        .display = .flex,
        .gap = .{ .single = .{ .px = 12 } },
        .flex_wrap = .wrap,
        .align_items = .center,
    };

    /// .task-date
    pub const date: Style = .{
        .font_family = tokens.font_mono,
        .font_size = .{ .px = 11 },
        .color = tokens.gray_500,
    };

    /// .task-tag
    pub const tag: Style = .{
        .font_family = tokens.font_mono,
        .font_size = .{ .px = 11 },
        .padding = .{ .each = .{ .top = .{ .px = 2 }, .right = .{ .px = 8 }, .bottom = .{ .px = 2 }, .left = .{ .px = 8 } } },
        .background_color = tokens.black_lighter,
        .border_radius = .{ .all = .{ .px = 4 } },
        .color = tokens.gray_400,
    };

    /// .task-actions
    pub const actions: Style = .{
        .display = .flex,
        .gap = .{ .single = .{ .px = 4 } },
        .opacity = .{ .value = 0 },
        .transition = transitions.opacity,
    };

    /// .task-item:hover .task-actions
    pub const actions_visible: Style = .{
        .opacity = .{ .value = 1 },
    };
};

// ============================================================================
// Edit Form Styles
// ============================================================================

pub const edit_form = struct {
    /// .edit-form
    pub const container: Style = .{
        .background_color = tokens.black_light,
        .border = Border.solid(.{ .px = 1 }, tokens.gold),
        .border_radius = .{ .all = .{ .px = 12 } },
        .padding = .{ .all = .{ .px = 24 } },
        .margin = .{ .each = .{ .top = .{ .px = 4 }, .right = .zero, .bottom = .{ .px = 4 }, .left = .zero } },
    };
};

// ============================================================================
// Progress Ring Styles
// ============================================================================

pub const progress = struct {
    /// .progress-ring
    pub const ring: Style = .{
        .position = .relative,
        .width = .{ .px = 120 },
        .height = .{ .px = 120 },
        .margin_bottom = .{ .px = 16 },
    };

    /// .progress-ring-text
    pub const text: Style = .{
        .position = .absolute,
        .inset = .zero,
        .display = .flex,
        .flex_direction = .column,
        .align_items = .center,
        .justify_content = .center,
    };

    /// .progress-ring-value
    pub const value: Style = .{
        .font_family = tokens.font_mono,
        .font_size = .{ .px = 24 },
        .font_weight = .{ .numeric = 600 },
        .color = tokens.gold,
    };

    /// .progress-ring-label
    pub const label: Style = .{
        .font_size = .{ .px = 10 },
        .font_weight = .{ .numeric = 500 },
        .text_transform = .uppercase,
        .letter_spacing = .{ .em = 0.08 },
        .color = tokens.gray_500,
        .margin_top = .{ .px = 2 },
    };
};

// ============================================================================
// Filter Styles
// ============================================================================

pub const filter = struct {
    /// .filter-section
    pub const section: Style = .{
        .margin_bottom = .{ .px = 20 },
    };

    /// .filter-section:last-child
    pub const section_last: Style = .{
        .margin_bottom = .zero,
    };

    /// .filter-label
    pub const label: Style = .{
        .font_size = .{ .px = 11 },
        .font_weight = .{ .numeric = 600 },
        .text_transform = .uppercase,
        .letter_spacing = .{ .em = 0.1 },
        .color = tokens.gray_500,
        .margin_bottom = .{ .px = 10 },
    };

    /// .filter-group
    pub const group: Style = .{
        .display = .flex,
        .flex_wrap = .wrap,
        .gap = .{ .single = .{ .px = 6 } },
    };

    /// .filter-btn
    pub const btn: Style = .{
        .padding = .{ .each = .{ .top = .{ .px = 8 }, .right = .{ .px = 14 }, .bottom = .{ .px = 8 }, .left = .{ .px = 14 } } },
        .background_color = tokens.black_surface,
        .border = Border.solid(.{ .px = 1 }, tokens.border_color),
        .border_radius = .{ .all = .{ .px = 6 } },
        .color = tokens.gray_400,
        .font_size = .{ .px = 13 },
        .font_weight = .{ .numeric = 500 },
        .cursor = .pointer,
        .transition = transitions.fast,
    };

    /// .filter-btn:hover
    pub const btn_hover: Style = .{
        .background_color = tokens.black_elevated,
        .color = tokens.white,
    };

    /// .filter-btn.active
    pub const btn_active: Style = .{
        .background_color = tokens.gold,
        .border_color = tokens.gold,
        .color = tokens.black,
    };

    /// .priority-dot
    pub const priority_dot: Style = .{
        .display = .inline_block,
        .width = .{ .px = 6 },
        .height = .{ .px = 6 },
        .border_radius = .{ .all = .{ .percent = 50 } },
        .margin_right = .{ .px = 6 },
    };

    /// .priority-dot.high
    pub const dot_high: Style = .{
        .display = .inline_block,
        .width = .{ .px = 6 },
        .height = .{ .px = 6 },
        .border_radius = .{ .all = .{ .percent = 50 } },
        .margin_right = .{ .px = 6 },
        .background_color = tokens.red,
    };

    /// .priority-dot.medium
    pub const dot_medium: Style = .{
        .display = .inline_block,
        .width = .{ .px = 6 },
        .height = .{ .px = 6 },
        .border_radius = .{ .all = .{ .percent = 50 } },
        .margin_right = .{ .px = 6 },
        .background_color = tokens.gold,
    };

    /// .priority-dot.low
    pub const dot_low: Style = .{
        .display = .inline_block,
        .width = .{ .px = 6 },
        .height = .{ .px = 6 },
        .border_radius = .{ .all = .{ .percent = 50 } },
        .margin_right = .{ .px = 6 },
        .background_color = tokens.green,
    };
};

// ============================================================================
// Navigation Styles
// ============================================================================

pub const nav = struct {
    /// .nav-links
    pub const links: Style = .{
        .display = .flex,
        .gap = .{ .single = .{ .px = 8 } },
    };

    /// .nav-link
    pub const link: Style = .{
        .flex = .{ .value = .{ .grow = 1, .shrink = 1, .basis = .zero } },
        .padding = .{ .all = .{ .px = 12 } },
        .background_color = tokens.black_surface,
        .border = Border.solid(.{ .px = 1 }, tokens.border_color),
        .border_radius = .{ .all = .{ .px = 8 } },
        .color = tokens.gray_400,
        .text_decoration = .none,
        .font_size = .{ .px = 13 },
        .font_weight = .{ .numeric = 500 },
        .text_align = .center,
        .transition = transitions.fast,
    };

    /// .nav-link:hover
    pub const link_hover: Style = .{
        .background_color = tokens.black_elevated,
        .color = tokens.white,
    };
};

// ============================================================================
// Feature List Styles
// ============================================================================

pub const feature = struct {
    /// .feature-list
    pub const list: Style = .{
        .display = .flex,
        .flex_direction = .column,
        .gap = .{ .single = .{ .px = 12 } },
    };

    /// .feature-item
    pub const item: Style = .{
        .padding = .{ .each = .{ .top = .{ .px = 14 }, .right = .{ .px = 16 }, .bottom = .{ .px = 14 }, .left = .{ .px = 16 } } },
        .background_color = tokens.black_surface,
        .border_radius = .{ .all = .{ .px = 8 } },
    };

    /// .feature-title
    pub const title: Style = .{
        .font_size = .{ .px = 13 },
        .font_weight = .{ .numeric = 500 },
        .color = tokens.white,
        .margin_bottom = .{ .px = 2 },
    };

    /// .feature-desc
    pub const desc: Style = .{
        .font_size = .{ .px = 12 },
        .color = tokens.gray_500,
    };
};

// ============================================================================
// Empty State Styles
// ============================================================================

pub const empty_state: Style = .{
    .text_align = .center,
    .padding = .{ .each = .{ .top = .{ .px = 48 }, .right = .{ .px = 24 }, .bottom = .{ .px = 48 }, .left = .{ .px = 24 } } },
    .color = tokens.gray_500,
    .font_size = .{ .px = 14 },
};

// ============================================================================
// Loading Styles
// ============================================================================

pub const loading = struct {
    /// .loading
    pub const container: Style = .{
        .display = .flex,
        .justify_content = .center,
        .padding = .{ .all = .{ .px = 32 } },
    };

    /// .spinner
    pub const spinner: Style = .{
        .width = .{ .px = 20 },
        .height = .{ .px = 20 },
        .border = Border.solid(.{ .px = 2 }, tokens.border_color),
        .border_top = Border.solid(.{ .px = 2 }, tokens.gold),
        .border_radius = .{ .all = .{ .percent = 50 } },
        .animation = "spin 0.6s linear infinite",
    };
};

// ============================================================================
// Toast Styles
// ============================================================================

pub const toast = struct {
    /// #toast container
    pub const container: Style = .{
        .position = .fixed,
        .top = .{ .px = 24 },
        .right = .{ .px = 24 },
        .z_index = .{ .value = 1000 },
    };

    /// .toast
    pub const notification: Style = .{
        .display = .flex,
        .align_items = .flex_start,
        .gap = .{ .single = .{ .px = 12 } },
        .background_color = tokens.black_light,
        .border = Border.solid(.{ .px = 1 }, tokens.border_color),
        .border_radius = .{ .all = .{ .px = 8 } },
        .padding = .{ .each = .{ .top = .{ .px = 14 }, .right = .{ .px = 16 }, .bottom = .{ .px = 14 }, .left = .{ .px = 16 } } },
        .box_shadow = BoxShadow{
            .x = .zero,
            .y = .{ .px = 8 },
            .blur = .{ .px = 24 },
            .spread = .zero,
            .color = Color.rgba(0, 0, 0, 127),
            .inset = false,
        },
        .margin_bottom = .{ .px = 8 },
        .font_size = .{ .px = 13 },
        .min_width = .{ .px = 280 },
        .max_width = .{ .px = 400 },
        .animation = "slideIn 0.2s ease-out forwards",
    };

    /// .toast-content
    pub const content: Style = .{
        .flex = .{ .value = .{ .grow = 1, .shrink = 1, .basis = .zero } },
        .display = .flex,
        .align_items = .center,
        .gap = .{ .single = .{ .px = 10 } },
    };

    /// .toast-icon
    pub const icon: Style = .{
        .flex = .{ .value = .{ .grow = 0, .shrink = 0, .basis = .auto } },
        .width = .{ .px = 18 },
        .height = .{ .px = 18 },
        .display = .flex,
        .align_items = .center,
        .justify_content = .center,
        .font_weight = .{ .numeric = 600 },
        .font_size = .{ .px = 12 },
    };

    /// .toast.success .toast-icon
    pub const icon_success: Style = .{
        .color = tokens.green,
    };

    /// .toast.error .toast-icon
    pub const icon_error: Style = .{
        .color = tokens.red,
    };

    /// .toast-message
    pub const message: Style = .{
        .flex = .{ .value = .{ .grow = 1, .shrink = 1, .basis = .zero } },
        .color = tokens.gray_100,
    };

    /// .toast-close
    pub const close: Style = .{
        .flex = .{ .value = .{ .grow = 0, .shrink = 0, .basis = .auto } },
        .width = .{ .px = 24 },
        .height = .{ .px = 24 },
        .display = .flex,
        .align_items = .center,
        .justify_content = .center,
        .background_color = Color.transparent,
        .border = Border.none,
        .color = tokens.gray_500,
        .cursor = .pointer,
        .border_radius = .{ .all = .{ .px = 4 } },
        .font_size = .{ .px = 16 },
        .font_weight = .{ .numeric = 400 },
        .line_height = .{ .number = 1 },
        .transition = transitions.fast,
    };

    /// .toast-close:hover
    pub const close_hover: Style = .{
        .background_color = tokens.black_elevated,
        .color = tokens.white,
    };

    /// .toast.success
    pub const success: Style = .{
        .border_left = Border.solid(.{ .px = 3 }, tokens.green),
    };

    /// .toast.error
    pub const err: Style = .{
        .border_left = Border.solid(.{ .px = 3 }, tokens.red),
    };
};

// ============================================================================
// Count Badge Styles
// ============================================================================

pub const count_badge: Style = .{
    .font_family = tokens.font_mono,
    .font_size = .{ .px = 11 },
    .font_weight = .{ .numeric = 500 },
    .background_color = tokens.gold_dim,
    .color = tokens.gold,
    .padding = .{ .each = .{ .top = .{ .px = 2 }, .right = .{ .px = 8 }, .bottom = .{ .px = 2 }, .left = .{ .px = 8 } } },
    .border_radius = .{ .all = .{ .px = 4 } },
    .margin_left = .{ .px = 8 },
};

// ============================================================================
// Info Bar Styles
// ============================================================================

pub const info_bar: Style = .{
    .display = .flex,
    .gap = .{ .single = .{ .px = 16 } },
    .margin_bottom = .{ .px = 24 },
    .padding = .{ .each = .{ .top = .{ .px = 12 }, .right = .{ .px = 16 }, .bottom = .{ .px = 12 }, .left = .{ .px = 16 } } },
    .background_color = tokens.black_surface,
    .border_radius = .{ .all = .{ .px = 8 } },
    .font_size = .{ .px = 12 },
    .color = tokens.gray_300,
};

pub const debug_mode: Style = .{
    .color = tokens.gold,
};

pub const production_mode: Style = .{
    .color = tokens.green,
};

pub const notification_style: Style = .{
    .color = tokens.red,
};

pub const no_notification: Style = .{
    .color = tokens.gray_500,
};

// ============================================================================
// Card Actions Styles
// ============================================================================

pub const card_actions: Style = .{
    .display = .flex,
    .gap = .{ .single = .{ .px = 8 } },
};

pub const clear_done_wrapper: Style = .{
    .display = .flex,
    .align_items = .center,
};

// ============================================================================
// HTMX Indicator Styles
// ============================================================================

pub const htmx_indicator: Style = .{
    .opacity = .{ .value = 0 },
    .transition = transitions.opacity,
};

pub const htmx_request_indicator: Style = .{
    .opacity = .{ .value = 1 },
};

// ============================================================================
// Responsive Styles
// ============================================================================

pub const responsive = struct {
    /// @media (max-width: 1024px) .app
    pub const app_tablet: Style = .{
        .padding = .{ .each = .{ .top = .{ .px = 32 }, .right = .{ .px = 24 }, .bottom = .{ .px = 32 }, .left = .{ .px = 24 } } },
    };

    /// @media (max-width: 1024px) .main-grid
    pub const main_grid_tablet: Style = .{
        .display = .block,
    };

    /// @media (max-width: 1024px) .sidebar
    pub const sidebar_tablet: Style = .{
        .margin_bottom = .{ .px = 24 },
    };

    /// @media (max-width: 1024px) .header
    pub const header_tablet: Style = .{
        .flex_direction = .column,
        .gap = .{ .single = .{ .px = 24 } },
    };

    /// @media (max-width: 1024px) .header-stats
    pub const header_stats_tablet: Style = .{
        .justify_content = .flex_start,
    };

    /// @media (max-width: 1024px) .header-stat
    pub const header_stat_tablet: Style = .{
        .text_align = .left,
    };

    /// @media (max-width: 640px) .app
    pub const app_mobile: Style = .{
        .padding = .{ .each = .{ .top = .{ .px = 24 }, .right = .{ .px = 16 }, .bottom = .{ .px = 24 }, .left = .{ .px = 16 } } },
    };

    /// @media (max-width: 640px) .form-row
    pub const form_row_mobile: Style = .{
        .flex_direction = .column,
    };

    /// @media (max-width: 640px) .header-stats
    pub const header_stats_mobile: Style = .{
        .gap = .{ .single = .{ .px = 24 } },
    };
};

// ============================================================================
// Stylesheet Generation
// ============================================================================

pub fn generateStylesheet(allocator: std.mem.Allocator) !Stylesheet {
    var sheet = Stylesheet.init(allocator);

    // Add keyframes
    try sheet.addKeyframes(animations.spin);
    try sheet.addKeyframes(animations.slide_in_right);

    // Reset
    try sheet.addRule("*", base.reset);
    try sheet.addRule("*::before", base.reset);
    try sheet.addRule("*::after", base.reset);

    // Base
    try sheet.addRule("body", base.body);

    // Layout
    try sheet.addRule(".app", layout.app);
    try sheet.addRule(".main-grid", layout.main_grid);
    try sheet.addRule(".main-column", layout.main_column);
    try sheet.addRule(".sidebar", layout.sidebar);

    // Header
    try sheet.addRule(".header", header.container);
    try sheet.addRule(".brand", header.brand);
    try sheet.addRule(".logo", header.logo);
    try sheet.addRule(".title-group h1", header.title);
    try sheet.addRule(".title-group p", header.subtitle);
    try sheet.addRule(".header-stats", header.stats);
    try sheet.addRule(".header-stat", header.stat);
    try sheet.addRule(".header-stat-value", header.stat_value);
    try sheet.addRule(".header-stat-value.gold", header.stat_value_gold);
    try sheet.addRule(".header-stat-label", header.stat_label);

    // Cards
    try sheet.addRule(".card", card.container);
    try sheet.addRule(".card + .card", card.container_adjacent);
    try sheet.addRule(".card-header", card.card_header);
    try sheet.addRule(".card-title", card.title);
    try sheet.addRule(".card-badge", card.badge);
    try sheet.addRule(".progress-card", card.progress);

    // Forms
    try sheet.addRule(".form-grid", form.grid);
    try sheet.addRule(".form-row", form.row);
    try sheet.addRule(".form-group", form.group);
    try sheet.addRule(".form-actions", form.actions);
    try sheet.addRule("input", form.input_base);
    try sheet.addRule("select", form.input_base);
    try sheet.addRule("textarea", form.textarea);
    try sheet.addRule("input:focus", form.input_focus);
    try sheet.addRule("select:focus", form.input_focus);
    try sheet.addRule("textarea:focus", form.input_focus);
    try sheet.addRule("label", form.label);
    try sheet.addRule(".search-wrapper", form.search_wrapper);

    // Buttons
    try sheet.addRule(".btn", button.base);
    try sheet.addRule(".btn-primary", button.primary);
    try sheet.addRule(".btn-primary:hover", button.primary_hover);
    try sheet.addRule(".btn-secondary", button.secondary);
    try sheet.addRule(".btn-secondary:hover", button.secondary_hover);
    try sheet.addRule(".btn-sm", button.small);
    try sheet.addRule(".btn-cancel", button.cancel);
    try sheet.addRule(".btn-cancel:hover", button.secondary_hover);
    try sheet.addRule(".btn-save", button.save);
    try sheet.addRule(".btn-save:hover", button.primary_hover);
    try sheet.addRule(".action-btn", button.action);
    try sheet.addRule(".action-btn:hover", button.action_hover);
    try sheet.addRule(".action-btn.delete:hover", button.action_delete_hover);

    // Task List
    try sheet.addRule(".task-list", task.list);
    try sheet.addRule(".task-item", task.item);
    try sheet.addRule(".task-item:hover", task.item_hover);
    try sheet.addRule(".task-item.priority-high", task.priority_high);
    try sheet.addRule(".task-item.priority-medium", task.priority_medium);
    try sheet.addRule(".task-item.priority-low", task.priority_low);
    try sheet.addRule(".task-item.completed", task.completed);
    try sheet.addRule(".task-item.completed .task-title", task.title_completed);
    try sheet.addRule(".task-checkbox", task.checkbox);
    try sheet.addRule(".task-checkbox:hover", task.checkbox_hover);
    try sheet.addRule(".task-checkbox:checked", task.checkbox_checked);
    try sheet.addRule(".task-content", task.content);
    try sheet.addRule(".task-title", task.title);
    try sheet.addRule(".task-desc", task.desc);
    try sheet.addRule(".task-meta", task.meta);
    try sheet.addRule(".task-date", task.date);
    try sheet.addRule(".task-tag", task.tag);
    try sheet.addRule(".task-actions", task.actions);
    try sheet.addRule(".task-item:hover .task-actions", task.actions_visible);

    // Edit Form
    try sheet.addRule(".edit-form", edit_form.container);
    try sheet.addRule(".edit-form label", form.label);
    try sheet.addRule(".edit-form .form-group", form.group);
    try sheet.addRule(".edit-form input", form.input_base);
    try sheet.addRule(".edit-form select", form.input_base);
    try sheet.addRule(".edit-form textarea", form.textarea);
    try sheet.addRule(".edit-form input:focus", form.input_focus);
    try sheet.addRule(".edit-form select:focus", form.input_focus);
    try sheet.addRule(".edit-form textarea:focus", form.input_focus);
    try sheet.addRule(".edit-form .form-row", .{ .display = .grid, .gap = .{ .single = .{ .px = 12 } } });
    try sheet.addRule(".edit-form .form-actions", form.actions);
    try sheet.addRule(".edit-form .btn", .{ .margin_top = .zero });

    // Progress Ring
    try sheet.addRule(".progress-ring", progress.ring);
    try sheet.addRule(".progress-ring-text", progress.text);
    try sheet.addRule(".progress-ring-value", progress.value);
    try sheet.addRule(".progress-ring-label", progress.label);

    // Filters
    try sheet.addRule(".filter-section", filter.section);
    try sheet.addRule(".filter-section:last-child", filter.section_last);
    try sheet.addRule(".filter-label", filter.label);
    try sheet.addRule(".filter-group", filter.group);
    try sheet.addRule(".filter-btn", filter.btn);
    try sheet.addRule(".filter-btn:hover", filter.btn_hover);
    try sheet.addRule(".filter-btn.active", filter.btn_active);
    try sheet.addRule(".priority-dot", filter.priority_dot);
    try sheet.addRule(".priority-dot.high", filter.dot_high);
    try sheet.addRule(".priority-dot.medium", filter.dot_medium);
    try sheet.addRule(".priority-dot.low", filter.dot_low);

    // Navigation
    try sheet.addRule(".nav-links", nav.links);
    try sheet.addRule(".nav-link", nav.link);
    try sheet.addRule(".nav-link:hover", nav.link_hover);

    // Features
    try sheet.addRule(".feature-list", feature.list);
    try sheet.addRule(".feature-item", feature.item);
    try sheet.addRule(".feature-title", feature.title);
    try sheet.addRule(".feature-desc", feature.desc);

    // Empty State
    try sheet.addRule(".empty-state", empty_state);

    // Loading
    try sheet.addRule(".loading", loading.container);
    try sheet.addRule(".spinner", loading.spinner);

    // Toast
    try sheet.addRule("#toast", toast.container);
    try sheet.addRule(".toast", toast.notification);
    try sheet.addRule(".toast-content", toast.content);
    try sheet.addRule(".toast-icon", toast.icon);
    try sheet.addRule(".toast.success .toast-icon", toast.icon_success);
    try sheet.addRule(".toast.error .toast-icon", toast.icon_error);
    try sheet.addRule(".toast-message", toast.message);
    try sheet.addRule(".toast-close", toast.close);
    try sheet.addRule(".toast-close:hover", toast.close_hover);
    try sheet.addRule(".toast.success", toast.success);
    try sheet.addRule(".toast.error", toast.err);

    // Count Badge
    try sheet.addRule(".count-badge", count_badge);

    // Info Bar
    try sheet.addRule(".info-bar", info_bar);

    // HTMX Indicators
    try sheet.addRule(".htmx-indicator", htmx_indicator);
    try sheet.addRule(".htmx-request .htmx-indicator", htmx_request_indicator);

    // Mode Indicators
    try sheet.addRule(".debug-mode", debug_mode);
    try sheet.addRule(".production-mode", production_mode);
    try sheet.addRule(".notification", notification_style);
    try sheet.addRule(".no-notification", no_notification);

    // Card Actions
    try sheet.addRule(".card-actions", card_actions);
    try sheet.addRule(".clear-done-wrapper", clear_done_wrapper);

    // Responsive - Tablet
    try sheet.addMediaRule(.{
        .query = .{ .max_width = 1024 },
        .styles = &[_]MediaRule.SelectorStyle{
            .{ .selector = ".app", .style = responsive.app_tablet },
            .{ .selector = ".main-grid", .style = responsive.main_grid_tablet },
            .{ .selector = ".sidebar", .style = responsive.sidebar_tablet },
            .{ .selector = ".header", .style = responsive.header_tablet },
            .{ .selector = ".header-stats", .style = responsive.header_stats_tablet },
            .{ .selector = ".header-stat", .style = responsive.header_stat_tablet },
        },
    });

    // Responsive - Mobile
    try sheet.addMediaRule(.{
        .query = .{ .max_width = 640 },
        .styles = &[_]MediaRule.SelectorStyle{
            .{ .selector = ".app", .style = responsive.app_mobile },
            .{ .selector = ".form-row", .style = responsive.form_row_mobile },
            .{ .selector = ".header-stats", .style = responsive.header_stats_mobile },
        },
    });

    // Raw CSS for things not easily expressed via Style struct
    try sheet.addRaw(
        \\/* Checkbox appearance */
        \\.task-checkbox {
        \\  appearance: none;
        \\  -webkit-appearance: none;
        \\  position: relative;
        \\}
        \\.task-checkbox:checked::after {
        \\  content: "";
        \\  position: absolute;
        \\  left: 5px;
        \\  top: 2px;
        \\  width: 5px;
        \\  height: 9px;
        \\  border: solid #0a0a0a;
        \\  border-width: 0 2px 2px 0;
        \\  transform: rotate(45deg);
        \\}
        \\/* Scrollbar styles */
        \\.task-list::-webkit-scrollbar {
        \\  width: 4px;
        \\}
        \\.task-list::-webkit-scrollbar-track {
        \\  background: transparent;
        \\}
        \\.task-list::-webkit-scrollbar-thumb {
        \\  background: #2a2a2a;
        \\  border-radius: 2px;
        \\}
        \\/* Placeholder color */
        \\input::placeholder {
        \\  color: #525252;
        \\}
        \\/* Select dropdown arrow */
        \\select {
        \\  appearance: none;
        \\  background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='10' viewBox='0 0 24 24' fill='none' stroke='%23525252' stroke-width='2'%3E%3Cpolyline points='6 9 12 15 18 9'/%3E%3C/svg%3E");
        \\  background-repeat: no-repeat;
        \\  background-position: right 14px center;
        \\  padding-right: 36px;
        \\}
        \\/* Date input color scheme */
        \\input[type="date"] {
        \\  color-scheme: dark;
        \\  min-width: 140px;
        \\  flex: 0 0 auto;
        \\}
        \\/* List reset */
        \\ul, ol {
        \\  list-style: none;
        \\}
        \\/* Progress ring SVG */
        \\.progress-ring svg {
        \\  transform: rotate(-90deg);
        \\}
        \\.progress-ring circle {
        \\  fill: transparent;
        \\  stroke-width: 6;
        \\}
        \\.progress-ring .bg {
        \\  stroke: #2a2a2a;
        \\}
        \\.progress-ring .fg {
        \\  stroke: #f7a41d;
        \\  stroke-linecap: round;
        \\  transition: stroke-dashoffset 0.5s;
        \\}
        \\/* Main grid columns for desktop */
        \\@media (min-width: 1025px) {
        \\  .main-grid {
        \\    grid-template-columns: 1fr 320px;
        \\  }
        \\}
        \\/* Outline focus */
        \\input:focus, select:focus, textarea:focus {
        \\  outline: none;
        \\}
    );

    return sheet;
}

// ============================================================================
// Tests
// ============================================================================

test "generate stylesheet" {
    const allocator = std.testing.allocator;
    var sheet = try generateStylesheet(allocator);
    defer sheet.deinit();

    const css_output = try sheet.toCss();
    defer allocator.free(css_output);

    // Verify the output contains expected selectors
    try std.testing.expect(std.mem.indexOf(u8, css_output, ".task-item") != null);
    try std.testing.expect(std.mem.indexOf(u8, css_output, ".btn-primary") != null);
    try std.testing.expect(std.mem.indexOf(u8, css_output, "@keyframes spin") != null);
    try std.testing.expect(std.mem.indexOf(u8, css_output, "@media") != null);
}
