const std = @import("std");
const context = @import("context.zig");

pub const ValveError = error{
    CapabilityRequired,
    ValveNotFound,
    ValveAlreadyRegistered,
    InvalidMethod,
};

pub const ValveState = enum {
    registered,
    initialized,
    started,
    stopped,
    failed,
};

pub const ValveCapability = enum {
    routes,
    middleware,
    background_tasks,
    health_checks,
    static_files,
    websockets,
    database_access,
    cache_access,
    metrics_access,
};

pub const ValveMetadata = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    author: []const u8,
    required_capabilities: []const ValveCapability,
};

pub const Valve = struct {
    metadata: ValveMetadata,

    init: *const fn (*Valve, *context.ValveContext) anyerror!void,

    deinit: *const fn (*Valve) void,

    onAppStart: ?*const fn (*Valve, *context.ValveContext) anyerror!void = null,

    onAppStop: ?*const fn (*Valve, *context.ValveContext) void = null,
};

test "ValveCapability enum values" {
    try std.testing.expectEqual(ValveCapability.routes, .routes);
    try std.testing.expectEqual(ValveCapability.middleware, .middleware);
    try std.testing.expectEqual(ValveCapability.background_tasks, .background_tasks);
    try std.testing.expectEqual(ValveCapability.health_checks, .health_checks);
    try std.testing.expectEqual(ValveCapability.static_files, .static_files);
    try std.testing.expectEqual(ValveCapability.websockets, .websockets);
    try std.testing.expectEqual(ValveCapability.database_access, .database_access);
    try std.testing.expectEqual(ValveCapability.cache_access, .cache_access);
    try std.testing.expectEqual(ValveCapability.metrics_access, .metrics_access);
}

test "ValveMetadata creation" {
    const metadata = ValveMetadata{
        .name = "test_valve",
        .version = "1.0.0",
        .description = "Test valve",
        .author = "Test Author",
        .required_capabilities = &[_]ValveCapability{ .routes, .middleware },
    };

    try std.testing.expectEqualStrings(metadata.name, "test_valve");
    try std.testing.expectEqualStrings(metadata.version, "1.0.0");
    try std.testing.expectEqualStrings(metadata.description, "Test valve");
    try std.testing.expectEqualStrings(metadata.author, "Test Author");
    try std.testing.expectEqual(metadata.required_capabilities.len, 2);
    try std.testing.expectEqual(metadata.required_capabilities[0], .routes);
    try std.testing.expectEqual(metadata.required_capabilities[1], .middleware);
}
