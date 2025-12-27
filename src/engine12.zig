const std = @import("std");
const posix = std.posix;
const net = std.net;
const vigil = @import("vigil");
const ziggurat = @import("ziggurat");
const types = @import("types.zig");
const handlers = @import("http/handlers.zig");
const fileserver = @import("http/fileserver.zig");
const Request = @import("http/request.zig").Request;
const response_mod = @import("http/response.zig");
const Response = response_mod.Response;
const router = @import("routing/router.zig");
const middleware_chain = @import("middleware/middleware.zig");
const route_group = @import("routing/route_group.zig");
const error_handler = @import("error_handler.zig");
const metrics = @import("observability/metrics.zig");
const rate_limit = @import("middleware/rate_limit.zig");
const cache = @import("data/cache.zig");
const dev_tools = @import("observability/dev_tools.zig");
const valve_registry_mod = @import("valve/registry.zig");
const valve_mod = @import("valve/valve.zig");
const runtime_routes_mod = @import("valve/runtime_routes.zig");
const orm = @import("orm/orm.zig");
const websocket_mod = @import("websocket/module.zig");
const hot_reload_mod = @import("hot_reload/module.zig");
const script_injector_mod = @import("hot_reload/script_injector.zig");
const htmx_mod = @import("htmx/module.zig");
const rest_api_mod = @import("routing/rest_api.zig");
const openapi = @import("openapi.zig");
const validation = @import("data/validation.zig");
const shutdown_utils = @import("utils/shutdown.zig");
const builtin = @import("builtin");

const allocator = std.heap.page_allocator;

fn generateRequestId(alloc: std.mem.Allocator) ![]const u8 {
    const timestamp = std.time.milliTimestamp();
    const random = @as(u64, @intCast(std.time.nanoTimestamp())) % 1000000;
    var buffer: [64]u8 = undefined;
    const id_str = std.fmt.bufPrint(&buffer, "req_{d}_{d}", .{ timestamp, random }) catch {
        return alloc.dupe(u8, "req_unknown");
    };
    return alloc.dupe(u8, id_str);
}

pub var global_middleware: ?*const middleware_chain.MiddlewareChain = null;

pub var global_metrics: ?*metrics.MetricsCollector = null;

var hot_reload_manager_for_ws: ?*hot_reload_mod.HotReloadManager = null;

fn hotReloadWebSocketHandler(conn: *websocket_mod.connection.WebSocketConnection) void {
    if (hot_reload_manager_for_ws) |mgr| {
        if (mgr.getReloadRoom()) |room| {
            room.join(conn) catch |err| {
                std.debug.print("[HotReload] Error joining room: {}\n", .{err});
                return;
            };

            const room_ptr_str = std.fmt.allocPrint(allocator, "{d}", .{@intFromPtr(room)}) catch return;
            defer allocator.free(room_ptr_str);
            conn.set("hot_reload_room", room_ptr_str) catch {};
        }
    }
}

pub var global_rate_limiter: ?*rate_limit.RateLimiter = null;

pub var global_cache: ?*cache.ResponseCache = null;

pub var global_logger: ?*dev_tools.Logger = null;

pub var global_error_handler: ?*error_handler.ErrorHandlerRegistry = null;

pub var global_runtime_routes: ?*runtime_routes_mod.RuntimeRouteRegistry = null;

pub var global_active_request_tracker: ?*shutdown_utils.ActiveRequestTracker = null;

var global_openapi_generator: ?*openapi.OpenAPIGenerator = null;

// Global Engine12 pointer for signal handling
var global_engine12_instance: ?*Engine12 = null;
var shutdown_triggered: bool = false;

// Signal handler for graceful shutdown on SIGINT/SIGTERM
fn handleSignal(sig: c_int) callconv(.c) void {
    const msg = if (sig == posix.SIG.INT) "\nReceived SIGINT (Ctrl+C)...\n" else "\nReceived SIGTERM...\n";
    _ = posix.write(posix.STDERR_FILENO, msg) catch {};

    if (shutdown_triggered) {
        // Second signal - force exit immediately
        const force_msg = "Forcing exit...\n";
        _ = posix.write(posix.STDERR_FILENO, force_msg) catch {};
        std.process.exit(1);
    }
    shutdown_triggered = true;

    if (global_engine12_instance) |engine| {
        engine.is_running = false;
        // Signal the connection queue to shutdown
        if (global_connection_queue) |queue| {
            queue.signalShutdown();
        }
    }
}

fn closeSocket(socket: posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        // On Windows, specific closesocket is required for sockets, handling return value manually
        _ = std.os.windows.ws2_32.closesocket(socket);
    } else {
        posix.close(socket);
    }
}

const ConnectionQueue = struct {
    const Self = @This();
    const MAX_QUEUE_SIZE = 4096;

    queue: [MAX_QUEUE_SIZE]posix.socket_t = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    not_full: std.Thread.Condition = .{},
    shutdown: bool = false,

    pub fn push(self: *Self, socket: posix.socket_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count >= MAX_QUEUE_SIZE and !self.shutdown) {
            self.not_full.wait(&self.mutex);
        }

        if (self.shutdown) {
            closeSocket(socket);
            return;
        }

        self.queue[self.tail] = socket;
        self.tail = (self.tail + 1) % MAX_QUEUE_SIZE;
        self.count += 1;

        self.not_empty.signal();
    }

    pub fn pop(self: *Self) ?posix.socket_t {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count == 0 and !self.shutdown) {
            self.not_empty.wait(&self.mutex);
        }

        if (self.count == 0) {
            return null; // Shutdown with empty queue
        }

        const socket = self.queue[self.head];
        self.head = (self.head + 1) % MAX_QUEUE_SIZE;
        self.count -= 1;

        self.not_full.signal();
        return socket;
    }

    pub fn signalShutdown(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.shutdown = true;
        self.not_empty.broadcast();
        self.not_full.broadcast();
    }
};

var global_connection_queue: ?*ConnectionQueue = null;

var global_server_for_workers: ?*ziggurat.Server = null;

var global_server_config: ?ServerConfig = null;

fn handleConnectionThreaded(socket: posix.socket_t) void {
    const server = global_server_for_workers orelse return;
    const config = global_server_config orelse return;

    defer closeSocket(socket);

    setSocketTimeouts(socket, config) catch return;

    const max_requests_per_connection: usize = 100;
    var requests_handled: usize = 0;

    while (requests_handled < max_requests_per_connection) : (requests_handled += 1) {
        if (global_active_request_tracker) |tracker| {
            tracker.increment();
        }
        defer {
            if (global_active_request_tracker) |tracker| {
                tracker.decrement();
            }
        }

        var buf: [65536]u8 = undefined; // 64KB buffer
        var total_read: usize = 0;

        const read_result = posix.recv(socket, &buf, 0);
        if (read_result) |bytes_read| {
            if (bytes_read == 0) return; // Connection closed by client
            total_read = bytes_read;
        } else |_| {
            return; // Read error or timeout - close connection
        }

        const header_end_marker = "\r\n\r\n";
        var header_end_pos: ?usize = null;

        if (std.mem.indexOf(u8, buf[0..total_read], header_end_marker)) |pos| {
            header_end_pos = pos;
        }

        while (header_end_pos == null and total_read < buf.len) {
            const additional_result = posix.recv(socket, buf[total_read..], 0);
            if (additional_result) |bytes| {
                if (bytes == 0) break;
                total_read += bytes;

                if (std.mem.indexOf(u8, buf[0..total_read], header_end_marker)) |pos| {
                    header_end_pos = pos;
                }
            } else |_| {
                break;
            }
        }

        var request = ziggurat.request.Request.init(allocator);
        defer request.deinit();

        request.parse(buf[0..total_read]) catch {
            const bad_request = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: 11\r\n\r\nBad Request";
            _ = posix.send(socket, bad_request, 0) catch {};
            return;
        };

        if (request.headers.get("Content-Length")) |cl_str| {
            const expected_body_len = std.fmt.parseInt(usize, cl_str, 10) catch 0;
            const header_len = if (header_end_pos) |pos| pos + header_end_marker.len else total_read;
            const current_body_len = if (total_read > header_len) total_read - header_len else 0;

            if (expected_body_len > current_body_len) {
                const remaining = expected_body_len - current_body_len;

                var body_read: usize = 0;
                while (body_read < remaining and (total_read + body_read) < buf.len) {
                    const chunk_result = posix.recv(socket, buf[total_read + body_read ..], 0);
                    if (chunk_result) |bytes| {
                        if (bytes == 0) break;
                        body_read += bytes;
                    } else |_| {
                        break;
                    }
                }
                total_read += body_read;

                request.deinit();
                request = ziggurat.request.Request.init(allocator);
                request.parse(buf[0..total_read]) catch {
                    const bad_request = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: 11\r\n\r\nBad Request";
                    _ = posix.send(socket, bad_request, 0) catch {};
                    return;
                };
            }
        }

        const keep_alive = if (request.headers.get("Connection")) |conn_header|
            !std.ascii.eqlIgnoreCase(conn_header, "close")
        else
            true; // Default to keep-alive for HTTP/1.1

        if (server.inner.middleware.process(&request)) |mw_response| {
            const formatted = if (response_mod.Response.getFormattedResponse(&mw_response)) |pre_formatted|
                pre_formatted
            else
                mw_response.format() catch return;

            defer {
                if (response_mod.Response.getFormattedResponse(&mw_response) != null) {
                    response_mod.Response.clearFormattedResponse(&mw_response);
                } else {
                    std.heap.page_allocator.free(formatted);
                }
            }

            response_mod.releasePendingBuffer();
            _ = posix.send(socket, formatted, 0) catch {};
            if (!keep_alive) return;
            continue;
        }

        const response = if (server.inner.router.matchRoute(&request)) |route_response|
            route_response
        else
            ziggurat.response.Response.init(.not_found, "text/plain", "Not Found");

        const formatted_response = if (response_mod.Response.getFormattedResponse(&response)) |pre_formatted|
            pre_formatted
        else
            response.format() catch return;

        defer {
            if (response_mod.Response.getFormattedResponse(&response) != null) {
                response_mod.Response.clearFormattedResponse(&response);
            } else {
                std.heap.page_allocator.free(formatted_response);
            }
        }

        response_mod.releasePendingBuffer();
        _ = posix.send(socket, formatted_response, 0) catch {};

        if (!keep_alive) return;
    }
}

fn setSocketTimeouts(socket: posix.socket_t, config: ServerConfig) !void {
    if (builtin.os.tag == .windows) {
        const read_timeout_ms: u32 = config.read_timeout;
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(read_timeout_ms));

        const write_timeout_ms: u32 = config.write_timeout;
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(write_timeout_ms));
    } else {
        const read_timeout = posix.timeval{
            .sec = @intCast(config.read_timeout / 1000),
            .usec = @intCast((config.read_timeout % 1000) * 1000),
        };
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(read_timeout));

        const write_timeout = posix.timeval{
            .sec = @intCast(config.write_timeout / 1000),
            .usec = @intCast((config.write_timeout % 1000) * 1000),
        };
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(write_timeout));
    }
}

fn workerThreadFn() void {
    const queue = global_connection_queue orelse return;

    while (true) {
        const socket = queue.pop() orelse break; // Null means shutdown
        handleConnectionThreaded(socket);
    }
}

pub fn createRuntimeRouteWrapper() fn (*ziggurat.request.Request) ziggurat.response.Response {
    return struct {
        fn wrapper(ziggurat_request: *ziggurat.request.Request) ziggurat.response.Response {
            if (global_active_request_tracker) |tracker| {
                tracker.increment();
                defer tracker.decrement();
            }

            const runtime_registry = global_runtime_routes orelse {
                return Response.text("Runtime routes not available").withStatus(500).toZiggurat();
            };

            const mw_chain = global_middleware orelse {
                var engine12_request = Request.fromZiggurat(ziggurat_request, allocator);
                defer engine12_request.deinit();

                const method_str = @tagName(ziggurat_request.method);
                const route = runtime_registry.findRoute(method_str, engine12_request.path(), &engine12_request) catch |err| {
                    std.debug.print("[Runtime Route] Error finding route: {}\n", .{err});
                    return Response.text("Internal server error").withStatus(500).toZiggurat();
                };

                if (route) |r| {
                    const engine12_response = r.handler(&engine12_request);
                    return engine12_response.toZiggurat();
                }

                return Response.text("Not Found").withStatus(404).toZiggurat();
            };

            const metrics_collector = global_metrics;

            var engine12_request = Request.fromZiggurat(ziggurat_request, allocator);

            const request_id = generateRequestId(engine12_request.arena.allocator()) catch "unknown";
            engine12_request.set("request_id", request_id) catch {};

            var timing = metrics.RequestTiming.start(engine12_request.path());

            defer engine12_request.deinit();

            if (mw_chain.executePreRequest(&engine12_request)) |abort_response| {
                if (metrics_collector) |mc| {
                    mc.incrementError();
                    timing.finish(mc) catch {};
                }
                return abort_response.toZiggurat();
            }

            const method_str = @tagName(ziggurat_request.method);
            const route = runtime_registry.findRoute(method_str, engine12_request.path(), &engine12_request) catch |err| {
                std.debug.print("[Runtime Route] Error finding route: {}\n", .{err});
                if (metrics_collector) |mc| {
                    mc.incrementError();
                    timing.finish(mc) catch {};
                }
                return Response.text("Internal server error").withStatus(500).toZiggurat();
            };

            if (route) |r| {
                var engine12_response = r.handler(&engine12_request);

                engine12_response = mw_chain.executeResponse(engine12_response, &engine12_request);

                if (metrics_collector) |mc| {
                    timing.finish(mc) catch {};
                }

                return engine12_response.toZiggurat();
            }

            if (metrics_collector) |mc| {
                mc.incrementError();
                timing.finish(mc) catch {};
            }
            return Response.text("Not Found").withStatus(404).toZiggurat();
        }
    }.wrapper;
}

pub fn wrapHandler(comptime handler_fn: anytype, comptime route_pattern: ?[]const u8) fn (*ziggurat.request.Request) ziggurat.response.Response {
    const HandlerType = @TypeOf(handler_fn);
    const actual_handler: types.HttpHandler = switch (@typeInfo(HandlerType)) {
        .pointer => |ptr_info| if (ptr_info.size == .one) handler_fn.* else handler_fn,
        else => handler_fn,
    };
    return struct {
        const handler = actual_handler;
        const pattern = route_pattern;

        fn wrapper(ziggurat_request: *ziggurat.request.Request) ziggurat.response.Response {
            if (global_active_request_tracker) |tracker| {
                tracker.increment();
                defer tracker.decrement();
            }

            const mw_chain = global_middleware orelse {
                var engine12_request = Request.fromZiggurat(ziggurat_request, allocator);
                defer engine12_request.deinit();
                const engine12_response = handler(&engine12_request);
                return engine12_response.toZiggurat();
            };

            const metrics_collector = global_metrics;

            const route_pattern_str = if (pattern) |p| p else ziggurat_request.path;
            var timing = metrics.RequestTiming.start(route_pattern_str);

            var engine12_request = Request.fromZiggurat(ziggurat_request, allocator);

            const request_id = generateRequestId(engine12_request.arena.allocator()) catch "unknown";
            engine12_request.set("request_id", request_id) catch {};

            defer engine12_request.deinit();

            if (mw_chain.executePreRequest(&engine12_request)) |abort_response| {
                if (metrics_collector) |mc| {
                    mc.incrementError();
                    timing.finish(mc) catch {};
                }
                return abort_response.toZiggurat();
            }

            if (pattern) |pattern_str| {
                if (std.mem.indexOf(u8, pattern_str, ":") != null) {
                    var route_pattern_parsed = router.RoutePattern.parse(allocator, pattern_str) catch {
                        const engine12_response = handler(&engine12_request);
                        var final_response = mw_chain.executeResponse(engine12_response, &engine12_request);
                        if (metrics_collector) |mc| {
                            timing.finish(mc) catch {};
                        }
                        return final_response.toZiggurat();
                    };
                    defer route_pattern_parsed.deinit(allocator);

                    if (route_pattern_parsed.match(engine12_request.arena.allocator(), ziggurat_request.path) catch null) |params| {
                        engine12_request.setRouteParams(params) catch |err| {
                            std.debug.print("Failed to set route params: {}\n", .{err});
                        };
                    }
                }
            }

            var engine12_response = handler(&engine12_request);

            engine12_response = mw_chain.executeResponse(engine12_response, &engine12_request);

            if (metrics_collector) |mc| {
                timing.finish(mc) catch {};
            }

            return engine12_response.toZiggurat();
        }
    }.wrapper;
}

pub const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    read_timeout: u32 = 10000,
    write_timeout: u32 = 10000,
    worker_threads: u16 = 12,
    buffer_size: usize = 16384,
    max_header_size: usize = 32768,
    max_body_size: usize = 10 * 1024 * 1024,
};

pub const Engine12 = struct {
    const MAX_ROUTES = 5000;
    const MAX_WORKERS = 32;
    const MAX_HEALTH_CHECKS = 8;
    const MAX_STATIC_ROUTES = 500;
    const MAX_WS_ROUTES = 1000;

    allocator: std.mem.Allocator,
    profile: types.ServerProfile,
    server_config: ServerConfig = .{},
    is_running: bool = false,
    request_count: u64 = 0,
    start_time: i64 = 0,

    http_routes: [MAX_ROUTES]?types.Route = [_]?types.Route{null} ** MAX_ROUTES,
    routes_count: usize = 0,
    custom_root_handler: bool = false, // Track if custom root handler is registered
    server_builder: ?ziggurat.ServerBuilder = null,
    server_built: bool = false,
    built_server: ?ziggurat.Server = null,

    static_routes: [MAX_STATIC_ROUTES]?fileserver.FileServer = [_]?fileserver.FileServer{null} ** MAX_STATIC_ROUTES,
    static_routes_count: usize = 0,
    static_root_mounted: bool = false, // Track if static files are mounted at "/"

    template_routes: [MAX_ROUTES]struct { path: []const u8, context_fn: *const anyopaque } = undefined,
    template_routes_count: usize = 0,

    background_workers: [MAX_WORKERS]?types.BackgroundWorker = [_]?types.BackgroundWorker{null} ** MAX_WORKERS,
    workers_count: usize = 0,

    health_checks: [MAX_HEALTH_CHECKS]?types.HealthCheckFn = [_]?types.HealthCheckFn{null} ** MAX_HEALTH_CHECKS,
    health_checks_count: usize = 0,

    middleware: middleware_chain.MiddlewareChain,

    error_handler_registry: error_handler.ErrorHandlerRegistry,

    metrics_collector: metrics.MetricsCollector,

    logger: dev_tools.Logger,

    valve_registry: ?valve_registry_mod.ValveRegistry = null,

    runtime_routes: runtime_routes_mod.RuntimeRouteRegistry,

    orm_instance: ?*orm.ORM = null,

    ws_manager: ?websocket_mod.manager.WebSocketManager = null,
    ws_routes: [MAX_WS_ROUTES]?types.WebSocketRoute = [_]?types.WebSocketRoute{null} ** MAX_WS_ROUTES,
    ws_routes_count: usize = 0,

    hot_reload_manager: ?*hot_reload_mod.HotReloadManager = null,

    htmx_config: ?htmx_mod.HtmxConfig = null,
    htmx_registration_failed: bool = false, // Track if HTMX middleware registration failed

    openapi_generator: ?openapi.OpenAPIGenerator = null,

    supervisor: ?vigil.Supervisor = null,
    http_server: ?*anyopaque = null,

    active_request_tracker: shutdown_utils.ActiveRequestTracker,
    shutdown_hooks: shutdown_utils.ShutdownHookRegistry,

    pub fn initWithProfile(profile: types.ServerProfile) !Engine12 {
        var app = Engine12{
            .allocator = allocator,
            .profile = profile,
            .middleware = middleware_chain.MiddlewareChain{},
            .error_handler_registry = error_handler.ErrorHandlerRegistry.init(allocator),
            .metrics_collector = metrics.MetricsCollector.init(allocator),
            .logger = dev_tools.Logger.fromEnvironment(allocator, profile.environment),
            .runtime_routes = runtime_routes_mod.RuntimeRouteRegistry.init(allocator),
            .active_request_tracker = shutdown_utils.ActiveRequestTracker.init(),
            .shutdown_hooks = shutdown_utils.ShutdownHookRegistry.init(allocator),
        };
        global_logger = &app.logger;
        global_active_request_tracker = &app.active_request_tracker;
        return app;
    }

    pub fn initDevelopment() !Engine12 {
        var app = try Engine12.initWithProfile(types.ServerProfile_Development);

        const hr_manager = try allocator.create(hot_reload_mod.HotReloadManager);
        hr_manager.* = hot_reload_mod.HotReloadManager.init(allocator, true);
        app.hot_reload_manager = hr_manager;

        script_injector_mod.setHotReloadManager(hr_manager);

        try app.useResponse(script_injector_mod.injectHotReloadScript);

        app.enableHtmx();

        return app;
    }

    pub fn initProduction() !Engine12 {
        return Engine12.initWithProfile(types.ServerProfile_Production);
    }

    pub fn initTesting() !Engine12 {
        return Engine12.initWithProfile(types.ServerProfile_Testing);
    }

    pub fn enableHtmx(self: *Engine12) void {
        const config = if (self.profile.environment == .production)
            htmx_mod.production_config
        else
            htmx_mod.development_config;
        self.enableHtmxWithConfig(config);
    }

    pub fn enableHtmxWithConfig(self: *Engine12, config: htmx_mod.HtmxConfig) void {
        self.htmx_config = config;
        htmx_mod.setConfig(config);
        self.htmx_registration_failed = false; // Reset flag

        self.useResponse(htmx_mod.injectHtmx) catch |err| {
            self.htmx_registration_failed = true;
            std.debug.print("[Engine12] Error: Failed to register HTMX injector middleware: {}\n", .{err});
            std.debug.print("[Engine12] This usually means too many middleware are registered (max: {d})\n", .{middleware_chain.MiddlewareChain.MAX_MIDDLEWARE});
            std.debug.print("[Engine12] HTMX will not be injected into responses. Consider removing unused middleware.\n", .{});
            return;
        };
    }

    pub fn disableHtmx(self: *Engine12) void {
        self.htmx_config = null;
        self.htmx_registration_failed = false;
        htmx_mod.setConfig(null);
    }

    pub fn isHtmxEnabled(self: *const Engine12) bool {
        return self.htmx_config != null and self.htmx_config.?.enabled and !self.htmx_registration_failed;
    }

    pub fn configure(self: *Engine12, config: ServerConfig) void {
        self.server_config = config;
    }

    pub fn setPort(self: *Engine12, port: u16) void {
        self.server_config.port = port;
    }

    pub fn setHost(self: *Engine12, host: []const u8) void {
        self.server_config.host = host;
    }

    pub fn getPort(self: *Engine12) u16 {
        return self.server_config.port;
    }

    pub fn getHost(self: *Engine12) []const u8 {
        return self.server_config.host;
    }

    pub fn deinit(self: *Engine12) void {
        self.is_running = false;

        self.logger.deinit();

        if (self.hot_reload_manager) |manager| {
            manager.deinit();
            allocator.destroy(manager);
            self.hot_reload_manager = null;
        }

        if (self.openapi_generator) |*generator| {
            generator.deinit();
            self.openapi_generator = null;
        }

        if (self.valve_registry) |*registry| {
            registry.deinit();
            self.valve_registry = null;
        }

        self.runtime_routes.deinit();

        self.shutdown_hooks.deinit(self.allocator);
    }

    pub fn registerValve(self: *Engine12, valve_ptr: *valve_mod.Valve) !void {
        if (self.valve_registry == null) {
            self.valve_registry = valve_registry_mod.ValveRegistry.init(self.allocator);
        }

        if (self.valve_registry) |*registry| {
            try registry.register(valve_ptr, self);
        }
    }

    pub fn unregisterValve(self: *Engine12, name: []const u8) !void {
        if (self.valve_registry) |*registry| {
            try registry.unregister(name);
        } else {
            return valve_mod.ValveError.ValveNotFound;
        }
    }

    pub fn getValveRegistry(self: *Engine12) ?*valve_registry_mod.ValveRegistry {
        if (self.valve_registry) |*registry| {
            return registry;
        }
        return null;
    }

    pub fn get(self: *Engine12, comptime path_pattern: []const u8, comptime handler: anytype) !void {
        if (self.routes_count >= MAX_ROUTES) {
            return error.TooManyRoutes;
        }
        if (self.server_built) {
            return error.ServerAlreadyBuilt;
        }

        if (std.mem.eql(u8, path_pattern, "/")) {
            self.custom_root_handler = true;
        }

        if (self.built_server == null) {
            var builder = ziggurat.ServerBuilder.init(self.allocator);
            var server = try builder
                .host(self.server_config.host)
                .port(self.server_config.port)
                .readTimeout(self.server_config.read_timeout)
                .writeTimeout(self.server_config.write_timeout)
                .build();

            global_middleware = &self.middleware;
            global_metrics = &self.metrics_collector;
            if (!self.static_root_mounted and !self.custom_root_handler) {
                try server.get("/", wrapHandler(handlers.handleDefaultRoot, "/"));
            }
            try server.get("/health", wrapHandler(handlers.handleHealthEndpoint, "/health"));
            try server.get("/ready", wrapHandler(handlers.handleReadyEndpoint, "/ready"));
            try server.get("/metrics", wrapHandler(handlers.handleMetricsEndpoint, "/metrics"));

            self.built_server = server;
            self.http_server = @ptrCast(&server);
        }

        global_middleware = &self.middleware;
        global_metrics = &self.metrics_collector;

        const wrapped_handler = wrapHandler(handler, path_pattern);

        if (self.built_server) |*server| {
            try server.get(path_pattern, wrapped_handler);
        }

        const HandlerType = @TypeOf(handler);
        const handler_for_storage: types.HttpHandler = switch (@typeInfo(HandlerType)) {
            .pointer => |ptr_info| if (ptr_info.size == .one) handler.* else handler,
            else => handler,
        };
        self.http_routes[self.routes_count] = types.Route{
            .path = path_pattern,
            .method = "GET",
            .handler_ptr = &handler_for_storage,
        };
        self.routes_count += 1;
    }

    pub fn getTry(self: *Engine12, comptime path_pattern: []const u8, comptime handler: types.TryHttpHandler) !void {
        return self.get(path_pattern, types.wrapTryHandler(handler));
    }

    pub fn postTry(self: *Engine12, comptime path_pattern: []const u8, comptime handler: types.TryHttpHandler) !void {
        return self.post(path_pattern, types.wrapTryHandler(handler));
    }

    pub fn putTry(self: *Engine12, comptime path_pattern: []const u8, comptime handler: types.TryHttpHandler) !void {
        return self.put(path_pattern, types.wrapTryHandler(handler));
    }

    pub fn deleteTry(self: *Engine12, comptime path_pattern: []const u8, comptime handler: types.TryHttpHandler) !void {
        return self.delete(path_pattern, types.wrapTryHandler(handler));
    }

    pub fn templateRoute(
        self: *Engine12,
        comptime path_pattern: []const u8,
        template_path: []const u8,
        context_fn: anytype,
    ) !void {
        const ContextFn = @TypeOf(context_fn);

        const template_path_copy = try self.allocator.dupe(u8, template_path);

        if (self.template_routes_count >= MAX_ROUTES) {
            return error.TooManyRoutes;
        }
        const route_index = self.template_routes_count;
        self.template_routes[route_index] = .{
            .path = template_path_copy,
            .context_fn = @ptrCast(&context_fn),
        };
        self.template_routes_count += 1;

        const captured_route_idx = route_index;
        const captured_app_ptr = self;

        const createHandler = struct {
            fn create(route_idx: usize, app: *Engine12) fn (*Request) Response {
                const Handler = struct {
                    fn handler(req: *Request) Response {
                        const route_info = app.template_routes[route_idx];
                        const template_path_ptr = route_info.path;
                        const context_fn_ptr = @as(ContextFn, @ptrCast(@alignCast(route_info.context_fn)));

                        const context = context_fn_ptr(req);
                        const templates_simple_mod = @import("templates/simple.zig");
                        const html = templates_simple_mod.renderSimple(template_path_ptr, context, app.allocator) catch |err| {
                            return switch (err) {
                                error.TemplateNotFound => Response.text("Template not found").withStatus(404),
                                error.TemplateTooLarge => Response.text("Template too large").withStatus(500),
                                else => Response.text("Template rendering error").withStatus(500),
                            };
                        };
                        defer app.allocator.free(html);
                        return Response.html(html);
                    }
                };
                return Handler.handler;
            }
        }.create(captured_route_idx, captured_app_ptr);

        try self.get(path_pattern, createHandler);
    }

    pub fn post(self: *Engine12, comptime path_pattern: []const u8, comptime handler: anytype) !void {
        if (self.routes_count >= MAX_ROUTES) {
            return error.TooManyRoutes;
        }
        if (self.server_built) {
            return error.ServerAlreadyBuilt;
        }

        if (self.built_server == null) {
            var builder = ziggurat.ServerBuilder.init(self.allocator);
            var server = try builder
                .host(self.server_config.host)
                .port(self.server_config.port)
                .readTimeout(self.server_config.read_timeout)
                .writeTimeout(self.server_config.write_timeout)
                .build();

            global_middleware = &self.middleware;
            global_metrics = &self.metrics_collector;
            if (!self.static_root_mounted and !self.custom_root_handler) {
                try server.get("/", wrapHandler(handlers.handleDefaultRoot, "/"));
            }
            try server.get("/health", wrapHandler(handlers.handleHealthEndpoint, "/health"));
            try server.get("/ready", wrapHandler(handlers.handleReadyEndpoint, "/ready"));
            try server.get("/metrics", wrapHandler(handlers.handleMetricsEndpoint, "/metrics"));

            self.built_server = server;
            self.http_server = @ptrCast(&server);
        }

        const wrapped_handler = wrapHandler(handler, path_pattern);

        if (self.built_server) |*server| {
            try server.post(path_pattern, wrapped_handler);
        }

        const HandlerTypePost = @TypeOf(handler);
        const handler_for_storage_post: types.HttpHandler = switch (@typeInfo(HandlerTypePost)) {
            .pointer => |ptr_info| if (ptr_info.size == .one) handler.* else handler,
            else => handler,
        };
        self.http_routes[self.routes_count] = types.Route{
            .path = path_pattern,
            .method = "POST",
            .handler_ptr = &handler_for_storage_post,
        };
        self.routes_count += 1;
    }

    pub fn postEmpty(self: *Engine12, comptime path_pattern: []const u8, comptime handler: anytype) !void {
        return self.post(path_pattern, handler);
    }

    pub fn put(self: *Engine12, comptime path_pattern: []const u8, comptime handler: anytype) !void {
        if (self.routes_count >= MAX_ROUTES) {
            return error.TooManyRoutes;
        }
        if (self.server_built) {
            return error.ServerAlreadyBuilt;
        }

        if (self.built_server == null) {
            var builder = ziggurat.ServerBuilder.init(self.allocator);
            var server = try builder
                .host(self.server_config.host)
                .port(self.server_config.port)
                .readTimeout(self.server_config.read_timeout)
                .writeTimeout(self.server_config.write_timeout)
                .build();

            global_middleware = &self.middleware;
            global_metrics = &self.metrics_collector;
            if (!self.static_root_mounted and !self.custom_root_handler) {
                try server.get("/", wrapHandler(handlers.handleDefaultRoot, "/"));
            }
            try server.get("/health", wrapHandler(handlers.handleHealthEndpoint, "/health"));
            try server.get("/ready", wrapHandler(handlers.handleReadyEndpoint, "/ready"));
            try server.get("/metrics", wrapHandler(handlers.handleMetricsEndpoint, "/metrics"));

            self.built_server = server;
            self.http_server = @ptrCast(&server);
        }

        const wrapped_handler = wrapHandler(handler, path_pattern);

        if (self.built_server) |*server| {
            try server.put(path_pattern, wrapped_handler);
        }

        const HandlerTypePut = @TypeOf(handler);
        const handler_for_storage_put: types.HttpHandler = switch (@typeInfo(HandlerTypePut)) {
            .pointer => |ptr_info| if (ptr_info.size == .one) handler.* else handler,
            else => handler,
        };
        self.http_routes[self.routes_count] = types.Route{
            .path = path_pattern,
            .method = "PUT",
            .handler_ptr = &handler_for_storage_put,
        };
        self.routes_count += 1;
    }

    pub fn delete(self: *Engine12, comptime path_pattern: []const u8, comptime handler: anytype) !void {
        if (self.routes_count >= MAX_ROUTES) {
            return error.TooManyRoutes;
        }
        if (self.server_built) {
            return error.ServerAlreadyBuilt;
        }

        if (self.built_server == null) {
            var builder = ziggurat.ServerBuilder.init(self.allocator);
            var server = try builder
                .host(self.server_config.host)
                .port(self.server_config.port)
                .readTimeout(self.server_config.read_timeout)
                .writeTimeout(self.server_config.write_timeout)
                .build();

            global_middleware = &self.middleware;
            global_metrics = &self.metrics_collector;
            if (!self.static_root_mounted and !self.custom_root_handler) {
                try server.get("/", wrapHandler(handlers.handleDefaultRoot, "/"));
            }
            try server.get("/health", wrapHandler(handlers.handleHealthEndpoint, "/health"));
            try server.get("/ready", wrapHandler(handlers.handleReadyEndpoint, "/ready"));
            try server.get("/metrics", wrapHandler(handlers.handleMetricsEndpoint, "/metrics"));

            self.built_server = server;
            self.http_server = @ptrCast(&server);
        }

        const wrapped_handler = wrapHandler(handler, path_pattern);

        if (self.built_server) |*server| {
            try server.delete(path_pattern, wrapped_handler);
        }

        const HandlerTypeDelete = @TypeOf(handler);
        const handler_for_storage_delete: types.HttpHandler = switch (@typeInfo(HandlerTypeDelete)) {
            .pointer => |ptr_info| if (ptr_info.size == .one) handler.* else handler,
            else => handler,
        };
        self.http_routes[self.routes_count] = types.Route{
            .path = path_pattern,
            .method = "DELETE",
            .handler_ptr = &handler_for_storage_delete,
        };
        self.routes_count += 1;
    }

    pub fn group(self: *Engine12, prefix: []const u8) route_group.RouteGroup {
        const get_wrapper = struct {
            fn wrap(ptr: *anyopaque, comptime path: []const u8, handler: anytype) !void {
                const engine = @as(*Engine12, @ptrCast(ptr));
                try engine.get(path, handler);
            }
        }.wrap;

        const post_wrapper = struct {
            fn wrap(ptr: *anyopaque, comptime path: []const u8, handler: anytype) !void {
                const engine = @as(*Engine12, @ptrCast(ptr));
                try engine.post(path, handler);
            }
        }.wrap;

        const put_wrapper = struct {
            fn wrap(ptr: *anyopaque, comptime path: []const u8, handler: anytype) !void {
                const engine = @as(*Engine12, @ptrCast(ptr));
                try engine.put(path, handler);
            }
        }.wrap;

        const delete_wrapper = struct {
            fn wrap(ptr: *anyopaque, comptime path: []const u8, handler: anytype) !void {
                const engine = @as(*Engine12, @ptrCast(ptr));
                try engine.delete(path, handler);
            }
        }.wrap;

        return route_group.RouteGroup{
            .engine_ptr = @as(*anyopaque, @ptrCast(self)),
            .prefix = prefix,
            .middleware = middleware_chain.MiddlewareChain{},
            .register_get = get_wrapper,
            .register_post = post_wrapper,
            .register_put = put_wrapper,
            .register_delete = delete_wrapper,
        };
    }

    pub fn getOpenApiGenerator(self: *Engine12) !*openapi.OpenAPIGenerator {
        if (self.openapi_generator == null) {
            self.openapi_generator = openapi.OpenAPIGenerator.init(self.allocator, .{
                .title = "Engine12 API",
                .version = "1.0.0",
            });
        }
        return &self.openapi_generator.?;
    }

    pub fn enableOpenApiDocs(self: *Engine12, comptime mount_path: []const u8, info: openapi.OpenApiInfo) !void {
        if (self.openapi_generator == null) {
            self.openapi_generator = openapi.OpenAPIGenerator.init(self.allocator, info);
        } else {
            self.openapi_generator.?.doc.info = info;
        }

        global_openapi_generator = &self.openapi_generator.?;

        const json_path = mount_path ++ "/openapi.json";

        try self.get(json_path, struct {
            fn handler(req: *Request) Response {
                _ = req;
                if (global_openapi_generator) |gen| {
                    const json = gen.doc.toJson() catch return Response.serverError("Failed to generate OpenAPI JSON");
                    defer std.heap.page_allocator.free(json);
                    return Response.text(json).withContentType("application/json");
                }
                return Response.serverError("OpenAPI generator not initialized");
            }
        }.handler);

        try self.get(mount_path, struct {
            fn handler(_: *Request) Response {
                const html =
                    \\<!DOCTYPE html>
                    \\<html lang="en">
                    \\<head>
                    \\  <meta charset="utf-8" />
                    \\  <meta name="viewport" content="width=device-width, initial-scale=1" />
                    \\  <title>Swagger UI</title>
                    \\  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5.11.0/swagger-ui.css" />
                    \\</head>
                    \\<body>
                    \\  <div id="swagger-ui"></div>
                    \\  <script src="https://unpkg.com/swagger-ui-dist@5.11.0/swagger-ui-bundle.js" crossorigin></script>
                    \\  <script>
                    \\    window.onload = () => {
                    \\      // Calculate JSON URL relative to current page
                    \\      const path = window.location.pathname;
                    \\      const jsonUrl = path.endsWith('/') ? path + 'openapi.json' : path + '/openapi.json';
                    \\      
                    \\      window.ui = SwaggerUIBundle({
                    \\        url: jsonUrl,
                    \\        dom_id: '#swagger-ui',
                    \\      });
                    \\    };
                    \\  </script>
                    \\</body>
                    \\</html>
                ;
                return Response.html(html);
            }
        }.handler);
    }

    pub fn restApi(self: *Engine12, comptime prefix: []const u8, comptime Model: type, config: rest_api_mod.RestApiConfig(Model)) !void {
        return rest_api_mod.restApi(self, prefix, Model, config);
    }

    pub fn restApiDefault(
        self: *Engine12,
        comptime prefix: []const u8,
        comptime Model: type,
        overrides: anytype,
    ) !void {
        const orm_instance = try self.getORM();

        const ConfigType = rest_api_mod.RestApiConfig(Model);
        const OverrideType = @TypeOf(overrides);

        var validator_fn: ?*const fn (*Request, Model) anyerror!validation.ValidationErrors = null;
        comptime {
            const type_info = @typeInfo(OverrideType);
            switch (type_info) {
                .@"struct" => |struct_info| {
                    for (struct_info.fields) |field| {
                        if (std.mem.eql(u8, field.name, "validator")) {
                            validator_fn = overrides.validator;
                            break;
                        }
                    }
                },
                else => {},
            }
        }
        const validator_provided = validator_fn != null;

        const default_validator = struct {
            fn validate(_: *Request, _: Model) anyerror!validation.ValidationErrors {
                const errors = validation.ValidationErrors.init(allocator);
                return errors;
            }
        }.validate;

        var config: ConfigType = undefined;
        config.orm = orm_instance;
        config.validator = if (validator_provided) validator_fn.? else default_validator;
        config.enable_pagination = true;
        config.enable_filtering = true;
        config.enable_sorting = true;
        config.authenticator = null;
        config.authorization = null;
        config.cache_ttl_ms = null;

        comptime {
            const type_info = @typeInfo(OverrideType);
            switch (type_info) {
                .@"struct" => |struct_info| {
                    for (struct_info.fields) |field| {
                        if (@hasField(ConfigType, field.name)) {
                            @field(config, field.name) = @field(overrides, field.name);
                        }
                    }
                },
                else => {},
            }
        }

        return rest_api_mod.restApi(self, prefix, Model, config);
    }

    pub fn useErrorHandler(self: *Engine12, handler: error_handler.ErrorHandler) void {
        self.error_handler_registry.register(handler);
    }

    pub fn setRateLimiter(self: *Engine12, limiter: *rate_limit.RateLimiter) void {
        _ = self;
        global_rate_limiter = limiter;
    }

    pub fn setCache(self: *Engine12, response_cache: *cache.ResponseCache) void {
        _ = self;
        global_cache = response_cache;
    }

    pub fn getCache(self: *Engine12) ?*cache.ResponseCache {
        _ = self;
        return global_cache;
    }

    pub fn getLogger(self: *Engine12) *dev_tools.Logger {
        return &self.logger;
    }

    pub fn setLogger(self: *Engine12, logger: dev_tools.Logger) void {
        self.logger.deinit();
        self.logger = logger;
    }

    pub fn enableRequestLogging(self: *Engine12, config: ?@import("middleware/logging_middleware.zig").LoggingConfig) !void {
        const logging_middleware_mod = @import("middleware/logging_middleware.zig");
        const default_config = logging_middleware_mod.LoggingConfig{};
        const logging_config = config orelse default_config;

        var logging_mw = logging_middleware_mod.LoggingMiddleware.init(logging_config);
        logging_middleware_mod.LoggingMiddleware.setGlobalLogger(&self.logger);
        logging_mw.setGlobalConfig();

        try self.usePreRequest(logging_mw.preRequestMwFn());
        try self.useResponse(logging_mw.responseMwFn());
    }

    pub fn usePreRequest(self: *Engine12, middleware: middleware_chain.PreRequestMiddlewareFn) !void {
        try self.middleware.addPreRequest(middleware);
    }

    pub fn useResponse(self: *Engine12, middleware: middleware_chain.ResponseMiddlewareFn) !void {
        try self.middleware.addResponse(middleware);
    }

    pub fn loadTemplate(self: *Engine12, template_path: []const u8) !*hot_reload_mod.RuntimeTemplate {
        if (self.hot_reload_manager) |manager| {
            return try manager.watchTemplate(template_path);
        }
        std.debug.print("[Engine12] Error: loadTemplate() requires development mode (initDevelopment()).\n", .{});
        std.debug.print("[Engine12] Template path: {s}\n", .{template_path});
        std.debug.print("[Engine12] In production, use @embedFile with comptime templates:\n", .{});
        std.debug.print("[Engine12]   const TemplateType = Template.compileFile(\"{s}\");\n", .{template_path});
        std.debug.print("[Engine12]   const html = try TemplateType.render(Context, context, allocator);\n", .{});
        return error.HotReloadNotEnabled;
    }

    pub const TemplateRegistry = struct {
        templates: std.StringHashMap(*hot_reload_mod.RuntimeTemplate),
        registry_allocator: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) TemplateRegistry {
            return TemplateRegistry{
                .templates = std.StringHashMap(*hot_reload_mod.RuntimeTemplate).init(alloc),
                .registry_allocator = alloc,
            };
        }

        pub fn get(self: *TemplateRegistry, name: []const u8) ?*hot_reload_mod.RuntimeTemplate {
            return self.templates.get(name);
        }

        pub fn has(self: *TemplateRegistry, name: []const u8) bool {
            return self.templates.contains(name);
        }

        pub fn count(self: *const TemplateRegistry) usize {
            return self.templates.count();
        }

        pub fn deinit(self: *TemplateRegistry) void {
            var iter = self.templates.iterator();
            while (iter.next()) |entry| {
                self.registry_allocator.free(entry.key_ptr.*);
            }
            self.templates.deinit();
        }
    };

    pub fn discoverTemplates(
        self: *Engine12,
        templates_dir: []const u8,
    ) !TemplateRegistry {
        var registry = TemplateRegistry.init(self.allocator);

        if (self.hot_reload_manager == null) {
            std.debug.print("[Engine12] Error: discoverTemplates() requires development mode (initDevelopment()).\n", .{});
            std.debug.print("[Engine12] Templates directory: {s}\n", .{templates_dir});
            std.debug.print("[Engine12] In production, use @embedFile with comptime templates instead.\n", .{});
            std.debug.print("[Engine12] Returning empty registry - templates will not be available.\n", .{});
            return registry;
        }

        var dir = std.fs.cwd().openDir(templates_dir, .{ .iterate = true }) catch |err| {
            std.debug.print("[Engine12] Warning: Could not open templates directory '{s}': {}\n", .{ templates_dir, err });
            return registry; // Return empty registry gracefully
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (true) {
            const entry = iterator.next() catch |err| {
                std.debug.print("[Engine12] Warning: Error iterating templates directory '{s}': {}\n", .{ templates_dir, err });
                return registry;
            } orelse break;

            if (entry.kind != .file) continue;
            const template_name = entry.name;
            if (!std.mem.endsWith(u8, template_name, ".zt.html")) continue;

            const template_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ templates_dir, template_name });
            defer self.allocator.free(template_path);

            const template = self.loadTemplate(template_path) catch |err| {
                std.debug.print("[Engine12] Warning: Failed to load template '{s}': {}\n", .{ template_path, err });
                continue;
            };

            if (template_name.len < 8) continue; // Skip files that are too short
            const route_name_len = template_name.len - 7;
            var route_name_slice = template_name[0..route_name_len];
            if (route_name_slice.len > 0 and route_name_slice[route_name_slice.len - 1] == '.') {
                route_name_slice = route_name_slice[0 .. route_name_slice.len - 1];
            }
            const route_name = route_name_slice;
            const route_name_copy = try self.allocator.dupe(u8, route_name);
            try registry.templates.put(route_name_copy, template);

            const route_path = if (std.mem.eql(u8, route_name, "index"))
                "/"
            else
                try std.fmt.allocPrint(self.allocator, "/{s}", .{route_name});
            defer if (!std.mem.eql(u8, route_name, "index")) {
                self.allocator.free(route_path);
            };

            std.debug.print("[Engine12] Discovered template: {s} (stored as: '{s}', route: {s})\n", .{ template_path, route_name_copy, route_path });
        }

        return registry;
    }

    pub fn websocket(self: *Engine12, comptime path_pattern: []const u8, handler: types.WebSocketHandler) !void {
        if (self.ws_routes_count >= MAX_WS_ROUTES) {
            return error.TooManyWebSocketRoutes;
        }

        if (self.ws_manager == null) {
            self.ws_manager = try websocket_mod.manager.WebSocketManager.init(self.allocator);
        }

        self.ws_routes[self.ws_routes_count] = types.WebSocketRoute{
            .path = path_pattern,
            .handler_ptr = handler, // Store function pointer value directly, not address
        };
        self.ws_routes_count += 1;

        if (self.ws_manager) |*manager| {
            try manager.registerServer(path_pattern, handler);
        }
    }

    pub fn discoverStaticFiles(self: *Engine12, static_dir: []const u8) !void {
        var dir = std.fs.cwd().openDir(static_dir, .{ .iterate = true }) catch |err| {
            std.debug.print("[Engine12] Warning: Could not open static directory '{s}': {}\n", .{ static_dir, err });
            return; // Gracefully return, don't fail
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (true) {
            const entry = iterator.next() catch |err| {
                std.debug.print("[Engine12] Warning: Error iterating static directory '{s}': {}\n", .{ static_dir, err });
                return;
            } orelse break;
            if (entry.kind != .directory) continue;

            const subdir_name = entry.name;

            if (subdir_name.len > 0 and subdir_name[0] == '.') continue;

            const mount_path = try std.fmt.allocPrint(self.allocator, "/{s}", .{subdir_name});
            defer self.allocator.free(mount_path);

            const full_dir_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ static_dir, subdir_name });
            defer self.allocator.free(full_dir_path);

            self.serveStatic(mount_path, full_dir_path) catch |err| {
                std.debug.print("[Engine12] Warning: Failed to register static route '{s}' -> '{s}': {}\n", .{ mount_path, full_dir_path, err });
                continue;
            };

            std.debug.print("[Engine12] Discovered static route: {s} -> {s}\n", .{ mount_path, full_dir_path });
        }
    }

    pub fn serveStaticDirectory(self: *Engine12, static_dir: []const u8) !void {
        try self.discoverStaticFiles(static_dir);
    }

    pub fn static(self: *Engine12, mount_path: []const u8, directory: []const u8) !void {
        var clean_mount = mount_path;
        if (std.mem.endsWith(u8, clean_mount, "/*")) {
            clean_mount = clean_mount[0 .. clean_mount.len - 2];
        } else if (std.mem.endsWith(u8, clean_mount, "*")) {
            clean_mount = clean_mount[0 .. clean_mount.len - 1];
        }
        if (clean_mount.len > 1 and std.mem.endsWith(u8, clean_mount, "/")) {
            clean_mount = clean_mount[0 .. clean_mount.len - 1];
        }
        if (clean_mount.len == 0) {
            clean_mount = "/";
        }
        try self.serveStatic(clean_mount, directory);
    }

    pub fn serveStatic(self: *Engine12, mount_path: []const u8, directory: []const u8) !void {
        if (self.static_routes_count >= MAX_STATIC_ROUTES) {
            return error.TooManyStaticRoutes;
        }

        const mount_path_copy = try self.allocator.dupe(u8, mount_path);
        const directory_copy = try self.allocator.dupe(u8, directory);

        var file_server = fileserver.FileServer.init(self.allocator, mount_path_copy, directory_copy);

        if (self.hot_reload_manager != null) {
            file_server.disableCache();
        }

        if (std.mem.eql(u8, mount_path_copy, "/")) {
            self.static_root_mounted = true;
        }

        self.static_routes[self.static_routes_count] = file_server;
        self.static_routes_count += 1;

        if (self.hot_reload_manager) |hr_manager| {
            hr_manager.watchStaticFiles(&self.static_routes[self.static_routes_count - 1].?) catch |err| {
                std.debug.print("[HotReload] Warning: Failed to watch static files: {}\n", .{err});
            };
        }

        if (self.built_server == null) {
            var builder = ziggurat.ServerBuilder.init(self.allocator);
            var server = try builder
                .host(self.server_config.host)
                .port(self.server_config.port)
                .readTimeout(self.server_config.read_timeout)
                .writeTimeout(self.server_config.write_timeout)
                .build();

            if (!std.mem.eql(u8, mount_path_copy, "/") and !self.custom_root_handler) {
                try server.get("/", wrapHandler(handlers.handleDefaultRoot, "/"));
            }
            try server.get("/health", wrapHandler(handlers.handleHealthEndpoint, "/health"));
            try server.get("/ready", wrapHandler(handlers.handleReadyEndpoint, "/ready"));
            try server.get("/metrics", wrapHandler(handlers.handleMetricsEndpoint, "/metrics"));

            self.built_server = server;
            self.http_server = @ptrCast(&server);
        }

        const static_index = static_file_registry_count;
        static_file_registry[static_index] = file_server;
        static_file_registry_count += 1;

        if (self.built_server) |*server| {
            static_mount_paths[static_index] = mount_path_copy;

            if (std.mem.eql(u8, mount_path, "/")) {
                const root_wrapper = struct {
                    fn handler(request: *ziggurat.request.Request) ziggurat.response.Response {
                        _ = request;
                        var i: usize = 0;
                        while (i < static_file_registry_count) {
                            if (static_file_registry[i]) |*fs| {
                                if (std.mem.eql(u8, static_mount_paths[i], "/")) {
                                    return fs.serveFile("/").toZiggurat();
                                }
                            }
                            i += 1;
                        }
                        return Response.text("Static file server not found").toZiggurat();
                    }
                }.handler;

                try server.get("/", root_wrapper);

                const css_wrapper = struct {
                    fn handler(request: *ziggurat.request.Request) ziggurat.response.Response {
                        _ = request;
                        var i: usize = 0;
                        while (i < static_file_registry_count) {
                            if (static_file_registry[i]) |*fs| {
                                if (std.mem.eql(u8, static_mount_paths[i], "/")) {
                                    return fs.serveFile("/css/styles.css").toZiggurat();
                                }
                            }
                            i += 1;
                        }
                        return Response.text("Static file server not found").toZiggurat();
                    }
                }.handler;

                const js_wrapper = struct {
                    fn handler(request: *ziggurat.request.Request) ziggurat.response.Response {
                        _ = request;
                        var i: usize = 0;
                        while (i < static_file_registry_count) {
                            if (static_file_registry[i]) |*fs| {
                                if (std.mem.eql(u8, static_mount_paths[i], "/")) {
                                    return fs.serveFile("/js/app.js").toZiggurat();
                                }
                            }
                            i += 1;
                        }
                        return Response.text("Static file server not found").toZiggurat();
                    }
                }.handler;

                try server.get("/css/styles.css", css_wrapper);
                try server.get("/js/app.js", js_wrapper);
            } else {
                const wrapper = struct {
                    fn handler(request: *ziggurat.request.Request) ziggurat.response.Response {
                        const request_path = request.path;

                        var i: usize = 0;
                        while (i < static_file_registry_count) {
                            if (static_file_registry[i]) |*fs| {
                                const registry_mount = static_mount_paths[i];
                                if (registry_mount.len > 0) {
                                    if (std.mem.startsWith(u8, request_path, registry_mount)) {
                                        return fs.serveFile(request_path).toZiggurat();
                                    }
                                }
                            }
                            i += 1;
                        }
                        return Response.text("Static file server not found").toZiggurat();
                    }
                }.handler;

                try server.get(mount_path_copy, wrapper);

                if (std.mem.eql(u8, mount_path_copy, "/css")) {
                    try server.get("/css/:file", wrapper);
                    try server.get("/css/style.css", wrapper);
                    try server.get("/css/styles.css", wrapper);
                } else if (std.mem.eql(u8, mount_path_copy, "/js")) {
                    try server.get("/js/:file", wrapper);
                    try server.get("/js/app.js", wrapper);
                    try server.get("/js/collapsible.js", wrapper);
                } else if (std.mem.eql(u8, mount_path_copy, "/images")) {
                    try server.get("/images/:file", wrapper);
                } else if (std.mem.eql(u8, mount_path_copy, "/fonts")) {
                    try server.get("/fonts/:file", wrapper);
                } else {}
            }
        }
    }

    pub fn initDatabase(self: *Engine12, db_path: []const u8) !void {
        const DatabaseSingleton = @import("orm/singleton.zig").DatabaseSingleton;
        const loadConfigFromEnv = @import("orm/singleton.zig").loadConfigFromEnv;

        const config = try loadConfigFromEnv(self.allocator, db_path);
        try DatabaseSingleton.initWithConfig(config, self.allocator);
    }

    pub fn initDatabaseWithMigrations(
        self: *Engine12,
        db_path: []const u8,
        migrations_dir: []const u8,
    ) !void {
        try self.initDatabase(db_path);

        const DatabaseSingleton = @import("orm/singleton.zig").DatabaseSingleton;
        const orm_instance = try DatabaseSingleton.get();

        const migration_discovery_mod = @import("orm/migration_discovery.zig");
        var registry = migration_discovery_mod.discoverMigrations(self.allocator, migrations_dir) catch |err| {
            std.debug.print("[Engine12] Warning: Migration discovery failed: {}\n", .{err});
            const init_path = try std.fmt.allocPrint(self.allocator, "{s}/init.zig", .{migrations_dir});
            defer self.allocator.free(init_path);

            const init_file = std.fs.cwd().openFile(init_path, .{}) catch {
                return; // No migrations to run
            };
            defer init_file.close();

            std.debug.print("[Engine12] Info: migrations/init.zig found. For comptime imports, use @import(\"migrations/init.zig\") directly.\n", .{});
            return;
        };
        defer registry.deinit();

        try orm_instance.runMigrationsFromRegistry(&registry);
    }

    pub fn getORM(_: *Engine12) !*orm.ORM {
        const DatabaseSingleton = @import("orm/singleton.zig").DatabaseSingleton;
        return DatabaseSingleton.get();
    }

    pub fn runTask(self: *Engine12, name: []const u8, task: types.BackgroundTask) !void {
        if (self.workers_count >= MAX_WORKERS) {
            return error.TooManyWorkers;
        }
        self.background_workers[self.workers_count] = types.BackgroundWorker{
            .name = name,
            .task = task,
            .interval_ms = null,
        };
        self.workers_count += 1;
    }

    pub fn schedulePeriodicTask(self: *Engine12, name: []const u8, task: types.BackgroundTask, interval_ms: u32) !void {
        if (self.workers_count >= MAX_WORKERS) {
            return error.TooManyWorkers;
        }
        self.background_workers[self.workers_count] = types.BackgroundWorker{
            .name = name,
            .task = task,
            .interval_ms = interval_ms,
        };
        self.workers_count += 1;
    }

    pub fn registerHealthCheck(self: *Engine12, check: types.HealthCheckFn) !void {
        if (self.health_checks_count >= MAX_HEALTH_CHECKS) {
            return error.TooManyHealthChecks;
        }
        self.health_checks[self.health_checks_count] = check;
        self.health_checks_count += 1;
    }

    pub fn getSystemHealth(self: *Engine12) types.HealthStatus {
        var overall_status: types.HealthStatus = .healthy;
        var i: usize = 0;
        while (i < self.health_checks_count) {
            if (self.health_checks[i]) |check| {
                const status = check();
                if (status == .unhealthy) {
                    return .unhealthy;
                }
                if (status == .degraded and overall_status == .healthy) {
                    overall_status = .degraded;
                }
            }
            i += 1;
        }
        return overall_status;
    }

    pub fn getUptimeMs(self: *Engine12) i64 {
        if (self.start_time == 0) return 0;
        return std.time.milliTimestamp() - self.start_time;
    }

    pub fn getRequestCount(self: *Engine12) u64 {
        return self.request_count;
    }

    pub fn start(self: *Engine12) !void {
        if (@import("builtin").mode == .Debug) {
            std.debug.print("\n[WARN] Running in Debug mode. Performance is significantly slower.\n", .{});
            std.debug.print("       Use: zig build -Doptimize=ReleaseFast for production.\n\n", .{});
        }

        self.start_time = std.time.milliTimestamp();
        self.is_running = true;

        try self.startHttpServer();
        try self.startBackgroundTasks();
        try self.startHotReloadManager(); // Register hot reload WebSocket route first
        try self.startWebSocketManager(); // Then start all WebSocket servers

        if (self.valve_registry) |*registry| {
            registry.onAppStart() catch |err| {
                std.debug.print("[Valve] Error during valve onAppStart: {}\n", .{err});
            };
        }
    }

    pub fn listen(self: *Engine12) !void {
        // Store global reference for signal handler
        global_engine12_instance = self;

        // Install SIGINT and SIGTERM handlers for graceful shutdown
        if (builtin.os.tag != .windows) {
            const act = posix.Sigaction{
                .handler = .{ .handler = handleSignal },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(posix.SIG.INT, &act, null);
            posix.sigaction(posix.SIG.TERM, &act, null);
        } else {
            // Suppress unused function warning on Windows
            _ = &handleSignal;
        }

        try self.start();
        self.printStatus();
        std.debug.print("Press Ctrl+C to stop the server...\n\n", .{});

        while (self.is_running) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }

        // Graceful shutdown triggered by signal
        self.stop() catch |err| {
            std.debug.print("[System] Error during shutdown: {}\n", .{err});
        };

        // Clear global reference
        global_engine12_instance = null;
    }

    pub fn stop(self: *Engine12) !void {
        std.debug.print("\n[System] Initiating graceful shutdown...\n", .{});

        self.is_running = false;

        // Immediately signal connection queue to stop accepting new connections
        if (global_connection_queue) |queue| {
            queue.signalShutdown();
        }

        // Close the listener socket to unblock the accept thread
        if (self.built_server) |*server| {
            closeSocket(server.inner.listener);
        }

        const timeout_ms = self.profile.graceful_shutdown_timeout_ms;
        const active_count = self.active_request_tracker.get();
        if (active_count > 0) {
            std.debug.print("[System] Waiting for {d} active request(s) to complete (timeout: {d}ms)...\n", .{ active_count, timeout_ms });
            const completed = self.active_request_tracker.waitForCompletion(timeout_ms);
            if (!completed) {
                std.debug.print("[System] Warning: Timeout waiting for requests. Proceeding with shutdown.\n", .{});
            } else {
                std.debug.print("[System] All requests completed.\n", .{});
            }
        }

        std.debug.print("[System] Executing shutdown hooks...\n", .{});
        self.shutdown_hooks.execute();

        if (self.valve_registry) |*registry| {
            registry.onAppStop();
        }

        self.stopHotReloadManager();
        self.stopWebSocketManager();
        try self.stopHttpServer();
        self.stopBackgroundTasks();

        const uptime = self.getUptimeMs();
        std.debug.print("[System] Shutdown complete. Uptime: {d}ms\n", .{uptime});

        // Brief pause to allow output to flush before returning to shell
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    pub fn registerShutdownHook(self: *Engine12, hook: shutdown_utils.ShutdownHook) !void {
        try self.shutdown_hooks.register(hook, self.allocator);
    }

    pub fn getActiveRequestCount(self: *const Engine12) u64 {
        return self.active_request_tracker.get();
    }

    fn startHttpServer(self: *Engine12) !void {
        self.server_built = true;

        if (self.built_server) |*server| {
            const num_workers = self.server_config.worker_threads;

            if (num_workers == 0) {
                const ServerThread = struct {
                    server_ptr: *ziggurat.Server,
                    fn run(ctx: @This()) void {
                        ctx.server_ptr.start() catch |err| {
                            std.debug.print("[HTTP] Server error: {}\n", .{err});
                        };
                    }
                };

                var thread = try std.Thread.spawn(.{}, ServerThread.run, .{ServerThread{ .server_ptr = server }});
                thread.detach();
                return;
            }

            std.debug.print("[HTTP] Starting with {d} worker threads\n", .{num_workers});

            const queue = try self.allocator.create(ConnectionQueue);
            queue.* = ConnectionQueue{};
            global_connection_queue = queue;
            global_server_for_workers = server;
            global_server_config = self.server_config;

            var i: u16 = 0;
            while (i < num_workers) : (i += 1) {
                var worker_thread = try std.Thread.spawn(.{}, workerThreadFn, .{});
                worker_thread.detach();
            }

            const AcceptThread = struct {
                fn run() void {
                    const srv = global_server_for_workers orelse return;
                    const q = global_connection_queue orelse return;

                    while (!q.shutdown) {
                        var client_address: net.Address = undefined;
                        var client_address_len: posix.socklen_t = @sizeOf(net.Address);

                        const socket = posix.accept(
                            srv.inner.listener,
                            &client_address.any,
                            &client_address_len,
                            0,
                        ) catch |err| {
                            if (q.shutdown) break;
                            std.debug.print("[HTTP] Accept error: {}\n", .{err});
                            continue;
                        };

                        q.push(socket);
                    }
                }
            };

            var accept_thread = try std.Thread.spawn(.{}, AcceptThread.run, .{});
            accept_thread.detach();
            return;
        }

        return error.ServerNotBuilt;
    }

    fn stopHttpServer(self: *Engine12) !void {
        if (self.http_server != null) {
            std.debug.print("[HTTP] Server shutdown\n", .{});
        }
    }

    fn startBackgroundTasks(self: *Engine12) !void {
        var supervisor = vigil.supervisor(self.allocator);

        var i: usize = 0;
        while (i < self.workers_count) {
            if (self.background_workers[i]) |worker| {
                _ = supervisor.child(worker.name, worker.task) catch |err| {
                    std.debug.print("[ERROR] Failed to start task '{s}': {any}\n", .{ worker.name, err });
                };
            }
            i += 1;
        }

        self.supervisor = supervisor.build();
        try self.supervisor.?.start();
    }

    fn stopBackgroundTasks(self: *Engine12) void {
        if (self.supervisor) |*sup| {
            std.debug.print("[Tasks] Stopping background tasks.\n", .{});
            // Just deinit without waiting for tasks to finish - they'll terminate when process exits
            sup.deinit();
            self.supervisor = null;
        }
    }

    fn startWebSocketManager(self: *Engine12) !void {
        if (self.ws_manager) |*manager| {
            try manager.start();
            std.debug.print("[WebSocket] Started {d} WebSocket server(s)\n", .{self.ws_routes_count});
        }
    }

    fn stopWebSocketManager(self: *Engine12) void {
        if (self.ws_manager) |*manager| {
            manager.stop();
            std.debug.print("[WebSocket] Stopped all WebSocket servers\n", .{});
        }
    }

    fn startHotReloadManager(self: *Engine12) !void {
        if (self.hot_reload_manager) |manager| {
            try manager.start();

            if (self.ws_manager == null) {
                self.ws_manager = try websocket_mod.manager.WebSocketManager.init(self.allocator);
            }

            hot_reload_manager_for_ws = manager;

            script_injector_mod.setHotReloadManager(manager);

            if (self.ws_routes_count < MAX_WS_ROUTES) {
                self.ws_routes[self.ws_routes_count] = types.WebSocketRoute{
                    .path = "/ws/hot-reload",
                    .handler_ptr = hotReloadWebSocketHandler, // Store function pointer value directly
                };
                self.ws_routes_count += 1;

                if (self.ws_manager) |*ws_mgr| {
                    try ws_mgr.registerServer("/ws/hot-reload", hotReloadWebSocketHandler);
                }
            }

            std.debug.print("[HotReload] Started hot reload manager\n", .{});
        }
    }

    fn stopHotReloadManager(self: *Engine12) void {
        if (self.hot_reload_manager) |manager| {
            manager.stop();
            std.debug.print("[HotReload] Stopped hot reload manager\n", .{});
        }
    }

    fn hasRoute(self: *Engine12, path: []const u8) bool {
        var i: usize = 0;
        while (i < self.routes_count) : (i += 1) {
            if (self.http_routes[i]) |route| {
                if (std.mem.eql(u8, route.path, path)) {
                    return true;
                }
            }
        }

        self.runtime_routes.mutex.lock();
        defer self.runtime_routes.mutex.unlock();

        var iterator = self.runtime_routes.routes.iterator();
        while (iterator.next()) |*entry| {
            const route = entry.value_ptr;
            if (std.mem.eql(u8, route.path_pattern, path)) {
                return true;
            }
        }

        return false;
    }

    pub fn printStatus(self: *Engine12) void {
        std.debug.print("\nServer ready\n", .{});
        std.debug.print("  Status: {s} | Health: {s} | Routes: {d} | Tasks: {d}\n", .{
            if (self.is_running) "RUNNING" else "STOPPED",
            @tagName(self.getSystemHealth()),
            self.routes_count,
            self.workers_count,
        });

        var printed_any = false;
        if (self.hasRoute("/")) {
            std.debug.print("\nFrontend: http://{s}:{d}/\n", .{ self.server_config.host, self.server_config.port });
            printed_any = true;
        }
        if (self.hasRoute("/api/todos")) {
            std.debug.print("API: http://{s}:{d}/api/todos\n", .{ self.server_config.host, self.server_config.port });
            printed_any = true;
        }
        if (printed_any) {
            std.debug.print("\n", .{});
        }
    }
};

fn testDummyHandler(_: *Request) Response {
    return Response.ok();
}

fn testDummyTask() void {}

fn testDummyHealthCheck() types.HealthStatus {
    return .healthy;
}

fn testDummyDegradedCheck() types.HealthStatus {
    return .degraded;
}

fn testDummyUnhealthyCheck() types.HealthStatus {
    return .unhealthy;
}

fn testDummyPreRequestMiddleware(_: *ziggurat.request.Request) bool {
    return true;
}

fn testDummyResponseMiddleware(_: ziggurat.response.Response) ziggurat.response.Response {
    return ziggurat.response.Response.json("{}");
}

test "Engine12 initWithProfile" {
    const profile = types.ServerProfile_Development;
    var app = try Engine12.initWithProfile(profile);
    defer app.deinit();
    try std.testing.expectEqual(app.profile.environment, types.Environment.development);
    try std.testing.expect(app.is_running == false);
    try std.testing.expectEqual(app.routes_count, 0);
}

test "Engine12 initDevelopment" {
    var app = try Engine12.initDevelopment();
    defer app.deinit();
    try std.testing.expectEqual(app.profile.environment, types.Environment.development);
}

test "Engine12 initProduction" {
    var app = try Engine12.initProduction();
    defer app.deinit();
    try std.testing.expectEqual(app.profile.environment, types.Environment.production);
}

test "Engine12 initTesting" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try std.testing.expectEqual(app.profile.environment, types.Environment.staging);
}

test "Engine12 runTask registration" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.runTask("test_task", &testDummyTask);
    try std.testing.expectEqual(app.workers_count, 1);
    try std.testing.expect(app.background_workers[0] != null);
    if (app.background_workers[0]) |worker| {
        try std.testing.expectEqualStrings(worker.name, "test_task");
        try std.testing.expect(worker.interval_ms == null);
    }
}

test "Engine12 schedulePeriodicTask registration" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.schedulePeriodicTask("periodic_task", &testDummyTask, 1000);
    try std.testing.expectEqual(app.workers_count, 1);
    try std.testing.expect(app.background_workers[0] != null);
    if (app.background_workers[0]) |worker| {
        try std.testing.expectEqualStrings(worker.name, "periodic_task");
        try std.testing.expect(worker.interval_ms != null);
        try std.testing.expectEqual(worker.interval_ms.?, 1000);
    }
}

test "Engine12 runTask fails when max workers exceeded" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    var i: usize = 0;
    while (i < Engine12.MAX_WORKERS) : (i += 1) {
        try app.runTask("task", &testDummyTask);
    }
    try std.testing.expectError(error.TooManyWorkers, app.runTask("task", &testDummyTask));
}

test "Engine12 registerHealthCheck" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.registerHealthCheck(&testDummyHealthCheck);
    try std.testing.expectEqual(app.health_checks_count, 1);
    try std.testing.expect(app.health_checks[0] != null);
}

test "Engine12 registerHealthCheck fails when max checks exceeded" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    var i: usize = 0;
    while (i < Engine12.MAX_HEALTH_CHECKS) : (i += 1) {
        try app.registerHealthCheck(&testDummyHealthCheck);
    }
    try std.testing.expectError(error.TooManyHealthChecks, app.registerHealthCheck(&testDummyHealthCheck));
}

test "Engine12 getSystemHealth returns healthy when no checks" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try std.testing.expectEqual(app.getSystemHealth(), types.HealthStatus.healthy);
}

test "Engine12 getSystemHealth returns healthy when all checks pass" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.registerHealthCheck(&testDummyHealthCheck);
    try std.testing.expectEqual(app.getSystemHealth(), types.HealthStatus.healthy);
}

test "Engine12 getSystemHealth returns degraded when one check degraded" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.registerHealthCheck(&testDummyHealthCheck);
    try app.registerHealthCheck(&testDummyDegradedCheck);
    try std.testing.expectEqual(app.getSystemHealth(), types.HealthStatus.degraded);
}

test "Engine12 getSystemHealth returns unhealthy when one check unhealthy" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try app.registerHealthCheck(&testDummyHealthCheck);
    try app.registerHealthCheck(&testDummyUnhealthyCheck);
    try std.testing.expectEqual(app.getSystemHealth(), types.HealthStatus.unhealthy);
}

test "Engine12 getUptimeMs returns 0 when not started" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try std.testing.expectEqual(app.getUptimeMs(), 0);
}

test "Engine12 getRequestCount returns 0 initially" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    try std.testing.expectEqual(app.getRequestCount(), 0);
}

test "Engine12 deinit sets is_running to false" {
    var app = try Engine12.initTesting();
    app.is_running = true;
    app.deinit();
    try std.testing.expect(app.is_running == false);
}

test "Engine12 usePreRequestMiddleware sets middleware" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    const mw = struct {
        fn mw(req: *Request) middleware_chain.MiddlewareResult {
            _ = req;
            return .proceed;
        }
    }.mw;
    try app.usePreRequest(mw);
    try std.testing.expect(app.middleware.pre_request_count > 0);
}

test "Engine12 useResponseMiddleware sets middleware" {
    var app = try Engine12.initTesting();
    defer app.deinit();
    const mw = struct {
        fn mw(resp: Response) Response {
            return resp;
        }
    }.mw;
    try app.useResponse(mw);
    try std.testing.expect(app.middleware.response_count > 0);
}

test "Engine12 registerValve" {
    var app = try Engine12.initTesting();
    defer app.deinit();

    const TestValve = struct {
        valve: valve_mod.Valve,
        init_called: bool = false,

        pub fn initFn(v: *valve_mod.Valve, ctx: *valve_registry_mod.context.ValveContext) !void {
            const Self = @This();
            const offset = @offsetOf(Self, "valve");
            const addr = @intFromPtr(v) - offset;
            const self = @as(*Self, @ptrFromInt(addr));
            self.init_called = true;
            _ = ctx;
        }

        pub fn deinitFn(v: *valve_mod.Valve) void {
            _ = v;
        }
    };

    var test_valve = TestValve{
        .valve = valve_mod.Valve{
            .metadata = valve_mod.ValveMetadata{
                .name = "test",
                .version = "1.0.0",
                .description = "Test",
                .author = "Test",
                .required_capabilities = &[_]valve_mod.ValveCapability{},
            },
            .init = &TestValve.initFn,
            .deinit = &TestValve.deinitFn,
        },
    };

    try app.registerValve(&test_valve.valve);
    try std.testing.expect(test_valve.init_called);
    try std.testing.expect(app.valve_registry != null);
}

var static_file_registry: [4]?fileserver.FileServer = [_]?fileserver.FileServer{null} ** 4;
var static_file_registry_count: usize = 0;
var static_mount_paths: [4][]const u8 = [1][]const u8{""} ** 4;

fn createStaticFileWrapperForPath(comptime mount_path: []const u8, comptime route_path: []const u8) fn (*ziggurat.request.Request) ziggurat.response.Response {
    return struct {
        const mount = mount_path;
        const route = route_path;

        fn wrapper(request: *ziggurat.request.Request) ziggurat.response.Response {
            _ = request;

            var i: usize = 0;
            while (i < static_file_registry_count) {
                if (static_file_registry[i]) |*fs| {
                    if (std.mem.eql(u8, static_mount_paths[i], mount)) {
                        return fs.serveFile(route).toZiggurat();
                    }
                }
                i += 1;
            }
            return Response.text("Static file server not found").toZiggurat();
        }
    }.wrapper;
}

fn staticFileHandler(request: *ziggurat.request.Request) ziggurat.response.Response {
    _ = request;
    var i: usize = 0;
    while (i < static_file_registry_count) {
        if (static_file_registry[i]) |*fs| {
            return fs.serveFile("/").toZiggurat();
        }
        i += 1;
    }
    return Response.text("Static file server not found").toZiggurat();
}
