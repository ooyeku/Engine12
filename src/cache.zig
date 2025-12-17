const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const middleware_chain = @import("middleware.zig");

pub const CacheError = error{
    InvalidArgument,
};

pub const CacheEntry = struct {
    body: []const u8,

    etag: []const u8,

    last_modified: i64,

    ttl_ms: u64,

    expires_at: i64,

    content_type: []const u8,

    pub fn init(allocator: std.mem.Allocator, body: []const u8, ttl_ms: u64, content_type: []const u8) (CacheError || std.mem.Allocator.Error || std.fmt.ParseFloatError || error{NoSpaceLeft})!CacheEntry {
        if (body.len == 0) {
            std.debug.print("[CacheEntry] Error: Attempted to create cache entry with empty body\n", .{});
            return error.InvalidArgument;
        }
        if (content_type.len == 0) {
            std.debug.print("[CacheEntry] Error: Attempted to create cache entry with empty content type\n", .{});
            return error.InvalidArgument;
        }

        const now = std.time.milliTimestamp();

        const hash = std.hash.CityHash64.hash(body);

        var etag_buffer: [32]u8 = undefined;
        const etag_str = try std.fmt.bufPrint(&etag_buffer, "\"{x}\"", .{hash});
        const etag = try allocator.dupe(u8, etag_str);

        const body_copy = try allocator.dupe(u8, body);
        const content_type_copy = try allocator.dupe(u8, content_type);

        return CacheEntry{
            .body = body_copy,
            .etag = etag,
            .last_modified = now,
            .ttl_ms = ttl_ms,
            .expires_at = now + @as(i64, @intCast(ttl_ms)),
            .content_type = content_type_copy,
        };
    }

    pub fn isExpired(self: *const CacheEntry) bool {
        return std.time.milliTimestamp() >= self.expires_at;
    }

    pub fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.etag);
        allocator.free(self.content_type);
    }
};

pub const ResponseCache = struct {
    entries: std.StringHashMap(CacheEntry),

    allocator: std.mem.Allocator,

    default_ttl_ms: u64,

    max_entries: usize = 0,
    
    insertion_order: std.ArrayListUnmanaged([]const u8) = .{},

    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, default_ttl_ms: u64) ResponseCache {
        return ResponseCache{
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .allocator = allocator,
            .default_ttl_ms = default_ttl_ms,
            .max_entries = 0,
            .insertion_order = .{},
            .mutex = .{},
        };
    }

    pub fn initWithLimit(allocator: std.mem.Allocator, default_ttl_ms: u64, max_entries: usize) ResponseCache {
        return ResponseCache{
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .allocator = allocator,
            .default_ttl_ms = default_ttl_ms,
            .max_entries = max_entries,
            .insertion_order = .{},
            .mutex = .{},
        };
    }

    fn evictOldest(self: *ResponseCache) void {
        if (self.insertion_order.items.len == 0) return;
        
        const key = self.insertion_order.items[0];
        
        _ = self.insertion_order.orderedRemove(0);
        
        if (self.entries.fetchRemove(key)) |removed| {
            var mutable_value = removed.value;
            mutable_value.deinit(self.allocator);
            self.allocator.free(removed.key);
        }
    }

    pub fn get(self: *ResponseCache, key: []const u8) ?*CacheEntry {
        if (key.len == 0) {
            return null; // Invalid key
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.getPtr(key)) |entry| {
            if (entry.isExpired()) {
                if (self.entries.fetchRemove(key)) |removed| {
                    var mutable_value = removed.value;
                    mutable_value.deinit(self.allocator);
                    self.allocator.free(removed.key);
                }
                return null;
            }
            return entry;
        }
        return null;
    }

    pub fn set(self: *ResponseCache, key: []const u8, body: []const u8, ttl_ms: ?u64, content_type: []const u8) (CacheError || std.mem.Allocator.Error || std.fmt.ParseFloatError || error{NoSpaceLeft})!void {
        if (key.len == 0) {
            std.debug.print("[Cache] Error: Attempted to cache with empty key\n", .{});
            return error.InvalidArgument;
        }
        if (body.len == 0) {
            std.debug.print("[Cache] Error: Attempted to cache empty body\n", .{});
            return error.InvalidArgument;
        }
        if (content_type.len == 0) {
            std.debug.print("[Cache] Error: Attempted to cache with empty content type\n", .{});
            return error.InvalidArgument;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const cache_ttl = ttl_ms orelse self.default_ttl_ms;

        if (self.entries.fetchRemove(key)) |old_entry| {
            for (self.insertion_order.items, 0..) |k, i| {
                if (std.mem.eql(u8, k, old_entry.key)) {
                    _ = self.insertion_order.orderedRemove(i);
                    break;
                }
            }
            
            var mutable_value = old_entry.value;
            mutable_value.deinit(self.allocator);
            self.allocator.free(old_entry.key);
        }

        if (self.max_entries > 0 and self.entries.count() >= self.max_entries) {
            self.evictOldest();
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const entry = try CacheEntry.init(self.allocator, body, cache_ttl, content_type);
        errdefer {
            var mutable_entry = entry;
            mutable_entry.deinit(self.allocator);
        }

        try self.entries.put(key_copy, entry);
        
        try self.insertion_order.append(self.allocator, key_copy);
    }

    pub fn invalidate(self: *ResponseCache, key: []const u8) void {
        if (key.len == 0) {
            return; // Invalid key, nothing to invalidate
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.entries.fetchRemove(key)) |entry| {
            for (self.insertion_order.items, 0..) |k, i| {
                if (std.mem.eql(u8, k, entry.key)) {
                    _ = self.insertion_order.orderedRemove(i);
                    break;
                }
            }
            
            var mutable_value = entry.value;
            mutable_value.deinit(self.allocator);
            self.allocator.free(entry.key);
        }
    }

    pub fn invalidatePrefix(self: *ResponseCache, prefix: []const u8) void {
        if (prefix.len == 0) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        var keys_to_remove = std.ArrayListUnmanaged([]const u8){};
        defer keys_to_remove.deinit(self.allocator);

        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                var mutable_value = entry.value_ptr.*;
                mutable_value.deinit(self.allocator);
                keys_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (keys_to_remove.items) |k| {
            for (self.insertion_order.items, 0..) |io_key, i| {
                if (std.mem.eql(u8, io_key, k)) {
                    _ = self.insertion_order.orderedRemove(i);
                    break;
                }
            }
            if (self.entries.fetchRemove(k)) |entry| {
                self.allocator.free(entry.key);
            }
        }
    }

    pub fn cleanup(self: *ResponseCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var keys_to_remove = std.ArrayListUnmanaged([]const u8){};
        defer keys_to_remove.deinit(self.allocator);

        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                var mutable_value = entry.value_ptr.*;
                mutable_value.deinit(self.allocator);
                keys_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (keys_to_remove.items) |key| {
            if (self.entries.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
            }
        }
    }

    pub fn deinit(self: *ResponseCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            var mutable_value = entry.value_ptr.*;
            mutable_value.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
        
        self.insertion_order.deinit(self.allocator);
    }
};

pub fn generateETag(body: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const hash = std.hash.CityHash64.hash(body);

    var etag_buffer: [32]u8 = undefined;
    const etag_str = try std.fmt.bufPrint(&etag_buffer, "\"{x}\"", .{hash});
    return try allocator.dupe(u8, etag_str);
}

pub fn createCachingMiddleware(cache_ptr: *ResponseCache, comptime route: []const u8, ttl_ms: ?u64) middleware_chain.PreRequestMiddlewareFn {
    _ = cache_ptr;
    _ = ttl_ms;
    _ = route;
    return struct {
        fn mw(req: *Request) middleware_chain.MiddlewareResult {
            const cache_key = req.path();
            const global_cache = @import("engine12.zig").global_cache orelse return .proceed;
            const entry = global_cache.get(cache_key);

            if (entry) |cached| {
                const if_none_match = req.header("If-None-Match");
                if (if_none_match) |etag| {
                    const etag_clean = if (etag.len > 0 and etag[0] == '"')
                        etag[1 .. etag.len - 1]
                    else
                        etag;
                    const cached_etag_clean = if (cached.etag.len > 0 and cached.etag[0] == '"')
                        cached.etag[1 .. cached.etag.len - 1]
                    else
                        cached.etag;

                    if (std.mem.eql(u8, etag_clean, cached_etag_clean)) {
                        req.context.put("cache_hit", "true") catch {};
                        req.context.put("cache_etag", cached.etag) catch {};
                        return .abort; // Will be handled by middleware chain to return 304
                    }
                }

                req.context.put("cache_hit", "true") catch {};
                req.context.put("cache_body", cached.body) catch {};
                req.context.put("cache_etag", cached.etag) catch {};
                req.context.put("cache_content_type", cached.content_type) catch {};
            }

            return .proceed;
        }
    }.mw;
}

pub fn createCacheResponseMiddleware(cache: *ResponseCache, route: []const u8, ttl_ms: ?u64) middleware_chain.ResponseMiddlewareFn {
    _ = route;
    _ = ttl_ms;
    _ = cache;
    return struct {
        fn mw(resp: Response) Response {
            return resp;
        }
    }.mw;
}

test "ResponseCache set and get" {
    var cache = ResponseCache.init(std.testing.allocator, 1000);
    defer cache.deinit();

    try cache.set("/test", "test body", null, "text/plain");

    const entry = cache.get("/test");
    try std.testing.expect(entry != null);
    if (entry) |e| {
        try std.testing.expectEqualStrings(e.body, "test body");
    }
}

test "ResponseCache expiration" {
    var cache = ResponseCache.init(std.testing.allocator, 10); // 10ms TTL
    defer cache.deinit();

    try cache.set("/test", "test body", null, "text/plain");

    try std.testing.expect(cache.get("/test") != null);

    std.Thread.sleep(20 * std.time.ns_per_ms);

    try std.testing.expect(cache.get("/test") == null);
}

test "ResponseCache invalidation" {
    var cache = ResponseCache.init(std.testing.allocator, 1000);
    defer cache.deinit();

    try cache.set("/test", "test body", null, "text/plain");
    try std.testing.expect(cache.get("/test") != null);

    cache.invalidate("/test");
    try std.testing.expect(cache.get("/test") == null);
}

test "CacheEntry init and expiration" {
    var entry = try CacheEntry.init(std.testing.allocator, "test body", 1000, "text/plain");
    defer entry.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(entry.body, "test body");
    try std.testing.expect(!entry.isExpired());
}

test "ResponseCache set and get with custom TTL" {
    var cache = ResponseCache.init(std.testing.allocator, 1000);
    defer cache.deinit();

    try cache.set("/test", "test body", 5000, "text/plain");

    const entry = cache.get("/test");
    try std.testing.expect(entry != null);
    if (entry) |e| {
        try std.testing.expectEqualStrings(e.body, "test body");
        try std.testing.expectEqual(e.ttl_ms, 5000);
    }
}

test "ResponseCache set overwrites existing entry" {
    var cache = ResponseCache.init(std.testing.allocator, 1000);
    defer cache.deinit();

    try cache.set("/test", "old body", null, "text/plain");
    try cache.set("/test", "new body", null, "text/plain");

    const entry = cache.get("/test");
    try std.testing.expect(entry != null);
    if (entry) |e| {
        try std.testing.expectEqualStrings(e.body, "new body");
    }
}

test "ResponseCache invalidatePrefix removes matching entries" {
    var cache = ResponseCache.init(std.testing.allocator, 1000);
    defer cache.deinit();

    try cache.set("/api/users", "users body", null, "application/json");
    try cache.set("/api/posts", "posts body", null, "application/json");
    try cache.set("/api/users/123", "user body", null, "application/json");
    try cache.set("/other", "other body", null, "text/plain");

    cache.invalidatePrefix("/api/users");

    try std.testing.expect(cache.get("/api/users") == null);
    try std.testing.expect(cache.get("/api/users/123") == null);
    try std.testing.expect(cache.get("/api/posts") != null);
    try std.testing.expect(cache.get("/other") != null);
}

test "ResponseCache cleanup removes expired entries" {
    var cache = ResponseCache.init(std.testing.allocator, 10);
    defer cache.deinit();

    try cache.set("/test1", "body1", null, "text/plain");
    try cache.set("/test2", "body2", 50, "text/plain");

    try std.testing.expect(cache.get("/test1") != null);
    try std.testing.expect(cache.get("/test2") != null);

    std.Thread.sleep(20 * std.time.ns_per_ms);

    cache.cleanup();

    try std.testing.expect(cache.get("/test1") == null);
    try std.testing.expect(cache.get("/test2") != null);
}

test "ResponseCache get returns null for non-existent key" {
    var cache = ResponseCache.init(std.testing.allocator, 1000);
    defer cache.deinit();

    const entry = cache.get("/nonexistent");
    try std.testing.expect(entry == null);
}

test "CacheEntry same body generates same ETag" {
    var entry1 = try CacheEntry.init(std.testing.allocator, "test body", 1000, "text/plain");
    defer entry1.deinit(std.testing.allocator);

    var entry2 = try CacheEntry.init(std.testing.allocator, "test body", 1000, "text/plain");
    defer entry2.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(entry1.etag, entry2.etag);
}

test "CacheEntry different body generates different ETag" {
    var entry1 = try CacheEntry.init(std.testing.allocator, "body1", 1000, "text/plain");
    defer entry1.deinit(std.testing.allocator);

    var entry2 = try CacheEntry.init(std.testing.allocator, "body2", 1000, "text/plain");
    defer entry2.deinit(std.testing.allocator);

    try std.testing.expect(!std.mem.eql(u8, entry1.etag, entry2.etag));
}

test "ResponseCache multiple entries" {
    var cache = ResponseCache.init(std.testing.allocator, 1000);
    defer cache.deinit();

    try cache.set("/api/users", "users", null, "application/json");
    try cache.set("/api/posts", "posts", null, "application/json");
    try cache.set("/api/comments", "comments", null, "application/json");

    try std.testing.expect(cache.get("/api/users") != null);
    try std.testing.expect(cache.get("/api/posts") != null);
    try std.testing.expect(cache.get("/api/comments") != null);
}

test "ResponseCache invalidate non-existent key" {
    var cache = ResponseCache.init(std.testing.allocator, 1000);
    defer cache.deinit();

    cache.invalidate("/nonexistent");
}

test "ResponseCache invalidatePrefix empty prefix" {
    var cache = ResponseCache.init(std.testing.allocator, 1000);
    defer cache.deinit();

    try cache.set("/test", "body", null, "text/plain");

    cache.invalidatePrefix("");

    try std.testing.expect(cache.get("/test") != null);
}

test "generateETag creates valid ETag" {
    const etag = try generateETag("test body", std.testing.allocator);
    defer std.testing.allocator.free(etag);

    try std.testing.expect(etag.len > 0);
    try std.testing.expect(etag[0] == '"');
    try std.testing.expect(etag[etag.len - 1] == '"');
}

test "CacheEntry expiration check" {
    var entry = try CacheEntry.init(std.testing.allocator, "test", 10, "text/plain");
    defer entry.deinit(std.testing.allocator);

    try std.testing.expect(!entry.isExpired());

    std.Thread.sleep(15 * std.time.ns_per_ms);

    try std.testing.expect(entry.isExpired());
}

test "CacheEntry init rejects empty body" {
    const result = CacheEntry.init(std.testing.allocator, "", 1000, "text/plain");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "CacheEntry init rejects empty content type" {
    const result = CacheEntry.init(std.testing.allocator, "body", 1000, "");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "ResponseCache set rejects empty key" {
    var cache = ResponseCache.init(std.testing.allocator, 1000);
    defer cache.deinit();

    const result = cache.set("", "body", null, "text/plain");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "ResponseCache set rejects empty body" {
    var cache = ResponseCache.init(std.testing.allocator, 1000);
    defer cache.deinit();

    const result = cache.set("key", "", null, "text/plain");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "ResponseCache set rejects empty content type" {
    var cache = ResponseCache.init(std.testing.allocator, 1000);
    defer cache.deinit();

    const result = cache.set("key", "body", null, "");
    try std.testing.expectError(error.InvalidArgument, result);
}

test "ResponseCache get returns null for empty key" {
    var cache = ResponseCache.init(std.testing.allocator, 1000);
    defer cache.deinit();

    const entry = cache.get("");
    try std.testing.expect(entry == null);
}

test "ResponseCache max entries limit" {
    var cache = ResponseCache.initWithLimit(std.testing.allocator, 1000, 2);
    defer cache.deinit();

    try cache.set("/test1", "body1", null, "text/plain");
    try cache.set("/test2", "body2", null, "text/plain");
    try std.testing.expect(cache.get("/test1") != null);
    try std.testing.expect(cache.get("/test2") != null);

    try cache.set("/test3", "body3", null, "text/plain");
    try std.testing.expect(cache.get("/test1") == null); // Evicted
    try std.testing.expect(cache.get("/test2") != null);
    try std.testing.expect(cache.get("/test3") != null);
}
