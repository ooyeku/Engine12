const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware = @import("middleware.zig");
const dev_tools = @import("dev_tools.zig");
const Logger = dev_tools.Logger;
const LogLevel = dev_tools.LogLevel;

pub const LoggingConfig = struct {
    log_requests: bool = true,
    
    log_responses: bool = true,
    
    log_body: bool = false,
    
    exclude_paths: []const []const u8 = &[_][]const u8{},
    
    request_log_level: LogLevel = .info,
    
    response_log_level: LogLevel = .info,
};

var global_logger: ?*Logger = null;
var global_logger_mutex: std.Thread.Mutex = .{};

var global_logging_config: ?LoggingConfig = null;
var global_logging_config_mutex: std.Thread.Mutex = .{};

pub const LoggingMiddleware = struct {
    config: LoggingConfig,
    
    pub fn init(config: LoggingConfig) LoggingMiddleware {
        return LoggingMiddleware{ .config = config };
    }
    
    pub fn setGlobalLogger(logger: *Logger) void {
        global_logger_mutex.lock();
        defer global_logger_mutex.unlock();
        global_logger = logger;
    }
    
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
    
    pub fn preRequestMwFn(self: *const LoggingMiddleware) middleware.PreRequestMiddlewareFn {
        _ = self; // Config is stored globally
        return preRequestMiddleware;
    }
    
    pub fn responseMwFn(self: *const LoggingMiddleware) middleware.ResponseMiddlewareFn {
        _ = self; // Config is stored globally
        return responseMiddleware;
    }
};

