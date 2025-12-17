const std = @import("std");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const router = @import("../router.zig");
const types = @import("../types.zig");

pub const RouteTrieNode = struct {
    children: std.AutoHashMap(u8, *RouteTrieNode),
    param_child: ?*RouteTrieNode = null,
    param_name: ?[]const u8 = null,
    routes: std.StringHashMap(*RuntimeRoute), // Keyed by HTTP method
    segment: []const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, segment: []const u8) !*Self {
        const node = try allocator.create(Self);
        node.* = Self{
            .children = std.AutoHashMap(u8, *RouteTrieNode).init(allocator),
            .param_child = null,
            .param_name = null,
            .routes = std.StringHashMap(*RuntimeRoute).init(allocator),
            .segment = try allocator.dupe(u8, segment),
            .allocator = allocator,
        };
        return node;
    }

    pub fn deinit(self: *Self) void {
        var child_iter = self.children.valueIterator();
        while (child_iter.next()) |child_ptr| {
            child_ptr.*.deinit();
        }
        self.children.deinit();

        if (self.param_child) |param_child| {
            param_child.deinit();
        }

        if (self.param_name) |name| {
            self.allocator.free(name);
        }

        self.routes.deinit();

        self.allocator.free(self.segment);

        self.allocator.destroy(self);
    }

    pub fn insert(self: *Self, path: []const u8, method: []const u8, route: *RuntimeRoute) !void {
        var current: *Self = self;
        var remaining = path;

        if (remaining.len > 0 and remaining[0] == '/') {
            remaining = remaining[1..];
        }

        while (remaining.len > 0) {
            const segment_end = std.mem.indexOfScalar(u8, remaining, '/') orelse remaining.len;
            const segment = remaining[0..segment_end];

            if (segment.len == 0) {
                remaining = if (segment_end < remaining.len) remaining[segment_end + 1 ..] else "";
                continue;
            }

            if (segment[0] == ':') {
                if (current.param_child == null) {
                    current.param_child = try RouteTrieNode.init(current.allocator, segment);
                    current.param_child.?.param_name = try current.allocator.dupe(u8, segment[1..]);
                }
                current = current.param_child.?;
            } else {
                const first_char = segment[0];
                if (current.children.get(first_char)) |child| {
                    if (std.mem.eql(u8, child.segment, segment)) {
                        current = child;
                    } else {
                        const new_child = try RouteTrieNode.init(current.allocator, segment);
                        try current.children.put(first_char, new_child);
                        current = new_child;
                    }
                } else {
                    const new_child = try RouteTrieNode.init(current.allocator, segment);
                    try current.children.put(first_char, new_child);
                    current = new_child;
                }
            }

            remaining = if (segment_end < remaining.len) remaining[segment_end + 1 ..] else "";
        }

        try current.routes.put(method, route);
    }

    pub fn match(
        self: *Self,
        path: []const u8,
        method: []const u8,
        params: *std.StringHashMap([]const u8),
        allocator: std.mem.Allocator,
    ) !?*RuntimeRoute {
        var current: *Self = self;
        var remaining = path;

        if (remaining.len > 0 and remaining[0] == '/') {
            remaining = remaining[1..];
        }

        while (remaining.len > 0) {
            const segment_end = std.mem.indexOfScalar(u8, remaining, '/') orelse remaining.len;
            const segment = remaining[0..segment_end];

            if (segment.len == 0) {
                remaining = if (segment_end < remaining.len) remaining[segment_end + 1 ..] else "";
                continue;
            }

            const first_char = segment[0];
            if (current.children.get(first_char)) |child| {
                if (std.mem.eql(u8, child.segment, segment)) {
                    current = child;
                    remaining = if (segment_end < remaining.len) remaining[segment_end + 1 ..] else "";
                    continue;
                }
            }

            if (current.param_child) |param_child| {
                if (param_child.param_name) |param_name| {
                    const value_copy = try allocator.dupe(u8, segment);
                    try params.put(param_name, value_copy);
                }
                current = param_child;
                remaining = if (segment_end < remaining.len) remaining[segment_end + 1 ..] else "";
                continue;
            }

            return null;
        }

        return current.routes.get(method);
    }
};

pub const RuntimeRoute = struct {
    method: []const u8,
    path_pattern: []const u8,
    pattern: router.RoutePattern,
    handler: *const fn (*Request) Response,
    valve_name: []const u8,

    pub fn deinit(self: *RuntimeRoute, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.path_pattern);
        var mutable_pattern = self.pattern;
        mutable_pattern.deinit(allocator);
        allocator.free(self.valve_name);
    }
};

pub const RuntimeRouteRegistry = struct {
    routes: std.StringHashMap(RuntimeRoute),
    trie_root: ?*RouteTrieNode = null,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .routes = std.StringHashMap(RuntimeRoute).init(allocator),
            .trie_root = null,
            .mutex = .{},
            .allocator = allocator,
        };
    }

    fn makeKey(allocator: std.mem.Allocator, method: []const u8, path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ method, path });
    }

    pub fn register(
        self: *Self,
        method: []const u8,
        path: []const u8,
        handler: *const fn (*Request) Response,
        valve_name: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var pattern = try router.RoutePattern.parse(self.allocator, path);
        errdefer pattern.deinit(self.allocator);

        const key = try makeKey(self.allocator, method, path);
        errdefer self.allocator.free(key);

        if (self.routes.contains(key)) {
            return error.RouteAlreadyExists;
        }

        const method_copy = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(method_copy);

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        const valve_name_copy = try self.allocator.dupe(u8, valve_name);
        errdefer self.allocator.free(valve_name_copy);

        try self.routes.put(key, RuntimeRoute{
            .method = method_copy,
            .path_pattern = path_copy,
            .pattern = pattern,
            .handler = handler,
            .valve_name = valve_name_copy,
        });

        if (self.trie_root == null) {
            self.trie_root = try RouteTrieNode.init(self.allocator, "");
        }

        const route_ptr = self.routes.getPtr(key).?;
        try self.trie_root.?.insert(path, method, route_ptr);
    }

    pub fn findRoute(
        self: *Self,
        method: []const u8,
        path: []const u8,
        request: *Request,
    ) !?*RuntimeRoute {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.trie_root) |trie| {
            var params = std.StringHashMap([]const u8).init(request.arena.allocator());
            if (try trie.match(path, method, &params, request.arena.allocator())) |route| {
                var param_iter = params.iterator();
                while (param_iter.next()) |*param_entry| {
                    try request.route_params.put(param_entry.key_ptr.*, param_entry.value_ptr.*);
                }
                return route;
            }
        }

        var iterator = self.routes.iterator();
        while (iterator.next()) |*entry| {
            const route = entry.value_ptr;

            if (!std.mem.eql(u8, route.method, method)) continue;

            if (std.mem.eql(u8, route.path_pattern, path)) {
                return route;
            }

            var mutable_pattern = route.pattern;
            if (try mutable_pattern.match(request.arena.allocator(), path)) |params| {
                var param_iter = params.iterator();
                while (param_iter.next()) |*param_entry| {
                    try request.route_params.put(param_entry.key_ptr.*, param_entry.value_ptr.*);
                }
                return route;
            }
        }

        return null;
    }

    pub fn unregister(self: *Self, method: []const u8, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try makeKey(self.allocator, method, path);
        defer self.allocator.free(key);

        if (self.routes.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            var mutable_value = entry.value;
            mutable_value.deinit(self.allocator);
        } else {
            return error.RouteNotFound;
        }
    }

    pub fn getValveRoutes(self: *Self, valve_name: []const u8, allocator: std.mem.Allocator) ![]RuntimeRoute {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayListUnmanaged(RuntimeRoute){};
        var iterator = self.routes.iterator();
        while (iterator.next()) |*entry| {
            if (std.mem.eql(u8, entry.value_ptr.*.valve_name, valve_name)) {
                try result.append(allocator, entry.value_ptr.*);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.trie_root) |trie| {
            trie.deinit();
        }

        var iterator = self.routes.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.routes.deinit();
    }
};

test "RuntimeRouteRegistry init and deinit" {
    var registry = RuntimeRouteRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try std.testing.expectEqual(registry.routes.count(), 0);
}

test "RuntimeRouteRegistry register and find exact match" {
    var registry = RuntimeRouteRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const handler = struct {
        fn handle(_: *Request) Response {
            return Response.text("test");
        }
    }.handle;

    try registry.register("GET", "/test", &handler, "test_valve");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var route_params = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer route_params.deinit();

    var req = Request{
        .inner = undefined, // Not used in findRoute
        .arena = arena,
        .context = std.StringHashMap([]const u8).init(std.testing.allocator),
        .route_params = route_params,
        ._query_params = null,
    };
    defer req.context.deinit();

    const route = try registry.findRoute("GET", "/test", &req);
    try std.testing.expect(route != null);
    if (route) |r| {
        try std.testing.expectEqualStrings(r.method, "GET");
        try std.testing.expectEqualStrings(r.path_pattern, "/test");
        try std.testing.expectEqualStrings(r.valve_name, "test_valve");
    }
}

test "RuntimeRouteRegistry register and find pattern match" {
    var registry = RuntimeRouteRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const handler = struct {
        fn handle(_: *Request) Response {
            return Response.text("test");
        }
    }.handle;

    try registry.register("GET", "/todos/:id", &handler, "test_valve");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var route_params = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer route_params.deinit();

    var req = Request{
        .inner = undefined, // Not used in findRoute
        .arena = arena,
        .context = std.StringHashMap([]const u8).init(std.testing.allocator),
        .route_params = route_params,
        ._query_params = null,
    };
    defer req.deinit();

    const route = try registry.findRoute("GET", "/todos/123", &req);
    try std.testing.expect(route != null);
    if (route) |r| {
        try std.testing.expectEqualStrings(r.path_pattern, "/todos/:id");
        const id = req.route_params.get("id");
        try std.testing.expect(id != null);
        if (id) |id_val| {
            try std.testing.expectEqualStrings(id_val, "123");
        }
    }
}

test "RuntimeRouteRegistry duplicate registration fails" {
    var registry = RuntimeRouteRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const handler = struct {
        fn handle(_: *Request) Response {
            return Response.text("test");
        }
    }.handle;

    try registry.register("GET", "/test", &handler, "test_valve");
    try std.testing.expectError(error.RouteAlreadyExists, registry.register("GET", "/test", &handler, "test_valve"));
}

test "RuntimeRouteRegistry unregister" {
    var registry = RuntimeRouteRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const handler = struct {
        fn handle(_: *Request) Response {
            return Response.text("test");
        }
    }.handle;

    try registry.register("GET", "/test", &handler, "test_valve");
    try std.testing.expectEqual(registry.routes.count(), 1);

    try registry.unregister("GET", "/test");
    try std.testing.expectEqual(registry.routes.count(), 0);
}
