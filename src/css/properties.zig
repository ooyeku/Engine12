const std = @import("std");
const values = @import("values.zig");

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

/// Display property values
pub const Display = enum {
    none,
    block,
    @"inline",
    inline_block,
    flex,
    inline_flex,
    grid,
    inline_grid,
    flow_root,
    contents,
    table,
    table_row,
    table_cell,
    list_item,
    inherit,
    initial,
    unset,

    pub fn toCss(self: Display) []const u8 {
        return switch (self) {
            .none => "none",
            .block => "block",
            .@"inline" => "inline",
            .inline_block => "inline-block",
            .flex => "flex",
            .inline_flex => "inline-flex",
            .grid => "grid",
            .inline_grid => "inline-grid",
            .flow_root => "flow-root",
            .contents => "contents",
            .table => "table",
            .table_row => "table-row",
            .table_cell => "table-cell",
            .list_item => "list-item",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Position property values
pub const Position = enum {
    static,
    relative,
    absolute,
    fixed,
    sticky,
    inherit,
    initial,
    unset,

    pub fn toCss(self: Position) []const u8 {
        return switch (self) {
            .static => "static",
            .relative => "relative",
            .absolute => "absolute",
            .fixed => "fixed",
            .sticky => "sticky",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Flexbox direction
pub const FlexDirection = enum {
    row,
    row_reverse,
    column,
    column_reverse,
    inherit,
    initial,
    unset,

    pub fn toCss(self: FlexDirection) []const u8 {
        return switch (self) {
            .row => "row",
            .row_reverse => "row-reverse",
            .column => "column",
            .column_reverse => "column-reverse",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Flexbox wrap
pub const FlexWrap = enum {
    nowrap,
    wrap,
    wrap_reverse,
    inherit,
    initial,
    unset,

    pub fn toCss(self: FlexWrap) []const u8 {
        return switch (self) {
            .nowrap => "nowrap",
            .wrap => "wrap",
            .wrap_reverse => "wrap-reverse",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Justify content values
pub const JustifyContent = enum {
    flex_start,
    flex_end,
    center,
    space_between,
    space_around,
    space_evenly,
    start,
    end,
    left,
    right,
    stretch,
    inherit,
    initial,
    unset,

    pub fn toCss(self: JustifyContent) []const u8 {
        return switch (self) {
            .flex_start => "flex-start",
            .flex_end => "flex-end",
            .center => "center",
            .space_between => "space-between",
            .space_around => "space-around",
            .space_evenly => "space-evenly",
            .start => "start",
            .end => "end",
            .left => "left",
            .right => "right",
            .stretch => "stretch",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Align items values
pub const AlignItems = enum {
    flex_start,
    flex_end,
    center,
    baseline,
    stretch,
    start,
    end,
    self_start,
    self_end,
    inherit,
    initial,
    unset,

    pub fn toCss(self: AlignItems) []const u8 {
        return switch (self) {
            .flex_start => "flex-start",
            .flex_end => "flex-end",
            .center => "center",
            .baseline => "baseline",
            .stretch => "stretch",
            .start => "start",
            .end => "end",
            .self_start => "self-start",
            .self_end => "self-end",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Align content values
pub const AlignContent = enum {
    flex_start,
    flex_end,
    center,
    space_between,
    space_around,
    space_evenly,
    stretch,
    start,
    end,
    baseline,
    inherit,
    initial,
    unset,

    pub fn toCss(self: AlignContent) []const u8 {
        return switch (self) {
            .flex_start => "flex-start",
            .flex_end => "flex-end",
            .center => "center",
            .space_between => "space-between",
            .space_around => "space-around",
            .space_evenly => "space-evenly",
            .stretch => "stretch",
            .start => "start",
            .end => "end",
            .baseline => "baseline",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Align self values
pub const AlignSelf = enum {
    auto,
    flex_start,
    flex_end,
    center,
    baseline,
    stretch,
    inherit,
    initial,
    unset,

    pub fn toCss(self: AlignSelf) []const u8 {
        return switch (self) {
            .auto => "auto",
            .flex_start => "flex-start",
            .flex_end => "flex-end",
            .center => "center",
            .baseline => "baseline",
            .stretch => "stretch",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Text alignment
pub const TextAlign = enum {
    left,
    right,
    center,
    justify,
    justify_all,
    start,
    end,
    match_parent,
    inherit,
    initial,
    unset,

    pub fn toCss(self: TextAlign) []const u8 {
        return switch (self) {
            .left => "left",
            .right => "right",
            .center => "center",
            .justify => "justify",
            .justify_all => "justify-all",
            .start => "start",
            .end => "end",
            .match_parent => "match-parent",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Text decoration
pub const TextDecoration = enum {
    none,
    underline,
    overline,
    line_through,
    blink,
    inherit,
    initial,
    unset,

    pub fn toCss(self: TextDecoration) []const u8 {
        return switch (self) {
            .none => "none",
            .underline => "underline",
            .overline => "overline",
            .line_through => "line-through",
            .blink => "blink",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Text transform
pub const TextTransform = enum {
    none,
    capitalize,
    uppercase,
    lowercase,
    full_width,
    full_size_kana,
    inherit,
    initial,
    unset,

    pub fn toCss(self: TextTransform) []const u8 {
        return switch (self) {
            .none => "none",
            .capitalize => "capitalize",
            .uppercase => "uppercase",
            .lowercase => "lowercase",
            .full_width => "full-width",
            .full_size_kana => "full-size-kana",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Font weight
pub const FontWeight = union(enum) {
    normal,
    bold,
    bolder,
    lighter,
    numeric: u16,
    inherit,
    initial,
    unset,

    pub fn format(self: FontWeight, writer: anytype) !void {
        switch (self) {
            .normal => try writer.writeAll("normal"),
            .bold => try writer.writeAll("bold"),
            .bolder => try writer.writeAll("bolder"),
            .lighter => try writer.writeAll("lighter"),
            .numeric => |n| try writer.print("{d}", .{n}),
            .inherit => try writer.writeAll("inherit"),
            .initial => try writer.writeAll("initial"),
            .unset => try writer.writeAll("unset"),
        }
    }

    // Common weights
    pub const thin = FontWeight{ .numeric = 100 };
    pub const extra_light = FontWeight{ .numeric = 200 };
    pub const light = FontWeight{ .numeric = 300 };
    pub const regular = FontWeight{ .numeric = 400 };
    pub const medium = FontWeight{ .numeric = 500 };
    pub const semi_bold = FontWeight{ .numeric = 600 };
    pub const bold_700 = FontWeight{ .numeric = 700 };
    pub const extra_bold = FontWeight{ .numeric = 800 };
    pub const black = FontWeight{ .numeric = 900 };
};

/// Font style
pub const FontStyle = enum {
    normal,
    italic,
    oblique,
    inherit,
    initial,
    unset,

    pub fn toCss(self: FontStyle) []const u8 {
        return switch (self) {
            .normal => "normal",
            .italic => "italic",
            .oblique => "oblique",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Overflow property
pub const Overflow = enum {
    visible,
    hidden,
    clip,
    scroll,
    auto,
    inherit,
    initial,
    unset,

    pub fn toCss(self: Overflow) []const u8 {
        return switch (self) {
            .visible => "visible",
            .hidden => "hidden",
            .clip => "clip",
            .scroll => "scroll",
            .auto => "auto",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Visibility property
pub const Visibility = enum {
    visible,
    hidden,
    collapse,
    inherit,
    initial,
    unset,

    pub fn toCss(self: Visibility) []const u8 {
        return switch (self) {
            .visible => "visible",
            .hidden => "hidden",
            .collapse => "collapse",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Cursor property
pub const Cursor = enum {
    auto,
    default,
    none,
    context_menu,
    help,
    pointer,
    progress,
    wait,
    cell,
    crosshair,
    text,
    vertical_text,
    alias,
    copy,
    move,
    no_drop,
    not_allowed,
    grab,
    grabbing,
    all_scroll,
    col_resize,
    row_resize,
    n_resize,
    e_resize,
    s_resize,
    w_resize,
    ne_resize,
    nw_resize,
    se_resize,
    sw_resize,
    ew_resize,
    ns_resize,
    nesw_resize,
    nwse_resize,
    zoom_in,
    zoom_out,
    inherit,
    initial,
    unset,

    pub fn toCss(self: Cursor) []const u8 {
        return switch (self) {
            .auto => "auto",
            .default => "default",
            .none => "none",
            .context_menu => "context-menu",
            .help => "help",
            .pointer => "pointer",
            .progress => "progress",
            .wait => "wait",
            .cell => "cell",
            .crosshair => "crosshair",
            .text => "text",
            .vertical_text => "vertical-text",
            .alias => "alias",
            .copy => "copy",
            .move => "move",
            .no_drop => "no-drop",
            .not_allowed => "not-allowed",
            .grab => "grab",
            .grabbing => "grabbing",
            .all_scroll => "all-scroll",
            .col_resize => "col-resize",
            .row_resize => "row-resize",
            .n_resize => "n-resize",
            .e_resize => "e-resize",
            .s_resize => "s-resize",
            .w_resize => "w-resize",
            .ne_resize => "ne-resize",
            .nw_resize => "nw-resize",
            .se_resize => "se-resize",
            .sw_resize => "sw-resize",
            .ew_resize => "ew-resize",
            .ns_resize => "ns-resize",
            .nesw_resize => "nesw-resize",
            .nwse_resize => "nwse-resize",
            .zoom_in => "zoom-in",
            .zoom_out => "zoom-out",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Pointer events
pub const PointerEvents = enum {
    auto,
    none,
    visible_painted,
    visible_fill,
    visible_stroke,
    visible,
    painted,
    fill,
    stroke,
    all,
    inherit,
    initial,
    unset,

    pub fn toCss(self: PointerEvents) []const u8 {
        return switch (self) {
            .auto => "auto",
            .none => "none",
            .visible_painted => "visiblePainted",
            .visible_fill => "visibleFill",
            .visible_stroke => "visibleStroke",
            .visible => "visible",
            .painted => "painted",
            .fill => "fill",
            .stroke => "stroke",
            .all => "all",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// User select
pub const UserSelect = enum {
    none,
    auto,
    text,
    contain,
    all,
    inherit,
    initial,
    unset,

    pub fn toCss(self: UserSelect) []const u8 {
        return switch (self) {
            .none => "none",
            .auto => "auto",
            .text => "text",
            .contain => "contain",
            .all => "all",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// White space handling
pub const WhiteSpace = enum {
    normal,
    nowrap,
    pre,
    pre_wrap,
    pre_line,
    break_spaces,
    inherit,
    initial,
    unset,

    pub fn toCss(self: WhiteSpace) []const u8 {
        return switch (self) {
            .normal => "normal",
            .nowrap => "nowrap",
            .pre => "pre",
            .pre_wrap => "pre-wrap",
            .pre_line => "pre-line",
            .break_spaces => "break-spaces",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Word break
pub const WordBreak = enum {
    normal,
    break_all,
    keep_all,
    break_word,
    inherit,
    initial,
    unset,

    pub fn toCss(self: WordBreak) []const u8 {
        return switch (self) {
            .normal => "normal",
            .break_all => "break-all",
            .keep_all => "keep-all",
            .break_word => "break-word",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Object fit
pub const ObjectFit = enum {
    fill,
    contain,
    cover,
    none,
    scale_down,
    inherit,
    initial,
    unset,

    pub fn toCss(self: ObjectFit) []const u8 {
        return switch (self) {
            .fill => "fill",
            .contain => "contain",
            .cover => "cover",
            .none => "none",
            .scale_down => "scale-down",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Background size
pub const BackgroundSize = union(enum) {
    auto,
    cover,
    contain,
    length: struct { width: Length, height: ?Length },
    inherit,
    initial,
    unset,

    pub fn format(self: BackgroundSize, writer: anytype) !void {
        switch (self) {
            .auto => try writer.writeAll("auto"),
            .cover => try writer.writeAll("cover"),
            .contain => try writer.writeAll("contain"),
            .length => |l| {
                try l.width.format(writer);
                if (l.height) |h| {
                    try writer.writeAll(" ");
                    try h.format(writer);
                }
            },
            .inherit => try writer.writeAll("inherit"),
            .initial => try writer.writeAll("initial"),
            .unset => try writer.writeAll("unset"),
        }
    }
};

/// Background position
pub const BackgroundPosition = union(enum) {
    top,
    bottom,
    left,
    right,
    center,
    position: struct { x: Length, y: Length },
    inherit,
    initial,
    unset,

    pub fn format(self: BackgroundPosition, writer: anytype) !void {
        switch (self) {
            .top => try writer.writeAll("top"),
            .bottom => try writer.writeAll("bottom"),
            .left => try writer.writeAll("left"),
            .right => try writer.writeAll("right"),
            .center => try writer.writeAll("center"),
            .position => |p| {
                try p.x.format(writer);
                try writer.writeAll(" ");
                try p.y.format(writer);
            },
            .inherit => try writer.writeAll("inherit"),
            .initial => try writer.writeAll("initial"),
            .unset => try writer.writeAll("unset"),
        }
    }
};

/// Background repeat
pub const BackgroundRepeat = enum {
    repeat,
    repeat_x,
    repeat_y,
    no_repeat,
    space,
    round,
    inherit,
    initial,
    unset,

    pub fn toCss(self: BackgroundRepeat) []const u8 {
        return switch (self) {
            .repeat => "repeat",
            .repeat_x => "repeat-x",
            .repeat_y => "repeat-y",
            .no_repeat => "no-repeat",
            .space => "space",
            .round => "round",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Box sizing
pub const BoxSizing = enum {
    content_box,
    border_box,
    inherit,
    initial,
    unset,

    pub fn toCss(self: BoxSizing) []const u8 {
        return switch (self) {
            .content_box => "content-box",
            .border_box => "border-box",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// List style type
pub const ListStyleType = enum {
    none,
    disc,
    circle,
    square,
    decimal,
    decimal_leading_zero,
    lower_roman,
    upper_roman,
    lower_greek,
    lower_latin,
    upper_latin,
    armenian,
    georgian,
    lower_alpha,
    upper_alpha,
    inherit,
    initial,
    unset,

    pub fn toCss(self: ListStyleType) []const u8 {
        return switch (self) {
            .none => "none",
            .disc => "disc",
            .circle => "circle",
            .square => "square",
            .decimal => "decimal",
            .decimal_leading_zero => "decimal-leading-zero",
            .lower_roman => "lower-roman",
            .upper_roman => "upper-roman",
            .lower_greek => "lower-greek",
            .lower_latin => "lower-latin",
            .upper_latin => "upper-latin",
            .armenian => "armenian",
            .georgian => "georgian",
            .lower_alpha => "lower-alpha",
            .upper_alpha => "upper-alpha",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// List style position
pub const ListStylePosition = enum {
    inside,
    outside,
    inherit,
    initial,
    unset,

    pub fn toCss(self: ListStylePosition) []const u8 {
        return switch (self) {
            .inside => "inside",
            .outside => "outside",
            .inherit => "inherit",
            .initial => "initial",
            .unset => "unset",
        };
    }
};

/// Flex value for flex-grow, flex-shrink
pub const Flex = union(enum) {
    none,
    auto,
    initial,
    value: struct { grow: f32, shrink: f32, basis: Length },
    inherit,
    unset,

    pub fn format(self: Flex, writer: anytype) !void {
        switch (self) {
            .none => try writer.writeAll("none"),
            .auto => try writer.writeAll("auto"),
            .initial => try writer.writeAll("initial"),
            .value => |v| {
                try writer.print("{d} {d} ", .{ v.grow, v.shrink });
                try v.basis.format(writer);
            },
            .inherit => try writer.writeAll("inherit"),
            .unset => try writer.writeAll("unset"),
        }
    }
};

/// Grid template
pub const GridTemplate = union(enum) {
    none,
    auto,
    tracks: []const GridTrack,
    inherit,
    initial,
    unset,

    pub const GridTrack = union(enum) {
        length: Length,
        fr: f32,
        min_content,
        max_content,
        auto,
        minmax: struct { min: Length, max: Length },
        repeat: struct { count: u32, track: *const GridTrack },
    };
};

/// Gap (for grid and flexbox)
pub const Gap = union(enum) {
    single: Length,
    both: struct { row: Length, column: Length },
    inherit,
    initial,
    unset,

    pub fn format(self: Gap, writer: anytype) !void {
        switch (self) {
            .single => |l| try l.format(writer),
            .both => |g| {
                try g.row.format(writer);
                try writer.writeAll(" ");
                try g.column.format(writer);
            },
            .inherit => try writer.writeAll("inherit"),
            .initial => try writer.writeAll("initial"),
            .unset => try writer.writeAll("unset"),
        }
    }
};

/// Aspect ratio
pub const AspectRatio = union(enum) {
    auto,
    ratio: struct { width: f32, height: f32 },
    inherit,
    initial,
    unset,

    pub fn format(self: AspectRatio, writer: anytype) !void {
        switch (self) {
            .auto => try writer.writeAll("auto"),
            .ratio => |r| try writer.print("{d} / {d}", .{ r.width, r.height }),
            .inherit => try writer.writeAll("inherit"),
            .initial => try writer.writeAll("initial"),
            .unset => try writer.writeAll("unset"),
        }
    }

    pub const square = AspectRatio{ .ratio = .{ .width = 1, .height = 1 } };
    pub const video = AspectRatio{ .ratio = .{ .width = 16, .height = 9 } };
    pub const portrait = AspectRatio{ .ratio = .{ .width = 3, .height = 4 } };
    pub const landscape = AspectRatio{ .ratio = .{ .width = 4, .height = 3 } };
};

/// Z-index
pub const ZIndex = union(enum) {
    auto,
    value: i32,
    inherit,
    initial,
    unset,

    pub fn format(self: ZIndex, writer: anytype) !void {
        switch (self) {
            .auto => try writer.writeAll("auto"),
            .value => |v| try writer.print("{d}", .{v}),
            .inherit => try writer.writeAll("inherit"),
            .initial => try writer.writeAll("initial"),
            .unset => try writer.writeAll("unset"),
        }
    }
};

/// Opacity
pub const Opacity = union(enum) {
    value: f32,
    inherit,
    initial,
    unset,

    pub fn format(self: Opacity, writer: anytype) !void {
        switch (self) {
            .value => |v| try writer.print("{d}", .{v}),
            .inherit => try writer.writeAll("inherit"),
            .initial => try writer.writeAll("initial"),
            .unset => try writer.writeAll("unset"),
        }
    }
};

/// Transition property
pub const Transition = struct {
    property: []const u8 = "all",
    duration: Duration = .{ .ms = 200 },
    timing_function: TimingFunction = .ease,
    delay: Duration = .{ .ms = 0 },

    pub fn format(self: Transition, writer: anytype) !void {
        try writer.writeAll(self.property);
        try writer.writeAll(" ");
        try self.duration.format(writer);
        try writer.writeAll(" ");
        try self.timing_function.format(writer);
        try writer.writeAll(" ");
        try self.delay.format(writer);
    }
};

// Test
test "Display toCss" {
    try std.testing.expectEqualStrings("flex", Display.flex.toCss());
    try std.testing.expectEqualStrings("inline-block", Display.inline_block.toCss());
}

test "FontWeight format" {
    var buf: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try FontWeight.semi_bold.format(stream.writer());
    try std.testing.expectEqualStrings("600", stream.getWritten());
}
