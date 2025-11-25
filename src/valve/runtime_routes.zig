const std = @import("std");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const router = @import("../router.zig");
const types = @import("../types.zig");

/// Trie node for fast O(path_length) route matching
/// Each node represents a path segment (e.g., "todos" in "/api/todos/123")
pub const RouteTrieNode = struct {
    /// Children indexed by first character of segment
    children: std.AutoHashMap(u8, *RouteTrieNode),
    /// Child for parameter segments (e.g., ":id")
    param_child: ?*RouteTrieNode = null,
    /// Param name if this is a parameter node
    param_name: ?[]const u8 = null,
    /// Route stored at this node (if path terminates here)
    routes: std.StringHashMap(*RuntimeRoute), // Keyed by HTTP method
    /// Full segment string for this node
    segment: []const u8,
    /// Allocator for memory management
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
        // Recursively deinit children
        var child_iter = self.children.valueIterator();
        while (child_iter.next()) |child_ptr| {
            child_ptr.*.deinit();
        }
        self.children.deinit();

        // Deinit param child
        if (self.param_child) |param_child| {
            param_child.deinit();
        }

        // Free param name
        if (self.param_name) |name| {
            self.allocator.free(name);
        }

        // Deinit routes map (don't free routes themselves, they're owned by registry)
        self.routes.deinit();

        // Free segment
        self.allocator.free(self.segment);

        // Free node itself
        self.allocator.destroy(self);
    }

    /// Insert a route into the trie
    pub fn insert(self: *Self, path: []const u8, method: []const u8, route: *RuntimeRoute) !void {
        var current: *Self = self;
        var remaining = path;

        // Skip leading slash
        if (remaining.len > 0 and remaining[0] == '/') {
            remaining = remaining[1..];
        }

        while (remaining.len > 0) {
            // Find next segment
            const segment_end = std.mem.indexOfScalar(u8, remaining, '/') orelse remaining.len;
            const segment = remaining[0..segment_end];

            if (segment.len == 0) {
                remaining = if (segment_end < remaining.len) remaining[segment_end + 1 ..] else "";
                continue;
            }

            // Check if this is a parameter segment
            if (segment[0] == ':') {
                // Parameter segment - use param_child
                if (current.param_child == null) {
                    current.param_child = try RouteTrieNode.init(current.allocator, segment);
                    current.param_child.?.param_name = try current.allocator.dupe(u8, segment[1..]);
                }
                current = current.param_child.?;
            } else {
                // Static segment - use children map
                const first_char = segment[0];
                if (current.children.get(first_char)) |child| {
                    // Check if segment matches
                    if (std.mem.eql(u8, child.segment, segment)) {
                        current = child;
                    } else {
                        // Different segment with same first char - create new child
                        // This is a simplification; a full radix tree would split the node
                        const new_child = try RouteTrieNode.init(current.allocator, segment);
                        try current.children.put(first_char, new_child);
                        current = new_child;
                    }
                } else {
                    // Create new child
                    const new_child = try RouteTrieNode.init(current.allocator, segment);
                    try current.children.put(first_char, new_child);
                    current = new_child;
                }
            }

            remaining = if (segment_end < remaining.len) remaining[segment_end + 1 ..] else "";
        }

        // Store route at terminal node
        try current.routes.put(method, route);
    }

    /// Match a path and extract parameters
    /// Returns the matched route or null
    pub fn match(
        self: *Self,
        path: []const u8,
        method: []const u8,
        params: *std.StringHashMap([]const u8),
        allocator: std.mem.Allocator,
    ) !?*RuntimeRoute {
        var current: *Self = self;
        var remaining = path;

        // Skip leading slash
        if (remaining.len > 0 and remaining[0] == '/') {
            remaining = remaining[1..];
        }

        while (remaining.len > 0) {
            // Find next segment
            const segment_end = std.mem.indexOfScalar(u8, remaining, '/') orelse remaining.len;
            const segment = remaining[0..segment_end];

            if (segment.len == 0) {
                remaining = if (segment_end < remaining.len) remaining[segment_end + 1 ..] else "";
                continue;
            }

            // Try static match first (faster)
            const first_char = segment[0];
            if (current.children.get(first_char)) |child| {
                if (std.mem.eql(u8, child.segment, segment)) {
                    current = child;
                    remaining = if (segment_end < remaining.len) remaining[segment_end + 1 ..] else "";
                    continue;
                }
            }

            // Try parameter match
            if (current.param_child) |param_child| {
                // Extract parameter value
                if (param_child.param_name) |param_name| {
                    const value_copy = try allocator.dupe(u8, segment);
                    try params.put(param_name, value_copy);
                }
                current = param_child;
                remaining = if (segment_end < remaining.len) remaining[segment_end + 1 ..] else "";
                continue;
            }

            // No match found
            return null;
        }

        // Check if route exists at terminal node
        return current.routes.get(method);
    }
};

/// Runtime route entry stored in the registry
pub const RuntimeRoute = struct {
    /// HTTP method (GET, POST, etc.)
    method: []const u8,
    /// Route pattern (e.g., "/todos/:id")
    path_pattern: []const u8,
    /// Parsed route pattern for matching
    pattern: router.RoutePattern,
    /// Handler function pointer
    handler: *const fn (*Request) Response,
    /// Valve name that registered this route (for tracking)
    valve_name: []const u8,

    /// Clean up allocated memory
    pub fn deinit(self: *RuntimeRoute, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.path_pattern);
        var mutable_pattern = self.pattern;
        mutable_pattern.deinit(allocator);
        allocator.free(self.valve_name);
    }
};

/// Registry for runtime routes registered by valves
/// Thread-safe with mutex protection
/// Uses trie-based index for O(path_length) route matching
pub const RuntimeRouteRegistry = struct {
    /// Routes stored by method+path key (for backward compatibility and management)
    routes: std.StringHashMap(RuntimeRoute),
    /// Trie root for fast O(path_length) route matching
    trie_root: ?*RouteTrieNode = null,
    /// Mutex for thread-safe access
    mutex: std.Thread.Mutex,
    /// Allocator for route storage
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new runtime route registry
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .routes = std.StringHashMap(RuntimeRoute).init(allocator),
            .trie_root = null,
            .mutex = .{},
            .allocator = allocator,
        };
    }

    /// Generate a key for method+path lookup
    fn makeKey(allocator: std.mem.Allocator, method: []const u8, path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ method, path });
    }

    /// Register a runtime route
    /// Returns error if route already exists or pattern is invalid
    /// Adds route to both HashMap (for management) and Trie (for fast matching)
    pub fn register(
        self: *Self,
        method: []const u8,
        path: []const u8,
        handler: *const fn (*Request) Response,
        valve_name: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Parse route pattern
        var pattern = try router.RoutePattern.parse(self.allocator, path);
        errdefer pattern.deinit(self.allocator);

        // Create key
        const key = try makeKey(self.allocator, method, path);
        errdefer self.allocator.free(key);

        // Check if route already exists
        if (self.routes.contains(key)) {
            // Don't free key or pattern here - errdefer will handle both
            return error.RouteAlreadyExists;
        }

        // Duplicate strings for storage
        const method_copy = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(method_copy);

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        const valve_name_copy = try self.allocator.dupe(u8, valve_name);
        errdefer self.allocator.free(valve_name_copy);

        // Store route in HashMap
        try self.routes.put(key, RuntimeRoute{
            .method = method_copy,
            .path_pattern = path_copy,
            .pattern = pattern,
            .handler = handler,
            .valve_name = valve_name_copy,
        });

        // Initialize trie root if needed
        if (self.trie_root == null) {
            self.trie_root = try RouteTrieNode.init(self.allocator, "");
        }

        // Add to trie for fast matching
        const route_ptr = self.routes.getPtr(key).?;
        try self.trie_root.?.insert(path, method, route_ptr);
    }

    /// Find a route matching the given method and path
    /// Returns the route if found, null otherwise
    /// Uses trie-based O(path_length) matching for fast lookups
    /// Falls back to linear scan only if trie matching fails
    /// Extracts route parameters into the request
    pub fn findRoute(
        self: *Self,
        method: []const u8,
        path: []const u8,
        request: *Request,
    ) !?*RuntimeRoute {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Fast path: use trie-based matching first
        if (self.trie_root) |trie| {
            var params = std.StringHashMap([]const u8).init(request.arena.allocator());
            if (try trie.match(path, method, &params, request.arena.allocator())) |route| {
                // Copy parameters to request
                var param_iter = params.iterator();
                while (param_iter.next()) |*param_entry| {
                    try request.route_params.put(param_entry.key_ptr.*, param_entry.value_ptr.*);
                }
                return route;
            }
        }

        // Slow path fallback: linear scan through all routes
        // This handles edge cases the trie might miss (complex patterns, wildcards, etc.)
        var iterator = self.routes.iterator();
        while (iterator.next()) |*entry| {
            const route = entry.value_ptr;

            // Check method matches
            if (!std.mem.eql(u8, route.method, method)) continue;

            // Check exact path match first
            if (std.mem.eql(u8, route.path_pattern, path)) {
                return route;
            }

            // Try pattern matching
            var mutable_pattern = route.pattern;
            if (try mutable_pattern.match(request.arena.allocator(), path)) |params| {
                // Extract route parameters into request
                var param_iter = params.iterator();
                while (param_iter.next()) |*param_entry| {
                    try request.route_params.put(param_entry.key_ptr.*, param_entry.value_ptr.*);
                }
                return route;
            }
        }

        return null;
    }

    /// Unregister a route by method and path
    pub fn unregister(self: *Self, method: []const u8, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try makeKey(self.allocator, method, path);
        defer self.allocator.free(key);

        if (self.routes.fetchRemove(key)) |entry| {
            // Free the key that was stored in the map
            self.allocator.free(entry.key);
            var mutable_value = entry.value;
            mutable_value.deinit(self.allocator);
        } else {
            return error.RouteNotFound;
        }
    }

    /// Get all routes registered by a specific valve
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

    /// Clean up all routes and deinitialize registry
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up trie
        if (self.trie_root) |trie| {
            trie.deinit();
        }

        // Clean up routes HashMap
        var iterator = self.routes.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.routes.deinit();
    }
};

// Tests
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

    // Create a minimal request for testing
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

    // Create a minimal request for testing
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
        // Check that parameter was extracted
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
