const std = @import("std");

pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .websocket, .level = .err },
    },
};

const E12 = @import("engine12");
const Request = E12.Request;
const Response = E12.Response;
const middleware_chain = E12.middleware;
const rate_limit = E12.rate_limit;
const ResponseCache = E12.cache.ResponseCache;
const error_handler = E12.error_handler;
const ErrorResponse = error_handler.ErrorResponse;
const cors_middleware = E12.cors_middleware;
const request_id_middleware = E12.request_id_middleware;
const LoggingMiddleware = E12.LoggingMiddleware;
const LoggingConfig = E12.LoggingConfig;
const BasicAuthValve = E12.BasicAuthValve;
const RuntimeTemplate = E12.RuntimeTemplate;
const restApi = E12.restApi;
const RestApiConfig = E12.RestApiConfig;
const Logger = E12.Logger;
const LogLevel = E12.LogLevel;

// Project modules
const database = @import("database.zig");
const models = @import("models.zig");
const Todo = models.Todo;
const validators = @import("validators.zig");
const auth = @import("auth.zig");
const handlers = struct {
    const search = @import("handlers/search.zig");
    const stats = @import("handlers/stats.zig");
    const views = @import("handlers/views.zig");
    const metrics = @import("handlers/metrics.zig");
    const htmx = @import("handlers/htmx.zig");
    const css = @import("handlers/css.zig");
};

const allocator = std.heap.page_allocator;

// Background task constants
const DAY_IN_MS: i64 = 24 * 60 * 60 * 1000;
const SEVEN_DAYS_MS: i64 = 7 * DAY_IN_MS;

// ============================================================================
// MIDDLEWARE
// ============================================================================

fn customErrorHandler(req: *Request, err: ErrorResponse, alloc: std.mem.Allocator) Response {
    // Log error using structured logger
    if (database.getLogger()) |logger| {
        const log_level: LogLevel = switch (err.error_type) {
            .validation_error, .bad_request => .warn,
            .authentication_error, .authorization_error => .warn,
            .not_found => .info,
            .rate_limit_exceeded => .warn,
            .request_too_large => .warn,
            .timeout => .warn,
            .internal_error, .unknown => LogLevel.err,
        };

        const entry_opt = logger.log(log_level, err.message) catch null;
        if (entry_opt) |entry| {
            _ = entry.field("error_code", err.code) catch {};
            _ = entry.field("error_type", @tagName(err.error_type)) catch {};
            if (err.details) |details| {
                _ = entry.field("details", details) catch {};
            }
            // Include request ID if available
            if (req.get("request_id")) |request_id| {
                _ = entry.field("request_id", request_id) catch {};
            }
            entry.log();
        }
    }

    // Create JSON error response (no context in production)
    const json = err.toJson(alloc, false) catch {
        return Response.serverError("Failed to serialize error");
    };
    defer alloc.free(json);

    // Determine status code
    const status_code: u16 = switch (err.error_type) {
        .validation_error, .bad_request => 400,
        .authentication_error => 401,
        .authorization_error => 403,
        .not_found => 404,
        .rate_limit_exceeded => 429,
        .request_too_large => 413,
        .timeout => 408,
        .internal_error, .unknown => 500,
    };

    var resp = Response.json(json).withStatus(status_code);

    // Add request ID to response headers if available
    if (req.get("request_id")) |request_id| {
        resp = resp.withHeader("X-Request-ID", request_id);
    }

    return resp;
}

fn bodySizeLimitMiddleware(req: *Request) middleware_chain.MiddlewareResult {
    const MAX_BODY_SIZE: usize = 10 * 1024; // 10KB

    const body = req.body();
    if (body.len > MAX_BODY_SIZE) {
        // Set context flag
        req.set("body_size_exceeded", "true") catch {};

        // Abort request
        return .abort;
    }

    return .proceed;
}

fn csrfMiddleware(req: *Request) middleware_chain.MiddlewareResult {
    const method = req.method();

    // Skip CSRF check for safe methods
    if (std.mem.eql(u8, method, "GET") or
        std.mem.eql(u8, method, "HEAD") or
        std.mem.eql(u8, method, "OPTIONS"))
    {
        return .proceed;
    }

    // For POST/PUT/DELETE, check for CSRF token
    // Simplified implementation - in production, validate token against session
    // For demo purposes, we'll allow requests without CSRF token
    // In production, uncomment the code below to enforce CSRF protection
    const csrf_token = req.header("X-CSRF-Token");

    if (csrf_token == null or csrf_token.?.len == 0) {
        // Missing CSRF token - for demo app, we'll allow it
        // Uncomment below for strict CSRF protection:
        // req.set("csrf_error", "true") catch {};
        // return .abort;
    }

    // In a full implementation, we would validate the token here
    // A real implementation would compare against a session-stored token

    return .proceed;
}

// ============================================================================
// BACKGROUND TASKS
// ============================================================================

fn cleanupOldCompletedTodos() void {
    // Run periodically every hour
    while (true) {
        const logger = database.getLogger();

        // Lock database mutex for thread-safe access
        database.db_mutex.lock();
        const orm = database.getORM() catch {
            database.db_mutex.unlock();
            if (logger) |l| l.errorMsg("Failed to get ORM for cleanup task");
            std.Thread.sleep(3600000 * std.time.ns_per_ms); // Sleep 1 hour
            continue;
        };
        const now = std.time.milliTimestamp();

        // Use driver-aware SQL - PostgreSQL uses BOOLEAN, SQLite uses INTEGER
        const completed_val = if (database.getDriver() == .postgresql) "TRUE" else "1";
        const sql = std.fmt.allocPrint(
            orm.allocator,
            "DELETE FROM todos WHERE completed = {s} AND ({} - updated_at) > {}",
            .{ completed_val, now, SEVEN_DAYS_MS },
        ) catch {
            database.db_mutex.unlock();
            if (logger) |l| l.errorMsg("Failed to build cleanup SQL");
            std.Thread.sleep(3600000 * std.time.ns_per_ms); // Sleep 1 hour
            continue;
        };

        _ = orm.db.execute(sql) catch {
            orm.allocator.free(sql);
            database.db_mutex.unlock();
            if (logger) |l| l.errorMsg("Failed to cleanup old todos");
            std.Thread.sleep(3600000 * std.time.ns_per_ms); // Sleep 1 hour
            continue;
        };

        orm.allocator.free(sql);
        database.db_mutex.unlock();

        if (logger) |l| l.infoMsg("Cleaned up old completed todos");

        // Sleep for 1 hour before next run
        std.Thread.sleep(3600000 * std.time.ns_per_ms);
    }
}

fn checkOverdueTodos() void {
    // Run periodically every hour
    while (true) {
        const logger = database.getLogger();

        // Lock database mutex for thread-safe access
        database.db_mutex.lock();
        const orm = database.getORM() catch {
            database.db_mutex.unlock();
            if (logger) |l| l.errorMsg("Failed to get ORM for overdue check");
            std.Thread.sleep(3600000 * std.time.ns_per_ms); // Sleep 1 hour
            continue;
        };
        const now = std.time.milliTimestamp();

        // Use driver-aware SQL - PostgreSQL uses BOOLEAN, SQLite uses INTEGER
        const completed_val = if (database.getDriver() == .postgresql) "FALSE" else "0";
        const sql = std.fmt.allocPrint(
            orm.allocator,
            "SELECT COUNT(*) as count FROM todos WHERE completed = {s} AND due_date IS NOT NULL AND due_date < {}",
            .{ completed_val, now },
        ) catch {
            database.db_mutex.unlock();
            if (logger) |l| l.errorMsg("Failed to build overdue check SQL");
            std.Thread.sleep(3600000 * std.time.ns_per_ms); // Sleep 1 hour
            continue;
        };

        var result = orm.db.query(sql) catch {
            orm.allocator.free(sql);
            database.db_mutex.unlock();
            if (logger) |l| l.errorMsg("Failed to check overdue todos");
            std.Thread.sleep(3600000 * std.time.ns_per_ms); // Sleep 1 hour
            continue;
        };
        result.deinit();
        orm.allocator.free(sql);
        database.db_mutex.unlock();

        // Parse count from result (simplified - just log if any found)
        if (logger) |l| l.infoMsg("Checked for overdue todos");

        // Sleep for 1 hour before next run
        std.Thread.sleep(3600000 * std.time.ns_per_ms);
    }
}

fn generateStatistics() void {
    // Statistics are now user-specific, so this background task is not applicable
    // Stats are generated on-demand per user via handleGetStats
    // Run periodically to keep the task alive
    while (true) {
        std.Thread.sleep(300000 * std.time.ns_per_ms); // Sleep 5 minutes
    }
}

fn validateStoreHealth() void {
    // Run periodically every 10 minutes
    while (true) {
        const logger = database.getLogger();

        // Lock database mutex for thread-safe access
        database.db_mutex.lock();
        const orm = database.getORM() catch {
            database.db_mutex.unlock();
            if (logger) |l| l.errorMsg("Failed to get ORM for health validation");
            std.Thread.sleep(600000 * std.time.ns_per_ms); // Sleep 10 minutes
            continue;
        };

        // Use raw SQL to count all todos across all users
        const sql = "SELECT COUNT(*) as count FROM todos";
        var result = orm.db.query(sql) catch {
            database.db_mutex.unlock();
            if (logger) |l| l.errorMsg("Failed to get todo count for health validation");
            std.Thread.sleep(600000 * std.time.ns_per_ms); // Sleep 10 minutes
            continue;
        };
        result.deinit();
        database.db_mutex.unlock();

        // Database doesn't have capacity limits, but we can warn if there are many todos
        // For now, just log that health check ran
        if (logger) |l| l.infoMsg("Store health validation completed");

        // Sleep for 10 minutes before next run
        std.Thread.sleep(600000 * std.time.ns_per_ms);
    }
}

// ============================================================================
// HEALTH CHECKS
// ============================================================================

fn checkTodoStoreHealth() E12.HealthStatus {
    // Lock database mutex for thread-safe access
    database.db_mutex.lock();
    defer database.db_mutex.unlock();

    const orm = database.getORM() catch return .unhealthy;

    // Simple health check - just verify database is accessible
    var result = orm.db.query("SELECT 1") catch return .unhealthy;
    result.deinit();

    return .healthy;
}

fn checkSystemPerformance() E12.HealthStatus {
    return .healthy;
}

// ============================================================================
// APP SETUP
// ============================================================================

pub fn createApp() !*E12.Engine12 {
    // Initialize database
    try database.initDatabase();

    // Engine12.initFromEnv() now returns a heap-allocated pointer
    // This prevents dangling pointer issues in EngineContext
    const app = try E12.Engine12.initFromEnv();

    // Register root route FIRST before anything else that might build the server
    std.debug.print("[Todo] Registering root route / FIRST\n", .{});
    try app.get("/", handlers.views.handleIndex);
    std.debug.print("[Todo] Root route registered, custom_root_handler should be true\n", .{});

    // Authentication disabled for this demo app
    // All todos use user_id = 1 by default
    _ = database.getORM() catch {
        return error.DatabaseNotInitialized;
    };

    // Load HTMX template
    // Allocate template registry on heap and move ownership (no copy!)
    const template_registry_ptr = try allocator.create(E12.TemplateRegistry);
    template_registry_ptr.* = try app.discoverTemplates("examples/todo/src/templates");
    database.setGlobalTemplateRegistry(template_registry_ptr);
    std.debug.print("[Todo] Template registry set with {} templates\n", .{template_registry_ptr.count()});

    // Note: Root route "/" is registered first in createApp() before any other initialization

    // HTMX-powered todo app - using minimal routes
    // Main page
    try app.get("/htmx", handlers.views.handleHtmxIndex);

    // HTMX todo handlers
    try app.get("/todos", handlers.htmx.handlePageAll);
    try app.get("/todos/all", handlers.htmx.handlePageAll);
    try app.get("/todos/active", handlers.htmx.handlePageActive);
    try app.get("/todos/completed", handlers.htmx.handlePageCompleted);
    try app.post("/todos", handlers.htmx.handleCreateTodo);
    try app.get("/todos/search", handlers.htmx.handleSearchTodos);
    try app.post("/todos/:id/toggle", handlers.htmx.handleToggleTodo);
    try app.get("/todos/:id/edit", handlers.htmx.handleEditTodo);
    try app.get("/todos/:id/view", handlers.htmx.handleViewTodo);
    try app.put("/todos/:id", handlers.htmx.handleUpdateTodo);
    try app.delete("/todos/:id", handlers.htmx.handleDeleteTodo);
    try app.post("/todos/clear-completed", handlers.htmx.handleClearCompleted);
    try app.get("/todos/stats", handlers.htmx.handleGetStats);

    // New interactive HTMX handlers (Tier 4 features)
    try app.get("/todos/filter", handlers.htmx.handleFilterByPriority);
    try app.get("/todos/completed-count", handlers.htmx.handleCompletedCount);
    try app.post("/todos/toggle-all", handlers.htmx.handleToggleAll);
    try app.post("/todos/restore", handlers.htmx.handleRestoreTodo);

    // HTMX analytics page
    try app.get("/analytics", handlers.htmx.handleAnalyticsPage);

    // HTMX utility handlers
    try app.get("/htmx/dismiss-toast", handlers.htmx.handleDismissToast);

    // Enable OpenAPI documentation
    try app.enableOpenApiDocs("/docs", .{
        .title = "Todo API",
        .version = "1.0.0",
        .description = "A simple todo management API with filtering and search (authentication disabled for demo)",
    });

    // Auth routes disabled - authentication removed from this demo app

    // Store app globally for background tasks to access logger
    database.setGlobalApp(app);

    // Initialize cache with 60 second default TTL
    // Allocate on heap so it persists beyond createApp() scope
    const response_cache = try allocator.create(ResponseCache);
    response_cache.* = ResponseCache.init(allocator, 60000);
    app.setCache(response_cache);

    // Store cache globally for potential background task usage
    database.setGlobalCache(response_cache);

    // Middleware
    // Order matters: body size limit -> CSRF -> CORS -> request ID -> logging
    try app.usePreRequest(&bodySizeLimitMiddleware);
    try app.usePreRequest(&csrfMiddleware);

    // CORS middleware - heap-allocated to persist beyond this function
    const static = struct {
        const origins = [_][]const u8{"*"};
        const methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS" };
        const headers = [_][]const u8{ "Content-Type", "Authorization", "X-CSRF-Token" };
    };
    const cors = try allocator.create(cors_middleware.CorsMiddleware);
    cors.* = cors_middleware.CorsMiddleware.init(.{
        .allowed_origins = &static.origins,
        .allowed_methods = &static.methods,
        .allowed_headers = &static.headers,
        .max_age = 3600,
        .allow_credentials = false,
    });
    cors.setGlobalConfig();
    const cors_mw_fn = cors.preflightMwFn();
    try app.usePreRequest(cors_mw_fn);

    // Request ID middleware - heap-allocated to persist beyond this function
    const req_id_mw = try allocator.create(request_id_middleware.RequestIdMiddleware);
    req_id_mw.* = request_id_middleware.RequestIdMiddleware.init(.{});
    const req_id_mw_fn = req_id_mw.preRequestMwFn();
    try app.usePreRequest(req_id_mw_fn);

    // Enable built-in request/response logging middleware
    const logging_static = struct {
        const exclude_paths = [_][]const u8{ "/metrics", "/health" };
    };
    const logging_config = LoggingConfig{
        .log_requests = true,
        .log_responses = true,
        .exclude_paths = &logging_static.exclude_paths,
    };
    try app.enableRequestLogging(logging_config);

    // Custom error handler
    app.useErrorHandler(customErrorHandler);

    // Rate limiting for API endpoints - allocate on heap to persist
    const api_rate_limiter = try allocator.create(rate_limit.RateLimiter);
    api_rate_limiter.* = rate_limit.RateLimiter.init(allocator, rate_limit.RateLimitConfig{
        .max_requests = 100,
        .window_ms = 60000, // 1 minute
    });

    try api_rate_limiter.setRouteConfig("/api/todos", rate_limit.RateLimitConfig{
        .max_requests = 50,
        .window_ms = 60000,
    });

    app.setRateLimiter(api_rate_limiter);

    // Metrics endpoint
    try app.get("/metrics", handlers.metrics.handleMetrics);

    // Serve dynamically generated CSS using Engine12's CSS-in-Zig system
    // This replaces static CSS files with type-safe, generated CSS
    try app.get("/css/style.css", handlers.css.handleCss);

    // API routes
    // Note: Route groups require comptime evaluation, so we register routes directly
    // Route groups are demonstrated in the codebase but require comptime usage

    // Custom endpoints for search and stats (not standard REST operations)
    try app.get("/api/todos/search", handlers.search.handleSearchTodos);
    try app.get("/api/todos/stats", handlers.stats.handleGetStats);

    // RESTful API endpoints - restApi automatically handles:
    // - GET /api/todos (list with pagination, filtering, sorting)
    // - GET /api/todos/:id (show)
    // - POST /api/todos (create)
    // - PUT /api/todos/:id (update)
    // - DELETE /api/todos/:id (delete)
    const orm_for_rest = database.getORM() catch {
        return error.DatabaseNotInitialized;
    };
    try app.restApi("/api/todos", Todo, RestApiConfig(Todo){
        .orm = orm_for_rest,
        .validator = validators.validateTodo,
        .authenticator = null,
        .authorization = null,
        .enable_pagination = true,
        .default_limit = 20, // Default items per page
        .max_limit = 100, // Maximum items per page (prevents excessive data transfer)
        .enable_filtering = true,
        .enable_sorting = true,
        .cache_ttl_ms = 30000, // 30 seconds
        // Note: Hooks are not currently supported due to Zig type system limitations
        // User_id and timestamps should be set in the validator or by modifying the model before calling restApi
    });

    // Health checks
    try app.registerHealthCheck(&checkTodoStoreHealth);
    try app.registerHealthCheck(&checkSystemPerformance);

    return app;
}

pub fn main() !void {
    // Initialize HTMX fragment cache
    E12.htmx.initGlobalCache(allocator);
    defer E12.htmx.deinitGlobalCache();

    const app = try createApp();
    defer {
        app.deinit();
        allocator.destroy(app);
    }

    if (database.getLogger()) |logger| {
        logger.infoMsg("Server starting - Press Ctrl+C to stop");
    }

    // Wrap listen in error handling to catch crashes
    app.listen() catch |err| {
        std.debug.print("\n[FATAL] Server crashed with error: {}\n", .{err});
        std.debug.print("This is likely a ziggurat HTTP server issue in ReleaseFast mode\n", .{});
        return err;
    };
}
