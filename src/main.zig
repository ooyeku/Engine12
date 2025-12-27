const std = @import("std");

pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .websocket, .level = .err },
    },
};

const E12 = @import("engine12");

pub fn main() !void {
    var app = try E12.Engine12.initProduction();
    defer app.deinit();

    try app.start();
    app.printStatus();

    std.Thread.sleep(std.time.ns_per_min * 60);
}
