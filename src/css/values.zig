const std = @import("std");

/// CSS length units
pub const Length = union(enum) {
    px: f32,
    em: f32,
    rem: f32,
    percent: f32,
    vh: f32,
    vw: f32,
    vmin: f32,
    vmax: f32,
    ch: f32,
    ex: f32,
    cap: f32,
    ic: f32,
    lh: f32,
    rlh: f32,
    cm: f32,
    mm: f32,
    in: f32,
    pt: f32,
    pc: f32,
    auto,
    zero,
    inherit,
    initial,
    unset,

    pub fn format(self: Length, writer: anytype) !void {
        switch (self) {
            .px => |v| try writer.print("{d}px", .{v}),
            .em => |v| try writer.print("{d}em", .{v}),
            .rem => |v| try writer.print("{d}rem", .{v}),
            .percent => |v| try writer.print("{d}%", .{v}),
            .vh => |v| try writer.print("{d}vh", .{v}),
            .vw => |v| try writer.print("{d}vw", .{v}),
            .vmin => |v| try writer.print("{d}vmin", .{v}),
            .vmax => |v| try writer.print("{d}vmax", .{v}),
            .ch => |v| try writer.print("{d}ch", .{v}),
            .ex => |v| try writer.print("{d}ex", .{v}),
            .cap => |v| try writer.print("{d}cap", .{v}),
            .ic => |v| try writer.print("{d}ic", .{v}),
            .lh => |v| try writer.print("{d}lh", .{v}),
            .rlh => |v| try writer.print("{d}rlh", .{v}),
            .cm => |v| try writer.print("{d}cm", .{v}),
            .mm => |v| try writer.print("{d}mm", .{v}),
            .in => |v| try writer.print("{d}in", .{v}),
            .pt => |v| try writer.print("{d}pt", .{v}),
            .pc => |v| try writer.print("{d}pc", .{v}),
            .auto => try writer.writeAll("auto"),
            .zero => try writer.writeAll("0"),
            .inherit => try writer.writeAll("inherit"),
            .initial => try writer.writeAll("initial"),
            .unset => try writer.writeAll("unset"),
        }
    }

    pub fn toCss(self: Length, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try self.format(buf.writer(allocator));
        return try buf.toOwnedSlice(allocator);
    }
};

/// RGBA color representation
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: f32 = 1.0,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1.0 };
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn fromHex(comptime hex: []const u8) Color {
        const h = if (hex[0] == '#') hex[1..] else hex;
        return switch (h.len) {
            3 => .{
                .r = parseHexDigit(h[0]) * 17,
                .g = parseHexDigit(h[1]) * 17,
                .b = parseHexDigit(h[2]) * 17,
                .a = 1.0,
            },
            4 => .{
                .r = parseHexDigit(h[0]) * 17,
                .g = parseHexDigit(h[1]) * 17,
                .b = parseHexDigit(h[2]) * 17,
                .a = @as(f32, @floatFromInt(parseHexDigit(h[3]) * 17)) / 255.0,
            },
            6 => .{
                .r = parseHexPair(h[0..2]),
                .g = parseHexPair(h[2..4]),
                .b = parseHexPair(h[4..6]),
                .a = 1.0,
            },
            8 => .{
                .r = parseHexPair(h[0..2]),
                .g = parseHexPair(h[2..4]),
                .b = parseHexPair(h[4..6]),
                .a = @as(f32, @floatFromInt(parseHexPair(h[6..8]))) / 255.0,
            },
            else => @compileError("Invalid hex color format"),
        };
    }

    fn parseHexDigit(c: u8) u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => 0,
        };
    }

    fn parseHexPair(comptime pair: *const [2]u8) u8 {
        return parseHexDigit(pair[0]) * 16 + parseHexDigit(pair[1]);
    }

    pub fn format(self: Color, writer: anytype) !void {
        if (self.a >= 1.0) {
            try writer.print("#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b });
        } else {
            try writer.print("rgba({d},{d},{d},{d:.2})", .{ self.r, self.g, self.b, self.a });
        }
    }

    pub fn toCss(self: Color, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try self.format(buf.writer(allocator));
        return try buf.toOwnedSlice(allocator);
    }

    // Named colors
    pub const transparent = Color.rgba(0, 0, 0, 0);
    pub const black = Color.rgb(0, 0, 0);
    pub const white = Color.rgb(255, 255, 255);
    pub const red = Color.rgb(255, 0, 0);
    pub const green = Color.rgb(0, 128, 0);
    pub const blue = Color.rgb(0, 0, 255);
    pub const yellow = Color.rgb(255, 255, 0);
    pub const cyan = Color.rgb(0, 255, 255);
    pub const magenta = Color.rgb(255, 0, 255);
    pub const gray = Color.rgb(128, 128, 128);
    pub const orange = Color.rgb(255, 165, 0);
    pub const purple = Color.rgb(128, 0, 128);
    pub const pink = Color.rgb(255, 192, 203);

    /// Lighten color by percentage (0.0 - 1.0)
    pub fn lighten(self: Color, amount: f32) Color {
        const factor = 1.0 + amount;
        return .{
            .r = @min(255, @as(u8, @intFromFloat(@as(f32, @floatFromInt(self.r)) * factor))),
            .g = @min(255, @as(u8, @intFromFloat(@as(f32, @floatFromInt(self.g)) * factor))),
            .b = @min(255, @as(u8, @intFromFloat(@as(f32, @floatFromInt(self.b)) * factor))),
            .a = self.a,
        };
    }

    /// Darken color by percentage (0.0 - 1.0)
    pub fn darken(self: Color, amount: f32) Color {
        const factor = 1.0 - amount;
        return .{
            .r = @as(u8, @intFromFloat(@as(f32, @floatFromInt(self.r)) * factor)),
            .g = @as(u8, @intFromFloat(@as(f32, @floatFromInt(self.g)) * factor)),
            .b = @as(u8, @intFromFloat(@as(f32, @floatFromInt(self.b)) * factor)),
            .a = self.a,
        };
    }

    /// Set alpha transparency
    pub fn withAlpha(self: Color, a: f32) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }
};

/// Time duration for animations
pub const Duration = union(enum) {
    ms: u32,
    s: f32,
    inherit,
    initial,
    unset,

    pub fn format(self: Duration, writer: anytype) !void {
        switch (self) {
            .ms => |v| try writer.print("{d}ms", .{v}),
            .s => |v| try writer.print("{d}s", .{v}),
            .inherit => try writer.writeAll("inherit"),
            .initial => try writer.writeAll("initial"),
            .unset => try writer.writeAll("unset"),
        }
    }

    pub fn toCss(self: Duration, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try self.format(buf.writer(allocator));
        return try buf.toOwnedSlice(allocator);
    }
};

/// Angle units
pub const Angle = union(enum) {
    deg: f32,
    rad: f32,
    grad: f32,
    turn: f32,
    inherit,
    initial,
    unset,

    pub fn format(self: Angle, writer: anytype) !void {
        switch (self) {
            .deg => |v| try writer.print("{d}deg", .{v}),
            .rad => |v| try writer.print("{d}rad", .{v}),
            .grad => |v| try writer.print("{d}grad", .{v}),
            .turn => |v| try writer.print("{d}turn", .{v}),
            .inherit => try writer.writeAll("inherit"),
            .initial => try writer.writeAll("initial"),
            .unset => try writer.writeAll("unset"),
        }
    }

    pub fn toCss(self: Angle, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try self.format(buf.writer(allocator));
        return try buf.toOwnedSlice(allocator);
    }
};

/// Box shadow definition
pub const BoxShadow = struct {
    x: Length = .zero,
    y: Length = .zero,
    blur: Length = .zero,
    spread: Length = .zero,
    color: Color = Color.rgba(0, 0, 0, 0.2),
    inset: bool = false,

    pub fn format(self: BoxShadow, writer: anytype) !void {
        if (self.inset) try writer.writeAll("inset ");
        try self.x.format(writer);
        try writer.writeAll(" ");
        try self.y.format(writer);
        try writer.writeAll(" ");
        try self.blur.format(writer);
        try writer.writeAll(" ");
        try self.spread.format(writer);
        try writer.writeAll(" ");
        try self.color.format(writer);
    }

    pub fn toCss(self: BoxShadow, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try self.format(buf.writer(allocator));
        return try buf.toOwnedSlice(allocator);
    }

    // Preset shadows
    pub const none = BoxShadow{ .x = .zero, .y = .zero, .blur = .zero, .spread = .zero, .color = Color.transparent };
    pub const sm = BoxShadow{ .x = .zero, .y = .{ .px = 1 }, .blur = .{ .px = 2 }, .spread = .zero, .color = Color.rgba(0, 0, 0, 0.05) };
    pub const md = BoxShadow{ .x = .zero, .y = .{ .px = 4 }, .blur = .{ .px = 6 }, .spread = .{ .px = -1 }, .color = Color.rgba(0, 0, 0, 0.1) };
    pub const lg = BoxShadow{ .x = .zero, .y = .{ .px = 10 }, .blur = .{ .px = 15 }, .spread = .{ .px = -3 }, .color = Color.rgba(0, 0, 0, 0.1) };
    pub const xl = BoxShadow{ .x = .zero, .y = .{ .px = 20 }, .blur = .{ .px = 25 }, .spread = .{ .px = -5 }, .color = Color.rgba(0, 0, 0, 0.1) };
    pub const xxl = BoxShadow{ .x = .zero, .y = .{ .px = 25 }, .blur = .{ .px = 50 }, .spread = .{ .px = -12 }, .color = Color.rgba(0, 0, 0, 0.25) };
    pub const inner = BoxShadow{ .x = .zero, .y = .{ .px = 2 }, .blur = .{ .px = 4 }, .spread = .zero, .color = Color.rgba(0, 0, 0, 0.05), .inset = true };
};

/// Text shadow definition
pub const TextShadow = struct {
    x: Length = .zero,
    y: Length = .zero,
    blur: Length = .zero,
    color: Color = Color.rgba(0, 0, 0, 0.3),

    pub fn format(self: TextShadow, writer: anytype) !void {
        try self.x.format(writer);
        try writer.writeAll(" ");
        try self.y.format(writer);
        try writer.writeAll(" ");
        try self.blur.format(writer);
        try writer.writeAll(" ");
        try self.color.format(writer);
    }

    pub fn toCss(self: TextShadow, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try self.format(buf.writer(allocator));
        return try buf.toOwnedSlice(allocator);
    }
};

/// Border style definition
pub const Border = struct {
    width: Length = .{ .px = 1 },
    style: BorderStyle = .solid,
    color: Color = Color.black,

    pub const BorderStyle = enum {
        none,
        hidden,
        dotted,
        dashed,
        solid,
        double,
        groove,
        ridge,
        inset,
        outset,

        pub fn toCss(self: BorderStyle) []const u8 {
            return switch (self) {
                .none => "none",
                .hidden => "hidden",
                .dotted => "dotted",
                .dashed => "dashed",
                .solid => "solid",
                .double => "double",
                .groove => "groove",
                .ridge => "ridge",
                .inset => "inset",
                .outset => "outset",
            };
        }
    };

    pub fn format(self: Border, writer: anytype) !void {
        try self.width.format(writer);
        try writer.writeAll(" ");
        try writer.writeAll(self.style.toCss());
        try writer.writeAll(" ");
        try self.color.format(writer);
    }

    pub fn toCss(self: Border, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try self.format(buf.writer(allocator));
        return try buf.toOwnedSlice(allocator);
    }

    pub const none = Border{ .width = .zero, .style = .none, .color = Color.transparent };
};

/// CSS gradient definition
pub const Gradient = union(enum) {
    linear: LinearGradient,
    radial: RadialGradient,
    conic: ConicGradient,

    pub const ColorStop = struct {
        color: Color,
        position: ?Length = null,
    };

    pub const LinearGradient = struct {
        angle: Angle = .{ .deg = 180 },
        stops: []const ColorStop,
    };

    pub const RadialGradient = struct {
        shape: enum { circle, ellipse } = .ellipse,
        stops: []const ColorStop,
    };

    pub const ConicGradient = struct {
        from_angle: Angle = .{ .deg = 0 },
        stops: []const ColorStop,
    };

    pub fn format(self: Gradient, writer: anytype) !void {
        switch (self) {
            .linear => |g| {
                try writer.writeAll("linear-gradient(");
                try g.angle.format(writer);
                for (g.stops) |stop| {
                    try writer.writeAll(", ");
                    try stop.color.format(writer);
                    if (stop.position) |pos| {
                        try writer.writeAll(" ");
                        try pos.format(writer);
                    }
                }
                try writer.writeAll(")");
            },
            .radial => |g| {
                try writer.writeAll("radial-gradient(");
                try writer.writeAll(if (g.shape == .circle) "circle" else "ellipse");
                for (g.stops) |stop| {
                    try writer.writeAll(", ");
                    try stop.color.format(writer);
                    if (stop.position) |pos| {
                        try writer.writeAll(" ");
                        try pos.format(writer);
                    }
                }
                try writer.writeAll(")");
            },
            .conic => |g| {
                try writer.writeAll("conic-gradient(from ");
                try g.from_angle.format(writer);
                for (g.stops) |stop| {
                    try writer.writeAll(", ");
                    try stop.color.format(writer);
                    if (stop.position) |pos| {
                        try writer.writeAll(" ");
                        try pos.format(writer);
                    }
                }
                try writer.writeAll(")");
            },
        }
    }

    pub fn toCss(self: Gradient, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try self.format(buf.writer(allocator));
        return try buf.toOwnedSlice(allocator);
    }
};

/// Transform functions
pub const Transform = union(enum) {
    translate: struct { x: Length, y: Length },
    translateX: Length,
    translateY: Length,
    translateZ: Length,
    translate3d: struct { x: Length, y: Length, z: Length },
    scale: struct { x: f32, y: f32 },
    scaleX: f32,
    scaleY: f32,
    scaleZ: f32,
    scale3d: struct { x: f32, y: f32, z: f32 },
    rotate: Angle,
    rotateX: Angle,
    rotateY: Angle,
    rotateZ: Angle,
    rotate3d: struct { x: f32, y: f32, z: f32, angle: Angle },
    skew: struct { x: Angle, y: Angle },
    skewX: Angle,
    skewY: Angle,
    perspective: Length,
    matrix: [6]f32,
    matrix3d: [16]f32,
    none,

    pub fn format(self: Transform, writer: anytype) !void {
        switch (self) {
            .translate => |t| {
                try writer.writeAll("translate(");
                try t.x.format(writer);
                try writer.writeAll(", ");
                try t.y.format(writer);
                try writer.writeAll(")");
            },
            .translateX => |v| {
                try writer.writeAll("translateX(");
                try v.format(writer);
                try writer.writeAll(")");
            },
            .translateY => |v| {
                try writer.writeAll("translateY(");
                try v.format(writer);
                try writer.writeAll(")");
            },
            .translateZ => |v| {
                try writer.writeAll("translateZ(");
                try v.format(writer);
                try writer.writeAll(")");
            },
            .translate3d => |t| {
                try writer.writeAll("translate3d(");
                try t.x.format(writer);
                try writer.writeAll(", ");
                try t.y.format(writer);
                try writer.writeAll(", ");
                try t.z.format(writer);
                try writer.writeAll(")");
            },
            .scale => |s| try writer.print("scale({d}, {d})", .{ s.x, s.y }),
            .scaleX => |v| try writer.print("scaleX({d})", .{v}),
            .scaleY => |v| try writer.print("scaleY({d})", .{v}),
            .scaleZ => |v| try writer.print("scaleZ({d})", .{v}),
            .scale3d => |s| try writer.print("scale3d({d}, {d}, {d})", .{ s.x, s.y, s.z }),
            .rotate => |a| {
                try writer.writeAll("rotate(");
                try a.format(writer);
                try writer.writeAll(")");
            },
            .rotateX => |a| {
                try writer.writeAll("rotateX(");
                try a.format(writer);
                try writer.writeAll(")");
            },
            .rotateY => |a| {
                try writer.writeAll("rotateY(");
                try a.format(writer);
                try writer.writeAll(")");
            },
            .rotateZ => |a| {
                try writer.writeAll("rotateZ(");
                try a.format(writer);
                try writer.writeAll(")");
            },
            .rotate3d => |r| {
                try writer.print("rotate3d({d}, {d}, {d}, ", .{ r.x, r.y, r.z });
                try r.angle.format(writer);
                try writer.writeAll(")");
            },
            .skew => |s| {
                try writer.writeAll("skew(");
                try s.x.format(writer);
                try writer.writeAll(", ");
                try s.y.format(writer);
                try writer.writeAll(")");
            },
            .skewX => |a| {
                try writer.writeAll("skewX(");
                try a.format(writer);
                try writer.writeAll(")");
            },
            .skewY => |a| {
                try writer.writeAll("skewY(");
                try a.format(writer);
                try writer.writeAll(")");
            },
            .perspective => |v| {
                try writer.writeAll("perspective(");
                try v.format(writer);
                try writer.writeAll(")");
            },
            .matrix => |m| try writer.print("matrix({d}, {d}, {d}, {d}, {d}, {d})", .{ m[0], m[1], m[2], m[3], m[4], m[5] }),
            .matrix3d => |m| try writer.print("matrix3d({d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d})", .{ m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15] }),
            .none => try writer.writeAll("none"),
        }
    }

    pub fn toCss(self: Transform, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try self.format(buf.writer(allocator));
        return try buf.toOwnedSlice(allocator);
    }
};

/// Timing functions for animations and transitions
pub const TimingFunction = union(enum) {
    ease,
    ease_in,
    ease_out,
    ease_in_out,
    linear,
    step_start,
    step_end,
    cubic_bezier: struct { x1: f32, y1: f32, x2: f32, y2: f32 },
    steps: struct { count: u32, jump: enum { start, end, none, both } },

    pub fn format(self: TimingFunction, writer: anytype) !void {
        switch (self) {
            .ease => try writer.writeAll("ease"),
            .ease_in => try writer.writeAll("ease-in"),
            .ease_out => try writer.writeAll("ease-out"),
            .ease_in_out => try writer.writeAll("ease-in-out"),
            .linear => try writer.writeAll("linear"),
            .step_start => try writer.writeAll("step-start"),
            .step_end => try writer.writeAll("step-end"),
            .cubic_bezier => |cb| try writer.print("cubic-bezier({d}, {d}, {d}, {d})", .{ cb.x1, cb.y1, cb.x2, cb.y2 }),
            .steps => |s| {
                const jump_str = switch (s.jump) {
                    .start => "start",
                    .end => "end",
                    .none => "none",
                    .both => "both",
                };
                try writer.print("steps({d}, {s})", .{ s.count, jump_str });
            },
        }
    }

    pub fn toCss(self: TimingFunction, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try self.format(buf.writer(allocator));
        return try buf.toOwnedSlice(allocator);
    }
};

/// Filter functions
pub const Filter = union(enum) {
    blur: Length,
    brightness: f32,
    contrast: f32,
    drop_shadow: BoxShadow,
    grayscale: f32,
    hue_rotate: Angle,
    invert: f32,
    opacity: f32,
    saturate: f32,
    sepia: f32,
    none,

    pub fn format(self: Filter, writer: anytype) !void {
        switch (self) {
            .blur => |v| {
                try writer.writeAll("blur(");
                try v.format(writer);
                try writer.writeAll(")");
            },
            .brightness => |v| try writer.print("brightness({d})", .{v}),
            .contrast => |v| try writer.print("contrast({d})", .{v}),
            .drop_shadow => |s| {
                try writer.writeAll("drop-shadow(");
                try s.format(writer);
                try writer.writeAll(")");
            },
            .grayscale => |v| try writer.print("grayscale({d})", .{v}),
            .hue_rotate => |a| {
                try writer.writeAll("hue-rotate(");
                try a.format(writer);
                try writer.writeAll(")");
            },
            .invert => |v| try writer.print("invert({d})", .{v}),
            .opacity => |v| try writer.print("opacity({d})", .{v}),
            .saturate => |v| try writer.print("saturate({d})", .{v}),
            .sepia => |v| try writer.print("sepia({d})", .{v}),
            .none => try writer.writeAll("none"),
        }
    }

    pub fn toCss(self: Filter, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);
        try self.format(buf.writer(allocator));
        return try buf.toOwnedSlice(allocator);
    }
};

// Tests
test "Color from hex" {
    const color = Color.fromHex("#ff5733");
    try std.testing.expectEqual(@as(u8, 255), color.r);
    try std.testing.expectEqual(@as(u8, 87), color.g);
    try std.testing.expectEqual(@as(u8, 51), color.b);
}

test "Color formatting" {
    const allocator = std.testing.allocator;
    const color = Color.rgb(255, 0, 128);
    const css = try color.toCss(allocator);
    defer allocator.free(css);
    try std.testing.expectEqualStrings("#ff0080", css);
}

test "Length formatting" {
    const allocator = std.testing.allocator;
    const length = Length{ .px = 16 };
    const css = try length.toCss(allocator);
    defer allocator.free(css);
    try std.testing.expectEqualStrings("16px", css);
}

test "BoxShadow formatting" {
    const allocator = std.testing.allocator;
    const shadow = BoxShadow.md;
    const css = try shadow.toCss(allocator);
    defer allocator.free(css);
    try std.testing.expect(css.len > 0);
}
