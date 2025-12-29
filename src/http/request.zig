const std = @import("std");
const ziggurat = @import("ziggurat");
const router = @import("../routing/router.zig");
const parsers = @import("../data/parsers.zig");

var request_id_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub const Request = struct {
    const MAX_CONTEXT_ENTRIES = 16;
    const MAX_ROUTE_PARAMS = 8;

    inner: *ziggurat.request.Request,

    arena: std.heap.ArenaAllocator,

    _context_keys: [MAX_CONTEXT_ENTRIES]?[]const u8 = .{null} ** MAX_CONTEXT_ENTRIES,
    _context_values: [MAX_CONTEXT_ENTRIES]?[]const u8 = .{null} ** MAX_CONTEXT_ENTRIES,
    _context_count: usize = 0,

    _route_param_keys: [MAX_ROUTE_PARAMS]?[]const u8 = .{null} ** MAX_ROUTE_PARAMS,
    _route_param_values: [MAX_ROUTE_PARAMS]?[]const u8 = .{null} ** MAX_ROUTE_PARAMS,
    _route_param_count: usize = 0,

    _context_overflow: ?std.StringHashMap([]const u8) = null,

    _route_params_overflow: ?std.StringHashMap([]const u8) = null,

    context: std.StringHashMap([]const u8),

    route_params: std.StringHashMap([]const u8),

    _query_params: ?std.StringHashMap([]const u8) = null,

    pub fn path(self: *const Request) []const u8 {
        const full_path = self.inner.path;
        const query_start = std.mem.indexOfScalar(u8, full_path, '?') orelse return full_path;
        return full_path[0..query_start];
    }

    pub fn fullPath(self: *const Request) []const u8 {
        return self.inner.path;
    }

    pub fn method(self: *const Request) []const u8 {
        return @tagName(self.inner.method);
    }

    pub fn body(self: *const Request) []const u8 {
        return self.inner.body;
    }

    pub fn allocator(self: *Request) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return self.inner.headers.get(name);
    }

    pub fn isHtmx(self: *const Request) bool {
        return self.header("HX-Request") != null;
    }

    pub fn isHtmxBoosted(self: *const Request) bool {
        const value = self.header("HX-Boosted") orelse return false;
        return std.mem.eql(u8, value, "true");
    }

    pub fn isHtmxPartial(self: *const Request) bool {
        return self.isHtmx() and !self.isHtmxBoosted();
    }

    pub fn htmxTarget(self: *const Request) ?[]const u8 {
        return self.header("HX-Target");
    }

    pub fn htmxTrigger(self: *const Request) ?[]const u8 {
        return self.header("HX-Trigger");
    }

    pub fn htmxCurrentUrl(self: *const Request) ?[]const u8 {
        return self.header("HX-Current-URL");
    }

    pub fn htmxPrompt(self: *const Request) ?[]const u8 {
        return self.header("HX-Prompt");
    }

    pub fn getFormParser(self: *Request) @import("../htmx/form.zig").FormParser {
        const htmx_form = @import("../htmx/form.zig");
        return htmx_form.FormParser.init(self.body(), self.allocator());
    }

    pub fn queryParams(self: *Request) !std.StringHashMap([]const u8) {
        if (self._query_params) |*params| {
            return params.*;
        }

        const params = try parsers.QueryParser.parse(self.arena.allocator(), self.inner.path);
        self._query_params = params;
        return params;
    }

    pub fn query(self: *Request, name: []const u8) !?[]const u8 {
        if (name.len > 256) {
            return error.InvalidArgument;
        }
        const params = try self.queryParams();
        const value = params.get(name);
        if (value) |v| {
            if (v.len > 4096) {
                std.debug.print("[Request Warning] Query parameter '{s}' value exceeds maximum length (4096 bytes)\n", .{name});
                return null;
            }
        }
        return value;
    }

    pub fn queryOptional(self: *Request, name: []const u8) ?[]const u8 {
        const params = self.queryParams() catch return null;
        return params.get(name);
    }

    pub fn queryStrict(self: *Request, name: []const u8) (error{QueryParameterMissing} || std.mem.Allocator.Error)![]const u8 {
        const params = try self.queryParams();
        return params.get(name) orelse error.QueryParameterMissing;
    }

    pub fn queryParam(self: *Request, name: []const u8) !router.Param {
        const value = (try self.query(name)) orelse "";
        return router.Param{ .value = value };
    }

    pub fn queryParamTyped(self: *Request, comptime T: type, name: []const u8) !?T {
        const value = try self.query(name);
        if (value == null) return null;

        const param_wrapper = router.Param{ .value = value.? };

        return switch (@typeInfo(T)) {
            .int => |int_info| switch (int_info.signedness) {
                .signed => switch (int_info.bits) {
                    32 => @as(T, @intCast(try param_wrapper.asI32())),
                    64 => @as(T, @intCast(try param_wrapper.asI64())),
                    else => @compileError("Unsupported signed integer type for queryParamTyped. Supported: i32, i64"),
                },
                .unsigned => switch (int_info.bits) {
                    32 => @as(T, @intCast(try param_wrapper.asU32())),
                    64 => @as(T, @intCast(try param_wrapper.asU64())),
                    else => @compileError("Unsupported unsigned integer type for queryParamTyped. Supported: u32, u64"),
                },
            },
            .float => |float_info| switch (float_info.bits) {
                64 => @as(T, try param_wrapper.asF64()),
                else => @compileError("Unsupported float type for queryParamTyped. Supported: f64"),
            },
            .bool => blk: {
                const str = param_wrapper.asString();
                if (std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "1")) {
                    break :blk true;
                } else if (std.mem.eql(u8, str, "false") or std.mem.eql(u8, str, "0")) {
                    break :blk false;
                } else {
                    return error.InvalidArgument;
                }
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return param_wrapper.asString();
                } else {
                    @compileError("Unsupported pointer type for queryParamTyped. Supported: []const u8");
                }
            },
            else => @compileError("Unsupported type for queryParamTyped. Supported: u32, i32, u64, i64, f64, bool, []const u8"),
        };
    }

    pub fn jsonBody(self: *Request, comptime T: type) !T {
        const MAX_BODY_SIZE = 10 * 1024 * 1024;
        if (self.body().len > MAX_BODY_SIZE) {
            std.debug.print("[Request Error] JSON body exceeds maximum size ({d} bytes)\n", .{MAX_BODY_SIZE});
            return error.InvalidArgument;
        }
        return parsers.BodyParser.json(T, self.body(), self.arena.allocator());
    }

    pub fn parseJson(self: *Request, comptime T: type) !T {
        return self.jsonBody(T);
    }

    pub fn parseJsonOptional(self: *Request, comptime T: type) ?T {
        return self.jsonBody(T) catch null;
    }

    pub fn validateJson(self: *Request, comptime T: type, schema: *@import("../data/validation.zig").ValidationSchema) (error{ValidationFailed} || @TypeOf(self.jsonBody(T)).Error)!T {
        const parsed = try self.jsonBody(T);

        const validation_errors = try schema.validate();
        defer validation_errors.deinit();

        if (!validation_errors.isEmpty()) {
            return error.ValidationFailed;
        }

        return parsed;
    }

    pub fn formBody(self: *Request) !std.StringHashMap([]const u8) {
        const MAX_FORM_SIZE = 1024 * 1024;
        if (self.body().len > MAX_FORM_SIZE) {
            std.debug.print("[Request Error] Form body exceeds maximum size ({d} bytes)\n", .{MAX_FORM_SIZE});
            return error.InvalidArgument;
        }
        return parsers.BodyParser.formData(self.arena.allocator(), self.body());
    }

    pub fn param(self: *const Request, name: []const u8) router.Param {
        for (0..self._route_param_count) |i| {
            if (self._route_param_keys[i]) |existing_key| {
                if (std.mem.eql(u8, existing_key, name)) {
                    const value = self._route_param_values[i] orelse "";
                    if (value.len > 1024) {
                        std.debug.print("[Request Warning] Route parameter '{s}' value exceeds maximum length (1024 bytes)\n", .{name});
                        return router.Param{ .value = "" };
                    }
                    return router.Param{ .value = value };
                }
            }
        }

        if (self._route_params_overflow) |overflow| {
            if (overflow.get(name)) |value| {
                if (value.len > 1024) {
                    std.debug.print("[Request Warning] Route parameter '{s}' value exceeds maximum length (1024 bytes)\n", .{name});
                    return router.Param{ .value = "" };
                }
                return router.Param{ .value = value };
            }
        }

        const value = self.route_params.get(name) orelse "";
        if (value.len > 1024) {
            std.debug.print("[Request Warning] Route parameter '{s}' value exceeds maximum length (1024 bytes)\n", .{name});
            return router.Param{ .value = "" };
        }
        return router.Param{ .value = value };
    }

    pub fn paramTyped(self: *const Request, comptime T: type, name: []const u8) !T {
        var value: ?[]const u8 = null;

        for (0..self._route_param_count) |i| {
            if (self._route_param_keys[i]) |existing_key| {
                if (std.mem.eql(u8, existing_key, name)) {
                    value = self._route_param_values[i];
                    break;
                }
            }
        }

        if (value == null) {
            if (self._route_params_overflow) |overflow| {
                value = overflow.get(name);
            }
        }

        if (value == null) {
            value = self.route_params.get(name);
        }

        const actual_value = value orelse return error.InvalidArgument;

        if (actual_value.len > 1024) {
            std.debug.print("[Request Warning] Route parameter '{s}' value exceeds maximum length (1024 bytes)\n", .{name});
            return error.InvalidArgument;
        }

        const param_wrapper = router.Param{ .value = actual_value };

        return switch (@typeInfo(T)) {
            .int => |int_info| switch (int_info.signedness) {
                .signed => switch (int_info.bits) {
                    32 => @as(T, @intCast(try param_wrapper.asI32())),
                    64 => @as(T, @intCast(try param_wrapper.asI64())),
                    else => @compileError("Unsupported signed integer type for paramTyped. Supported: i32, i64"),
                },
                .unsigned => switch (int_info.bits) {
                    32 => @as(T, @intCast(try param_wrapper.asU32())),
                    64 => @as(T, @intCast(try param_wrapper.asU64())),
                    else => @compileError("Unsupported unsigned integer type for paramTyped. Supported: u32, u64"),
                },
            },
            .float => |float_info| switch (float_info.bits) {
                64 => @as(T, try param_wrapper.asF64()),
                else => @compileError("Unsupported float type for paramTyped. Supported: f64"),
            },
            .bool => blk: {
                const str = param_wrapper.asString();
                if (std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "1")) {
                    break :blk true;
                } else if (std.mem.eql(u8, str, "false") or std.mem.eql(u8, str, "0")) {
                    break :blk false;
                } else {
                    return error.InvalidArgument;
                }
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return param_wrapper.asString();
                } else {
                    @compileError("Unsupported pointer type for paramTyped. Supported: []const u8");
                }
            },
            else => @compileError("Unsupported type for paramTyped. Supported: u32, i32, u64, i64, f64, bool, []const u8"),
        };
    }

    pub fn set(self: *Request, key: []const u8, value: []const u8) !void {
        const key_dup = try self.arena.allocator().dupe(u8, key);
        const value_dup = try self.arena.allocator().dupe(u8, value);

        for (0..self._context_count) |i| {
            if (self._context_keys[i]) |existing_key| {
                if (std.mem.eql(u8, existing_key, key_dup)) {
                    self._context_values[i] = value_dup;
                    return;
                }
            }
        }

        if (self._context_count < MAX_CONTEXT_ENTRIES) {
            self._context_keys[self._context_count] = key_dup;
            self._context_values[self._context_count] = value_dup;
            self._context_count += 1;
            return;
        }

        if (self._context_overflow == null) {
            self._context_overflow = std.StringHashMap([]const u8).init(self.arena.allocator());
        }
        try self._context_overflow.?.put(key_dup, value_dup);

        try self.context.put(key_dup, value_dup);
    }

    pub fn get(self: *const Request, key: []const u8) ?[]const u8 {
        for (0..self._context_count) |i| {
            if (self._context_keys[i]) |existing_key| {
                if (std.mem.eql(u8, existing_key, key)) {
                    return self._context_values[i];
                }
            }
        }

        if (self._context_overflow) |overflow| {
            if (overflow.get(key)) |value| {
                return value;
            }
        }

        return self.context.get(key);
    }

    pub fn setTyped(self: *Request, comptime T: type, ptr: *T) !void {
        const key = comptime typeName(T);
        const addr = @intFromPtr(ptr);
        var buf: [20]u8 = undefined;
        const addr_str = std.fmt.bufPrint(&buf, "{d}", .{addr}) catch return error.OutOfMemory;
        try self.set(key, addr_str);
    }

    pub fn getTyped(self: *const Request, comptime T: type) ?*T {
        const key = comptime typeName(T);
        if (self.get(key)) |addr_str| {
            const addr = std.fmt.parseInt(usize, addr_str, 10) catch return null;
            if (addr == 0) return null;
            return @as(*T, @ptrFromInt(addr));
        }
        return null;
    }

    pub fn getTypedConst(self: *const Request, comptime T: type) ?*const T {
        if (self.getTyped(T)) |ptr| {
            return ptr;
        }
        return null;
    }

    pub fn setTypedValue(self: *Request, comptime T: type, value: T) !void {
        const ptr = try self.arena.allocator().create(T);
        ptr.* = value;
        try self.setTyped(T, ptr);
    }

    pub fn getTypedValue(self: *const Request, comptime T: type) ?T {
        if (self.getTyped(T)) |ptr| {
            return ptr.*;
        }
        return null;
    }

    fn typeName(comptime T: type) []const u8 {
        return "__typed_" ++ @typeName(T);
    }

    pub fn setRouteParams(self: *Request, params: std.StringHashMap([]const u8)) !void {
        self._route_param_count = 0;
        for (0..MAX_ROUTE_PARAMS) |i| {
            self._route_param_keys[i] = null;
            self._route_param_values[i] = null;
        }

        if (self._route_params_overflow) |*overflow| {
            overflow.deinit();
            self._route_params_overflow = null;
        }

        self.route_params.deinit();
        self.route_params = std.StringHashMap([]const u8).init(std.heap.page_allocator);

        var it = params.iterator();
        while (it.next()) |entry| {
            const key_dup = try self.arena.allocator().dupe(u8, entry.key_ptr.*);
            const value_dup = try self.arena.allocator().dupe(u8, entry.value_ptr.*);

            if (self._route_param_count < MAX_ROUTE_PARAMS) {
                self._route_param_keys[self._route_param_count] = key_dup;
                self._route_param_values[self._route_param_count] = value_dup;
                self._route_param_count += 1;
            } else {
                if (self._route_params_overflow == null) {
                    self._route_params_overflow = std.StringHashMap([]const u8).init(self.arena.allocator());
                }
                try self._route_params_overflow.?.put(key_dup, value_dup);
            }

            try self.route_params.put(key_dup, value_dup);
        }
    }

    pub fn fromZiggurat(ziggurat_request: *ziggurat.request.Request, backing_allocator: std.mem.Allocator) Request {
        const arena = std.heap.ArenaAllocator.init(backing_allocator);

        const context = std.StringHashMap([]const u8).init(std.heap.page_allocator);
        const route_params = std.StringHashMap([]const u8).init(std.heap.page_allocator);

        var request = Request{
            .inner = ziggurat_request,
            .arena = arena,
            .context = context,
            .route_params = route_params,
            ._query_params = null,
        };

        const request_id = request.generateRequestId() catch "";
        if (request_id.len > 0) {
            request.set("request_id", request_id) catch {};
        }

        return request;
    }

    fn generateRequestId(self: *Request) ![]const u8 {
        const id = request_id_counter.fetchAdd(1, .monotonic);

        var buffer: [16]u8 = undefined;
        const result = std.fmt.bufPrint(&buffer, "{x}", .{id}) catch return error.OutOfMemory;

        return try self.arena.allocator().dupe(u8, result);
    }

    pub fn requestId(self: *const Request) ?[]const u8 {
        return self.get("request_id");
    }

    pub fn cache(self: *Request) ?*@import("../data/cache.zig").ResponseCache {
        _ = self;
        if (@import("../engine12.zig").global_context) |ctx| {
            return ctx.cache;
        }
        return null;
    }

    pub fn cacheGet(self: *Request, key: []const u8) !?*@import("../data/cache.zig").CacheEntry {
        const cache_instance = self.cache() orelse return null;
        return cache_instance.get(key);
    }

    pub fn cacheSet(self: *Request, key: []const u8, cache_body: []const u8, ttl_ms: ?u64, content_type: []const u8) !void {
        const cache_instance = self.cache() orelse return;
        try cache_instance.set(key, cache_body, ttl_ms, content_type);
    }

    pub fn cacheInvalidate(self: *Request, key: []const u8) void {
        const cache_instance = self.cache() orelse return;
        cache_instance.invalidate(key);
    }

    pub fn cacheInvalidatePrefix(self: *Request, prefix: []const u8) void {
        const cache_instance = self.cache() orelse return;
        cache_instance.invalidatePrefix(prefix);
    }

    pub fn deinit(self: *Request) void {
        if (self._context_overflow) |*overflow| {
            overflow.deinit();
        }
        if (self._route_params_overflow) |*overflow| {
            overflow.deinit();
        }

        self.context.deinit();
        self.route_params.deinit();
        if (self._query_params) |*params| {
            params.deinit();
        }
        self.arena.deinit();
    }
};

fn createTestZigguratRequest(path: []const u8, method: ziggurat.request.Method, body: []const u8) ziggurat.request.Request {
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    return ziggurat.request.Request{
        .path = path,
        .method = method,
        .body = body,
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
}

test "Request path access" {
    var ziggurat_req = createTestZigguratRequest("/api/test", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    try std.testing.expectEqualStrings(req.path(), "/api/test");
}

test "Request method access" {
    var ziggurat_req = createTestZigguratRequest("/api/test", .POST, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    try std.testing.expectEqualStrings(req.method(), "POST");
}

test "Request body access" {
    var ziggurat_req = createTestZigguratRequest("/api/test", .POST, "{\"test\":\"data\"}");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    try std.testing.expectEqualStrings(req.body(), "{\"test\":\"data\"}");
}

test "Request allocator provides arena" {
    var ziggurat_req = createTestZigguratRequest("/api/test", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const allocator = req.allocator();
    const data = try allocator.dupe(u8, "test string");
    try std.testing.expectEqualStrings(data, "test string");
}

test "Request context set and get" {
    var ziggurat_req = createTestZigguratRequest("/api/test", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    try req.set("user_id", "12345");
    const user_id = req.get("user_id");
    try std.testing.expect(user_id != null);
    try std.testing.expectEqualStrings(user_id.?, "12345");

    const missing = req.get("nonexistent");
    try std.testing.expect(missing == null);
}

test "Request param extraction" {
    var ziggurat_req = createTestZigguratRequest("/api/todos/123", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const id_value = try req.arena.allocator().dupe(u8, "123");
    try params.put("id", id_value);
    try req.setRouteParams(params);

    const id = try req.param("id").asU32();
    try std.testing.expectEqual(id, 123);

    const missing = req.param("nonexistent").asString();
    try std.testing.expectEqualStrings(missing, "");
}

test "Request query parsing" {
    var ziggurat_req = createTestZigguratRequest("/api/todos?limit=10&offset=20", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const limit = try req.query("limit");
    try std.testing.expect(limit != null);
    try std.testing.expectEqualStrings(limit.?, "10");

    const offset = try req.query("offset");
    try std.testing.expect(offset != null);
    try std.testing.expectEqualStrings(offset.?, "20");

    try std.testing.expectEqualStrings(req.path(), "/api/todos");
}

test "Request form body parsing" {
    var ziggurat_req = createTestZigguratRequest("/api/todos", .POST, "title=Hello&completed=true");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const form = try req.formBody();
    const title = form.get("title");
    try std.testing.expect(title != null);
    try std.testing.expectEqualStrings(title.?, "Hello");

    const completed = form.get("completed");
    try std.testing.expect(completed != null);
    try std.testing.expectEqualStrings(completed.?, "true");
}

test "Request path with query string extraction" {
    var ziggurat_req = createTestZigguratRequest("/api/todos?limit=10&offset=20&sort=asc", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    try std.testing.expectEqualStrings(req.path(), "/api/todos");
    try std.testing.expectEqualStrings(req.fullPath(), "/api/todos?limit=10&offset=20&sort=asc");
}

test "Request path without query string" {
    var ziggurat_req = createTestZigguratRequest("/api/todos", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    try std.testing.expectEqualStrings(req.path(), "/api/todos");
    try std.testing.expectEqualStrings(req.fullPath(), "/api/todos");
}

test "Request empty path" {
    var ziggurat_req = createTestZigguratRequest("", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    try std.testing.expectEqualStrings(req.path(), "");
    try std.testing.expectEqualStrings(req.method(), "GET");
}

test "Request query parsing with empty values" {
    var ziggurat_req = createTestZigguratRequest("/api/test?key1=&key2=value&key3=", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const key1 = try req.query("key1");
    try std.testing.expect(key1 != null);
    try std.testing.expectEqualStrings(key1.?, "");

    const key2 = try req.query("key2");
    try std.testing.expect(key2 != null);
    try std.testing.expectEqualStrings(key2.?, "value");

    const key3 = try req.query("key3");
    try std.testing.expect(key3 != null);
    try std.testing.expectEqualStrings(key3.?, "");
}

test "Request query parsing with missing parameter" {
    var ziggurat_req = createTestZigguratRequest("/api/test?key1=value1", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const missing = try req.query("nonexistent");
    try std.testing.expect(missing == null);
}

test "Request query parsing with URL encoded values" {
    var ziggurat_req = createTestZigguratRequest("/api/test?q=hello%20world&tag=test%2Bvalue", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const q = try req.query("q");
    try std.testing.expect(q != null);
    try std.testing.expectEqualStrings(q.?, "hello world");

    const tag = try req.query("tag");
    try std.testing.expect(tag != null);
    try std.testing.expectEqualStrings(tag.?, "test+value");
}

test "Request queryParam with default value" {
    var ziggurat_req = createTestZigguratRequest("/api/test?limit=50", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const limit = try req.queryParam("limit");
    const limit_u32 = limit.asU32Default(10);
    try std.testing.expectEqual(limit_u32, 50);

    const missing_limit = try req.queryParam("nonexistent");
    const default_limit = missing_limit.asU32Default(10);
    try std.testing.expectEqual(default_limit, 10);
}

test "Request queryParams caching" {
    var ziggurat_req = createTestZigguratRequest("/api/test?key=value", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const params1 = try req.queryParams();
    const params2 = try req.queryParams();

    try std.testing.expectEqual(params1.count(), params2.count());
    try std.testing.expectEqualStrings(params1.get("key").?, params2.get("key").?);
}

test "Request form body parsing with empty values" {
    var ziggurat_req = createTestZigguratRequest("/api/test", .POST, "key1=&key2=value&key3=");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const form = try req.formBody();
    const key1 = form.get("key1");
    try std.testing.expect(key1 != null);
    try std.testing.expectEqualStrings(key1.?, "");

    const key2 = form.get("key2");
    try std.testing.expect(key2 != null);
    try std.testing.expectEqualStrings(key2.?, "value");
}

test "Request form body parsing with URL encoded values" {
    var ziggurat_req = createTestZigguratRequest("/api/test", .POST, "name=John%20Doe&email=test%40example.com");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const form = try req.formBody();
    const name = form.get("name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings(name.?, "John Doe");

    const email = form.get("email");
    try std.testing.expect(email != null);
    try std.testing.expectEqualStrings(email.?, "test@example.com");
}

test "Request empty form body" {
    var ziggurat_req = createTestZigguratRequest("/api/test", .POST, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const form = try req.formBody();
    try std.testing.expectEqual(form.count(), 0);
}

test "Request param with empty value" {
    var ziggurat_req = createTestZigguratRequest("/api/todos/", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const empty_value = try req.arena.allocator().dupe(u8, "");
    try params.put("id", empty_value);
    try req.setRouteParams(params);

    const id = req.param("id").asString();
    try std.testing.expectEqualStrings(id, "");
}

test "Request param with missing parameter" {
    var ziggurat_req = createTestZigguratRequest("/api/todos", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const missing = req.param("nonexistent").asString();
    try std.testing.expectEqualStrings(missing, "");
}

test "Request param type conversions" {
    var ziggurat_req = createTestZigguratRequest("/api/todos/123", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const id_value = try req.arena.allocator().dupe(u8, "123");
    try params.put("id", id_value);
    try req.setRouteParams(params);

    const id_u32 = try req.param("id").asU32();
    try std.testing.expectEqual(id_u32, 123);

    const id_i32 = try req.param("id").asI32();
    try std.testing.expectEqual(id_i32, 123);

    const id_u64 = try req.param("id").asU64();
    try std.testing.expectEqual(id_u64, 123);
}

test "Request param invalid number conversion" {
    var ziggurat_req = createTestZigguratRequest("/api/todos/abc", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const id_value = try req.arena.allocator().dupe(u8, "abc");
    try params.put("id", id_value);
    try req.setRouteParams(params);

    const id_u32 = req.param("id").asU32Default(999);
    try std.testing.expectEqual(id_u32, 999);

    const id_i32 = req.param("id").asI32Default(-1);
    try std.testing.expectEqual(id_i32, -1);
}

test "Request param negative number" {
    var ziggurat_req = createTestZigguratRequest("/api/todos/-5", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const id_value = try req.arena.allocator().dupe(u8, "-5");
    try params.put("id", id_value);
    try req.setRouteParams(params);

    const id_i32 = try req.param("id").asI32();
    try std.testing.expectEqual(id_i32, -5);

    const id_u32 = req.param("id").asU32Default(0);
    try std.testing.expectEqual(id_u32, 0);
}

test "Request param float conversion" {
    var ziggurat_req = createTestZigguratRequest("/api/todos/3.14", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const value = try req.arena.allocator().dupe(u8, "3.14");
    try params.put("value", value);
    try req.setRouteParams(params);

    const float_value = try req.param("value").asF64();
    try std.testing.expect(float_value > 3.13 and float_value < 3.15);
}

test "Request setRouteParams replaces existing params" {
    var ziggurat_req = createTestZigguratRequest("/api/todos/123", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    var params1 = std.StringHashMap([]const u8).init(req.arena.allocator());
    const id1 = try req.arena.allocator().dupe(u8, "123");
    try params1.put("id", id1);
    try req.setRouteParams(params1);

    var params2 = std.StringHashMap([]const u8).init(req.arena.allocator());
    const id2 = try req.arena.allocator().dupe(u8, "456");
    try params2.put("id", id2);
    try req.setRouteParams(params2);

    const id = req.param("id").asString();
    try std.testing.expectEqualStrings(id, "456");
}

test "Request context multiple values" {
    var ziggurat_req = createTestZigguratRequest("/api/test", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    try req.set("user_id", "12345");
    try req.set("role", "admin");
    try req.set("session_id", "abc123");

    try std.testing.expectEqualStrings(req.get("user_id").?, "12345");
    try std.testing.expectEqualStrings(req.get("role").?, "admin");
    try std.testing.expectEqualStrings(req.get("session_id").?, "abc123");

    const missing = req.get("nonexistent");
    try std.testing.expect(missing == null);
}

test "Request cache access methods" {
    var ziggurat_req = createTestZigguratRequest("/api/test", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    var response_cache = @import("../data/cache.zig").ResponseCache.init(std.testing.allocator, 60000);
    defer response_cache.deinit();

    // Create a test context
    const EngineContext = @import("../context.zig").EngineContext;
    var test_metrics = @import("../observability/metrics.zig").MetricsCollector.init(std.testing.allocator);
    var test_logger = @import("../observability/dev_tools.zig").Logger.init(std.testing.allocator, .debug);
    defer test_logger.deinit();
    var test_error_handler = @import("../error_handler.zig").ErrorHandlerRegistry.init(std.testing.allocator);
    var test_runtime_routes = @import("../valve/runtime_routes.zig").RuntimeRouteRegistry.init(std.testing.allocator);
    defer test_runtime_routes.deinit();
    var test_tracker = @import("../utils/shutdown.zig").ActiveRequestTracker.init();
    const test_mw = @import("../middleware/middleware.zig").MiddlewareChain.init();

    var test_ctx = EngineContext{
        .middleware = &test_mw,
        .metrics = &test_metrics,
        .rate_limiter = null,
        .cache = &response_cache,
        .logger = &test_logger,
        .error_handler = &test_error_handler,
        .runtime_routes = &test_runtime_routes,
        .active_request_tracker = &test_tracker,
        .limits = @import("../config/module.zig").LimitsConfig{},
    };

    @import("../engine12.zig").global_context = &test_ctx;
    defer @import("../engine12.zig").global_context = null;

    const cache_instance = req.cache();
    try std.testing.expect(cache_instance != null);

    try req.cacheSet("test_key", "test_value", null, "text/plain");

    const entry = try req.cacheGet("test_key");
    try std.testing.expect(entry != null);
    if (entry) |e| {
        try std.testing.expectEqualStrings(e.body, "test_value");
        try std.testing.expectEqualStrings(e.content_type, "text/plain");
    }

    req.cacheInvalidate("test_key");
    const entry_after_invalidate = try req.cacheGet("test_key");
    try std.testing.expect(entry_after_invalidate == null);
}

test "Request cache methods return null when cache not configured" {
    var ziggurat_req = createTestZigguratRequest("/api/test", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    @import("../engine12.zig").global_context = null;

    const cache_instance = req.cache();
    try std.testing.expect(cache_instance == null);

    const entry = try req.cacheGet("test_key");
    try std.testing.expect(entry == null);

    try req.cacheSet("test_key", "test_value", null, "text/plain");

    req.cacheInvalidate("test_key");
}

test "Request context overwrite value" {
    var ziggurat_req = createTestZigguratRequest("/api/test", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    try req.set("key", "value1");
    try std.testing.expectEqualStrings(req.get("key").?, "value1");

    try req.set("key", "value2");
    try std.testing.expectEqualStrings(req.get("key").?, "value2");
}

test "Request empty body" {
    var ziggurat_req = createTestZigguratRequest("/api/test", .POST, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    try std.testing.expectEqualStrings(req.body(), "");
}

test "Request all HTTP methods" {
    const methods = [_]ziggurat.request.Method{ .GET, .POST, .PUT, .DELETE, .PATCH, .HEAD, .OPTIONS };

    for (methods) |method| {
        var ziggurat_req = createTestZigguratRequest("/api/test", method, "");
        var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
        defer req.deinit();

        const method_str = req.method();
        try std.testing.expect(method_str.len > 0);
    }
}

test "Request queryParamTyped with u32" {
    var ziggurat_req = createTestZigguratRequest("/api/test?page=5&limit=20", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const page = try req.queryParamTyped(u32, "page");
    try std.testing.expect(page != null);
    try std.testing.expectEqual(page.?, 5);

    const limit = try req.queryParamTyped(u32, "limit");
    try std.testing.expect(limit != null);
    try std.testing.expectEqual(limit.?, 20);

    const missing = try req.queryParamTyped(u32, "missing");
    try std.testing.expect(missing == null);
}

test "Request queryParamTyped with bool" {
    var ziggurat_req = createTestZigguratRequest("/api/test?enabled=true&disabled=false", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    const enabled = try req.queryParamTyped(bool, "enabled");
    try std.testing.expect(enabled != null);
    try std.testing.expect(enabled.? == true);

    const disabled = try req.queryParamTyped(bool, "disabled");
    try std.testing.expect(disabled != null);
    try std.testing.expect(disabled.? == false);
}

test "Request paramTyped with i64" {
    var ziggurat_req = createTestZigguratRequest("/api/todos/123", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const id_value = try req.arena.allocator().dupe(u8, "123");
    try params.put("id", id_value);
    try req.setRouteParams(params);

    const id = try req.paramTyped(i64, "id");
    try std.testing.expectEqual(id, 123);
}

test "Request paramTyped with string" {
    var ziggurat_req = createTestZigguratRequest("/api/posts/my-slug", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    var params = std.StringHashMap([]const u8).init(req.arena.allocator());
    const slug_value = try req.arena.allocator().dupe(u8, "my-slug");
    try params.put("slug", slug_value);
    try req.setRouteParams(params);

    const slug = try req.paramTyped([]const u8, "slug");
    try std.testing.expectEqualStrings(slug, "my-slug");
}

test "Request paramTyped missing parameter" {
    var ziggurat_req = createTestZigguratRequest("/api/todos", .GET, "");
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();

    try std.testing.expectError(error.InvalidArgument, req.paramTyped(i64, "id"));
}
