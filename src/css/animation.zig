const std = @import("std");
const values = @import("values.zig");
const properties = @import("properties.zig");
const style_mod = @import("style.zig");

pub const Duration = values.Duration;
pub const TimingFunction = values.TimingFunction;
pub const Transform = values.Transform;
pub const Style = style_mod.Style;
pub const Transition = properties.Transition;

/// Keyframe definition for CSS animations
pub const Keyframes = struct {
    name: []const u8,
    frames: []const Frame,

    pub const Frame = struct {
        /// Position in animation (0-100 percent, or use 'from'/'to')
        position: Position,
        /// Style at this keyframe
        style: Style,

        pub const Position = union(enum) {
            percent: u8,
            from,
            to,
        };
    };

    /// Generate CSS @keyframes rule
    pub fn toCss(self: Keyframes, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(allocator);
        const writer = buf.writer(allocator);

        try writer.print("@keyframes {s}{{", .{self.name});

        for (self.frames) |frame| {
            switch (frame.position) {
                .percent => |p| try writer.print("{d}%{{", .{p}),
                .from => try writer.writeAll("from{"),
                .to => try writer.writeAll("to{"),
            }
            try frame.style.writeCss(writer);
            try writer.writeAll("}");
        }

        try writer.writeAll("}");
        return try buf.toOwnedSlice(allocator);
    }

    /// Create a simple fade-in animation
    pub fn fadeIn() Keyframes {
        return .{
            .name = "fadeIn",
            .frames = &[_]Frame{
                .{ .position = .from, .style = .{ .opacity = .{ .value = 0 } } },
                .{ .position = .to, .style = .{ .opacity = .{ .value = 1 } } },
            },
        };
    }

    /// Create a simple fade-out animation
    pub fn fadeOut() Keyframes {
        return .{
            .name = "fadeOut",
            .frames = &[_]Frame{
                .{ .position = .from, .style = .{ .opacity = .{ .value = 1 } } },
                .{ .position = .to, .style = .{ .opacity = .{ .value = 0 } } },
            },
        };
    }

    /// Create a slide-in from bottom animation
    pub fn slideInUp() Keyframes {
        return .{
            .name = "slideInUp",
            .frames = &[_]Frame{
                .{ .position = .from, .style = .{
                    .transform = .{ .translateY = .{ .percent = 100 } },
                    .opacity = .{ .value = 0 },
                } },
                .{ .position = .to, .style = .{
                    .transform = .{ .translateY = .zero },
                    .opacity = .{ .value = 1 },
                } },
            },
        };
    }

    /// Create a slide-in from top animation
    pub fn slideInDown() Keyframes {
        return .{
            .name = "slideInDown",
            .frames = &[_]Frame{
                .{ .position = .from, .style = .{
                    .transform = .{ .translateY = .{ .percent = -100 } },
                    .opacity = .{ .value = 0 },
                } },
                .{ .position = .to, .style = .{
                    .transform = .{ .translateY = .zero },
                    .opacity = .{ .value = 1 },
                } },
            },
        };
    }

    /// Create a slide-in from left animation
    pub fn slideInLeft() Keyframes {
        return .{
            .name = "slideInLeft",
            .frames = &[_]Frame{
                .{ .position = .from, .style = .{
                    .transform = .{ .translateX = .{ .percent = -100 } },
                    .opacity = .{ .value = 0 },
                } },
                .{ .position = .to, .style = .{
                    .transform = .{ .translateX = .zero },
                    .opacity = .{ .value = 1 },
                } },
            },
        };
    }

    /// Create a slide-in from right animation
    pub fn slideInRight() Keyframes {
        return .{
            .name = "slideInRight",
            .frames = &[_]Frame{
                .{ .position = .from, .style = .{
                    .transform = .{ .translateX = .{ .percent = 100 } },
                    .opacity = .{ .value = 0 },
                } },
                .{ .position = .to, .style = .{
                    .transform = .{ .translateX = .zero },
                    .opacity = .{ .value = 1 },
                } },
            },
        };
    }

    /// Create a scale-in animation
    pub fn scaleIn() Keyframes {
        return .{
            .name = "scaleIn",
            .frames = &[_]Frame{
                .{ .position = .from, .style = .{
                    .transform = .{ .scale = .{ .x = 0, .y = 0 } },
                    .opacity = .{ .value = 0 },
                } },
                .{ .position = .to, .style = .{
                    .transform = .{ .scale = .{ .x = 1, .y = 1 } },
                    .opacity = .{ .value = 1 },
                } },
            },
        };
    }

    /// Create a bounce animation
    pub fn bounce() Keyframes {
        return .{
            .name = "bounce",
            .frames = &[_]Frame{
                .{ .position = .{ .percent = 0 }, .style = .{ .transform = .{ .translateY = .zero } } },
                .{ .position = .{ .percent = 20 }, .style = .{ .transform = .{ .translateY = .zero } } },
                .{ .position = .{ .percent = 40 }, .style = .{ .transform = .{ .translateY = .{ .px = -30 } } } },
                .{ .position = .{ .percent = 50 }, .style = .{ .transform = .{ .translateY = .zero } } },
                .{ .position = .{ .percent = 60 }, .style = .{ .transform = .{ .translateY = .{ .px = -15 } } } },
                .{ .position = .{ .percent = 80 }, .style = .{ .transform = .{ .translateY = .zero } } },
                .{ .position = .{ .percent = 100 }, .style = .{ .transform = .{ .translateY = .zero } } },
            },
        };
    }

    /// Create a pulse animation
    pub fn pulse() Keyframes {
        return .{
            .name = "pulse",
            .frames = &[_]Frame{
                .{ .position = .{ .percent = 0 }, .style = .{ .transform = .{ .scale = .{ .x = 1, .y = 1 } } } },
                .{ .position = .{ .percent = 50 }, .style = .{ .transform = .{ .scale = .{ .x = 1.05, .y = 1.05 } } } },
                .{ .position = .{ .percent = 100 }, .style = .{ .transform = .{ .scale = .{ .x = 1, .y = 1 } } } },
            },
        };
    }

    /// Create a shake animation
    pub fn shake() Keyframes {
        return .{
            .name = "shake",
            .frames = &[_]Frame{
                .{ .position = .{ .percent = 0 }, .style = .{ .transform = .{ .translateX = .zero } } },
                .{ .position = .{ .percent = 10 }, .style = .{ .transform = .{ .translateX = .{ .px = -10 } } } },
                .{ .position = .{ .percent = 20 }, .style = .{ .transform = .{ .translateX = .{ .px = 10 } } } },
                .{ .position = .{ .percent = 30 }, .style = .{ .transform = .{ .translateX = .{ .px = -10 } } } },
                .{ .position = .{ .percent = 40 }, .style = .{ .transform = .{ .translateX = .{ .px = 10 } } } },
                .{ .position = .{ .percent = 50 }, .style = .{ .transform = .{ .translateX = .{ .px = -10 } } } },
                .{ .position = .{ .percent = 60 }, .style = .{ .transform = .{ .translateX = .{ .px = 10 } } } },
                .{ .position = .{ .percent = 70 }, .style = .{ .transform = .{ .translateX = .{ .px = -10 } } } },
                .{ .position = .{ .percent = 80 }, .style = .{ .transform = .{ .translateX = .{ .px = 10 } } } },
                .{ .position = .{ .percent = 90 }, .style = .{ .transform = .{ .translateX = .{ .px = -10 } } } },
                .{ .position = .{ .percent = 100 }, .style = .{ .transform = .{ .translateX = .zero } } },
            },
        };
    }

    /// Create a spin animation
    pub fn spin() Keyframes {
        return .{
            .name = "spin",
            .frames = &[_]Frame{
                .{ .position = .from, .style = .{ .transform = .{ .rotate = .{ .deg = 0 } } } },
                .{ .position = .to, .style = .{ .transform = .{ .rotate = .{ .deg = 360 } } } },
            },
        };
    }

    /// Create a ping animation (for notifications)
    pub fn ping() Keyframes {
        return .{
            .name = "ping",
            .frames = &[_]Frame{
                .{ .position = .{ .percent = 0 }, .style = .{
                    .transform = .{ .scale = .{ .x = 1, .y = 1 } },
                    .opacity = .{ .value = 1 },
                } },
                .{ .position = .{ .percent = 75 }, .style = .{
                    .transform = .{ .scale = .{ .x = 2, .y = 2 } },
                    .opacity = .{ .value = 0 },
                } },
                .{ .position = .{ .percent = 100 }, .style = .{
                    .transform = .{ .scale = .{ .x = 2, .y = 2 } },
                    .opacity = .{ .value = 0 },
                } },
            },
        };
    }
};

/// Animation configuration
pub const Animation = struct {
    name: []const u8,
    duration: Duration = .{ .ms = 300 },
    timing_function: TimingFunction = .ease,
    delay: Duration = .{ .ms = 0 },
    iteration_count: IterationCount = .{ .count = 1 },
    direction: Direction = .normal,
    fill_mode: FillMode = .none,
    play_state: PlayState = .running,

    pub const IterationCount = union(enum) {
        count: f32,
        infinite,

        pub fn format(self: IterationCount, writer: anytype) !void {
            switch (self) {
                .count => |c| try writer.print("{d}", .{c}),
                .infinite => try writer.writeAll("infinite"),
            }
        }
    };

    pub const Direction = enum {
        normal,
        reverse,
        alternate,
        alternate_reverse,

        pub fn toCss(self: Direction) []const u8 {
            return switch (self) {
                .normal => "normal",
                .reverse => "reverse",
                .alternate => "alternate",
                .alternate_reverse => "alternate-reverse",
            };
        }
    };

    pub const FillMode = enum {
        none,
        forwards,
        backwards,
        both,

        pub fn toCss(self: FillMode) []const u8 {
            return switch (self) {
                .none => "none",
                .forwards => "forwards",
                .backwards => "backwards",
                .both => "both",
            };
        }
    };

    pub const PlayState = enum {
        running,
        paused,

        pub fn toCss(self: PlayState) []const u8 {
            return switch (self) {
                .running => "running",
                .paused => "paused",
            };
        }
    };

    /// Generate the animation CSS property value
    pub fn toCss(self: Animation, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(allocator);
        const writer = buf.writer(allocator);

        try writer.writeAll(self.name);
        try writer.writeAll(" ");
        try self.duration.format(writer);
        try writer.writeAll(" ");
        try self.timing_function.format(writer);
        try writer.writeAll(" ");
        try self.delay.format(writer);
        try writer.writeAll(" ");
        try self.iteration_count.format(writer);
        try writer.writeAll(" ");
        try writer.writeAll(self.direction.toCss());
        try writer.writeAll(" ");
        try writer.writeAll(self.fill_mode.toCss());
        try writer.writeAll(" ");
        try writer.writeAll(self.play_state.toCss());

        return try buf.toOwnedSlice(allocator);
    }
};

/// Transition builder for easy transition creation
pub const TransitionBuilder = struct {
    properties: std.ArrayListUnmanaged(TransitionProperty),
    allocator: std.mem.Allocator,

    pub const TransitionProperty = struct {
        property: []const u8,
        duration: Duration,
        timing_function: TimingFunction,
        delay: Duration,
    };

    pub fn init(allocator: std.mem.Allocator) TransitionBuilder {
        return .{
            .properties = std.ArrayListUnmanaged(TransitionProperty){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TransitionBuilder) void {
        self.properties.deinit(self.allocator);
    }

    pub fn add(
        self: *TransitionBuilder,
        property: []const u8,
        duration: Duration,
        timing_function: TimingFunction,
        delay: Duration,
    ) !void {
        try self.properties.append(self.allocator, .{
            .property = property,
            .duration = duration,
            .timing_function = timing_function,
            .delay = delay,
        });
    }

    pub fn addSimple(self: *TransitionBuilder, property: []const u8, duration: Duration) !void {
        try self.add(property, duration, .ease, .{ .ms = 0 });
    }

    pub fn all(self: *TransitionBuilder, duration: Duration) !void {
        try self.addSimple("all", duration);
    }

    pub fn toCss(self: TransitionBuilder) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        for (self.properties.items, 0..) |prop, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(prop.property);
            try writer.writeAll(" ");
            try prop.duration.format(writer);
            try writer.writeAll(" ");
            try prop.timing_function.format(writer);
            const zero_delay = Duration{ .ms = 0 };
            if (!std.meta.eql(prop.delay, zero_delay)) {
                try writer.writeAll(" ");
                try prop.delay.format(writer);
            }
        }

        return try buf.toOwnedSlice(self.allocator);
    }
};

/// Preset transition configurations
pub const Transitions = struct {
    pub const fast = Duration{ .ms = 75 };
    pub const normal = Duration{ .ms = 150 };
    pub const slow = Duration{ .ms = 300 };
    pub const slower = Duration{ .ms = 500 };

    /// Common transition for interactive elements
    pub fn interactive() Transition {
        return .{
            .property = "all",
            .duration = normal,
            .timing_function = .ease_out,
            .delay = .{ .ms = 0 },
        };
    }

    /// Smooth color transitions
    pub fn colors() Transition {
        return .{
            .property = "color, background-color, border-color",
            .duration = normal,
            .timing_function = .ease,
            .delay = .{ .ms = 0 },
        };
    }

    /// Transform transitions
    pub fn transform() Transition {
        return .{
            .property = "transform",
            .duration = slow,
            .timing_function = .ease_out,
            .delay = .{ .ms = 0 },
        };
    }

    /// Opacity transitions
    pub fn opacity() Transition {
        return .{
            .property = "opacity",
            .duration = normal,
            .timing_function = .ease,
            .delay = .{ .ms = 0 },
        };
    }

    /// Shadow transitions
    pub fn shadow() Transition {
        return .{
            .property = "box-shadow",
            .duration = normal,
            .timing_function = .ease,
            .delay = .{ .ms = 0 },
        };
    }
};

// Tests
test "Keyframes toCss - fadeIn" {
    const allocator = std.testing.allocator;
    const kf = Keyframes.fadeIn();
    const css = try kf.toCss(allocator);
    defer allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, "@keyframes fadeIn") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "from{") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "to{") != null);
}

test "Animation toCss" {
    const allocator = std.testing.allocator;
    const anim = Animation{
        .name = "fadeIn",
        .duration = .{ .ms = 300 },
        .iteration_count = .infinite,
    };
    const css = try anim.toCss(allocator);
    defer allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, "fadeIn") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "300ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "infinite") != null);
}

test "TransitionBuilder" {
    const allocator = std.testing.allocator;
    var builder = TransitionBuilder.init(allocator);
    defer builder.deinit();

    try builder.addSimple("opacity", .{ .ms = 200 });
    try builder.add("transform", .{ .ms = 300 }, .ease_out, .{ .ms = 100 });

    const css = try builder.toCss();
    defer allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, "opacity 200ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "transform 300ms") != null);
}
