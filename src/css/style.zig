const std = @import("std");
const values = @import("values.zig");
const properties = @import("properties.zig");

pub const Length = values.Length;
pub const Color = values.Color;
pub const Duration = values.Duration;
pub const Angle = values.Angle;
pub const BoxShadow = values.BoxShadow;
pub const BoxShadowList = values.BoxShadowList;
pub const TextShadow = values.TextShadow;
pub const Border = values.Border;
pub const Gradient = values.Gradient;
pub const Transform = values.Transform;
pub const TimingFunction = values.TimingFunction;
pub const Filter = values.Filter;

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

/// Complete CSS style definition
/// All properties are optional - only set properties will be rendered
pub const Style = struct {
    // Layout
    display: ?Display = null,
    position: ?Position = null,
    top: ?Length = null,
    right: ?Length = null,
    bottom: ?Length = null,
    left: ?Length = null,
    inset: ?Length = null,
    z_index: ?ZIndex = null,
    float: ?Float = null,
    clear: ?Clear = null,

    // Box Model
    width: ?Length = null,
    height: ?Length = null,
    min_width: ?Length = null,
    min_height: ?Length = null,
    max_width: ?Length = null,
    max_height: ?Length = null,
    margin: ?Sides = null,
    margin_top: ?Length = null,
    margin_right: ?Length = null,
    margin_bottom: ?Length = null,
    margin_left: ?Length = null,
    padding: ?Sides = null,
    padding_top: ?Length = null,
    padding_right: ?Length = null,
    padding_bottom: ?Length = null,
    padding_left: ?Length = null,
    box_sizing: ?BoxSizing = null,
    aspect_ratio: ?AspectRatio = null,

    // Flexbox
    flex_direction: ?FlexDirection = null,
    flex_wrap: ?FlexWrap = null,
    justify_content: ?JustifyContent = null,
    align_items: ?AlignItems = null,
    align_content: ?AlignContent = null,
    align_self: ?AlignSelf = null,
    flex: ?Flex = null,
    flex_grow: ?f32 = null,
    flex_shrink: ?f32 = null,
    flex_basis: ?Length = null,
    order: ?i32 = null,
    gap: ?Gap = null,
    row_gap: ?Length = null,
    column_gap: ?Length = null,

    // Grid
    grid_template_columns: ?[]const u8 = null,
    grid_template_rows: ?[]const u8 = null,
    grid_column: ?[]const u8 = null,
    grid_row: ?[]const u8 = null,
    grid_area: ?[]const u8 = null,
    grid_auto_flow: ?GridAutoFlow = null,
    place_items: ?PlaceItems = null,
    place_content: ?PlaceContent = null,

    // Background
    background: ?Background = null,
    background_color: ?Color = null,
    background_image: ?[]const u8 = null,
    background_gradient: ?Gradient = null, // Type-safe gradient support
    background_size: ?BackgroundSize = null,
    background_position: ?BackgroundPosition = null,
    background_repeat: ?BackgroundRepeat = null,
    background_attachment: ?BackgroundAttachment = null,
    background_clip: ?BackgroundClip = null,

    // Border
    border: ?Border = null,
    border_top: ?Border = null,
    border_right: ?Border = null,
    border_bottom: ?Border = null,
    border_left: ?Border = null,
    border_width: ?Length = null,
    border_style: ?Border.BorderStyle = null,
    border_color: ?Color = null,
    border_radius: ?Corners = null,
    border_top_left_radius: ?Length = null,
    border_top_right_radius: ?Length = null,
    border_bottom_right_radius: ?Length = null,
    border_bottom_left_radius: ?Length = null,
    border_collapse: ?BorderCollapse = null,

    // Outline
    outline: ?Border = null,
    outline_width: ?Length = null,
    outline_style: ?Border.BorderStyle = null,
    outline_color: ?Color = null,
    outline_offset: ?Length = null,

    // Typography
    color: ?Color = null,
    font_family: ?[]const u8 = null,
    font_size: ?Length = null,
    font_weight: ?FontWeight = null,
    font_style: ?FontStyle = null,
    line_height: ?LineHeight = null,
    letter_spacing: ?Length = null,
    text_align: ?TextAlign = null,
    text_decoration: ?TextDecoration = null,
    text_decoration_color: ?Color = null,
    text_decoration_style: ?TextDecorationStyle = null,
    text_decoration_thickness: ?Length = null,
    text_transform: ?TextTransform = null,
    text_indent: ?Length = null,
    text_overflow: ?TextOverflow = null,
    text_shadow: ?TextShadow = null,
    white_space: ?WhiteSpace = null,
    word_break: ?WordBreak = null,
    word_spacing: ?Length = null,
    vertical_align: ?VerticalAlign = null,

    // Visual Effects
    opacity: ?Opacity = null,
    visibility: ?Visibility = null,
    box_shadow: ?BoxShadow = null,
    box_shadows: ?BoxShadowList = null, // Multiple shadows support
    filter: ?Filter = null,
    backdrop_filter: ?Filter = null,
    mix_blend_mode: ?BlendMode = null,
    background_blend_mode: ?BlendMode = null,

    // Transform
    transform: ?Transform = null,
    transform_origin: ?TransformOrigin = null,
    perspective: ?Length = null,
    perspective_origin: ?TransformOrigin = null,

    // Transitions & Animations
    transition: ?Transition = null,
    transition_property: ?[]const u8 = null,
    transition_duration: ?Duration = null,
    transition_timing_function: ?TimingFunction = null,
    transition_delay: ?Duration = null,
    animation: ?[]const u8 = null,
    animation_name: ?[]const u8 = null,
    animation_duration: ?Duration = null,
    animation_timing_function: ?TimingFunction = null,
    animation_delay: ?Duration = null,
    animation_iteration_count: ?AnimationIterationCount = null,
    animation_direction: ?AnimationDirection = null,
    animation_fill_mode: ?AnimationFillMode = null,
    animation_play_state: ?AnimationPlayState = null,

    // Overflow & Clipping
    overflow: ?Overflow = null,
    overflow_x: ?Overflow = null,
    overflow_y: ?Overflow = null,
    clip_path: ?[]const u8 = null,

    // Interaction
    cursor: ?Cursor = null,
    pointer_events: ?PointerEvents = null,
    user_select: ?UserSelect = null,
    resize: ?Resize = null,
    touch_action: ?TouchAction = null,
    scroll_behavior: ?ScrollBehavior = null,

    // Lists
    list_style: ?[]const u8 = null,
    list_style_type: ?properties.ListStyleType = null,
    list_style_position: ?properties.ListStylePosition = null,
    list_style_image: ?[]const u8 = null,

    // Tables
    table_layout: ?TableLayout = null,

    // Object
    object_fit: ?ObjectFit = null,
    object_position: ?BackgroundPosition = null,

    // Content
    content: ?[]const u8 = null,

    // Will Change
    will_change: ?[]const u8 = null,

    // Custom properties (CSS variables)
    custom: ?[]const CustomProperty = null,

    // Pseudo-class styles
    hover: ?*const Style = null,
    focus: ?*const Style = null,
    active: ?*const Style = null,
    visited: ?*const Style = null,
    disabled: ?*const Style = null,
    first_child: ?*const Style = null,
    last_child: ?*const Style = null,
    nth_child: ?NthChild = null,
    focus_visible: ?*const Style = null,
    focus_within: ?*const Style = null,

    // Pseudo-element styles
    before: ?*const Style = null,
    after: ?*const Style = null,
    placeholder: ?*const Style = null,
    selection: ?*const Style = null,
    first_line: ?*const Style = null,
    first_letter: ?*const Style = null,

    /// Additional types
    pub const Float = enum { none, left, right, inherit, initial, unset };
    pub const Clear = enum { none, left, right, both, inherit, initial, unset };

    pub const Sides = union(enum) {
        all: Length,
        vertical_horizontal: struct { vertical: Length, horizontal: Length },
        top_horizontal_bottom: struct { top: Length, horizontal: Length, bottom: Length },
        each: struct { top: Length, right: Length, bottom: Length, left: Length },

        pub fn format(self: Sides, writer: anytype) !void {
            switch (self) {
                .all => |l| try l.format(writer),
                .vertical_horizontal => |vh| {
                    try vh.vertical.format(writer);
                    try writer.writeAll(" ");
                    try vh.horizontal.format(writer);
                },
                .top_horizontal_bottom => |thb| {
                    try thb.top.format(writer);
                    try writer.writeAll(" ");
                    try thb.horizontal.format(writer);
                    try writer.writeAll(" ");
                    try thb.bottom.format(writer);
                },
                .each => |e| {
                    try e.top.format(writer);
                    try writer.writeAll(" ");
                    try e.right.format(writer);
                    try writer.writeAll(" ");
                    try e.bottom.format(writer);
                    try writer.writeAll(" ");
                    try e.left.format(writer);
                },
            }
        }
    };

    pub const Corners = union(enum) {
        all: Length,
        each: struct { top_left: Length, top_right: Length, bottom_right: Length, bottom_left: Length },

        pub fn format(self: Corners, writer: anytype) !void {
            switch (self) {
                .all => |l| try l.format(writer),
                .each => |e| {
                    try e.top_left.format(writer);
                    try writer.writeAll(" ");
                    try e.top_right.format(writer);
                    try writer.writeAll(" ");
                    try e.bottom_right.format(writer);
                    try writer.writeAll(" ");
                    try e.bottom_left.format(writer);
                },
            }
        }
    };

    pub const LineHeight = union(enum) {
        normal,
        number: f32,
        length: Length,
        inherit,
        initial,
        unset,

        pub fn format(self: LineHeight, writer: anytype) !void {
            switch (self) {
                .normal => try writer.writeAll("normal"),
                .number => |n| try writer.print("{d}", .{n}),
                .length => |l| try l.format(writer),
                .inherit => try writer.writeAll("inherit"),
                .initial => try writer.writeAll("initial"),
                .unset => try writer.writeAll("unset"),
            }
        }
    };

    pub const GridAutoFlow = enum { row, column, dense, row_dense, column_dense };
    pub const PlaceItems = enum { start, end, center, stretch };
    pub const PlaceContent = enum { start, end, center, stretch, space_between, space_around, space_evenly };
    pub const BackgroundAttachment = enum { scroll, fixed, local };
    pub const BackgroundClip = enum { border_box, padding_box, content_box, text };
    pub const BorderCollapse = enum { collapse, separate };
    pub const TextDecorationStyle = enum { solid, double, dotted, dashed, wavy };
    pub const TextOverflow = enum { clip, ellipsis };
    pub const VerticalAlign = enum { baseline, sub, super, text_top, text_bottom, middle, top, bottom };
    pub const BlendMode = enum { normal, multiply, screen, overlay, darken, lighten, color_dodge, color_burn, hard_light, soft_light, difference, exclusion, hue, saturation, color, luminosity };
    pub const AnimationIterationCount = union(enum) { count: f32, infinite };
    pub const AnimationDirection = enum { normal, reverse, alternate, alternate_reverse };
    pub const AnimationFillMode = enum { none, forwards, backwards, both };
    pub const AnimationPlayState = enum { running, paused };
    pub const Resize = enum { none, both, horizontal, vertical };
    pub const TouchAction = enum { auto, none, pan_x, pan_y, pan_left, pan_right, pan_up, pan_down, pinch_zoom, manipulation };
    pub const ScrollBehavior = enum { auto, smooth };
    pub const TableLayout = enum { auto, fixed };

    pub const TransformOrigin = union(enum) {
        keywords: struct { x: enum { left, center, right }, y: enum { top, center, bottom } },
        position: struct { x: Length, y: Length },
    };

    pub const Background = struct {
        color: ?Color = null,
        image: ?[]const u8 = null,
        position: ?BackgroundPosition = null,
        size: ?BackgroundSize = null,
        repeat: ?BackgroundRepeat = null,
        attachment: ?BackgroundAttachment = null,
    };

    pub const NthChild = struct {
        formula: []const u8, // e.g., "2n+1", "odd", "even", "3"
        style: *const Style,
    };

    pub const CustomProperty = struct {
        name: []const u8,
        value: []const u8,
    };

    /// Merge two styles, with other taking precedence
    pub fn merge(self: Style, other: Style) Style {
        var result = self;
        inline for (@typeInfo(Style).@"struct".fields) |field| {
            const other_value = @field(other, field.name);
            if (other_value != null) {
                @field(result, field.name) = other_value;
            }
        }
        return result;
    }

    /// Create a style with common layout presets
    pub fn flexCenter() Style {
        return .{
            .display = .flex,
            .justify_content = .center,
            .align_items = .center,
        };
    }

    pub fn flexColumn() Style {
        return .{
            .display = .flex,
            .flex_direction = .column,
        };
    }

    pub fn flexRow() Style {
        return .{
            .display = .flex,
            .flex_direction = .row,
        };
    }

    pub fn absoluteFill() Style {
        return .{
            .position = .absolute,
            .inset = .zero,
        };
    }

    pub fn fixedFill() Style {
        return .{
            .position = .fixed,
            .inset = .zero,
        };
    }

    pub fn gridCenter() Style {
        return .{
            .display = .grid,
            .place_items = .center,
        };
    }

    /// Render the style to CSS
    pub fn toCss(self: Style, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(allocator);
        try self.writeCss(buf.writer(allocator));
        return try buf.toOwnedSlice(allocator);
    }

    /// Write CSS to a writer
    pub fn writeCss(self: Style, writer: anytype) !void {
        // Layout
        if (self.display) |v| try writeProperty(writer, "display", v.toCss());
        if (self.position) |v| try writeProperty(writer, "position", v.toCss());
        if (self.top) |v| try writePropertyValue(writer, "top", v);
        if (self.right) |v| try writePropertyValue(writer, "right", v);
        if (self.bottom) |v| try writePropertyValue(writer, "bottom", v);
        if (self.left) |v| try writePropertyValue(writer, "left", v);
        if (self.inset) |v| try writePropertyValue(writer, "inset", v);
        if (self.z_index) |v| try writePropertyValue(writer, "z-index", v);

        // Box Model
        if (self.width) |v| try writePropertyValue(writer, "width", v);
        if (self.height) |v| try writePropertyValue(writer, "height", v);
        if (self.min_width) |v| try writePropertyValue(writer, "min-width", v);
        if (self.min_height) |v| try writePropertyValue(writer, "min-height", v);
        if (self.max_width) |v| try writePropertyValue(writer, "max-width", v);
        if (self.max_height) |v| try writePropertyValue(writer, "max-height", v);
        if (self.margin) |v| try writePropertyValue(writer, "margin", v);
        if (self.margin_top) |v| try writePropertyValue(writer, "margin-top", v);
        if (self.margin_right) |v| try writePropertyValue(writer, "margin-right", v);
        if (self.margin_bottom) |v| try writePropertyValue(writer, "margin-bottom", v);
        if (self.margin_left) |v| try writePropertyValue(writer, "margin-left", v);
        if (self.padding) |v| try writePropertyValue(writer, "padding", v);
        if (self.padding_top) |v| try writePropertyValue(writer, "padding-top", v);
        if (self.padding_right) |v| try writePropertyValue(writer, "padding-right", v);
        if (self.padding_bottom) |v| try writePropertyValue(writer, "padding-bottom", v);
        if (self.padding_left) |v| try writePropertyValue(writer, "padding-left", v);
        if (self.box_sizing) |v| try writeProperty(writer, "box-sizing", v.toCss());
        if (self.aspect_ratio) |v| try writePropertyValue(writer, "aspect-ratio", v);

        // Flexbox
        if (self.flex_direction) |v| try writeProperty(writer, "flex-direction", v.toCss());
        if (self.flex_wrap) |v| try writeProperty(writer, "flex-wrap", v.toCss());
        if (self.justify_content) |v| try writeProperty(writer, "justify-content", v.toCss());
        if (self.align_items) |v| try writeProperty(writer, "align-items", v.toCss());
        if (self.align_content) |v| try writeProperty(writer, "align-content", v.toCss());
        if (self.align_self) |v| try writeProperty(writer, "align-self", v.toCss());
        if (self.flex) |v| try writePropertyValue(writer, "flex", v);
        if (self.flex_grow) |v| try writer.print("flex-grow:{d};", .{v});
        if (self.flex_shrink) |v| try writer.print("flex-shrink:{d};", .{v});
        if (self.flex_basis) |v| try writePropertyValue(writer, "flex-basis", v);
        if (self.order) |v| try writer.print("order:{d};", .{v});
        if (self.gap) |v| try writePropertyValue(writer, "gap", v);
        if (self.row_gap) |v| try writePropertyValue(writer, "row-gap", v);
        if (self.column_gap) |v| try writePropertyValue(writer, "column-gap", v);

        // Grid
        if (self.grid_template_columns) |v| try writeProperty(writer, "grid-template-columns", v);
        if (self.grid_template_rows) |v| try writeProperty(writer, "grid-template-rows", v);
        if (self.grid_column) |v| try writeProperty(writer, "grid-column", v);
        if (self.grid_row) |v| try writeProperty(writer, "grid-row", v);
        if (self.grid_area) |v| try writeProperty(writer, "grid-area", v);

        // Background
        if (self.background_color) |v| try writePropertyValue(writer, "background-color", v);
        if (self.background_image) |v| try writeProperty(writer, "background-image", v);
        if (self.background_gradient) |v| try writePropertyValue(writer, "background-image", v);
        if (self.background_size) |v| try writePropertyValue(writer, "background-size", v);
        if (self.background_position) |v| try writePropertyValue(writer, "background-position", v);
        if (self.background_repeat) |v| try writeProperty(writer, "background-repeat", v.toCss());

        // Border
        if (self.border) |v| try writePropertyValue(writer, "border", v);
        if (self.border_top) |v| try writePropertyValue(writer, "border-top", v);
        if (self.border_right) |v| try writePropertyValue(writer, "border-right", v);
        if (self.border_bottom) |v| try writePropertyValue(writer, "border-bottom", v);
        if (self.border_left) |v| try writePropertyValue(writer, "border-left", v);
        if (self.border_width) |v| try writePropertyValue(writer, "border-width", v);
        if (self.border_style) |v| try writeProperty(writer, "border-style", v.toCss());
        if (self.border_color) |v| try writePropertyValue(writer, "border-color", v);
        if (self.border_radius) |v| try writePropertyValue(writer, "border-radius", v);
        if (self.border_top_left_radius) |v| try writePropertyValue(writer, "border-top-left-radius", v);
        if (self.border_top_right_radius) |v| try writePropertyValue(writer, "border-top-right-radius", v);
        if (self.border_bottom_right_radius) |v| try writePropertyValue(writer, "border-bottom-right-radius", v);
        if (self.border_bottom_left_radius) |v| try writePropertyValue(writer, "border-bottom-left-radius", v);

        // Outline
        if (self.outline) |v| try writePropertyValue(writer, "outline", v);
        if (self.outline_offset) |v| try writePropertyValue(writer, "outline-offset", v);

        // Typography
        if (self.color) |v| try writePropertyValue(writer, "color", v);
        if (self.font_family) |v| try writeProperty(writer, "font-family", v);
        if (self.font_size) |v| try writePropertyValue(writer, "font-size", v);
        if (self.font_weight) |v| try writePropertyValue(writer, "font-weight", v);
        if (self.font_style) |v| try writeProperty(writer, "font-style", v.toCss());
        if (self.line_height) |v| try writePropertyValue(writer, "line-height", v);
        if (self.letter_spacing) |v| try writePropertyValue(writer, "letter-spacing", v);
        if (self.text_align) |v| try writeProperty(writer, "text-align", v.toCss());
        if (self.text_decoration) |v| try writeProperty(writer, "text-decoration", v.toCss());
        if (self.text_transform) |v| try writeProperty(writer, "text-transform", v.toCss());
        if (self.text_indent) |v| try writePropertyValue(writer, "text-indent", v);
        if (self.text_shadow) |v| try writePropertyValue(writer, "text-shadow", v);
        if (self.white_space) |v| try writeProperty(writer, "white-space", v.toCss());
        if (self.word_break) |v| try writeProperty(writer, "word-break", v.toCss());

        // Visual Effects
        if (self.opacity) |v| try writePropertyValue(writer, "opacity", v);
        if (self.visibility) |v| try writeProperty(writer, "visibility", v.toCss());
        if (self.box_shadow) |v| try writePropertyValue(writer, "box-shadow", v);
        if (self.box_shadows) |v| try writePropertyValue(writer, "box-shadow", v);
        if (self.filter) |v| try writePropertyValue(writer, "filter", v);
        if (self.backdrop_filter) |v| try writePropertyValue(writer, "backdrop-filter", v);

        // Transform
        if (self.transform) |v| try writePropertyValue(writer, "transform", v);

        // Transitions
        if (self.transition) |v| try writePropertyValue(writer, "transition", v);
        if (self.transition_property) |v| try writeProperty(writer, "transition-property", v);
        if (self.transition_duration) |v| try writePropertyValue(writer, "transition-duration", v);
        if (self.transition_timing_function) |v| try writePropertyValue(writer, "transition-timing-function", v);
        if (self.transition_delay) |v| try writePropertyValue(writer, "transition-delay", v);

        // Animation
        if (self.animation) |v| try writeProperty(writer, "animation", v);
        if (self.animation_name) |v| try writeProperty(writer, "animation-name", v);
        if (self.animation_duration) |v| try writePropertyValue(writer, "animation-duration", v);

        // Overflow
        if (self.overflow) |v| try writeProperty(writer, "overflow", v.toCss());
        if (self.overflow_x) |v| try writeProperty(writer, "overflow-x", v.toCss());
        if (self.overflow_y) |v| try writeProperty(writer, "overflow-y", v.toCss());

        // Interaction
        if (self.cursor) |v| try writeProperty(writer, "cursor", v.toCss());
        if (self.pointer_events) |v| try writeProperty(writer, "pointer-events", v.toCss());
        if (self.user_select) |v| try writeProperty(writer, "user-select", v.toCss());

        // Object
        if (self.object_fit) |v| try writeProperty(writer, "object-fit", v.toCss());

        // Content
        if (self.content) |v| try writer.print("content:\"{s}\";", .{v});

        // Will Change
        if (self.will_change) |v| try writeProperty(writer, "will-change", v);

        // Custom properties
        if (self.custom) |customs| {
            for (customs) |prop| {
                try writer.print("--{s}:{s};", .{ prop.name, prop.value });
            }
        }
    }

    fn writeProperty(writer: anytype, name: []const u8, value: []const u8) !void {
        try writer.print("{s}:{s};", .{ name, value });
    }

    fn writePropertyValue(writer: anytype, name: []const u8, value: anytype) !void {
        try writer.print("{s}:", .{name});
        try value.format(writer);
        try writer.writeAll(";");
    }
};

// Tests
test "Style to CSS - basic properties" {
    const style = Style{
        .display = .flex,
        .padding = .{ .all = .{ .px = 16 } },
        .background_color = Color.fromHex("#ffffff"),
    };

    const allocator = std.testing.allocator;
    const css = try style.toCss(allocator);
    defer allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, "display:flex;") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "padding:16px;") != null);
}

test "Style merge" {
    const base = Style{
        .display = .block,
        .color = Color.black,
    };

    const override = Style{
        .color = Color.red,
        .padding = .{ .all = .{ .px = 8 } },
    };

    const merged = base.merge(override);
    try std.testing.expect(merged.display == .block);
    try std.testing.expect(merged.color.?.r == 255);
    try std.testing.expect(merged.padding != null);
}

test "Style presets" {
    const centered = Style.flexCenter();
    try std.testing.expect(centered.display == .flex);
    try std.testing.expect(centered.justify_content == .center);
    try std.testing.expect(centered.align_items == .center);
}
