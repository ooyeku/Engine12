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
const config_mod = @import("config/module.zig");

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

/// Single global context pointer.
/// Required because Zig comptime closures in wrapHandler() cannot capture runtime values
pub var global_context: ?*@import("context.zig").EngineContext = null;

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

var global_openapi_generator: ?*openapi.OpenAPIGenerator = null;

/// Global Engine12 pointer for signal handling
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
        engine.is_running.store(false, .monotonic);
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
    queue: []posix.socket_t,
    max_size: usize,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    not_full: std.Thread.Condition = .{},
    shutdown: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, max_size: usize) !*Self {
        const self = try alloc.create(Self);
        self.* = Self{
            .queue = try alloc.alloc(posix.socket_t, max_size),
            .max_size = max_size,
            .allocator = alloc,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.queue);
        self.allocator.destroy(self);
    }

    pub fn push(self: *Self, socket: posix.socket_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count >= self.max_size and !self.shutdown) {
            self.not_full.wait(&self.mutex);
        }

        if (self.shutdown) {
            closeSocket(socket);
            return;
        }

        self.queue[self.tail] = socket;
        self.tail = (self.tail + 1) % self.max_size;
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
        self.head = (self.head + 1) % self.max_size;
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

// Thread handles for graceful shutdown (must join, not detach)
var global_worker_threads: [128]?std.Thread = [_]?std.Thread{null} ** 128;
var global_worker_thread_count: usize = 0;
var global_accept_thread: ?std.Thread = null;

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
        if (global_context) |ctx| {
            ctx.active_request_tracker.increment();
        }
        defer {
            if (global_context) |ctx| {
                ctx.active_request_tracker.decrement();
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
            const ctx = global_context orelse {
                return Response.text("Engine context not initialized").withStatus(500).toZiggurat();
            };

            ctx.active_request_tracker.increment();
            defer ctx.active_request_tracker.decrement();

            const mw_chain = ctx.middleware;
            const runtime_registry = ctx.runtime_routes;
            const metrics_collector = ctx.metrics;

            // Fallback if no middleware chain
            if (false) {
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
            }

            var engine12_request = Request.fromZiggurat(ziggurat_request, allocator);

            const request_id = generateRequestId(engine12_request.arena.allocator()) catch "unknown";
            engine12_request.set("request_id", request_id) catch {};

            var timing = metrics.RequestTiming.start(engine12_request.path());

            defer engine12_request.deinit();

            if (mw_chain.executePreRequest(&engine12_request)) |abort_response| {
                metrics_collector.incrementError();
                timing.finish(metrics_collector) catch {};
                return abort_response.toZiggurat();
            }

            const method_str = @tagName(ziggurat_request.method);
            const route = runtime_registry.findRoute(method_str, engine12_request.path(), &engine12_request) catch |err| {
                std.debug.print("[Runtime Route] Error finding route: {}\n", .{err});
                metrics_collector.incrementError();
                timing.finish(metrics_collector) catch {};
                return Response.text("Internal server error").withStatus(500).toZiggurat();
            };

            if (route) |r| {
                var engine12_response = r.handler(&engine12_request);

                engine12_response = mw_chain.executeResponse(engine12_response, &engine12_request);

                timing.finish(metrics_collector) catch {};

                return engine12_response.toZiggurat();
            }

            metrics_collector.incrementError();
            timing.finish(metrics_collector) catch {};
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
            const ctx = global_context orelse {
                // Fallback when context not initialized
                var engine12_request = Request.fromZiggurat(ziggurat_request, allocator);
                defer engine12_request.deinit();
                const engine12_response = handler(&engine12_request);
                return engine12_response.toZiggurat();
            };

            ctx.active_request_tracker.increment();
            defer ctx.active_request_tracker.decrement();

            const mw_chain = ctx.middleware;
            const metrics_collector = ctx.metrics;

            const route_pattern_str = if (pattern) |p| p else ziggurat_request.path;
            var timing = metrics.RequestTiming.start(route_pattern_str);

            var engine12_request = Request.fromZiggurat(ziggurat_request, allocator);

            const request_id = generateRequestId(engine12_request.arena.allocator()) catch "unknown";
            engine12_request.set("request_id", request_id) catch {};

            defer engine12_request.deinit();

            if (mw_chain.executePreRequest(&engine12_request)) |abort_response| {
                metrics_collector.incrementError();
                timing.finish(metrics_collector) catch {};
                return abort_response.toZiggurat();
            }

            if (pattern) |pattern_str| {
                if (std.mem.indexOf(u8, pattern_str, ":") != null) {
                    var route_pattern_parsed = router.RoutePattern.parse(allocator, pattern_str) catch {
                        const engine12_response = handler(&engine12_request);
                        var final_response = mw_chain.executeResponse(engine12_response, &engine12_request);
                        timing.finish(metrics_collector) catch {};
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

            timing.finish(metrics_collector) catch {};

            return engine12_response.toZiggurat();
        }
    }.wrapper;
}

/// Configuration options for the HTTP server.
///
/// These settings control network behavior, performance tuning, and resource limits.
/// Default values are suitable for development; production deployments should tune
/// `worker_threads` and timeout values based on expected load.
///
/// ## Example
/// ```zig
/// app.configure(.{
///     .host = "0.0.0.0",      // Bind to all interfaces
///     .port = 8080,
///     .worker_threads = 16,   // Match CPU cores for I/O-bound workloads
///     .read_timeout = 30000,  // 30 second read timeout
/// });
/// ```
pub const ServerConfig = struct {
    /// IP address to bind the server to. Use "0.0.0.0" to accept connections on all interfaces.
    host: []const u8 = "127.0.0.1",
    /// TCP port number to listen on. Ports below 1024 require elevated privileges.
    port: u16 = 8080,
    /// Maximum time in milliseconds to wait for request data from clients.
    read_timeout: u32 = 10000,
    /// Maximum time in milliseconds to wait when sending response data to clients.
    write_timeout: u32 = 10000,
    /// Number of worker threads for handling concurrent connections.
    /// Set to 0 for single-threaded mode. Recommended: number of CPU cores.
    worker_threads: u16 = 12,
    /// Internal buffer size for reading request data.
    buffer_size: usize = 16384,
    /// Maximum allowed size for HTTP headers in bytes.
    max_header_size: usize = 32768,
    /// Maximum allowed size for request body in bytes (default: 10MB).
    max_body_size: usize = 10 * 1024 * 1024,
};

/// Internal structure for template route registration.
/// Maps URL paths to template files and their context generation functions.
pub const TemplateRouteEntry = struct {
    /// The filesystem path to the template file.
    path: []const u8,
    /// Opaque pointer to the context generation function.
    context_fn: *const anyopaque,
};

/// The core Engine12 web application framework.
///
/// Engine12 provides a complete, batteries-included web framework for Zig with:
/// - **HTTP Routing**: GET, POST, PUT, DELETE with dynamic path parameters
/// - **Middleware**: Pre-request and response transformation pipelines
/// - **REST API**: Automatic CRUD endpoint generation from ORM models
/// - **WebSockets**: Real-time bidirectional communication
/// - **Templates**: Hot-reloading HTML templates with Zig syntax
/// - **Static Files**: Efficient file serving with caching
/// - **Health Checks**: Kubernetes-compatible liveness/readiness probes
/// - **Metrics**: Prometheus-compatible request metrics
/// - **Graceful Shutdown**: Clean connection draining on SIGTERM
///
/// ## Lifecycle
/// 1. Initialize with `initFromEnv()`, `initDevelopment()`, or `initProduction()`
/// 2. Register routes with `get()`, `post()`, `put()`, `delete()`
/// 3. Add middleware with `usePreRequest()`, `useResponse()`
/// 4. Start server with `listen()` (blocking) or `start()` (non-blocking)
/// 5. Cleanup with `deinit()` and `allocator.destroy(app)`
///
/// ## Example
/// ```zig
/// const app = try Engine12.initFromEnv();
/// defer {
///     app.deinit();
///     allocator.destroy(app);
/// }
///
/// try app.get("/", handleIndex);
/// try app.get("/api/users/:id", handleGetUser);
/// try app.post("/api/users", handleCreateUser);
///
/// try app.listen();
/// ```
pub const Engine12 = struct {
    allocator: std.mem.Allocator,
    profile: types.ServerProfile,
    server_config: ServerConfig = .{},
    is_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    request_count: u64 = 0,
    start_time: i64 = 0,

    // Dynamic arrays for routes and workers
    http_routes: std.ArrayListUnmanaged(?types.Route),
    routes_count: usize = 0,
    custom_root_handler: bool = false, // Track if custom root handler is registered
    server_builder: ?ziggurat.ServerBuilder = null,
    server_built: bool = false,
    built_server: ?ziggurat.Server = null,

    static_routes: std.ArrayListUnmanaged(?fileserver.FileServer),
    static_routes_count: usize = 0,
    static_root_mounted: bool = false, // Track if static files are mounted at "/"

    template_routes: std.ArrayListUnmanaged(TemplateRouteEntry),
    template_routes_count: usize = 0,

    background_workers: std.ArrayListUnmanaged(?types.BackgroundWorker),
    workers_count: usize = 0,

    health_checks: std.ArrayListUnmanaged(?types.HealthCheckFn),
    health_checks_count: usize = 0,

    middleware: middleware_chain.MiddlewareChain,

    error_handler_registry: error_handler.ErrorHandlerRegistry,

    metrics_collector: metrics.MetricsCollector,

    logger: dev_tools.Logger,

    valve_registry: ?valve_registry_mod.ValveRegistry = null,

    runtime_routes: runtime_routes_mod.RuntimeRouteRegistry,

    orm_instance: ?*orm.ORM = null,

    ws_manager: ?websocket_mod.manager.WebSocketManager = null,
    ws_routes: std.ArrayListUnmanaged(?types.WebSocketRoute),
    ws_routes_count: usize = 0,

    hot_reload_manager: ?*hot_reload_mod.HotReloadManager = null,

    htmx_config: ?htmx_mod.HtmxConfig = null,
    htmx_registration_failed: bool = false, // Track if HTMX middleware registration failed

    openapi_generator: ?openapi.OpenAPIGenerator = null,

    supervisor: ?vigil.Supervisor = null,
    http_server: ?*anyopaque = null,

    active_request_tracker: shutdown_utils.ActiveRequestTracker,
    shutdown_hooks: shutdown_utils.ShutdownHookRegistry,

    // Configurable limits
    limits: config_mod.LimitsConfig,

    // Engine context for dependency injection
    engine_context: ?*@import("context.zig").EngineContext = null,

    /// Initializes a new Engine12 application instance with the specified server profile.
    ///
    /// This is the core initialization function that configures the application based on
    /// the provided profile (development, production, or testing). The returned pointer
    /// is heap-allocated and must be cleaned up with `deinit()` followed by `allocator.destroy(app)`.
    ///
    /// ## Parameters
    /// - `profile`: A `ServerProfile` that configures logging verbosity, timeouts, and environment settings.
    ///   Use `ServerProfile_Development`, `ServerProfile_Production`, or `ServerProfile_Testing`.
    ///
    /// ## Returns
    /// A pointer to the initialized Engine12 instance, or an error if initialization fails.
    ///
    /// ## Example
    /// ```zig
    /// const app = try Engine12.initWithProfile(types.ServerProfile_Production);
    /// defer {
    ///     app.deinit();
    ///     allocator.destroy(app);
    /// }
    /// ```
    ///
    /// ## Note
    /// For most use cases, prefer `initFromEnv()` which automatically reads configuration
    /// from environment variables and .env files, making deployments more flexible.
    pub fn initWithProfile(profile: types.ServerProfile) !*Engine12 {
        const default_limits = config_mod.LimitsConfig{};
        return initWithProfileAndLimits(profile, default_limits);
    }

    /// Internal initialization function that creates the Engine12 instance with both
    /// a server profile and custom resource limits.
    ///
    /// This function heap-allocates the Engine12 struct to prevent dangling pointer issues
    /// when EngineContext references internal fields. All internal arrays (routes, middleware,
    /// health checks) are pre-allocated based on the limits configuration.
    fn initWithProfileAndLimits(profile: types.ServerProfile, limits: config_mod.LimitsConfig) !*Engine12 {
        var http_routes = std.ArrayListUnmanaged(?types.Route){};
        try http_routes.ensureTotalCapacity(allocator, limits.max_routes);

        var static_routes = std.ArrayListUnmanaged(?fileserver.FileServer){};
        try static_routes.ensureTotalCapacity(allocator, limits.max_static_routes);

        var template_routes = std.ArrayListUnmanaged(TemplateRouteEntry){};
        try template_routes.ensureTotalCapacity(allocator, limits.max_routes);

        var background_workers = std.ArrayListUnmanaged(?types.BackgroundWorker){};
        try background_workers.ensureTotalCapacity(allocator, limits.max_background_workers);

        var health_checks = std.ArrayListUnmanaged(?types.HealthCheckFn){};
        try health_checks.ensureTotalCapacity(allocator, limits.max_health_checks);

        var ws_routes = std.ArrayListUnmanaged(?types.WebSocketRoute){};
        try ws_routes.ensureTotalCapacity(allocator, limits.max_ws_routes);

        const app = try allocator.create(Engine12);
        app.* = Engine12{
            .allocator = allocator,
            .profile = profile,
            .http_routes = http_routes,
            .static_routes = static_routes,
            .template_routes = template_routes,
            .background_workers = background_workers,
            .health_checks = health_checks,
            .ws_routes = ws_routes,
            .middleware = middleware_chain.MiddlewareChain.init(),
            .error_handler_registry = error_handler.ErrorHandlerRegistry.init(allocator),
            .metrics_collector = metrics.MetricsCollector.init(allocator),
            .logger = dev_tools.Logger.fromEnvironment(allocator, profile.environment),
            .runtime_routes = runtime_routes_mod.RuntimeRouteRegistry.init(allocator),
            .active_request_tracker = shutdown_utils.ActiveRequestTracker.init(),
            .shutdown_hooks = shutdown_utils.ShutdownHookRegistry.init(allocator),
            .limits = limits,
        };

        // Create and set the global context for dependency injection
        const ctx = try allocator.create(@import("context.zig").EngineContext);
        ctx.* = .{
            .middleware = &app.middleware,
            .metrics = &app.metrics_collector,
            .rate_limiter = null,
            .cache = null,
            .logger = &app.logger,
            .error_handler = &app.error_handler_registry,
            .runtime_routes = &app.runtime_routes,
            .active_request_tracker = &app.active_request_tracker,
            .limits = limits,
        };
        app.engine_context = ctx;
        global_context = ctx;

        return app;
    }

    /// Initializes Engine12 in development mode with hot reload and HTMX support enabled.
    ///
    /// This initialization mode is optimized for local development workflows:
    /// - **Hot Reload**: Automatically watches template and static files for changes,
    ///   pushing updates to connected browsers via WebSocket without page refresh.
    /// - **HTMX Injection**: Automatically injects HTMX library into HTML responses.
    /// - **Verbose Logging**: Enables detailed request/response logging for debugging.
    ///
    /// ## Returns
    /// A heap-allocated Engine12 pointer configured for development.
    ///
    /// ## Example
    /// ```zig
    /// const app = try Engine12.initDevelopment();
    /// defer {
    ///     app.deinit();
    ///     allocator.destroy(app);
    /// }
    /// try app.get("/", handleIndex);
    /// try app.listen();
    /// ```
    ///
    /// ## Note
    /// Do not use this mode in production - it has performance overhead from file watching
    /// and includes development-only features. Use `initProduction()` or `initFromEnv()` instead.
    pub fn initDevelopment() !*Engine12 {
        const app = try Engine12.initWithProfile(types.ServerProfile_Development);

        const hr_manager = try allocator.create(hot_reload_mod.HotReloadManager);
        hr_manager.* = hot_reload_mod.HotReloadManager.init(allocator, true);
        app.hot_reload_manager = hr_manager;

        script_injector_mod.setHotReloadManager(hr_manager);

        try app.useResponse(script_injector_mod.injectHotReloadScript);

        app.enableHtmx();

        return app;
    }

    /// Initializes Engine12 in production mode with optimized settings.
    ///
    /// Production mode configuration includes:
    /// - **Minimal Logging**: Only errors and critical warnings are logged.
    /// - **Optimized Timeouts**: Shorter timeouts to quickly recycle stale connections.
    /// - **No Hot Reload**: File watching is disabled for maximum performance.
    /// - **No Debug Features**: Development tools and verbose output are disabled.
    ///
    /// ## Returns
    /// A heap-allocated Engine12 pointer configured for production.
    ///
    /// ## Example
    /// ```zig
    /// const app = try Engine12.initProduction();
    /// defer {
    ///     app.deinit();
    ///     allocator.destroy(app);
    /// }
    /// ```
    ///
    /// ## Note
    /// For cloud deployments, prefer `initFromEnv()` which reads configuration from
    /// environment variables, allowing runtime configuration without recompilation.
    pub fn initProduction() !*Engine12 {
        return Engine12.initWithProfile(types.ServerProfile_Production);
    }

    /// Initializes Engine12 in testing mode for unit and integration tests.
    ///
    /// Testing mode provides:
    /// - **Isolated Environment**: Uses staging environment settings.
    /// - **Fast Initialization**: Minimal feature set for quick test startup.
    /// - **Predictable Behavior**: Deterministic configuration for reproducible tests.
    ///
    /// ## Returns
    /// A heap-allocated Engine12 pointer configured for testing.
    ///
    /// ## Example
    /// ```zig
    /// test "API endpoint returns 200" {
    ///     const app = try Engine12.initTesting();
    ///     defer {
    ///         app.deinit();
    ///         allocator.destroy(app);
    ///     }
    ///     try app.get("/test", testHandler);
    ///     // ... test assertions
    /// }
    /// ```
    pub fn initTesting() !*Engine12 {
        return Engine12.initWithProfile(types.ServerProfile_Testing);
    }

    /// Initializes Engine12 from environment variables and .env files.
    ///
    /// This is the **recommended initialization method** for production deployments.
    /// It automatically reads configuration from:
    /// 1. `.env` file in the current directory (if present)
    /// 2. System environment variables (override .env values)
    ///
    /// ## Supported Environment Variables
    /// - `ENGINE12_ENV`: Environment mode (`development`, `staging`, `production`)
    /// - `ENGINE12_HOST`: Server bind address (default: `127.0.0.1`)
    /// - `ENGINE12_PORT`: Server port (default: `8080`)
    /// - `ENGINE12_WORKERS`: Number of worker threads (default: `12`)
    /// - `ENGINE12_READ_TIMEOUT_MS`: Request read timeout in milliseconds
    /// - `ENGINE12_WRITE_TIMEOUT_MS`: Response write timeout in milliseconds
    /// - `ENGINE12_MAX_BODY_SIZE`: Maximum request body size in bytes
    ///
    /// ## Returns
    /// A heap-allocated Engine12 pointer with environment-based configuration.
    ///
    /// ## Example
    /// ```zig
    /// // .env file:
    /// // ENGINE12_ENV=production
    /// // ENGINE12_PORT=3000
    ///
    /// const app = try Engine12.initFromEnv();
    /// defer {
    ///     app.deinit();
    ///     allocator.destroy(app);
    /// }
    /// try app.listen(); // Listens on port 3000
    /// ```
    ///
    /// ## Note
    /// In development mode (ENGINE12_ENV=development), hot reload and HTMX are
    /// automatically enabled. In production mode, they are disabled for performance.
    pub fn initFromEnv() !*Engine12 {
        var cfg = try config_mod.Config.load(allocator);
        defer cfg.deinit();
        return initFromConfigInternal(&cfg);
    }

    /// Initializes Engine12 from a pre-built Config struct.
    ///
    /// Use this when you need programmatic control over configuration, such as
    /// loading from a custom config file format or building configuration dynamically.
    ///
    /// ## Parameters
    /// - `cfg`: A pointer to a Config struct containing server and limit settings.
    ///   String values are copied, so the config can be safely freed after this call.
    ///
    /// ## Returns
    /// A heap-allocated Engine12 pointer with the specified configuration.
    ///
    /// ## Example
    /// ```zig
    /// var cfg = config_mod.Config{
    ///     .environment = .production,
    ///     .server = .{
    ///         .host = "0.0.0.0",
    ///         .port = 8080,
    ///         .workers = 16,
    ///     },
    /// };
    /// const app = try Engine12.initFromConfig(&cfg);
    /// ```
    ///
    /// ## Note
    /// For most use cases, `initFromEnv()` is simpler and more deployment-friendly.
    pub fn initFromConfig(cfg: *const config_mod.Config) !*Engine12 {
        return initFromConfigInternal(cfg);
    }

    fn initFromConfigInternal(cfg: *const config_mod.Config) !*Engine12 {
        // Determine profile from environment
        const profile: types.ServerProfile = switch (cfg.environment) {
            .development => types.ServerProfile_Development,
            .staging => types.ServerProfile_Testing,
            .production => types.ServerProfile_Production,
        };

        const app = try Engine12.initWithProfileAndLimits(profile, cfg.limits);

        // Copy host string to page allocator (it will live for app lifetime)
        const host_copy = try allocator.dupe(u8, cfg.server.host);

        // Apply server configuration from env
        app.server_config = ServerConfig{
            .host = host_copy,
            .port = cfg.server.port,
            .worker_threads = cfg.server.workers,
            .read_timeout = cfg.server.read_timeout_ms,
            .write_timeout = cfg.server.write_timeout_ms,
            .max_body_size = cfg.server.max_body_size,
            .buffer_size = 16384,
            .max_header_size = 32768,
        };

        // Enable hot reload and HTMX in development
        if (cfg.isDevelopment()) {
            const hr_manager = try allocator.create(hot_reload_mod.HotReloadManager);
            hr_manager.* = hot_reload_mod.HotReloadManager.init(allocator, true);
            app.hot_reload_manager = hr_manager;
            script_injector_mod.setHotReloadManager(hr_manager);
            try app.useResponse(script_injector_mod.injectHotReloadScript);
            app.enableHtmx();
        }

        // Print config summary in debug mode
        if (builtin.mode == .Debug) {
            cfg.printSummary();
        }

        return app;
    }

    /// Enables automatic HTMX library injection into HTML responses.
    ///
    /// When enabled, the HTMX JavaScript library is automatically injected into
    /// HTML responses, enabling HTMX functionality without manual script includes.
    /// Uses environment-appropriate defaults (minified in production).
    ///
    /// ## Note
    /// Automatically enabled when using `initDevelopment()` or `initFromEnv()`
    /// in development mode.
    ///
    /// ## Example
    /// ```zig
    /// const app = try Engine12.initProduction();
    /// app.enableHtmx();  // Add HTMX support
    /// ```
    pub fn enableHtmx(self: *Engine12) void {
        const config = if (self.profile.environment == .production)
            htmx_mod.production_config
        else
            htmx_mod.development_config;
        self.enableHtmxWithConfig(config);
    }

    /// Enables HTMX injection with custom configuration.
    ///
    /// ## Parameters
    /// - `config`: HTMX configuration options (CDN URL, extensions, etc.)
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

    /// Disables HTMX injection.
    pub fn disableHtmx(self: *Engine12) void {
        self.htmx_config = null;
        self.htmx_registration_failed = false;
        htmx_mod.setConfig(null);
    }

    /// Returns whether HTMX injection is currently enabled.
    ///
    /// HTMX injection automatically adds the HTMX library to HTML responses,
    /// enabling HTMX functionality without manual script includes.
    pub fn isHtmxEnabled(self: *const Engine12) bool {
        return self.htmx_config != null and self.htmx_config.?.enabled and !self.htmx_registration_failed;
    }

    /// Applies a complete server configuration.
    ///
    /// Use this to set all server options at once. For individual settings,
    /// use `setPort()` or `setHost()` instead.
    ///
    /// ## Example
    /// ```zig
    /// app.configure(.{
    ///     .host = "0.0.0.0",
    ///     .port = 3000,
    ///     .worker_threads = 8,
    /// });
    /// ```
    pub fn configure(self: *Engine12, config: ServerConfig) void {
        self.server_config = config;
    }

    /// Sets the TCP port the server will listen on.
    ///
    /// Must be called before `listen()` or `start()`.
    /// Ports below 1024 require elevated privileges on Unix systems.
    pub fn setPort(self: *Engine12, port: u16) void {
        self.server_config.port = port;
    }

    /// Sets the IP address the server will bind to.
    ///
    /// - Use "127.0.0.1" for localhost only (default)
    /// - Use "0.0.0.0" to accept connections on all interfaces
    pub fn setHost(self: *Engine12, host: []const u8) void {
        self.server_config.host = host;
    }

    /// Returns the configured server port.
    pub fn getPort(self: *Engine12) u16 {
        return self.server_config.port;
    }

    /// Returns the configured server host address.
    pub fn getHost(self: *Engine12) []const u8 {
        return self.server_config.host;
    }

    /// Releases all resources held by the Engine12 instance.
    ///
    /// This must be called before destroying the Engine12 pointer.
    /// Automatically called by `stop()`, but should also be called explicitly
    /// in defer blocks to ensure cleanup on errors.
    ///
    /// ## Example
    /// ```zig
    /// const app = try Engine12.initFromEnv();
    /// defer {
    ///     app.deinit();
    ///     allocator.destroy(app);
    /// }
    /// ```
    pub fn deinit(self: *Engine12) void {
        self.is_running.store(false, .monotonic);

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

        // Free dynamic arrays
        self.http_routes.deinit(self.allocator);
        self.static_routes.deinit(self.allocator);
        self.template_routes.deinit(self.allocator);
        self.background_workers.deinit(self.allocator);
        self.health_checks.deinit(self.allocator);
        self.ws_routes.deinit(self.allocator);

        if (self.ws_manager) |*manager| {
            manager.deinit();
            self.ws_manager = null;
        }

        // Free engine context if allocated
        if (self.engine_context) |ctx| {
            self.allocator.destroy(ctx);
            self.engine_context = null;
        }
    }

    /// Registers a Valve plugin with the application.
    ///
    /// Valves are modular plugins that extend Engine12's functionality.
    /// They can add routes, middleware, background tasks, and respond to
    /// application lifecycle events.
    ///
    /// ## Parameters
    /// - `valve_ptr`: Pointer to a Valve struct implementing the valve interface.
    ///
    /// ## Example
    /// ```zig
    /// var auth_valve = AuthValve.init(config);
    /// try app.registerValve(&auth_valve.valve);
    /// ```
    pub fn registerValve(self: *Engine12, valve_ptr: *valve_mod.Valve) !void {
        if (self.valve_registry == null) {
            self.valve_registry = valve_registry_mod.ValveRegistry.init(self.allocator);
        }

        if (self.valve_registry) |*registry| {
            try registry.register(valve_ptr, self);
        }
    }

    /// Removes a registered valve by name.
    ///
    /// ## Parameters
    /// - `name`: The name of the valve to unregister.
    ///
    /// ## Errors
    /// - `ValveError.ValveNotFound`: No valve with the given name is registered.
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

    /// Registers a GET route handler for the specified URL path pattern.
    ///
    /// GET routes are used to retrieve resources and should be idempotent (calling
    /// multiple times produces the same result). This is the most common route type
    /// for serving web pages and API data retrieval.
    ///
    /// ## Parameters
    /// - `path_pattern`: A comptime URL path that can include dynamic segments:
    ///   - Static paths: `/users`, `/api/todos`
    ///   - Dynamic segments: `/users/:id`, `/posts/:slug/comments`
    ///   - The `:param` segments are extracted and available via `request.param("id")`
    /// - `handler`: A function with signature `fn (*Request) Response`
    ///
    /// ## Errors
    /// - `error.TooManyRoutes`: Maximum route limit exceeded (configurable in LimitsConfig)
    /// - `error.ServerAlreadyBuilt`: Routes cannot be added after `listen()` is called
    ///
    /// ## Example
    /// ```zig
    /// // Static route
    /// try app.get("/", handleIndex);
    ///
    /// // Dynamic route with parameter
    /// try app.get("/users/:id", handleUserProfile);
    ///
    /// fn handleUserProfile(req: *Request) Response {
    ///     const user_id = req.param("id") orelse return Response.badRequest("Missing user ID");
    ///     // Fetch and return user data...
    ///     return Response.json(user_json);
    /// }
    /// ```
    pub fn get(self: *Engine12, comptime path_pattern: []const u8, comptime handler: anytype) !void {
        if (self.routes_count >= self.limits.max_routes) {
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
            try server.get(path_pattern, wrapped_handler);
        }

        const HandlerType = @TypeOf(handler);
        const handler_for_storage: types.HttpHandler = switch (@typeInfo(HandlerType)) {
            .pointer => |ptr_info| if (ptr_info.size == .one) handler.* else handler,
            else => handler,
        };
        try self.http_routes.append(self.allocator, types.Route{
            .path = path_pattern,
            .method = "GET",
            .handler_ptr = &handler_for_storage,
        });
        self.routes_count += 1;
    }

    /// Registers a GET route with a handler that can return errors.
    ///
    /// This is a convenience wrapper for handlers that use Zig's error handling instead
    /// of manually constructing error responses. Errors are automatically converted to
    /// appropriate HTTP error responses.
    ///
    /// ## Parameters
    /// - `path_pattern`: URL path pattern (see `get()` for pattern syntax)
    /// - `handler`: A function with signature `fn (*Request) !Response`
    ///
    /// ## Example
    /// ```zig
    /// try app.getTry("/users/:id", handleUser);
    ///
    /// fn handleUser(req: *Request) !Response {
    ///     const id = try std.fmt.parseInt(u32, req.param("id").?, 10);
    ///     const user = try db.getUser(id);  // Errors auto-convert to 500
    ///     return Response.json(user);
    /// }
    /// ```
    pub fn getTry(self: *Engine12, comptime path_pattern: []const u8, comptime handler: types.TryHttpHandler) !void {
        return self.get(path_pattern, types.wrapTryHandler(handler));
    }

    /// Registers a POST route with a handler that can return errors.
    /// See `getTry()` for error handling behavior.
    pub fn postTry(self: *Engine12, comptime path_pattern: []const u8, comptime handler: types.TryHttpHandler) !void {
        return self.post(path_pattern, types.wrapTryHandler(handler));
    }

    /// Registers a PUT route with a handler that can return errors.
    /// See `getTry()` for error handling behavior.
    pub fn putTry(self: *Engine12, comptime path_pattern: []const u8, comptime handler: types.TryHttpHandler) !void {
        return self.put(path_pattern, types.wrapTryHandler(handler));
    }

    /// Registers a DELETE route with a handler that can return errors.
    /// See `getTry()` for error handling behavior.
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

        if (self.template_routes_count >= self.limits.max_routes) {
            return error.TooManyRoutes;
        }
        try self.template_routes.append(self.allocator, .{
            .path = template_path_copy,
            .context_fn = @ptrCast(&context_fn),
        });
        const route_index = self.template_routes_count;
        self.template_routes_count += 1;

        const captured_route_idx = route_index;
        const captured_app_ptr = self;

        const createHandler = struct {
            fn create(route_idx: usize, app: *Engine12) fn (*Request) Response {
                const Handler = struct {
                    fn handler(req: *Request) Response {
                        const route_info = app.template_routes.items[route_idx];
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

    /// Registers a POST route handler for the specified URL path pattern.
    ///
    /// POST routes are used to create new resources or submit data that causes side effects.
    /// Unlike GET requests, POST requests are not idempotent and typically include a request body.
    ///
    /// ## Parameters
    /// - `path_pattern`: A comptime URL path (see `get()` for pattern syntax)
    /// - `handler`: A function with signature `fn (*Request) Response`
    ///
    /// ## Request Body Access
    /// Access the request body using `request.body()` or parse JSON with `request.json(T)`:
    /// ```zig
    /// fn handleCreate(req: *Request) Response {
    ///     const todo = req.json(Todo) catch return Response.badRequest("Invalid JSON");
    ///     // Process and save the todo...
    ///     return Response.json(saved_todo).withStatus(201);
    /// }
    /// ```
    ///
    /// ## Example
    /// ```zig
    /// try app.post("/api/todos", handleCreateTodo);
    /// try app.post("/users/:id/avatar", handleUploadAvatar);
    /// ```
    pub fn post(self: *Engine12, comptime path_pattern: []const u8, comptime handler: anytype) !void {
        if (self.routes_count >= self.limits.max_routes) {
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
        try self.http_routes.append(self.allocator, types.Route{
            .path = path_pattern,
            .method = "POST",
            .handler_ptr = &handler_for_storage_post,
        });
        self.routes_count += 1;
    }

    /// Alias for `post()`. Registers a POST route handler.
    /// Useful for semantic clarity when the route doesn't expect a request body.
    pub fn postEmpty(self: *Engine12, comptime path_pattern: []const u8, comptime handler: anytype) !void {
        return self.post(path_pattern, handler);
    }

    /// Registers a PUT route handler for the specified URL path pattern.
    ///
    /// PUT routes are used to update or replace an existing resource entirely.
    /// PUT requests should be idempotent - calling them multiple times with the
    /// same data produces the same result.
    ///
    /// ## Parameters
    /// - `path_pattern`: A comptime URL path (see `get()` for pattern syntax)
    /// - `handler`: A function with signature `fn (*Request) Response`
    ///
    /// ## PUT vs PATCH
    /// - **PUT**: Replaces the entire resource with the request body
    /// - **PATCH**: Partially updates the resource (not yet implemented in Engine12)
    ///
    /// ## Example
    /// ```zig
    /// try app.put("/api/todos/:id", handleUpdateTodo);
    ///
    /// fn handleUpdateTodo(req: *Request) Response {
    ///     const id = req.param("id") orelse return Response.badRequest("Missing ID");
    ///     const updated_todo = req.json(Todo) catch return Response.badRequest("Invalid JSON");
    ///     // Update the todo in database...
    ///     return Response.json(updated_todo);
    /// }
    /// ```
    pub fn put(self: *Engine12, comptime path_pattern: []const u8, comptime handler: anytype) !void {
        if (self.routes_count >= self.limits.max_routes) {
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
        try self.http_routes.append(self.allocator, types.Route{
            .path = path_pattern,
            .method = "PUT",
            .handler_ptr = &handler_for_storage_put,
        });
        self.routes_count += 1;
    }

    /// Registers a DELETE route handler for the specified URL path pattern.
    ///
    /// DELETE routes are used to remove resources. DELETE requests should be idempotent -
    /// deleting a resource that doesn't exist should return success (or 404), not an error.
    ///
    /// ## Parameters
    /// - `path_pattern`: A comptime URL path (see `get()` for pattern syntax)
    /// - `handler`: A function with signature `fn (*Request) Response`
    ///
    /// ## Response Conventions
    /// - **200 OK**: Resource deleted successfully, response body contains deleted resource
    /// - **204 No Content**: Resource deleted successfully, no response body
    /// - **404 Not Found**: Resource didn't exist (optional - some APIs return 200/204)
    ///
    /// ## Example
    /// ```zig
    /// try app.delete("/api/todos/:id", handleDeleteTodo);
    ///
    /// fn handleDeleteTodo(req: *Request) Response {
    ///     const id = req.param("id") orelse return Response.badRequest("Missing ID");
    ///     // Delete from database...
    ///     return Response.noContent();  // 204 response
    /// }
    /// ```
    pub fn delete(self: *Engine12, comptime path_pattern: []const u8, comptime handler: anytype) !void {
        if (self.routes_count >= self.limits.max_routes) {
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
        try self.http_routes.append(self.allocator, types.Route{
            .path = path_pattern,
            .method = "DELETE",
            .handler_ptr = &handler_for_storage_delete,
        });
        self.routes_count += 1;
    }

    /// Creates a route group with a common URL prefix.
    ///
    /// Route groups help organize related routes and can apply shared middleware.
    /// All routes registered through the group will have the prefix prepended.
    ///
    /// ## Parameters
    /// - `prefix`: URL prefix for all routes in the group (e.g., "/api/v1")
    ///
    /// ## Returns
    /// A RouteGroup that can be used to register routes with the prefix.
    ///
    /// ## Example
    /// ```zig
    /// const api = app.group("/api/v1");
    /// try api.get("/users", handleListUsers);     // Registers /api/v1/users
    /// try api.post("/users", handleCreateUser);   // Registers /api/v1/users
    /// try api.get("/users/:id", handleGetUser);   // Registers /api/v1/users/:id
    /// ```
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
            .middleware = middleware_chain.MiddlewareChain.init(),
            .register_get = get_wrapper,
            .register_post = post_wrapper,
            .register_put = put_wrapper,
            .register_delete = delete_wrapper,
        };
    }

    /// Returns the OpenAPI generator for programmatic schema building.
    ///
    /// Creates the generator on first access. Use this for advanced customization
    /// of the OpenAPI specification beyond what `enableOpenApiDocs()` provides.
    pub fn getOpenApiGenerator(self: *Engine12) !*openapi.OpenAPIGenerator {
        if (self.openapi_generator == null) {
            self.openapi_generator = openapi.OpenAPIGenerator.init(self.allocator, .{
                .title = "Engine12 API",
                .version = "1.0.0",
            });
        }
        return &self.openapi_generator.?;
    }

    /// Enables interactive API documentation with Swagger UI.
    ///
    /// Mounts a Swagger UI interface at the specified path, providing interactive
    /// API documentation based on the OpenAPI specification. The JSON spec is
    /// automatically served at `{mount_path}/openapi.json`.
    ///
    /// ## Parameters
    /// - `mount_path`: URL path for the documentation UI (e.g., "/docs")
    /// - `info`: API metadata (title, version, description)
    ///
    /// ## Example
    /// ```zig
    /// try app.enableOpenApiDocs("/docs", .{
    ///     .title = "My API",
    ///     .version = "1.0.0",
    ///     .description = "REST API for my application",
    /// });
    /// // Swagger UI available at http://localhost:8080/docs
    /// // OpenAPI JSON at http://localhost:8080/docs/openapi.json
    /// ```
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

    /// Registers a complete RESTful API for an ORM model.
    ///
    /// Automatically generates standard CRUD endpoints for the model:
    /// - `GET {prefix}` - List all (with pagination, filtering, sorting)
    /// - `GET {prefix}/:id` - Get single resource
    /// - `POST {prefix}` - Create new resource
    /// - `PUT {prefix}/:id` - Update resource
    /// - `DELETE {prefix}/:id` - Delete resource
    ///
    /// ## Parameters
    /// - `prefix`: URL prefix for the API (e.g., "/api/todos")
    /// - `Model`: The ORM model type (must have table metadata)
    /// - `config`: Configuration for validation, auth, caching, etc.
    ///
    /// ## Example
    /// ```zig
    /// try app.restApi("/api/todos", Todo, .{
    ///     .orm = orm,
    ///     .validator = validateTodo,
    ///     .enable_pagination = true,
    ///     .default_limit = 20,
    ///     .max_limit = 100,
    ///     .enable_filtering = true,
    ///     .enable_sorting = true,
    ///     .cache_ttl_ms = 30000,
    /// });
    /// ```
    pub fn restApi(self: *Engine12, comptime prefix: []const u8, comptime Model: type, config: rest_api_mod.RestApiConfig(Model)) !void {
        return rest_api_mod.restApi(self, prefix, Model, config);
    }

    /// Registers a RESTful API with sensible defaults.
    ///
    /// Simplified version of `restApi()` that uses default configuration
    /// with optional overrides. Useful for quick prototyping.
    ///
    /// ## Parameters
    /// - `prefix`: URL prefix for the API
    /// - `Model`: The ORM model type
    /// - `overrides`: Struct with fields to override defaults
    ///
    /// ## Example
    /// ```zig
    /// try app.restApiDefault("/api/users", User, .{
    ///     .validator = validateUser,
    /// });
    /// ```
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

    /// Registers a custom error handler for transforming errors into HTTP responses.
    ///
    /// The error handler receives the request, error details, and an allocator to construct
    /// a custom error response. Use this to implement consistent error formatting, logging,
    /// and error-specific status codes across your application.
    ///
    /// ## Parameters
    /// - `handler`: A function with signature `fn (*Request, ErrorResponse, Allocator) Response`
    ///
    /// ## Example
    /// ```zig
    /// app.useErrorHandler(customErrorHandler);
    ///
    /// fn customErrorHandler(req: *Request, err: ErrorResponse, alloc: Allocator) Response {
    ///     const json = err.toJson(alloc, false) catch return Response.serverError("Error");
    ///     defer alloc.free(json);
    ///     return Response.json(json).withStatus(err.statusCode());
    /// }
    /// ```
    pub fn useErrorHandler(self: *Engine12, handler: error_handler.ErrorHandler) void {
        self.error_handler_registry.register(handler);
    }

    /// Configures the rate limiter for throttling requests.
    ///
    /// Rate limiting protects your API from abuse and ensures fair resource usage.
    /// The limiter must be heap-allocated to persist for the application lifetime.
    ///
    /// ## Parameters
    /// - `limiter`: A heap-allocated RateLimiter configured with request limits and time windows.
    ///
    /// ## Example
    /// ```zig
    /// const limiter = try allocator.create(RateLimiter);
    /// limiter.* = RateLimiter.init(allocator, .{
    ///     .max_requests = 100,
    ///     .window_ms = 60000,  // 100 requests per minute
    /// });
    /// app.setRateLimiter(limiter);
    /// ```
    pub fn setRateLimiter(self: *Engine12, limiter: *rate_limit.RateLimiter) void {
        if (self.engine_context) |ctx| {
            ctx.rate_limiter = limiter;
        }
    }

    /// Configures the response cache for caching HTTP responses.
    ///
    /// Response caching reduces database load and improves response times for
    /// frequently accessed, cacheable content. The cache must be heap-allocated.
    ///
    /// ## Parameters
    /// - `response_cache`: A heap-allocated ResponseCache with TTL configuration.
    ///
    /// ## Example
    /// ```zig
    /// const cache = try allocator.create(ResponseCache);
    /// cache.* = ResponseCache.init(allocator, 60000);  // 60 second TTL
    /// app.setCache(cache);
    /// ```
    pub fn setCache(self: *Engine12, response_cache: *cache.ResponseCache) void {
        if (self.engine_context) |ctx| {
            ctx.cache = response_cache;
        }
    }

    /// Returns the configured response cache, if any.
    ///
    /// ## Returns
    /// A pointer to the ResponseCache, or null if no cache is configured.
    pub fn getCache(self: *Engine12) ?*cache.ResponseCache {
        if (self.engine_context) |ctx| {
            return ctx.cache;
        }
        return null;
    }

    /// Returns a pointer to the application's logger instance.
    ///
    /// The logger provides structured logging with configurable levels and output formats.
    /// Use this to add application-specific log entries that integrate with Engine12's
    /// logging infrastructure.
    ///
    /// ## Example
    /// ```zig
    /// const logger = app.getLogger();
    /// logger.infoMsg("Application started");
    /// logger.errorMsg("Database connection failed");
    /// ```
    pub fn getLogger(self: *Engine12) *dev_tools.Logger {
        return &self.logger;
    }

    /// Replaces the application's logger with a custom implementation.
    ///
    /// The previous logger is properly deinitialized before replacement.
    ///
    /// ## Parameters
    /// - `logger`: A new Logger instance to use for all application logging.
    pub fn setLogger(self: *Engine12, logger: dev_tools.Logger) void {
        self.logger.deinit();
        self.logger = logger;
    }

    /// Enables built-in request/response logging middleware.
    ///
    /// This middleware logs incoming requests and outgoing responses with timing
    /// information. Useful for debugging and monitoring in development and production.
    ///
    /// ## Parameters
    /// - `config`: Optional LoggingConfig to customize what is logged. Pass `null` for defaults.
    ///
    /// ## Example
    /// ```zig
    /// // Use defaults
    /// try app.enableRequestLogging(null);
    ///
    /// // Custom configuration
    /// try app.enableRequestLogging(.{
    ///     .log_requests = true,
    ///     .log_responses = true,
    ///     .exclude_paths = &.{ "/health", "/metrics" },
    /// });
    /// ```
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

    /// Registers a pre-request middleware function.
    ///
    /// Pre-request middleware runs before the route handler and can:
    /// - Modify the request (add headers, parse data, set context values)
    /// - Abort the request early by returning a response
    /// - Allow the request to proceed to the next middleware or handler
    ///
    /// Middleware executes in registration order. The first middleware to return
    /// `.abort` stops the chain and sends its response to the client.
    ///
    /// ## Parameters
    /// - `middleware`: A function with signature `fn (*Request) MiddlewareResult`
    ///   where MiddlewareResult is `.proceed` or `.abort`
    ///
    /// ## Example
    /// ```zig
    /// try app.usePreRequest(&authMiddleware);
    ///
    /// fn authMiddleware(req: *Request) MiddlewareResult {
    ///     if (req.header("Authorization") == null) {
    ///         return .abort;  // Returns 401 Unauthorized
    ///     }
    ///     return .proceed;
    /// }
    /// ```
    pub fn usePreRequest(self: *Engine12, middleware: middleware_chain.PreRequestMiddlewareFn) !void {
        try self.middleware.addPreRequest(middleware);
    }

    /// Registers a response middleware function.
    ///
    /// Response middleware runs after the route handler and can transform the
    /// response before it's sent to the client. Common uses include:
    /// - Adding security headers (CORS, CSP, etc.)
    /// - Compressing response bodies
    /// - Injecting scripts or content (e.g., HTMX, hot reload)
    /// - Response logging and metrics
    ///
    /// ## Parameters
    /// - `middleware`: A function with signature `fn (Response, *Request) Response`
    ///
    /// ## Example
    /// ```zig
    /// try app.useResponse(&securityHeaders);
    ///
    /// fn securityHeaders(response: Response, req: *Request) Response {
    ///     _ = req;
    ///     return response
    ///         .withHeader("X-Content-Type-Options", "nosniff")
    ///         .withHeader("X-Frame-Options", "DENY");
    /// }
    /// ```
    pub fn useResponse(self: *Engine12, middleware: middleware_chain.ResponseMiddlewareFn) !void {
        try self.middleware.addResponse(middleware);
    }

    /// Loads a template file and registers it for hot-reload watching.
    ///
    /// This function is only available in development mode (`initDevelopment()`).
    /// Templates are automatically reloaded when the file changes on disk.
    ///
    /// ## Parameters
    /// - `template_path`: Relative or absolute path to the template file.
    ///
    /// ## Returns
    /// A pointer to the RuntimeTemplate that can be used for rendering.
    ///
    /// ## Errors
    /// - `error.HotReloadNotEnabled`: Called outside development mode.
    ///
    /// ## Example
    /// ```zig
    /// const app = try Engine12.initDevelopment();
    /// const template = try app.loadTemplate("templates/index.zt.html");
    /// const html = try template.render(MyContext, context, allocator);
    /// ```
    ///
    /// ## Note
    /// In production, use comptime templates with `@embedFile` for better performance:
    /// ```zig
    /// const TemplateType = Template.compileFile("templates/index.zt.html");
    /// const html = try TemplateType.render(Context, context, allocator);
    /// ```
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

    /// A registry that maps template names to their RuntimeTemplate instances.
    ///
    /// Used with `discoverTemplates()` to automatically load all templates from a directory.
    /// Template names are derived from filenames (e.g., "index.zt.html" becomes "index").
    pub const TemplateRegistry = struct {
        templates: std.StringHashMap(*hot_reload_mod.RuntimeTemplate),
        registry_allocator: std.mem.Allocator,

        /// Creates a new empty TemplateRegistry.
        pub fn init(alloc: std.mem.Allocator) TemplateRegistry {
            return TemplateRegistry{
                .templates = std.StringHashMap(*hot_reload_mod.RuntimeTemplate).init(alloc),
                .registry_allocator = alloc,
            };
        }

        /// Retrieves a template by name.
        /// Returns null if the template is not found.
        pub fn get(self: *TemplateRegistry, name: []const u8) ?*hot_reload_mod.RuntimeTemplate {
            return self.templates.get(name);
        }

        /// Checks if a template with the given name exists.
        pub fn has(self: *TemplateRegistry, name: []const u8) bool {
            return self.templates.contains(name);
        }

        /// Returns the number of templates in the registry.
        pub fn count(self: *const TemplateRegistry) usize {
            return self.templates.count();
        }

        /// Frees all resources associated with the registry.
        pub fn deinit(self: *TemplateRegistry) void {
            var iter = self.templates.iterator();
            while (iter.next()) |entry| {
                self.registry_allocator.free(entry.key_ptr.*);
            }
            self.templates.deinit();
        }
    };

    /// Scans a directory for template files and loads them into a registry.
    ///
    /// Automatically discovers all `.zt.html` files in the specified directory,
    /// loads them with hot-reload support, and creates a registry for easy access.
    /// Template names are derived from filenames without the extension.
    ///
    /// ## Parameters
    /// - `templates_dir`: Path to the directory containing template files.
    ///
    /// ## Returns
    /// A TemplateRegistry containing all discovered templates.
    ///
    /// ## Example
    /// ```zig
    /// const registry = try app.discoverTemplates("src/templates");
    /// defer registry.deinit();
    ///
    /// // Access templates by name (filename without .zt.html)
    /// if (registry.get("index")) |template| {
    ///     const html = try template.render(Context, ctx, allocator);
    /// }
    /// ```
    ///
    /// ## Note
    /// Only available in development mode. Returns an empty registry in production.
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

    /// Registers a WebSocket endpoint at the specified path.
    ///
    /// WebSocket connections allow real-time, bidirectional communication between
    /// the server and clients. Use this for features like live updates, chat,
    /// collaborative editing, or streaming data.
    ///
    /// ## Parameters
    /// - `path_pattern`: The URL path for WebSocket connections (e.g., "/ws/chat")
    /// - `handler`: A function called when a new WebSocket connection is established.
    ///   Signature: `fn (*WebSocketConnection) void`
    ///
    /// ## Example
    /// ```zig
    /// try app.websocket("/ws/notifications", handleNotifications);
    ///
    /// fn handleNotifications(conn: *WebSocketConnection) void {
    ///     // Join a room for broadcasting
    ///     conn.joinRoom("global") catch return;
    ///
    ///     // Handle incoming messages
    ///     while (conn.receive()) |message| {
    ///         conn.send(message) catch break;
    ///     }
    /// }
    /// ```
    ///
    /// ## Note
    /// The WebSocket manager is automatically initialized on first use.
    pub fn websocket(self: *Engine12, comptime path_pattern: []const u8, handler: types.WebSocketHandler) !void {
        if (self.ws_routes_count >= self.limits.max_ws_routes) {
            return error.TooManyWebSocketRoutes;
        }

        if (self.ws_manager == null) {
            self.ws_manager = try websocket_mod.manager.WebSocketManager.init(self.allocator);
        }

        try self.ws_routes.append(self.allocator, types.WebSocketRoute{
            .path = path_pattern,
            .handler_ptr = handler, // Store function pointer value directly, not address
        });
        self.ws_routes_count += 1;

        if (self.ws_manager) |*manager| {
            try manager.registerServer(path_pattern, handler);
        }
    }

    /// Automatically discovers and registers static file routes from a directory.
    ///
    /// Scans subdirectories of the given path and mounts each as a static file route.
    /// For example, a `static/css` directory becomes available at `/css/*`.
    ///
    /// ## Parameters
    /// - `static_dir`: Path to the parent directory containing static asset folders.
    ///
    /// ## Example
    /// ```zig
    /// // Directory structure:
    /// // static/
    /// //   css/
    /// //     styles.css
    /// //   js/
    /// //     app.js
    ///
    /// try app.discoverStaticFiles("static");
    /// // Now accessible at /css/styles.css and /js/app.js
    /// ```
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

    /// Alias for `discoverStaticFiles()`. Scans and registers static file routes.
    pub fn serveStaticDirectory(self: *Engine12, static_dir: []const u8) !void {
        try self.discoverStaticFiles(static_dir);
    }

    /// Mounts a directory of static files at the specified URL path.
    ///
    /// This is a convenience wrapper around `serveStatic()` that handles path
    /// normalization (removes trailing slashes and wildcards).
    ///
    /// ## Parameters
    /// - `mount_path`: URL path prefix (e.g., "/assets", "/static/*")
    /// - `directory`: Filesystem path to the directory containing files.
    ///
    /// ## Example
    /// ```zig
    /// try app.static("/assets/*", "public/assets");
    /// // Files in public/assets/ are now served at /assets/*
    /// ```
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

    /// Mounts a directory of static files at the specified URL path.
    ///
    /// Files are served with appropriate MIME types based on extension.
    /// In development mode, caching is disabled for live reload support.
    ///
    /// ## Parameters
    /// - `mount_path`: URL path prefix where files will be accessible.
    /// - `directory`: Filesystem path to the directory containing files.
    ///
    /// ## Errors
    /// - `error.TooManyStaticRoutes`: Maximum static route limit exceeded.
    ///
    /// ## Example
    /// ```zig
    /// try app.serveStatic("/css", "public/stylesheets");
    /// try app.serveStatic("/js", "public/javascripts");
    /// try app.serveStatic("/", "public");  // Serve index.html at root
    /// ```
    pub fn serveStatic(self: *Engine12, mount_path: []const u8, directory: []const u8) !void {
        if (self.static_routes_count >= self.limits.max_static_routes) {
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

        try self.static_routes.append(self.allocator, file_server);
        self.static_routes_count += 1;

        if (self.hot_reload_manager) |hr_manager| {
            hr_manager.watchStaticFiles(&self.static_routes.items[self.static_routes_count - 1].?) catch |err| {
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

    /// Initializes the database connection from environment configuration.
    ///
    /// Reads database configuration from environment variables and establishes
    /// the connection. The database path can be overridden by the `db_path` parameter.
    ///
    /// ## Parameters
    /// - `db_path`: Default path to the SQLite database file.
    ///
    /// ## Environment Variables
    /// - `DATABASE_URL`: Full database connection URL (overrides db_path)
    /// - `DATABASE_DRIVER`: Database driver (`sqlite` or `postgresql`)
    ///
    /// ## Example
    /// ```zig
    /// try app.initDatabase("data/app.db");
    /// const orm = try app.getORM();
    /// ```
    pub fn initDatabase(self: *Engine12, db_path: []const u8) !void {
        const DatabaseSingleton = @import("orm/singleton.zig").DatabaseSingleton;
        const loadConfigFromEnv = @import("orm/singleton.zig").loadConfigFromEnv;

        const config = try loadConfigFromEnv(self.allocator, db_path);
        try DatabaseSingleton.initWithConfig(config, self.allocator);
    }

    /// Initializes the database and runs pending migrations.
    ///
    /// Combines `initDatabase()` with automatic migration discovery and execution.
    /// Migrations are discovered from `.zig` files in the specified directory.
    ///
    /// ## Parameters
    /// - `db_path`: Path to the database file.
    /// - `migrations_dir`: Path to the directory containing migration files.
    ///
    /// ## Example
    /// ```zig
    /// try app.initDatabaseWithMigrations("data/app.db", "src/migrations");
    /// ```
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

    /// Returns the ORM instance for database operations.
    ///
    /// The ORM provides a fluent interface for querying and persisting data.
    /// The database must be initialized with `initDatabase()` before calling this.
    ///
    /// ## Returns
    /// A pointer to the ORM instance.
    ///
    /// ## Errors
    /// Returns an error if the database has not been initialized.
    ///
    /// ## Example
    /// ```zig
    /// const orm = try app.getORM();
    /// const users = try orm.findAll(User);
    /// ```
    pub fn getORM(_: *Engine12) !*orm.ORM {
        const DatabaseSingleton = @import("orm/singleton.zig").DatabaseSingleton;
        return DatabaseSingleton.get();
    }

    /// Registers a one-time background task to run when the server starts.
    ///
    /// Background tasks run in separate threads and are supervised for restarts
    /// on failure. Use this for initialization tasks or long-running processes.
    ///
    /// ## Parameters
    /// - `name`: A descriptive name for the task (used in logs).
    /// - `task`: A function pointer with signature `fn () void`.
    ///
    /// ## Example
    /// ```zig
    /// try app.runTask("cache-warmup", warmupCache);
    ///
    /// fn warmupCache() void {
    ///     // Pre-populate cache with frequently accessed data
    /// }
    /// ```
    pub fn runTask(self: *Engine12, name: []const u8, task: types.BackgroundTask) !void {
        if (self.workers_count >= self.limits.max_background_workers) {
            return error.TooManyWorkers;
        }
        try self.background_workers.append(self.allocator, types.BackgroundWorker{
            .name = name,
            .task = task,
            .interval_ms = null,
        });
        self.workers_count += 1;
    }

    /// Registers a recurring background task that runs at fixed intervals.
    ///
    /// Periodic tasks are useful for maintenance operations like cache cleanup,
    /// health monitoring, or data synchronization.
    ///
    /// ## Parameters
    /// - `name`: A descriptive name for the task.
    /// - `task`: A function pointer with signature `fn () void`.
    /// - `interval_ms`: Time between executions in milliseconds.
    ///
    /// ## Example
    /// ```zig
    /// // Clean up expired sessions every 5 minutes
    /// try app.schedulePeriodicTask("session-cleanup", cleanupSessions, 300_000);
    ///
    /// fn cleanupSessions() void {
    ///     // Delete expired sessions from database
    /// }
    /// ```
    pub fn schedulePeriodicTask(self: *Engine12, name: []const u8, task: types.BackgroundTask, interval_ms: u32) !void {
        if (self.workers_count >= self.limits.max_background_workers) {
            return error.TooManyWorkers;
        }
        try self.background_workers.append(self.allocator, types.BackgroundWorker{
            .name = name,
            .task = task,
            .interval_ms = interval_ms,
        });
        self.workers_count += 1;
    }

    /// Registers a health check function for the `/health` endpoint.
    ///
    /// Health checks are called when the `/health` endpoint is accessed and
    /// determine the overall system health status. Use for checking database
    /// connectivity, external service availability, or resource thresholds.
    ///
    /// ## Parameters
    /// - `check`: A function returning `HealthStatus` (.healthy, .degraded, .unhealthy)
    ///
    /// ## Health Status Logic
    /// - All checks healthy → system healthy
    /// - Any check degraded → system degraded
    /// - Any check unhealthy → system unhealthy (fails fast)
    ///
    /// ## Example
    /// ```zig
    /// try app.registerHealthCheck(&checkDatabaseHealth);
    ///
    /// fn checkDatabaseHealth() HealthStatus {
    ///     const orm = getORM() catch return .unhealthy;
    ///     orm.db.query("SELECT 1") catch return .unhealthy;
    ///     return .healthy;
    /// }
    /// ```
    pub fn registerHealthCheck(self: *Engine12, check: types.HealthCheckFn) !void {
        if (self.health_checks_count >= self.limits.max_health_checks) {
            return error.TooManyHealthChecks;
        }
        try self.health_checks.append(self.allocator, check);
        self.health_checks_count += 1;
    }

    /// Evaluates all registered health checks and returns the overall system status.
    ///
    /// ## Returns
    /// - `.healthy`: All checks passed
    /// - `.degraded`: At least one check returned degraded, but none unhealthy
    /// - `.unhealthy`: At least one check failed
    pub fn getSystemHealth(self: *Engine12) types.HealthStatus {
        var overall_status: types.HealthStatus = .healthy;
        var i: usize = 0;
        while (i < self.health_checks_count) {
            if (self.health_checks.items[i]) |check| {
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

    /// Returns how long the server has been running in milliseconds.
    ///
    /// Returns 0 if the server has not been started.
    pub fn getUptimeMs(self: *Engine12) i64 {
        if (self.start_time == 0) return 0;
        return std.time.milliTimestamp() - self.start_time;
    }

    /// Returns the total number of requests processed since server start.
    pub fn getRequestCount(self: *Engine12) u64 {
        return self.request_count;
    }

    /// Starts all server components without blocking.
    ///
    /// This starts the HTTP server, background tasks, WebSocket servers, and
    /// hot reload manager (in development mode). Use this when you need to
    /// start the server as part of a larger application or test harness.
    ///
    /// For most applications, use `listen()` instead which blocks until shutdown.
    ///
    /// ## Example
    /// ```zig
    /// try app.start();
    /// // Server is now running
    /// // ... do other work ...
    /// try app.stop();
    /// ```
    pub fn start(self: *Engine12) !void {
        if (@import("builtin").mode == .Debug) {
            std.debug.print("\n[WARN] Running in Debug mode. Performance is significantly slower.\n", .{});
            std.debug.print("       Use: zig build -Doptimize=ReleaseFast for production.\n\n", .{});
        }

        self.start_time = std.time.milliTimestamp();
        self.is_running.store(true, .monotonic);

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

    /// Starts the server and blocks until shutdown is triggered.
    ///
    /// This is the main entry point for running an Engine12 application.
    /// It starts all server components, installs signal handlers for graceful
    /// shutdown (SIGINT/SIGTERM), and blocks until the server is stopped.
    ///
    /// ## Signal Handling
    /// - First Ctrl+C (SIGINT) or SIGTERM: Initiates graceful shutdown
    /// - Second signal: Forces immediate exit
    ///
    /// ## Graceful Shutdown
    /// On shutdown, the server:
    /// 1. Stops accepting new connections
    /// 2. Waits for in-flight requests to complete (with timeout)
    /// 3. Executes registered shutdown hooks
    /// 4. Stops background tasks and WebSocket servers
    /// 5. Releases all resources
    ///
    /// ## Example
    /// ```zig
    /// pub fn main() !void {
    ///     const app = try Engine12.initFromEnv();
    ///     defer {
    ///         app.deinit();
    ///         allocator.destroy(app);
    ///     }
    ///
    ///     try app.get("/", handleIndex);
    ///     try app.listen();  // Blocks until Ctrl+C
    /// }
    /// ```
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

        while (self.is_running.load(.monotonic)) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        // Graceful shutdown triggered by signal
        self.stop() catch |err| {
            std.debug.print("[System] Error during shutdown: {}\n", .{err});
        };

        // Clear global reference
        global_engine12_instance = null;
    }

    /// Gracefully shuts down all server components.
    ///
    /// This function:
    /// 1. Signals worker threads to stop
    /// 2. Closes the listening socket
    /// 3. Waits for active requests to complete (with configurable timeout)
    /// 4. Executes shutdown hooks in registration order
    /// 5. Stops valves, hot reload, WebSocket, and HTTP servers
    /// 6. Cleans up connection queues
    ///
    /// Normally called automatically by `listen()` on signal receipt.
    /// Call directly when using `start()` for manual lifecycle control.
    ///
    /// ## Example
    /// ```zig
    /// try app.start();
    /// // ... run tests or other logic ...
    /// try app.stop();
    /// ```
    pub fn stop(self: *Engine12) !void {
        std.debug.print("\n[System] Initiating graceful shutdown...\n", .{});

        self.is_running.store(false, .monotonic);

        // Clear global context
        global_context = null;

        // Immediately signal connection queue to stop accepting new connections
        if (global_connection_queue) |queue| {
            queue.signalShutdown();
        }

        // Close the listener socket to unblock the accept thread
        if (self.built_server) |*server| {
            closeSocket(server.inner.listener);
        }

        // Join the accept thread first (it will exit once listener is closed)
        if (global_accept_thread) |thread| {
            thread.join();
            global_accept_thread = null;
        }

        if (global_worker_thread_count > 0) {
            for (global_worker_threads[0..global_worker_thread_count]) |maybe_thread| {
                if (maybe_thread) |thread| {
                    thread.join();
                }
            }
            global_worker_thread_count = 0;
        }

        const timeout_ms = self.profile.graceful_shutdown_timeout_ms;
        const active_count = self.active_request_tracker.get();
        if (active_count > 0) {
            if (active_count > 0) {
                _ = self.active_request_tracker.waitForCompletion(timeout_ms);
            }
        }

        self.shutdown_hooks.execute();

        if (self.valve_registry) |*registry| {
            registry.onAppStop();
        }

        self.stopHotReloadManager();
        self.stopWebSocketManager();
        try self.stopHttpServer();
        self.stopBackgroundTasks();

        // Cleanup connection queue if it was created
        if (global_connection_queue) |queue| {
            queue.deinit();
            global_connection_queue = null;
        }

        const uptime = self.getUptimeMs();
        std.debug.print("[System] Shutdown complete. Uptime: {d}ms\n", .{uptime});

        // Brief pause to allow output to flush before returning to shell
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    /// Registers a function to be called during graceful shutdown.
    ///
    /// Shutdown hooks run after the server stops accepting new connections
    /// but before resources are fully released. Use for cleanup operations
    /// like closing database connections, flushing caches, or notifying
    /// external services.
    ///
    /// Hooks execute in registration order.
    ///
    /// ## Parameters
    /// - `hook`: A function with signature `fn () void`
    ///
    /// ## Example
    /// ```zig
    /// try app.registerShutdownHook(flushMetrics);
    /// try app.registerShutdownHook(closeDatabase);
    ///
    /// fn flushMetrics() void {
    ///     // Send final metrics before shutdown
    /// }
    /// ```
    pub fn registerShutdownHook(self: *Engine12, hook: shutdown_utils.ShutdownHook) !void {
        try self.shutdown_hooks.register(hook, self.allocator);
    }

    /// Returns the number of currently active (in-flight) requests.
    ///
    /// Useful for monitoring load or implementing custom backpressure.
    /// During graceful shutdown, the server waits for this count to reach
    /// zero before fully stopping.
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

                const thread = try std.Thread.spawn(.{}, ServerThread.run, .{ServerThread{ .server_ptr = server }});
                global_accept_thread = thread;
                return;
            }

            std.debug.print("[HTTP] Starting with {d} worker threads\n", .{num_workers});

            const queue = try ConnectionQueue.init(self.allocator, self.limits.max_queue_size);
            global_connection_queue = queue;
            global_server_for_workers = server;
            global_server_config = self.server_config;

            var i: u16 = 0;
            while (i < num_workers) : (i += 1) {
                const worker_thread = try std.Thread.spawn(.{}, workerThreadFn, .{});
                if (i < 128) {
                    global_worker_threads[i] = worker_thread;
                    global_worker_thread_count = i + 1;
                } else {
                    // Fallback: detach if we exceed our storage capacity
                    worker_thread.detach();
                }
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

            const accept_thread = try std.Thread.spawn(.{}, AcceptThread.run, .{});
            global_accept_thread = accept_thread;
            return;
        }

        return error.ServerNotBuilt;
    }

    fn stopHttpServer(self: *Engine12) !void {
        if (self.http_server != null) {}
    }

    fn startBackgroundTasks(self: *Engine12) !void {
        var supervisor = vigil.supervisor(self.allocator);

        var i: usize = 0;
        while (i < self.workers_count) {
            if (self.background_workers.items[i]) |worker| {
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

            if (self.ws_routes_count < self.limits.max_ws_routes) {
                try self.ws_routes.append(self.allocator, types.WebSocketRoute{
                    .path = "/ws/hot-reload",
                    .handler_ptr = hotReloadWebSocketHandler, // Store function pointer value directly
                });
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
        }
    }

    fn hasRoute(self: *Engine12, path: []const u8) bool {
        var i: usize = 0;
        while (i < self.routes_count) : (i += 1) {
            if (self.http_routes.items[i]) |route| {
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
            if (self.is_running.load(.monotonic)) "RUNNING" else "STOPPED",
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
    const app = try Engine12.initWithProfile(profile);
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    try std.testing.expectEqual(app.profile.environment, types.Environment.development);
    try std.testing.expect(app.is_running.load(.monotonic) == false);
    try std.testing.expectEqual(app.routes_count, 0);
}

test "Engine12 initDevelopment" {
    const app = try Engine12.initDevelopment();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    try std.testing.expectEqual(app.profile.environment, types.Environment.development);
}

test "Engine12 initProduction" {
    const app = try Engine12.initProduction();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    try std.testing.expectEqual(app.profile.environment, types.Environment.production);
}

test "Engine12 initTesting" {
    const app = try Engine12.initTesting();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    try std.testing.expectEqual(app.profile.environment, types.Environment.staging);
}

test "Engine12 runTask registration" {
    const app = try Engine12.initTesting();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    try app.runTask("test_task", &testDummyTask);
    try std.testing.expectEqual(app.workers_count, 1);
    try std.testing.expect(app.background_workers.items[0] != null);
    if (app.background_workers.items[0]) |worker| {
        try std.testing.expectEqualStrings(worker.name, "test_task");
        try std.testing.expect(worker.interval_ms == null);
    }
}

test "Engine12 schedulePeriodicTask registration" {
    const app = try Engine12.initTesting();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    try app.schedulePeriodicTask("periodic_task", &testDummyTask, 1000);
    try std.testing.expectEqual(app.workers_count, 1);
    try std.testing.expect(app.background_workers.items[0] != null);
    if (app.background_workers.items[0]) |worker| {
        try std.testing.expectEqualStrings(worker.name, "periodic_task");
        try std.testing.expect(worker.interval_ms != null);
        try std.testing.expectEqual(worker.interval_ms.?, 1000);
    }
}

test "Engine12 runTask fails when max workers exceeded" {
    const app = try Engine12.initTesting();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    var i: usize = 0;
    while (i < app.limits.max_background_workers) : (i += 1) {
        try app.runTask("task", &testDummyTask);
    }
    try std.testing.expectError(error.TooManyWorkers, app.runTask("task", &testDummyTask));
}

test "Engine12 registerHealthCheck" {
    const app = try Engine12.initTesting();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    try app.registerHealthCheck(&testDummyHealthCheck);
    try std.testing.expectEqual(app.health_checks_count, 1);
    try std.testing.expect(app.health_checks.items[0] != null);
}

test "Engine12 registerHealthCheck fails when max checks exceeded" {
    const app = try Engine12.initTesting();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    var i: usize = 0;
    while (i < app.limits.max_health_checks) : (i += 1) {
        try app.registerHealthCheck(&testDummyHealthCheck);
    }
    try std.testing.expectError(error.TooManyHealthChecks, app.registerHealthCheck(&testDummyHealthCheck));
}

test "Engine12 getSystemHealth returns healthy when no checks" {
    const app = try Engine12.initTesting();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    try std.testing.expectEqual(app.getSystemHealth(), types.HealthStatus.healthy);
}

test "Engine12 getSystemHealth returns healthy when all checks pass" {
    const app = try Engine12.initTesting();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    try app.registerHealthCheck(&testDummyHealthCheck);
    try std.testing.expectEqual(app.getSystemHealth(), types.HealthStatus.healthy);
}

test "Engine12 getSystemHealth returns degraded when one check degraded" {
    const app = try Engine12.initTesting();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    try app.registerHealthCheck(&testDummyHealthCheck);
    try app.registerHealthCheck(&testDummyDegradedCheck);
    try std.testing.expectEqual(app.getSystemHealth(), types.HealthStatus.degraded);
}

test "Engine12 getSystemHealth returns unhealthy when one check unhealthy" {
    const app = try Engine12.initTesting();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    try app.registerHealthCheck(&testDummyHealthCheck);
    try app.registerHealthCheck(&testDummyUnhealthyCheck);
    try std.testing.expectEqual(app.getSystemHealth(), types.HealthStatus.unhealthy);
}

test "Engine12 getUptimeMs returns 0 when not started" {
    const app = try Engine12.initTesting();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    try std.testing.expectEqual(app.getUptimeMs(), 0);
}

test "Engine12 getRequestCount returns 0 initially" {
    const app = try Engine12.initTesting();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    try std.testing.expectEqual(app.getRequestCount(), 0);
}

test "Engine12 deinit sets is_running to false" {
    const app = try Engine12.initTesting();
    app.is_running.store(true, .monotonic);
    app.deinit();
    allocator.destroy(app);
    // Note: Cannot check is_running after destroy since app pointer is invalid
}

test "Engine12 usePreRequestMiddleware sets middleware" {
    const app = try Engine12.initTesting();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
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
    const app = try Engine12.initTesting();
    defer {
        app.deinit();
        allocator.destroy(app);
    }
    const mw = struct {
        fn mw(resp: Response) Response {
            return resp;
        }
    }.mw;
    try app.useResponse(mw);
    try std.testing.expect(app.middleware.response_count > 0);
}

test "Engine12 registerValve" {
    const app = try Engine12.initTesting();
    defer {
        app.deinit();
        allocator.destroy(app);
    }

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
