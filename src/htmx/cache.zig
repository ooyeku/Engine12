const std = @import("std");
const Response = @import("../http/response.zig").Response;

/// Fragment cache entry
pub const CacheEntry = struct {
    html: []const u8,
    etag: []const u8,
    expires_at: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CacheEntry) void {
        self.allocator.free(self.html);
        self.allocator.free(self.etag);
    }

    pub fn isExpired(self: CacheEntry) bool {
        return std.time.timestamp() > self.expires_at;
    }
};

/// Fragment cache for rendered HTML fragments
pub const FragmentCache = struct {
    cache: std.StringHashMap(CacheEntry),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FragmentCache {
        return .{
            .cache = std.StringHashMap(CacheEntry).init(allocator),
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FragmentCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.cache.deinit();
    }

    /// Generate ETag from content
    fn generateETag(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(content);
        const hash = hasher.final();
        return std.fmt.allocPrint(allocator, "\"{x}\"", .{hash});
    }

    /// Store a fragment in the cache
    pub fn put(self: *FragmentCache, key: []const u8, html: []const u8, ttl_ms: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const etag = try generateETag(self.allocator, html);
        const expires_at = std.time.timestamp() + @divTrunc(ttl_ms, 1000);

        const html_copy = try self.allocator.dupe(u8, html);
        errdefer self.allocator.free(html_copy);

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const entry = CacheEntry{
            .html = html_copy,
            .etag = etag,
            .expires_at = expires_at,
            .allocator = self.allocator,
        };

        // Remove old entry if exists
        if (self.cache.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            var old_value = old.value;
            old_value.deinit();
        }

        try self.cache.put(key_copy, entry);
    }

    /// Get a fragment from the cache
    pub fn get(self: *FragmentCache, key: []const u8) ?CacheEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.cache.get(key)) |entry| {
            if (entry.isExpired()) {
                return null;
            }
            return entry;
        }
        return null;
    }

    /// Check if a fragment exists and is not expired
    pub fn has(self: *FragmentCache, key: []const u8) bool {
        return self.get(key) != null;
    }

    /// Invalidate a specific cache entry
    pub fn invalidate(self: *FragmentCache, key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.cache.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            var entry_value = entry.value;
            entry_value.deinit();
        }
    }

    /// Invalidate all cache entries matching a prefix
    pub fn invalidatePrefix(self: *FragmentCache, prefix: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Collect keys to remove
        var keys_buf: [256][]const u8 = undefined;
        var keys_count: usize = 0;

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                if (keys_count < keys_buf.len) {
                    keys_buf[keys_count] = entry.key_ptr.*;
                    keys_count += 1;
                }
            }
        }

        // Remove collected keys
        for (keys_buf[0..keys_count]) |key| {
            if (self.cache.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
                var entry_value = entry.value;
                entry_value.deinit();
            }
        }
    }

    /// Clear all expired entries
    pub fn clearExpired(self: *FragmentCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Collect keys to remove
        var keys_buf: [256][]const u8 = undefined;
        var keys_count: usize = 0;

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                if (keys_count < keys_buf.len) {
                    keys_buf[keys_count] = entry.key_ptr.*;
                    keys_count += 1;
                }
            }
        }

        // Remove collected keys
        for (keys_buf[0..keys_count]) |key| {
            if (self.cache.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
                var entry_value = entry.value;
                entry_value.deinit();
            }
        }
    }

    /// Clear all cache entries
    pub fn clear(self: *FragmentCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.cache.clearAndFree();
    }

    /// Get cache statistics
    pub fn stats(self: *FragmentCache) CacheStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var expired: usize = 0;
        var active: usize = 0;

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                expired += 1;
            } else {
                active += 1;
            }
        }

        return CacheStats{
            .total_entries = self.cache.count(),
            .active_entries = active,
            .expired_entries = expired,
        };
    }
};

pub const CacheStats = struct {
    total_entries: usize,
    active_entries: usize,
    expired_entries: usize,
};

/// Global fragment cache instance
var global_cache: ?FragmentCache = null;
var global_cache_mutex: std.Thread.Mutex = .{};

/// Initialize the global fragment cache
pub fn initGlobalCache(allocator: std.mem.Allocator) void {
    global_cache_mutex.lock();
    defer global_cache_mutex.unlock();

    if (global_cache == null) {
        global_cache = FragmentCache.init(allocator);
    }
}

/// Get the global fragment cache
pub fn getGlobalCache() ?*FragmentCache {
    global_cache_mutex.lock();
    defer global_cache_mutex.unlock();

    if (global_cache) |*cache| {
        return cache;
    }
    return null;
}

/// Deinitialize the global fragment cache
pub fn deinitGlobalCache() void {
    global_cache_mutex.lock();
    defer global_cache_mutex.unlock();

    if (global_cache) |*cache| {
        cache.deinit();
        global_cache = null;
    }
}

/// Cache a response fragment
pub fn cacheResponse(key: []const u8, html: []const u8, ttl_ms: i64) !void {
    if (getGlobalCache()) |cache| {
        try cache.put(key, html, ttl_ms);
    }
}

/// Get a cached response
pub fn getCachedResponse(key: []const u8) ?CacheEntry {
    if (getGlobalCache()) |cache| {
        return cache.get(key);
    }
    return null;
}

/// Invalidate a cached response
pub fn invalidateCache(key: []const u8) void {
    if (getGlobalCache()) |cache| {
        cache.invalidate(key);
    }
}

/// Invalidate all cache entries with a prefix
pub fn invalidateCachePrefix(prefix: []const u8) void {
    if (getGlobalCache()) |cache| {
        cache.invalidatePrefix(prefix);
    }
}

// Tests
test "fragment cache stores and retrieves entries" {
    const allocator = std.heap.page_allocator;
    var cache = FragmentCache.init(allocator);
    defer cache.deinit();

    const html = "<div>Test Content</div>";
    try cache.put("test-key", html, 60000);

    const entry = cache.get("test-key");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings(html, entry.?.html);
}

test "fragment cache expires entries" {
    const allocator = std.heap.page_allocator;
    var cache = FragmentCache.init(allocator);
    defer cache.deinit();

    const html = "<div>Test</div>";
    try cache.put("expire-test", html, -1000); // Already expired

    const entry = cache.get("expire-test");
    try std.testing.expect(entry == null);
}

test "fragment cache invalidates entries" {
    const allocator = std.heap.page_allocator;
    var cache = FragmentCache.init(allocator);
    defer cache.deinit();

    try cache.put("inv-test", "<div>Test</div>", 60000);
    cache.invalidate("inv-test");

    const entry = cache.get("inv-test");
    try std.testing.expect(entry == null);
}

test "fragment cache invalidates by prefix" {
    const allocator = std.heap.page_allocator;
    var cache = FragmentCache.init(allocator);
    defer cache.deinit();

    try cache.put("user:1", "<div>User 1</div>", 60000);
    try cache.put("user:2", "<div>User 2</div>", 60000);
    try cache.put("post:1", "<div>Post 1</div>", 60000);

    cache.invalidatePrefix("user:");

    try std.testing.expect(cache.get("user:1") == null);
    try std.testing.expect(cache.get("user:2") == null);
    try std.testing.expect(cache.get("post:1") != null);
}

test "fragment cache stats" {
    const allocator = std.heap.page_allocator;
    var cache = FragmentCache.init(allocator);
    defer cache.deinit();

    try cache.put("key1", "<div>1</div>", 60000);
    try cache.put("key2", "<div>2</div>", -1000); // Expired

    const cache_stats = cache.stats();
    try std.testing.expectEqual(@as(usize, 2), cache_stats.total_entries);
    try std.testing.expectEqual(@as(usize, 1), cache_stats.active_entries);
    try std.testing.expectEqual(@as(usize, 1), cache_stats.expired_entries);
}
