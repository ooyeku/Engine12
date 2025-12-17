const std = @import("std");
const ziggurat = @import("ziggurat");
const engine12 = @import("../engine12.zig");
const Engine12 = engine12.Engine12;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const types = @import("../types.zig");
const middleware_chain = @import("../middleware.zig");
const cache = @import("../cache.zig");
const metrics = @import("../metrics.zig");
const orm = @import("../orm/orm.zig");
const valve = @import("valve.zig");
const ValveCapability = valve.ValveCapability;
const handlers = @import("../handlers.zig");
const wrapHandler = engine12.wrapHandler;
const createRuntimeRouteWrapper = engine12.createRuntimeRouteWrapper;
const websocket_mod = @import("../websocket/module.zig");

pub const ValveContext = struct {
    app: *Engine12,
    allocator: std.mem.Allocator,
    capabilities: std.ArrayListUnmanaged(ValveCapability),
    valve_name: []const u8,
    state: valve.ValveState = .registered,

    const Self = @This();

    pub fn hasCapability(self: *const Self, cap: ValveCapability) bool {
        for (self.capabilities.items) |c| {
            if (c == cap) return true;
        }
        return false;
    }

    pub fn registerRoute(
        self: *Self,
        method: []const u8,
        path: []const u8,
        handler: types.HttpHandler,
    ) !void {
        if (!self.hasCapability(.routes)) {
            return valve.ValveError.CapabilityRequired;
        }

        const handler_ptr: *const fn (*Request) Response = handler;
        try self.app.runtime_routes.register(method, path, handler_ptr, self.valve_name);

        if (self.app.built_server == null) {
            var builder = ziggurat.ServerBuilder.init(self.app.allocator);
            var server = try builder
                .host("127.0.0.1")
                .port(8080)
                .readTimeout(5000)
                .writeTimeout(5000)
                .build();

            engine12.global_middleware = &self.app.middleware;
            engine12.global_metrics = &self.app.metrics_collector;
            engine12.global_runtime_routes = &self.app.runtime_routes;

            if (!self.app.static_root_mounted and !self.app.custom_root_handler) {
                const default_handler = struct {
                    fn handle(_: *Request) Response {
                        return Response.text("engine12");
                    }
                }.handle;
                try server.get("/", wrapHandler(default_handler, "/"));
            }
            try server.get("/health", wrapHandler(handlers.handleHealthEndpoint, "/health"));
            try server.get("/metrics", wrapHandler(handlers.handleMetricsEndpoint, "/metrics"));

            self.app.built_server = server;
            self.app.http_server = @ptrCast(&server);
        }

        engine12.global_middleware = &self.app.middleware;
        engine12.global_metrics = &self.app.metrics_collector;
        engine12.global_runtime_routes = &self.app.runtime_routes;

        const wrapped_handler = createRuntimeRouteWrapper();

        if (self.app.built_server) |*server| {
            if (std.mem.eql(u8, method, "GET")) {
                try server.get(path, wrapped_handler);
            } else if (std.mem.eql(u8, method, "POST")) {
                try server.post(path, wrapped_handler);
            } else if (std.mem.eql(u8, method, "PUT")) {
                try server.put(path, wrapped_handler);
            } else if (std.mem.eql(u8, method, "DELETE")) {
                try server.delete(path, wrapped_handler);
            } else if (std.mem.eql(u8, method, "PATCH")) {
                try server.post(path, wrapped_handler);
            } else {
                return valve.ValveError.InvalidMethod;
            }
        } else {
            return valve.ValveError.InvalidMethod;
        }
    }

    pub fn registerMiddleware(
        self: *Self,
        mw: middleware_chain.PreRequestMiddlewareFn,
    ) !void {
        if (!self.hasCapability(.middleware)) {
            return valve.ValveError.CapabilityRequired;
        }
        try self.app.usePreRequest(mw);
    }

    pub fn registerWebSocket(
        self: *Self,
        path: []const u8,
        handler: websocket_mod.WebSocketHandler,
    ) !void {
        if (!self.hasCapability(.websockets)) {
            return valve.ValveError.CapabilityRequired;
        }
        try self.app.websocket(path, handler);
    }

    pub fn registerResponseMiddleware(
        self: *Self,
        mw: middleware_chain.ResponseMiddlewareFn,
    ) !void {
        if (!self.hasCapability(.middleware)) {
            return valve.ValveError.CapabilityRequired;
        }
        try self.app.useResponse(mw);
    }

    pub fn registerTask(
        self: *Self,
        name: []const u8,
        task: types.BackgroundTask,
        interval_ms: ?u32,
    ) !void {
        if (!self.hasCapability(.background_tasks)) {
            return valve.ValveError.CapabilityRequired;
        }

        if (interval_ms) |interval| {
            try self.app.schedulePeriodicTask(name, task, interval);
        } else {
            try self.app.runTask(name, task);
        }
    }

    pub fn registerHealthCheck(
        self: *Self,
        check: types.HealthCheckFn,
    ) !void {
        if (!self.hasCapability(.health_checks)) {
            return valve.ValveError.CapabilityRequired;
        }
        try self.app.registerHealthCheck(check);
    }

    pub fn serveStatic(
        self: *Self,
        mount_path: []const u8,
        directory: []const u8,
    ) !void {
        if (!self.hasCapability(.static_files)) {
            return valve.ValveError.CapabilityRequired;
        }
        try self.app.serveStatic(mount_path, directory);
    }

    pub fn getORM(self: *Self) !?*orm.ORM {
        if (!self.hasCapability(.database_access)) {
            return valve.ValveError.CapabilityRequired;
        }
        return self.app.orm_instance;
    }

    pub fn getCache(self: *Self) ?*cache.ResponseCache {
        if (!self.hasCapability(.cache_access)) {
            return null;
        }
        return self.app.getCache();
    }

    pub fn getMetrics(self: *Self) ?*metrics.MetricsCollector {
        if (!self.hasCapability(.metrics_access)) {
            return null;
        }
        return &self.app.metrics_collector;
    }

    pub fn deinit(self: *Self) void {
        if (self.capabilities.items.len > 0) {
            self.capabilities.deinit(self.allocator);
        }
    }
};

test "ValveContext hasCapability" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var capabilities = std.ArrayListUnmanaged(ValveCapability){};
    defer capabilities.deinit(std.testing.allocator);
    try capabilities.append(std.testing.allocator, .routes);
    try capabilities.append(std.testing.allocator, .middleware);

    var ctx = ValveContext{
        .app = &app,
        .allocator = std.testing.allocator,
        .capabilities = capabilities,
        .valve_name = "test",
    };

    try std.testing.expect(ctx.hasCapability(.routes));
    try std.testing.expect(ctx.hasCapability(.middleware));
    try std.testing.expect(!ctx.hasCapability(.database_access));
}

test "ValveContext registerRoute requires capability" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var capabilities = std.ArrayListUnmanaged(ValveCapability){};
    defer capabilities.deinit(std.testing.allocator);

    var ctx = ValveContext{
        .app = &app,
        .allocator = std.testing.allocator,
        .capabilities = capabilities,
        .valve_name = "test",
    };

    const dummyHandler = struct {
        fn handler(_: *Request) Response {
            return Response.json("{}");
        }
    }.handler;

    try std.testing.expectError(valve.ValveError.CapabilityRequired, ctx.registerRoute("GET", "/test", dummyHandler));
}


test "ValveContext registerMiddleware requires capability" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var capabilities = std.ArrayListUnmanaged(ValveCapability){};
    defer capabilities.deinit(std.testing.allocator);

    var ctx = ValveContext{
        .app = &app,
        .allocator = std.testing.allocator,
        .capabilities = capabilities,
        .valve_name = "test",
    };

    const dummyMw = struct {
        fn mw(_: *Request) middleware_chain.MiddlewareResult {
            return .proceed;
        }
    }.mw;

    try std.testing.expectError(valve.ValveError.CapabilityRequired, ctx.registerMiddleware(&dummyMw));
}

test "ValveContext registerTask requires capability" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var capabilities = std.ArrayListUnmanaged(ValveCapability){};
    defer capabilities.deinit(std.testing.allocator);

    var ctx = ValveContext{
        .app = &app,
        .allocator = std.testing.allocator,
        .capabilities = capabilities,
        .valve_name = "test",
    };

    const dummyTask = struct {
        fn task() void {}
    }.task;

    try std.testing.expectError(valve.ValveError.CapabilityRequired, ctx.registerTask("test", &dummyTask, null));
}

test "ValveContext getCache requires capability" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    var capabilities = std.ArrayListUnmanaged(ValveCapability){};
    defer capabilities.deinit(std.testing.allocator);

    var ctx = ValveContext{
        .app = &app,
        .allocator = std.testing.allocator,
        .capabilities = capabilities,
        .valve_name = "test",
    };

    try std.testing.expect(ctx.getCache() == null);
}
