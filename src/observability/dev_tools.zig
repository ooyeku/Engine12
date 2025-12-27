const std = @import("std");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const types = @import("../types.zig");

pub const RouteInfo = struct {
    method: []const u8,
    path: []const u8,
    handler_name: []const u8 = "unknown",

    pub fn init(allocator: std.mem.Allocator, method: []const u8, path: []const u8, handler_name: []const u8) !RouteInfo {
        const method_copy = try allocator.dupe(u8, method);
        const path_copy = try allocator.dupe(u8, path);
        const handler_copy = try allocator.dupe(u8, handler_name);

        return RouteInfo{
            .method = method_copy,
            .path = path_copy,
            .handler_name = handler_copy,
        };
    }

    pub fn deinit(self: *RouteInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.path);
        allocator.free(self.handler_name);
    }
};

pub const RouteRegistry = struct {
    routes: std.ArrayListUnmanaged(RouteInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RouteRegistry {
        return RouteRegistry{
            .routes = std.ArrayListUnmanaged(RouteInfo){},
            .allocator = allocator,
        };
    }

    pub fn register(self: *RouteRegistry, method: []const u8, path: []const u8, handler_name: []const u8) !void {
        const route_info = try RouteInfo.init(self.allocator, method, path, handler_name);
        try self.routes.append(self.allocator, route_info);
    }

    pub fn getAll(self: *const RouteRegistry) []const RouteInfo {
        return self.routes.items;
    }

    pub fn getByMethod(self: *const RouteRegistry, method: []const u8, matches: *std.ArrayListUnmanaged(RouteInfo)) !void {
        for (self.routes.items) |route| {
            if (std.mem.eql(u8, route.method, method)) {
                try matches.append(self.allocator, route);
            }
        }
    }

    pub fn toJson(self: *const RouteRegistry, allocator: std.mem.Allocator) ![]const u8 {
        var output = std.ArrayListUnmanaged(u8){};
        const writer = output.writer(allocator);

        try writer.print("{{\"routes\":[", .{});
        for (self.routes.items, 0..) |route, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print(
                "{{\"method\":\"{s}\",\"path\":\"{s}\",\"handler\":\"{s}\"}}",
                .{ route.method, route.path, route.handler_name },
            );
        }
        try writer.print("]}}", .{});

        return output.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *RouteRegistry) void {
        for (self.routes.items) |*route| {
            route.deinit(self.allocator);
        }
        self.routes.deinit(self.allocator);
    }
};

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn toInt(self: LogLevel) u8 {
        return switch (self) {
            .debug => 0,
            .info => 1,
            .warn => 2,
            .err => 3,
        };
    }
};

pub const OutputFormat = enum {
    json,
    human,
};

pub const LogDestination = enum {
    stdout,
    file,
    syslog,
};

const FileHandle = struct {
    file: std.fs.File,
    mutex: std.Thread.Mutex,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, file_path: []const u8) !FileHandle {
        const path_copy = try allocator.dupe(u8, file_path);
        errdefer allocator.free(path_copy);

        const file = try std.fs.cwd().createFile(file_path, .{ .truncate = false, .read = true });
        errdefer file.close();

        return FileHandle{
            .file = file,
            .mutex = .{},
            .path = path_copy,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FileHandle) void {
        self.file.close();
        self.allocator.free(self.path);
    }

    pub fn write(self: *FileHandle, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = try self.file.write(data);
        try self.file.sync();
    }
};

pub const LogEntry = struct {
    level: LogLevel,
    message: []const u8,
    timestamp: i64,
    fields: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    logger: ?*Logger = null,

    pub fn init(allocator: std.mem.Allocator, level: LogLevel, message: []const u8) !LogEntry {
        const message_copy = try allocator.dupe(u8, message);
        return LogEntry{
            .level = level,
            .message = message_copy,
            .timestamp = std.time.milliTimestamp(),
            .fields = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
            .logger = null,
        };
    }

    pub fn initOwned(allocator: std.mem.Allocator, level: LogLevel, message: []const u8) !LogEntry {
        return LogEntry{
            .level = level,
            .message = message,
            .timestamp = std.time.milliTimestamp(),
            .fields = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
            .logger = null,
        };
    }

    pub fn field(self: *LogEntry, key: []const u8, value: []const u8) !*LogEntry {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.fields.put(key_copy, value_copy);
        return self;
    }

    pub fn fieldInt(self: *LogEntry, key: []const u8, value: anytype) !*LogEntry {
        const key_copy = try self.allocator.dupe(u8, key);
        var buffer: [32]u8 = undefined;
        const value_str = try std.fmt.bufPrint(&buffer, "{d}", .{value});
        const value_copy = try self.allocator.dupe(u8, value_str);
        try self.fields.put(key_copy, value_copy);
        return self;
    }

    pub fn fieldBool(self: *LogEntry, key: []const u8, value: bool) !*LogEntry {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_str = if (value) "true" else "false";
        const value_copy = try self.allocator.dupe(u8, value_str);
        try self.fields.put(key_copy, value_copy);
        return self;
    }

    pub fn withRequest(self: *LogEntry, req: *Request) !*LogEntry {
        const request_id = req.get("request_id") orelse "unknown";
        _ = try self.field("request_id", request_id);

        _ = try self.field("method", req.method());

        _ = try self.field("path", req.path());

        if (req.header("User-Agent")) |ua| {
            _ = try self.field("user_agent", ua);
        }

        if (req.header("X-Forwarded-For")) |xff| {
            const comma_pos = std.mem.indexOfScalar(u8, xff, ',') orelse xff.len;
            _ = try self.field("ip", xff[0..comma_pos]);
        } else if (req.header("X-Real-IP")) |real_ip| {
            _ = try self.field("ip", real_ip);
        }

        return self;
    }

    pub fn withResponse(self: *LogEntry, status_code: ?u16, req: ?*Request) !*LogEntry {
        if (status_code) |code| {
            _ = try self.fieldInt("status_code", code);
        }

        if (req) |r| {
            if (r.get("request_start_time")) |start_time_str| {
                const start_time = std.fmt.parseInt(i64, start_time_str, 10) catch {
                    return self;
                };
                const end_time = std.time.milliTimestamp();
                const duration_ms = end_time - start_time;
                _ = try self.fieldInt("duration_ms", duration_ms);
            }
        }

        return self;
    }

    pub fn log(self: *LogEntry) void {
        const logger_ptr = self.logger;
        const entry_allocator = self.allocator;
        const should_destroy = logger_ptr != null;

        if (logger_ptr) |logger| {
            if (self.message.len > 0) {
                logger.printEntry(self);
            }
        } else {
            const json = self.toJson(self.allocator) catch {
                self.deinit();
                return;
            };
            defer entry_allocator.free(json);
            std.debug.print("{s}\n", .{json});
        }

        self.deinit();

        if (should_destroy) {
            if (logger_ptr) |logger| {
                logger.allocator.destroy(self);
            }
        }
    }

    pub fn toJson(self: *const LogEntry, allocator: std.mem.Allocator) ![]const u8 {
        var output = std.ArrayListUnmanaged(u8){};
        const writer = output.writer(allocator);

        var escaped_message = std.ArrayListUnmanaged(u8){};
        defer escaped_message.deinit(allocator);
        try escapeJsonString(self.message, &escaped_message, allocator);

        try writer.print(
            "{{\"level\":\"{s}\",\"message\":\"{s}\",\"timestamp\":{d}",
            .{ @tagName(self.level), escaped_message.items, self.timestamp },
        );

        if (self.fields.count() > 0) {
            try writer.print(",\"fields\":{{", .{});
            var iterator = self.fields.iterator();
            var first = true;
            while (iterator.next()) |entry| {
                if (!first) try writer.print(",", .{});
                first = false;

                var escaped_value = std.ArrayListUnmanaged(u8){};
                defer escaped_value.deinit(allocator);
                try escapeJsonString(entry.value_ptr.*, &escaped_value, allocator);

                try writer.print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, escaped_value.items });
            }
            try writer.print("}}", .{});
        }

        try writer.print("}}", .{});
        return output.toOwnedSlice(allocator);
    }

    pub fn toHumanReadable(self: *const LogEntry, allocator: std.mem.Allocator) ![]const u8 {
        var output = std.ArrayListUnmanaged(u8){};
        const writer = output.writer(allocator);

        const Time = @import("../utils/time.zig").Time;
        const formatted_timestamp = Time.formatTimestamp(self.timestamp, allocator) catch {
            try writer.print("[{d}] ", .{self.timestamp});
            const level_str = switch (self.level) {
                .debug => "DEBUG",
                .info => "INFO",
                .warn => "WARN",
                .err => "ERROR",
            };
            try writer.print("{s} {s}", .{ level_str, self.message });
            if (self.fields.count() > 0) {
                var iterator = self.fields.iterator();
                while (iterator.next()) |entry| {
                    try writer.print(" {s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
            }
            return output.toOwnedSlice(allocator);
        };
        defer allocator.free(formatted_timestamp);

        const level_str = switch (self.level) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };

        try writer.print("[{s}] {s} {s}", .{ formatted_timestamp, level_str, self.message });

        if (self.fields.count() > 0) {
            var iterator = self.fields.iterator();
            while (iterator.next()) |entry| {
                try writer.print(" {s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }

        return output.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *LogEntry) void {
        self.allocator.free(self.message);
        var iterator = self.fields.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.fields.deinit();
    }
};

fn escapeJsonString(input: []const u8, output: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    for (input) |byte| {
        switch (byte) {
            '"' => try output.appendSlice(allocator, "\\\""),
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            else => try output.append(allocator, byte),
        }
    }
}

pub const Logger = struct {
    allocator: std.mem.Allocator,
    min_level: LogLevel,
    format: OutputFormat,
    destinations: std.ArrayListUnmanaged(LogDestination),
    file_handle: ?*FileHandle = null,
    syslog_facility: ?u8 = null,

    pub fn init(allocator: std.mem.Allocator, min_level: LogLevel) Logger {
        var logger = Logger{
            .allocator = allocator,
            .min_level = min_level,
            .format = .json,
            .destinations = .{},
        };
        logger.destinations.append(allocator, .stdout) catch {};
        return logger;
    }

    pub fn addDestination(self: *Logger, destination: LogDestination) !void {
        for (self.destinations.items) |dest| {
            if (dest == destination) {
                return; // Already added
            }
        }
        try self.destinations.append(self.allocator, destination);
    }

    pub fn setFileDestination(self: *Logger, file_path: []const u8) !void {
        if (self.file_handle) |handle| {
            handle.deinit();
            self.allocator.destroy(handle);
        }
        const handle = try self.allocator.create(FileHandle);
        errdefer self.allocator.destroy(handle);
        handle.* = try FileHandle.init(self.allocator, file_path);
        self.file_handle = handle;
        try self.addDestination(.file);
    }

    pub fn setSyslogFacility(self: *Logger, facility: u8) !void {
        self.syslog_facility = facility;
        try self.addDestination(.syslog);
    }

    pub fn deinit(self: *Logger) void {
        self.destinations.deinit(self.allocator);
        if (self.file_handle) |handle| {
            handle.deinit();
            self.allocator.destroy(handle);
        }
    }

    pub fn fromEnvironment(allocator: std.mem.Allocator, environment: types.Environment) Logger {
        const min_level: LogLevel = switch (environment) {
            .development => .debug,
            .staging => .info,
            .production => .info,
        };

        const format: OutputFormat = switch (environment) {
            .development => .human,
            .staging => .human,
            .production => .json,
        };

        var logger = Logger{
            .allocator = allocator,
            .min_level = min_level,
            .format = format,
            .destinations = .{},
        };
        logger.destinations.append(allocator, .stdout) catch {};
        return logger;
    }

    pub fn setFormat(self: *Logger, format: OutputFormat) void {
        self.format = format;
    }

    pub fn log(self: *Logger, level: LogLevel, message: []const u8) !*LogEntry {
        if (level.toInt() < self.min_level.toInt()) {
            const empty_entry = try self.allocator.create(LogEntry);
            empty_entry.* = LogEntry{
                .level = level,
                .message = "",
                .timestamp = std.time.milliTimestamp(),
                .fields = std.StringHashMap([]const u8).init(self.allocator),
                .allocator = self.allocator,
                .logger = self,
            };
            return empty_entry;
        }

        const entry = try LogEntry.init(self.allocator, level, message);
        const entry_ptr = try self.allocator.create(LogEntry);
        entry_ptr.* = entry;
        entry_ptr.logger = self;
        return entry_ptr;
    }

    pub fn debug(self: *Logger, message: []const u8) !*LogEntry {
        return self.log(.debug, message);
    }

    pub fn info(self: *Logger, message: []const u8) !*LogEntry {
        return self.log(.info, message);
    }

    pub fn warn(self: *Logger, message: []const u8) !*LogEntry {
        return self.log(.warn, message);
    }

    pub fn logError(self: *Logger, message: []const u8) !*LogEntry {
        return self.log(.err, message);
    }

    pub fn fromRequest(self: *Logger, req: *Request, level: LogLevel, message: []const u8) !*LogEntry {
        var entry = try self.log(level, message);
        _ = try entry.withRequest(req);
        return entry;
    }

    pub fn logRequest(self: *Logger, req: *Request, level: LogLevel, message: []const u8) !void {
        var entry = try self.fromRequest(req, level, message);
        entry.log();
    }

    pub fn logResponse(self: *Logger, req: *Request, status_code: ?u16, level: LogLevel, message: []const u8) !void {
        var entry = try self.log(level, message);
        _ = try entry.withRequest(req);
        _ = try entry.withResponse(status_code, req);
        entry.log();
    }

    pub fn logErrorWithContext(self: *Logger, message: []const u8, err: anytype) !void {
        var entry = try self.logError(message);
        const err_name = @errorName(err);
        _ = try entry.field("error", err_name);
        entry.log();
    }

    pub fn debugf(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        if (LogLevel.debug.toInt() < self.min_level.toInt()) return;
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        const entry = LogEntry.initOwned(self.allocator, .debug, message) catch {
            self.allocator.free(message);
            return;
        };
        const entry_ptr = self.allocator.create(LogEntry) catch {
            self.allocator.free(message);
            return;
        };
        entry_ptr.* = entry;
        entry_ptr.logger = self;
        entry_ptr.log();
    }

    pub fn infof(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        if (LogLevel.info.toInt() < self.min_level.toInt()) return;
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        const entry = LogEntry.initOwned(self.allocator, .info, message) catch {
            self.allocator.free(message);
            return;
        };
        const entry_ptr = self.allocator.create(LogEntry) catch {
            self.allocator.free(message);
            return;
        };
        entry_ptr.* = entry;
        entry_ptr.logger = self;
        entry_ptr.log();
    }

    pub fn warnf(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        if (LogLevel.warn.toInt() < self.min_level.toInt()) return;
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        const entry = LogEntry.initOwned(self.allocator, .warn, message) catch {
            self.allocator.free(message);
            return;
        };
        const entry_ptr = self.allocator.create(LogEntry) catch {
            self.allocator.free(message);
            return;
        };
        entry_ptr.* = entry;
        entry_ptr.logger = self;
        entry_ptr.log();
    }

    pub fn errorf(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        const entry = LogEntry.initOwned(self.allocator, .err, message) catch {
            self.allocator.free(message);
            return;
        };
        const entry_ptr = self.allocator.create(LogEntry) catch {
            self.allocator.free(message);
            return;
        };
        entry_ptr.* = entry;
        entry_ptr.logger = self;
        entry_ptr.log();
    }

    pub fn debugMsg(self: *Logger, message: []const u8) void {
        if (LogLevel.debug.toInt() < self.min_level.toInt()) return;
        const entry = LogEntry.init(self.allocator, .debug, message) catch return;
        const entry_ptr = self.allocator.create(LogEntry) catch return;
        entry_ptr.* = entry;
        entry_ptr.logger = self;
        entry_ptr.log();
    }

    pub fn infoMsg(self: *Logger, message: []const u8) void {
        if (LogLevel.info.toInt() < self.min_level.toInt()) return;
        const entry = LogEntry.init(self.allocator, .info, message) catch return;
        const entry_ptr = self.allocator.create(LogEntry) catch return;
        entry_ptr.* = entry;
        entry_ptr.logger = self;
        entry_ptr.log();
    }

    pub fn warnMsg(self: *Logger, message: []const u8) void {
        if (LogLevel.warn.toInt() < self.min_level.toInt()) return;
        const entry = LogEntry.init(self.allocator, .warn, message) catch return;
        const entry_ptr = self.allocator.create(LogEntry) catch return;
        entry_ptr.* = entry;
        entry_ptr.logger = self;
        entry_ptr.log();
    }

    pub fn errorMsg(self: *Logger, message: []const u8) void {
        const entry = LogEntry.init(self.allocator, .err, message) catch return;
        const entry_ptr = self.allocator.create(LogEntry) catch return;
        entry_ptr.* = entry;
        entry_ptr.logger = self;
        entry_ptr.log();
    }

    pub fn infoWithFields(self: *Logger, message: []const u8, fields: anytype) void {
        if (LogLevel.info.toInt() < self.min_level.toInt()) return;
        const entry = LogEntry.init(self.allocator, .info, message) catch return;
        const entry_ptr = self.allocator.create(LogEntry) catch return;
        entry_ptr.* = entry;
        entry_ptr.logger = self;

        inline for (fields) |field_pair| {
            _ = entry_ptr.field(field_pair[0], field_pair[1]) catch {};
        }

        entry_ptr.log();
    }

    pub fn childLogger(self: *Logger, context_fields: struct {
        user_id: ?[]const u8 = null,
        request_id: ?[]const u8 = null,
        component: ?[]const u8 = null,
    }) Logger {
        _ = context_fields; // Reserved for future use
        var child = Logger{
            .allocator = self.allocator,
            .min_level = self.min_level,
            .format = self.format,
            .destinations = .{},
            .file_handle = self.file_handle,
            .syslog_facility = self.syslog_facility,
        };
        child.destinations.appendSlice(self.allocator, self.destinations.items) catch {};
        return child;
    }

    pub fn printEntry(self: *Logger, entry: *LogEntry) void {
        const formatted = switch (self.format) {
            .json => entry.toJson(self.allocator) catch return,
            .human => entry.toHumanReadable(self.allocator) catch return,
        };
        defer self.allocator.free(formatted);

        const formatted_with_newline = std.fmt.allocPrint(self.allocator, "{s}\n", .{formatted}) catch return;
        defer self.allocator.free(formatted_with_newline);

        for (self.destinations.items) |dest| {
            switch (dest) {
                .stdout => {
                    std.debug.print("{s}", .{formatted_with_newline});
                },
                .file => {
                    if (self.file_handle) |handle| {
                        handle.write(formatted_with_newline) catch {
                            continue;
                        };
                    }
                },
                .syslog => {
                    std.debug.print("[SYSLOG] {s}", .{formatted_with_newline});
                },
            }
        }
    }

    pub fn print(self: *Logger, entry: *LogEntry) void {
        self.printEntry(entry);
    }
};

test "RouteRegistry register and getAll" {
    var registry = RouteRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register("GET", "/api/todos", "handleGetTodos");
    try registry.register("POST", "/api/todos", "handleCreateTodo");

    const routes = registry.getAll();
    try std.testing.expectEqual(routes.len, 2);
    try std.testing.expectEqualStrings(routes[0].method, "GET");
    try std.testing.expectEqualStrings(routes[0].path, "/api/todos");
}

test "LogEntry init and toJson" {
    var entry = try LogEntry.init(std.testing.allocator, .info, "Test message");
    defer entry.deinit();

    _ = try entry.field("user_id", "123");
    _ = try entry.field("action", "login");

    const json = try entry.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "info") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Test message") != null);
}

test "Logger log levels" {
    var logger = Logger.init(std.testing.allocator, .info);
    defer logger.deinit();

    var debug_entry = try logger.debug("Debug message");
    defer {
        debug_entry.deinit();
        logger.allocator.destroy(debug_entry);
    }
    try std.testing.expectEqual(debug_entry.message.len, 0); // Below min level

    var info_entry = try logger.info("Info message");
    defer {
        info_entry.deinit();
        logger.allocator.destroy(info_entry);
    }
    try std.testing.expectEqualStrings(info_entry.message, "Info message");
}

test "RouteRegistry getByMethod filters correctly" {
    var registry = RouteRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register("GET", "/api/users", "getUsers");
    try registry.register("POST", "/api/users", "createUser");
    try registry.register("GET", "/api/posts", "getPosts");
    try registry.register("PUT", "/api/users", "updateUser");

    var get_routes = std.ArrayListUnmanaged(RouteInfo){};
    defer get_routes.deinit(std.testing.allocator);

    try registry.getByMethod("GET", &get_routes);

    try std.testing.expectEqual(get_routes.items.len, 2);
}

test "RouteRegistry toJson formats correctly" {
    var registry = RouteRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register("GET", "/api/todos", "handleTodos");
    try registry.register("POST", "/api/todos", "createTodo");

    const json = try registry.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "GET") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "POST") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "/api/todos") != null);
}

test "RouteRegistry empty registry" {
    var registry = RouteRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const routes = registry.getAll();
    try std.testing.expectEqual(routes.len, 0);

    const json = try registry.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "[]") != null);
}

test "LogEntry toJson with fields" {
    var entry = try LogEntry.init(std.testing.allocator, .info, "Test message");
    defer entry.deinit();

    _ = try entry.field("user_id", "123");
    _ = try entry.field("action", "login");

    const json = try entry.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "info") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Test message") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "user_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "action") != null);
}

test "LogEntry toJson without fields" {
    var entry = try LogEntry.init(std.testing.allocator, .warn, "Warning message");
    defer entry.deinit();

    const json = try entry.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "warn") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Warning message") != null);
}

test "Logger all log levels" {
    var logger = Logger.init(std.testing.allocator, .debug);
    defer logger.deinit();

    var debug_entry = try logger.debug("Debug");
    defer {
        debug_entry.deinit();
        logger.allocator.destroy(debug_entry);
    }
    try std.testing.expectEqualStrings(debug_entry.message, "Debug");

    var info_entry = try logger.info("Info");
    defer {
        info_entry.deinit();
        logger.allocator.destroy(info_entry);
    }
    try std.testing.expectEqualStrings(info_entry.message, "Info");

    var warn_entry = try logger.warn("Warn");
    defer {
        warn_entry.deinit();
        logger.allocator.destroy(warn_entry);
    }
    try std.testing.expectEqualStrings(warn_entry.message, "Warn");

    var error_entry = try logger.logError("Error");
    defer {
        error_entry.deinit();
        logger.allocator.destroy(error_entry);
    }
    try std.testing.expectEqualStrings(error_entry.message, "Error");
}

test "Logger min level filtering" {
    var logger = Logger.init(std.testing.allocator, .warn);
    defer logger.deinit();

    var debug_entry = try logger.debug("Debug");
    defer {
        debug_entry.deinit();
        logger.allocator.destroy(debug_entry);
    }
    try std.testing.expectEqual(debug_entry.message.len, 0);

    var info_entry = try logger.info("Info");
    defer {
        info_entry.deinit();
        logger.allocator.destroy(info_entry);
    }
    try std.testing.expectEqual(info_entry.message.len, 0);

    var warn_entry = try logger.warn("Warn");
    defer {
        warn_entry.deinit();
        logger.allocator.destroy(warn_entry);
    }
    try std.testing.expectEqualStrings(warn_entry.message, "Warn");

    var error_entry = try logger.logError("Error");
    defer {
        error_entry.deinit();
        logger.allocator.destroy(error_entry);
    }
    try std.testing.expectEqualStrings(error_entry.message, "Error");
}

test "LogEntry builder pattern chaining" {
    var logger = Logger.init(std.testing.allocator, .debug);
    defer logger.deinit();

    var entry = try logger.info("Test message");
    defer {
        entry.deinit();
        logger.allocator.destroy(entry);
    }

    _ = try entry.field("key1", "value1");
    _ = try entry.field("key2", "value2");
    _ = try entry.fieldInt("count", 42);
    _ = try entry.fieldBool("enabled", true);

    try std.testing.expectEqualStrings(entry.message, "Test message");
    try std.testing.expect(entry.fields.get("key1") != null);
    try std.testing.expect(entry.fields.get("key2") != null);
    try std.testing.expect(entry.fields.get("count") != null);
    try std.testing.expect(entry.fields.get("enabled") != null);
    try std.testing.expectEqualStrings(entry.fields.get("count").?, "42");
    try std.testing.expectEqualStrings(entry.fields.get("enabled").?, "true");
}

test "LogEntry JSON format" {
    var logger = Logger.init(std.testing.allocator, .info);
    defer logger.deinit();
    logger.setFormat(.json);

    var entry = try logger.info("Test message");
    defer {
        entry.deinit();
        logger.allocator.destroy(entry);
    }

    _ = try entry.field("user_id", "123");

    const json = try entry.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "info") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Test message") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "user_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "123") != null);
}

test "LogEntry human-readable format" {
    var logger = Logger.init(std.testing.allocator, .info);
    defer logger.deinit();
    logger.setFormat(.human);

    var entry = try logger.warn("Warning message");
    defer {
        entry.deinit();
        logger.allocator.destroy(entry);
    }

    _ = try entry.field("error_code", "500");

    const human = try entry.toHumanReadable(std.testing.allocator);
    defer std.testing.allocator.free(human);

    try std.testing.expect(std.mem.indexOf(u8, human, "WARN") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "Warning message") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "error_code=500") != null);
}

test "Logger fromEnvironment selects correct format" {
    var dev_logger = Logger.fromEnvironment(std.testing.allocator, .development);
    defer dev_logger.deinit();
    try std.testing.expectEqual(dev_logger.format, .human);
    try std.testing.expectEqual(dev_logger.min_level, .debug);

    var prod_logger = Logger.fromEnvironment(std.testing.allocator, .production);
    defer prod_logger.deinit();
    try std.testing.expectEqual(prod_logger.format, .json);
    try std.testing.expectEqual(prod_logger.min_level, .info);

    var staging_logger = Logger.fromEnvironment(std.testing.allocator, .staging);
    defer staging_logger.deinit();
    try std.testing.expectEqual(staging_logger.format, .human);
    try std.testing.expectEqual(staging_logger.min_level, .info);
}

test "LogEntry withRequest captures request context" {
    var logger = Logger.init(std.testing.allocator, .info);
    defer logger.deinit();

    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    try req.set("request_id", "test-req-123");

    var entry = try logger.fromRequest(&req, .info, "Request handled");
    defer {
        entry.deinit();
        logger.allocator.destroy(entry);
    }

    try std.testing.expect(entry.fields.get("request_id") != null);
    try std.testing.expect(entry.fields.get("method") != null);
    try std.testing.expect(entry.fields.get("path") != null);
    try std.testing.expectEqualStrings(entry.fields.get("request_id").?, "test-req-123");
    try std.testing.expectEqualStrings(entry.fields.get("method").?, "GET");
    try std.testing.expectEqualStrings(entry.fields.get("path").?, "/api/todos");
}
