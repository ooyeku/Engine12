const std = @import("std");
const types = @import("types.zig");

pub const ServiceState = enum {
    stopped,
    starting,
    running,
    stopping,
    failed,
    restarting,
};

pub const RestartPolicy = enum {
    never,
    on_failure,
    always,
    on_failure_limited,
};

pub const ServiceConfig = struct {
    name: []const u8,
    restart_policy: RestartPolicy = .on_failure,
    max_retries: u32 = 3,
    restart_delay_ms: u64 = 1000,
    health_check_interval_ms: u64 = 30000,
    startup_timeout_ms: u64 = 30000,
    shutdown_timeout_ms: u64 = 10000,
};

pub const Service = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (*anyopaque) anyerror!void,
        stop: *const fn (*anyopaque) void,
        healthCheck: *const fn (*anyopaque) types.HealthStatus,
        getName: *const fn (*anyopaque) []const u8,
    };

    pub fn start(self: Service) !void {
        return self.vtable.start(self.ptr);
    }

    pub fn stop(self: Service) void {
        self.vtable.stop(self.ptr);
    }

    pub fn healthCheck(self: Service) types.HealthStatus {
        return self.vtable.healthCheck(self.ptr);
    }

    pub fn getName(self: Service) []const u8 {
        return self.vtable.getName(self.ptr);
    }

    pub fn init(comptime T: type, ptr: *T) Service {
        const Impl = struct {
            fn start(p: *anyopaque) anyerror!void {
                const self: *T = @ptrCast(@alignCast(p));
                return self.start();
            }

            fn stop(p: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(p));
                self.stop();
            }

            fn healthCheck(p: *anyopaque) types.HealthStatus {
                const self: *T = @ptrCast(@alignCast(p));
                return self.healthCheck();
            }

            fn getName(p: *anyopaque) []const u8 {
                const self: *T = @ptrCast(@alignCast(p));
                if (@hasDecl(T, "getName")) {
                    return self.getName();
                }
                return @typeName(T);
            }
        };

        return Service{
            .ptr = ptr,
            .vtable = &.{
                .start = Impl.start,
                .stop = Impl.stop,
                .healthCheck = Impl.healthCheck,
                .getName = Impl.getName,
            },
        };
    }
};

pub const ManagedService = struct {
    service: Service,
    config: ServiceConfig,
    state: ServiceState,
    restart_count: u32,
    last_error: ?[]const u8,
    started_at: ?i64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, service: Service, config: ServiceConfig) ManagedService {
        return ManagedService{
            .service = service,
            .config = config,
            .state = .stopped,
            .restart_count = 0,
            .last_error = null,
            .started_at = null,
            .allocator = allocator,
        };
    }

    pub fn start(self: *ManagedService) !void {
        if (self.state == .running) return;

        self.state = .starting;
        self.service.start() catch |err| {
            self.state = .failed;
            self.last_error = @errorName(err);
            return err;
        };
        self.state = .running;
        self.started_at = std.time.milliTimestamp();
        self.restart_count = 0;
    }

    pub fn stop(self: *ManagedService) void {
        if (self.state == .stopped) return;

        self.state = .stopping;
        self.service.stop();
        self.state = .stopped;
        self.started_at = null;
    }

    pub fn shouldRestart(self: *const ManagedService) bool {
        if (self.state != .failed) return false;

        return switch (self.config.restart_policy) {
            .never => false,
            .on_failure => true,
            .always => true,
            .on_failure_limited => self.restart_count < self.config.max_retries,
        };
    }

    pub fn restart(self: *ManagedService) !void {
        if (self.state == .running) {
            self.stop();
        }

        self.state = .restarting;
        self.restart_count += 1;

        if (self.config.restart_delay_ms > 0) {
            std.time.sleep(self.config.restart_delay_ms * std.time.ns_per_ms);
        }

        try self.start();
    }

    pub fn getHealth(self: *ManagedService) types.HealthStatus {
        if (self.state != .running) return .unhealthy;
        return self.service.healthCheck();
    }

    pub fn getUptime(self: *const ManagedService) ?i64 {
        if (self.started_at) |started| {
            return std.time.milliTimestamp() - started;
        }
        return null;
    }
};

pub const ServiceRegistry = struct {
    services: std.StringHashMap(ManagedService),
    allocator: std.mem.Allocator,
    health_check_thread: ?std.Thread = null,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator) ServiceRegistry {
        return ServiceRegistry{
            .services = std.StringHashMap(ManagedService).init(allocator),
            .allocator = allocator,
            .health_check_thread = null,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *ServiceRegistry) void {
        self.stopAll();

        self.running.store(false, .monotonic);
        if (self.health_check_thread) |thread| {
            thread.join();
        }

        var it = self.services.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.services.deinit();
    }

    pub fn register(self: *ServiceRegistry, service: Service, config: ServiceConfig) !void {
        const name_copy = try self.allocator.dupe(u8, config.name);
        errdefer self.allocator.free(name_copy);

        var config_copy = config;
        config_copy.name = name_copy;

        const managed = ManagedService.init(self.allocator, service, config_copy);
        try self.services.put(name_copy, managed);
    }

    pub fn get(self: *ServiceRegistry, name: []const u8) ?*ManagedService {
        return self.services.getPtr(name);
    }

    pub fn startAll(self: *ServiceRegistry) !void {
        var it = self.services.valueIterator();
        while (it.next()) |managed| {
            managed.start() catch |err| {
                std.debug.print("[ServiceRegistry] Failed to start service '{s}': {s}\n", .{
                    managed.config.name,
                    @errorName(err),
                });
            };
        }
    }

    pub fn stopAll(self: *ServiceRegistry) void {
        var it = self.services.valueIterator();
        while (it.next()) |managed| {
            managed.stop();
        }
    }

    pub fn startService(self: *ServiceRegistry, name: []const u8) !void {
        if (self.services.getPtr(name)) |managed| {
            try managed.start();
        } else {
            return error.ServiceNotFound;
        }
    }

    pub fn stopService(self: *ServiceRegistry, name: []const u8) !void {
        if (self.services.getPtr(name)) |managed| {
            managed.stop();
        } else {
            return error.ServiceNotFound;
        }
    }

    pub fn getOverallHealth(self: *ServiceRegistry) types.HealthStatus {
        var any_degraded = false;

        var it = self.services.valueIterator();
        while (it.next()) |managed| {
            const health = managed.getHealth();
            if (health == .unhealthy) return .unhealthy;
            if (health == .degraded) any_degraded = true;
        }

        return if (any_degraded) .degraded else .healthy;
    }

    pub fn getHealthReport(self: *ServiceRegistry, allocator: std.mem.Allocator) ![]const ServiceHealthReport {
        var reports = std.ArrayListUnmanaged(ServiceHealthReport){};
        errdefer reports.deinit(allocator);

        var it = self.services.iterator();
        while (it.next()) |entry| {
            const managed = entry.value_ptr;
            try reports.append(allocator, ServiceHealthReport{
                .name = managed.config.name,
                .state = managed.state,
                .health = managed.getHealth(),
                .uptime_ms = managed.getUptime(),
                .restart_count = managed.restart_count,
                .last_error = managed.last_error,
            });
        }

        return reports.toOwnedSlice(allocator);
    }

    pub fn checkAndRestart(self: *ServiceRegistry) void {
        var it = self.services.valueIterator();
        while (it.next()) |managed| {
            if (managed.state == .running) {
                const health = managed.service.healthCheck();
                if (health == .unhealthy) {
                    std.debug.print("[ServiceRegistry] Service '{s}' unhealthy, marking as failed\n", .{
                        managed.config.name,
                    });
                    managed.state = .failed;
                }
            }

            if (managed.shouldRestart()) {
                std.debug.print("[ServiceRegistry] Restarting service '{s}' (attempt {d})\n", .{
                    managed.config.name,
                    managed.restart_count + 1,
                });
                managed.restart() catch |err| {
                    std.debug.print("[ServiceRegistry] Restart failed: {s}\n", .{@errorName(err)});
                };
            }
        }
    }

    pub fn startHealthChecks(self: *ServiceRegistry) !void {
        self.running.store(true, .monotonic);
        self.health_check_thread = try std.Thread.spawn(.{}, healthCheckLoop, .{self});
    }

    fn healthCheckLoop(self: *ServiceRegistry) void {
        while (self.running.load(.monotonic)) {
            self.checkAndRestart();

            var min_interval: u64 = 30000; // Default 30s
            var it = self.services.valueIterator();
            while (it.next()) |managed| {
                if (managed.config.health_check_interval_ms > 0 and
                    managed.config.health_check_interval_ms < min_interval)
                {
                    min_interval = managed.config.health_check_interval_ms;
                }
            }

            std.time.sleep(min_interval * std.time.ns_per_ms);
        }
    }
};

pub const ServiceHealthReport = struct {
    name: []const u8,
    state: ServiceState,
    health: types.HealthStatus,
    uptime_ms: ?i64,
    restart_count: u32,
    last_error: ?[]const u8,
};

test "ServiceRegistry basic operations" {
    const allocator = std.testing.allocator;

    const MockService = struct {
        started: bool = false,
        healthy: bool = true,

        pub fn start(self: *@This()) !void {
            self.started = true;
        }

        pub fn stop(self: *@This()) void {
            self.started = false;
        }

        pub fn healthCheck(self: *@This()) types.HealthStatus {
            return if (self.healthy) .healthy else .unhealthy;
        }
    };

    var mock = MockService{};
    var registry = ServiceRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(Service.init(MockService, &mock), .{
        .name = "test-service",
        .restart_policy = .never,
    });

    try registry.startAll();
    try std.testing.expect(mock.started);

    const health = registry.getOverallHealth();
    try std.testing.expectEqual(health, .healthy);

    registry.stopAll();
    try std.testing.expect(!mock.started);
}

test "ServiceRegistry restart policy" {
    const allocator = std.testing.allocator;

    const FailingService = struct {
        fail_count: u32 = 0,
        max_fails: u32,

        pub fn start(self: *@This()) !void {
            if (self.fail_count < self.max_fails) {
                self.fail_count += 1;
                return error.ServiceStartFailed;
            }
        }

        pub fn stop(_: *@This()) void {}

        pub fn healthCheck(_: *@This()) types.HealthStatus {
            return .healthy;
        }
    };

    var failing = FailingService{ .max_fails = 2 };
    var registry = ServiceRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(Service.init(FailingService, &failing), .{
        .name = "failing-service",
        .restart_policy = .on_failure_limited,
        .max_retries = 3,
        .restart_delay_ms = 0, // No delay for tests
    });

    registry.startAll() catch {};

    if (registry.get("failing-service")) |managed| {
        try std.testing.expectEqual(managed.state, .failed);
        try std.testing.expect(managed.shouldRestart());

        try managed.restart();
        try managed.restart();

        try std.testing.expectEqual(managed.state, .running);
    } else {
        try std.testing.expect(false); // Service not found
    }
}

test "ManagedService uptime tracking" {
    const allocator = std.testing.allocator;

    const SimpleService = struct {
        pub fn start(_: *@This()) !void {}
        pub fn stop(_: *@This()) void {}
        pub fn healthCheck(_: *@This()) types.HealthStatus {
            return .healthy;
        }
    };

    var simple = SimpleService{};
    var managed = ManagedService.init(allocator, Service.init(SimpleService, &simple), .{
        .name = "simple",
    });

    try std.testing.expect(managed.getUptime() == null);

    try managed.start();
    try std.testing.expect(managed.getUptime() != null);

    managed.stop();
    try std.testing.expect(managed.getUptime() == null);
}
