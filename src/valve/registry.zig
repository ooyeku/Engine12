const std = @import("std");
const valve = @import("valve.zig");
const Valve = valve.Valve;
const ValveCapability = valve.ValveCapability;
pub const context = @import("context.zig");
const ValveContext = context.ValveContext;
const Engine12 = @import("../engine12.zig").Engine12;
const error_info = @import("error_info.zig");
const ValveErrorInfo = error_info.ValveErrorInfo;
const ValveErrorPhase = error_info.ValveErrorPhase;

pub const RegistryError = error{
    TooManyValves,
};

pub const MAX_VALVES = 32;

pub const ValveRegistry = struct {
    valves: std.ArrayListUnmanaged(*Valve),
    contexts: std.ArrayListUnmanaged(ValveContext),
    valve_error_info: std.ArrayListUnmanaged(?ValveErrorInfo),
    allocator: std.mem.Allocator,
    app: ?*Engine12 = null,
    mutex: std.Thread.Mutex = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .valves = std.ArrayListUnmanaged(*Valve){},
            .contexts = std.ArrayListUnmanaged(ValveContext){},
            .valve_error_info = std.ArrayListUnmanaged(?ValveErrorInfo){},
            .allocator = allocator,
            .app = null,
            .mutex = .{},
        };
    }

    pub fn register(self: *Self, valve_ptr: *Valve, app: *Engine12) !void {
        if (valve_ptr.metadata.name.len == 0) {
            std.debug.print("[ValveRegistry] Error: Attempted to register valve with empty name\n", .{});
            return error.InvalidArgument;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.app == null) {
            self.app = app;
        }

        for (self.valves.items) |existing| {
            if (std.mem.eql(u8, existing.metadata.name, valve_ptr.metadata.name)) {
                return error.ValveAlreadyRegistered;
            }
        }

        if (self.valves.items.len >= MAX_VALVES) {
            return RegistryError.TooManyValves;
        }

        var capabilities = std.ArrayListUnmanaged(ValveCapability){};
        errdefer capabilities.deinit(self.allocator);

        for (valve_ptr.metadata.required_capabilities) |cap| {
            try capabilities.append(self.allocator, cap);
        }

        var ctx = ValveContext{
            .app = app,
            .allocator = app.allocator,
            .capabilities = capabilities,
            .valve_name = valve_ptr.metadata.name,
            .state = .registered,
        };

        valve_ptr.init(valve_ptr, &ctx) catch |err| {
            ctx.state = .failed;
            const error_msg = try std.fmt.allocPrint(self.allocator, "init: {s}", .{@errorName(err)});
            defer self.allocator.free(error_msg);
            const error_info_val = ValveErrorInfo.create(
                self.allocator,
                .init,
                @errorName(err),
                error_msg,
            ) catch |alloc_err| {
                try self.valves.append(self.allocator, valve_ptr);
                try self.contexts.append(self.allocator, ctx);
                try self.valve_error_info.append(self.allocator, null);
                return alloc_err;
            };
            try self.valves.append(self.allocator, valve_ptr);
            try self.contexts.append(self.allocator, ctx);
            try self.valve_error_info.append(self.allocator, error_info_val);
            return err;
        };
        ctx.state = .initialized;

        try self.valves.append(self.allocator, valve_ptr);
        try self.contexts.append(self.allocator, ctx);
        try self.valve_error_info.append(self.allocator, null);
    }

    pub fn unregister(self: *Self, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.valves.items[i].metadata.name, name)) {
                if (self.app) |app| {
                    if (app.runtime_routes.getValveRoutes(name, self.allocator)) |valve_routes| {
                        defer self.allocator.free(valve_routes);
                        for (valve_routes) |*route| {
                            app.runtime_routes.unregister(route.method, route.path_pattern) catch |err| {
                                std.debug.print("[Valve] Warning: Failed to unregister route {s} {s}: {}\n", .{ route.method, route.path_pattern, err });
                            };
                        }
                    } else |err| {
                        std.debug.print("[Valve] Warning: Failed to get routes for '{s}': {}\n", .{ name, err });
                    }
                }

                self.valves.items[i].deinit(self.valves.items[i]);

                _ = self.valves.swapRemove(i);
                var ctx = self.contexts.swapRemove(i);
                ctx.deinit();
                var error_info_opt = self.valve_error_info.swapRemove(i);
                if (error_info_opt) |*error_info_val| {
                    error_info_val.deinit(self.allocator);
                }

                return;
            }
        }
        return valve.ValveError.ValveNotFound;
    }

    pub fn getContext(self: *Self, name: []const u8) ?*ValveContext {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.valves.items[i].metadata.name, name)) {
                return &self.contexts.items[i];
            }
        }
        return null;
    }

    pub fn getValveNames(self: *Self, allocator: std.mem.Allocator) ![]const []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var names = std.ArrayListUnmanaged([]const u8){};
        for (self.valves.items) |v| {
            try names.append(allocator, v.metadata.name);
        }
        return names.toOwnedSlice(allocator);
    }

    pub fn onAppStart(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            if (self.contexts.items[i].state == .failed) continue;

            if (self.valves.items[i].onAppStart) |callback| {
                callback(self.valves.items[i], &self.contexts.items[i]) catch |err| {
                    self.contexts.items[i].state = .failed;
                    if (self.valve_error_info.items[i]) |*old_error_info| {
                        old_error_info.deinit(self.allocator);
                    }
                    const error_msg = try std.fmt.allocPrint(self.allocator, "onAppStart: {s}", .{@errorName(err)});
                    defer self.allocator.free(error_msg);
                    const error_info_val = ValveErrorInfo.create(
                        self.allocator,
                        .start,
                        @errorName(err),
                        error_msg,
                    ) catch |alloc_err| {
                        self.valve_error_info.items[i] = null;
                        std.debug.print("[Valve] Error in onAppStart for '{s}': {} (also failed to create error info: {})\n", .{ self.valves.items[i].metadata.name, err, alloc_err });
                        continue;
                    };
                    self.valve_error_info.items[i] = error_info_val;
                    std.debug.print("[Valve] Error in onAppStart for '{s}': {}\n", .{ self.valves.items[i].metadata.name, err });
                    continue;
                };
                if (self.contexts.items[i].state == .initialized) {
                    self.contexts.items[i].state = .started;
                }
            } else {
                if (self.contexts.items[i].state == .initialized) {
                    self.contexts.items[i].state = .started;
                }
            }
        }
    }

    pub fn onAppStop(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            if (self.valves.items[i].onAppStop) |callback| {
                callback(self.valves.items[i], &self.contexts.items[i]);
            }
            if (self.contexts.items[i].state != .failed) {
                self.contexts.items[i].state = .stopped;
            }
        }
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.valves.items) |v| {
            v.deinit(v);
        }

        for (self.contexts.items) |*ctx| {
            ctx.deinit();
        }

        for (self.valve_error_info.items) |*error_info_opt| {
            if (error_info_opt.*) |*error_info_val| {
                error_info_val.deinit(self.allocator);
            }
        }

        self.valves.deinit(self.allocator);
        self.contexts.deinit(self.allocator);
        self.valve_error_info.deinit(self.allocator);
    }

    pub fn getValveState(self: *Self, name: []const u8) ?valve.ValveState {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.valves.items[i].metadata.name, name)) {
                return self.contexts.items[i].state;
            }
        }
        return null;
    }

    pub fn getErrorInfo(self: *Self, name: []const u8) ?ValveErrorInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.valves.items[i].metadata.name, name)) {
                if (self.valve_error_info.items[i]) |error_info_val| {
                    return error_info_val;
                }
                return null;
            }
        }
        return null;
    }

    pub fn getValveErrors(self: *Self, name: []const u8) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.valves.items[i].metadata.name, name)) {
                if (self.valve_error_info.items[i]) |error_info_val| {
                    return error_info_val.message;
                }
                return "";
            }
        }
        return "";
    }

    pub fn isValveHealthy(self: *Self, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.valves.items[i].metadata.name, name)) {
                return self.contexts.items[i].state != .failed;
            }
        }
        return false;
    }

    pub fn getFailedValves(self: *Self, allocator: std.mem.Allocator) ![]const []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var failed = std.ArrayListUnmanaged([]const u8){};
        var i: usize = 0;
        while (i < self.valves.items.len) : (i += 1) {
            if (self.contexts.items[i].state == .failed) {
                try failed.append(allocator, self.valves.items[i].metadata.name);
            }
        }
        return failed.toOwnedSlice(allocator);
    }
};

test "ValveRegistry init" {
    var registry = ValveRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try std.testing.expectEqual(registry.valves.items.len, 0);
}

test "ValveRegistry register and unregister" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var registry = ValveRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const TestValve = struct {
        valve: Valve,
        init_called: bool = false,
        deinit_called: bool = false,

        pub fn initFn(v: *Valve, ctx: *ValveContext) !void {
            const Self = @This();
            const offset = @offsetOf(Self, "valve");
            const addr = @intFromPtr(v) - offset;
            const self = @as(*Self, @ptrFromInt(addr));
            self.init_called = true;
            _ = ctx;
        }

        pub fn deinitFn(v: *Valve) void {
            const Self = @This();
            const offset = @offsetOf(Self, "valve");
            const addr = @intFromPtr(v) - offset;
            const self = @as(*Self, @ptrFromInt(addr));
            self.deinit_called = true;
        }
    };

    var test_valve = TestValve{
        .valve = Valve{
            .metadata = valve.ValveMetadata{
                .name = "test",
                .version = "1.0.0",
                .description = "Test valve",
                .author = "Test",
                .required_capabilities = &[_]ValveCapability{},
            },
            .init = &TestValve.initFn,
            .deinit = &TestValve.deinitFn,
        },
    };

    try registry.register(&test_valve.valve, &app);
    try std.testing.expect(test_valve.init_called);
    try std.testing.expectEqual(registry.valves.items.len, 1);

    try registry.unregister("test");
    try std.testing.expect(test_valve.deinit_called);
    try std.testing.expectEqual(registry.valves.items.len, 0);
}

test "ValveRegistry duplicate registration fails" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var registry = ValveRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const TestValve = struct {
        valve: Valve,

        pub fn initFn(_: *Valve, _: *ValveContext) !void {}
        pub fn deinitFn(_: *Valve) void {}
    };

    var test_valve = TestValve{
        .valve = Valve{
            .metadata = valve.ValveMetadata{
                .name = "test",
                .version = "1.0.0",
                .description = "Test",
                .author = "Test",
                .required_capabilities = &[_]ValveCapability{},
            },
            .init = &TestValve.initFn,
            .deinit = &TestValve.deinitFn,
        },
    };

    try registry.register(&test_valve.valve, &app);
    try std.testing.expectError(valve.ValveError.ValveAlreadyRegistered, registry.register(&test_valve.valve, &app));
}

test "ValveRegistry getContext" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var registry = ValveRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const TestValve = struct {
        valve: Valve,

        pub fn initFn(_: *Valve, _: *ValveContext) !void {}
        pub fn deinitFn(_: *Valve) void {}
    };

    var test_valve = TestValve{
        .valve = Valve{
            .metadata = valve.ValveMetadata{
                .name = "test",
                .version = "1.0.0",
                .description = "Test",
                .author = "Test",
                .required_capabilities = &[_]ValveCapability{},
            },
            .init = &TestValve.initFn,
            .deinit = &TestValve.deinitFn,
        },
    };

    try registry.register(&test_valve.valve, &app);

    const ctx = registry.getContext("test");
    try std.testing.expect(ctx != null);
    if (ctx) |c| {
        try std.testing.expectEqualStrings(c.valve_name, "test");
    }

    try std.testing.expect(registry.getContext("nonexistent") == null);
}


test "ValveRegistry structured error info" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var registry = ValveRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const FailingValve = struct {
        valve: Valve,

        pub fn initFn(_: *Valve, _: *ValveContext) !void {
            return error.TestError;
        }

        pub fn deinitFn(_: *Valve) void {}
    };

    var failing_valve = FailingValve{
        .valve = Valve{
            .metadata = valve.ValveMetadata{
                .name = "failing",
                .version = "1.0.0",
                .description = "Failing valve",
                .author = "Test",
                .required_capabilities = &[_]ValveCapability{},
            },
            .init = &FailingValve.initFn,
            .deinit = &FailingValve.deinitFn,
        },
    };

    registry.register(&failing_valve.valve, &app) catch |err| {
        try std.testing.expectEqual(err, error.TestError);
    };

    if (registry.getErrorInfo("failing")) |err_info| {
        try std.testing.expectEqual(err_info.phase, .init);
        try std.testing.expectEqualStrings(err_info.error_type, "TestError");
        try std.testing.expect(err_info.timestamp > 0);
        try std.testing.expect(err_info.message.len > 0);
    } else {
        try std.testing.expect(false); // Error info should exist
    }

    const error_msg = registry.getValveErrors("failing");
    try std.testing.expect(error_msg.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, error_msg, "init") != null);
}

test "ValveRegistry thread-safe queries" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var registry = ValveRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const TestValve = struct {
        valve: Valve,

        pub fn initFn(_: *Valve, _: *ValveContext) !void {}
        pub fn deinitFn(_: *Valve) void {}
    };

    var test_valve = TestValve{
        .valve = Valve{
            .metadata = valve.ValveMetadata{
                .name = "test",
                .version = "1.0.0",
                .description = "Test",
                .author = "Test",
                .required_capabilities = &[_]ValveCapability{},
            },
            .init = &TestValve.initFn,
            .deinit = &TestValve.deinitFn,
        },
    };

    try registry.register(&test_valve.valve, &app);

    const ctx1 = registry.getContext("test");
    const ctx2 = registry.getContext("test");
    const state1 = registry.getValveState("test");
    const state2 = registry.getValveState("test");
    const healthy1 = registry.isValveHealthy("test");
    const healthy2 = registry.isValveHealthy("test");

    try std.testing.expect(ctx1 != null);
    try std.testing.expect(ctx2 != null);
    try std.testing.expect(state1 != null);
    try std.testing.expect(state2 != null);
    try std.testing.expect(healthy1 == true);
    try std.testing.expect(healthy2 == true);
    try std.testing.expectEqual(state1, state2);
}

test "ValveRegistry getFailedValves" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var registry = ValveRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const SuccessValve = struct {
        valve: Valve,

        pub fn initFn(_: *Valve, _: *ValveContext) !void {}
        pub fn deinitFn(_: *Valve) void {}
    };

    const FailingValve = struct {
        valve: Valve,

        pub fn initFn(_: *Valve, _: *ValveContext) !void {
            return error.TestError;
        }

        pub fn deinitFn(_: *Valve) void {}
    };

    var success_valve = SuccessValve{
        .valve = Valve{
            .metadata = valve.ValveMetadata{
                .name = "success",
                .version = "1.0.0",
                .description = "Success",
                .author = "Test",
                .required_capabilities = &[_]ValveCapability{},
            },
            .init = &SuccessValve.initFn,
            .deinit = &SuccessValve.deinitFn,
        },
    };

    var failing_valve = FailingValve{
        .valve = Valve{
            .metadata = valve.ValveMetadata{
                .name = "failing",
                .version = "1.0.0",
                .description = "Failing",
                .author = "Test",
                .required_capabilities = &[_]ValveCapability{},
            },
            .init = &FailingValve.initFn,
            .deinit = &FailingValve.deinitFn,
        },
    };

    try registry.register(&success_valve.valve, &app);
    registry.register(&failing_valve.valve, &app) catch {};

    const failed = try registry.getFailedValves(std.testing.allocator);
    defer std.testing.allocator.free(failed);

    try std.testing.expectEqual(failed.len, 1);
    try std.testing.expectEqualStrings(failed[0], "failing");
}
