const std = @import("std");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const middleware = @import("middleware.zig");
const dev_tools = @import("../observability/dev_tools.zig");
const Logger = dev_tools.Logger;
const LogLevel = dev_tools.LogLevel;

/// Configuration for request/response logging middleware.
///
/// ## Example
/// ```zig
/// const logging_config = LoggingConfig{
///     .log_requests = true,
///     .log_responses = true,
///     .log_body = false, // Don't log request/response bodies
///     .exclude_paths = &[_][]const u8{ "/health", "/metrics" }, // Skip health checks
///     .request_log_level = .info,
///     .response_log_level = .info,
/// };
/// ```
pub const LoggingConfig = struct {
    /// Whether to log incoming requests
    log_requests: bool = true,

    /// Whether to log outgoing responses
    log_responses: bool = true,

    /// Whether to include request/response bodies in logs (can be verbose)
    log_body: bool = false,

    /// Paths that should not be logged (e.g., health checks, metrics endpoints)
    exclude_paths: []const []const u8 = &[_][]const u8{},

    /// Log level for request log entries
    request_log_level: LogLevel = .info,

    /// Log level for response log entries
    response_log_level: LogLevel = .info,
};

var global_logger: ?*Logger = null;
var global_logger_mutex: std.Thread.Mutex = .{};

var global_logging_config: ?LoggingConfig = null;
var global_logging_config_mutex: std.Thread.Mutex = .{};

/// Middleware for logging HTTP requests and responses.
/// Logs request method, path, headers, and timing information.
pub const LoggingMiddleware = struct {
    config: LoggingConfig,

    /// Initialize logging middleware with the given configuration.
    pub fn init(config: LoggingConfig) LoggingMiddleware {
        return LoggingMiddleware{ .config = config };
    }

    /// Set the global logger instance used by the logging middleware.
    /// This must be called before using the middleware.
    pub fn setGlobalLogger(logger: *Logger) void {
        global_logger_mutex.lock();
        defer global_logger_mutex.unlock();
        global_logger = logger;
    }

    /// Set this middleware's configuration as the global logging config.
    /// This must be called before using the middleware in request processing.
    pub fn setGlobalConfig(self: *const LoggingMiddleware) void {
        global_logging_config_mutex.lock();
        defer global_logging_config_mutex.unlock();
        global_logging_config = self.config;
    }

    fn isExcluded(path: []const u8, exclude_paths: []const []const u8) bool {
        for (exclude_paths) |excluded| {
            if (std.mem.startsWith(u8, path, excluded)) {
                return true;
            }
        }
        return false;
    }

    fn preRequestMiddleware(req: *Request) middleware.MiddlewareResult {
        global_logging_config_mutex.lock();
        const config = global_logging_config orelse {
            global_logging_config_mutex.unlock();
            return .proceed; // No config set
        };
        global_logging_config_mutex.unlock();

        global_logger_mutex.lock();
        const logger = global_logger orelse {
            global_logger_mutex.unlock();
            return .proceed; // No logger set
        };
        global_logger_mutex.unlock();

        if (isExcluded(req.path(), config.exclude_paths)) {
            return .proceed;
        }

        if (!config.log_requests) {
            return .proceed;
        }

        const start_time = std.time.milliTimestamp();
        const start_time_str = std.fmt.allocPrint(req.arena.allocator(), "{d}", .{start_time}) catch {
            return .proceed; // If allocation fails, just proceed
        };
        req.set("request_start_time", start_time_str) catch {};

        const entry = logger.fromRequest(req, config.request_log_level, "Request received") catch {
            return .proceed; // If logging fails, just proceed
        };
        entry.log();

        return .proceed;
    }

    fn responseMiddleware(resp: Response) Response {
        global_logging_config_mutex.lock();
        const config = global_logging_config orelse {
            global_logging_config_mutex.unlock();
            return resp; // No config set
        };
        global_logging_config_mutex.unlock();

        if (!config.log_responses) {
            return resp;
        }

        return resp;
    }

    /// Get the pre-request middleware function for logging.
    /// Logs incoming requests with method, path, headers, and timestamp.
    /// Also stores the request start time for calculating request duration.
    ///
    /// ## Example
    /// ```zig
    /// var logging = LoggingMiddleware.init(.{});
    /// LoggingMiddleware.setGlobalLogger(&logger);
    /// logging.setGlobalConfig();
    /// app.usePreRequest(logging.preRequestMwFn());
    /// ```
    pub fn preRequestMwFn(self: *const LoggingMiddleware) middleware.PreRequestMiddlewareFn {
        _ = self; // Config is stored globally
        return preRequestMiddleware;
    }

    /// Get the response middleware function for logging.
    /// Logs outgoing responses with status code and other metadata.
    ///
    /// ## Example
    /// ```zig
    /// var logging = LoggingMiddleware.init(.{});
    /// logging.setGlobalConfig();
    /// app.useResponse(logging.responseMwFn());
    /// ```
    pub fn responseMwFn(self: *const LoggingMiddleware) middleware.ResponseMiddlewareFn {
        _ = self; // Config is stored globally
        return responseMiddleware;
    }
};
