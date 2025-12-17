const std = @import("std");

pub const ShutdownHook = *const fn () void;

pub const ShutdownHookRegistry = struct {
    hooks: std.ArrayListUnmanaged(ShutdownHook),
    mutex: std.Thread.Mutex,

    pub fn init(_: std.mem.Allocator) ShutdownHookRegistry {
        return ShutdownHookRegistry{
            .hooks = std.ArrayListUnmanaged(ShutdownHook){},
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *ShutdownHookRegistry, allocator: std.mem.Allocator) void {
        self.hooks.deinit(allocator);
    }

    pub fn register(self: *ShutdownHookRegistry, hook: ShutdownHook, allocator: std.mem.Allocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.hooks.append(allocator, hook);
    }

    pub fn execute(self: *ShutdownHookRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.hooks.items) |hook| {
            hook();
        }
    }

    pub fn count(self: *const ShutdownHookRegistry) usize {
        (@constCast(self)).mutex.lock();
        defer (@constCast(self)).mutex.unlock();
        return self.hooks.items.len;
    }
};

pub const ActiveRequestTracker = struct {
    count: std.atomic.Value(u64),
    mutex: std.Thread.Mutex,

    pub fn init() ActiveRequestTracker {
        return ActiveRequestTracker{
            .count = std.atomic.Value(u64).init(0),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn increment(self: *ActiveRequestTracker) void {
        _ = self.count.fetchAdd(1, .monotonic);
    }

    pub fn decrement(self: *ActiveRequestTracker) void {
        _ = self.count.fetchSub(1, .monotonic);
    }

    pub fn get(self: *const ActiveRequestTracker) u64 {
        return self.count.load(.monotonic);
    }

    pub fn waitForCompletion(self: *const ActiveRequestTracker, timeout_ms: u32) bool {
        const start_time = std.time.milliTimestamp();
        const timeout_ns = @as(i64, timeout_ms) * std.time.ns_per_ms;

        while (self.get() > 0) {
            const elapsed = std.time.nanoTimestamp() - start_time;
            if (elapsed >= timeout_ns) {
                return false; // Timeout
            }

            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        return true; // All requests completed
    }
};

test "ShutdownHookRegistry init and register" {
    const allocator = std.testing.allocator;
    var registry = ShutdownHookRegistry.init(allocator);
    defer registry.deinit(allocator);

    const hook = struct {
        fn testHook() void {
        }
    }.testHook;

    try registry.register(hook, allocator);
    try std.testing.expectEqual(registry.count(), 1);
}

test "ShutdownHookRegistry execute" {
    const allocator = std.testing.allocator;
    var registry = ShutdownHookRegistry.init(allocator);
    defer registry.deinit(allocator);

    const hook = struct {
        fn testHook() void {
        }
    }.testHook;

    try registry.register(hook, allocator);
    registry.execute();
}

test "ActiveRequestTracker increment and decrement" {
    var tracker = ActiveRequestTracker.init();
    try std.testing.expectEqual(tracker.get(), 0);

    tracker.increment();
    try std.testing.expectEqual(tracker.get(), 1);

    tracker.increment();
    try std.testing.expectEqual(tracker.get(), 2);

    tracker.decrement();
    try std.testing.expectEqual(tracker.get(), 1);

    tracker.decrement();
    try std.testing.expectEqual(tracker.get(), 0);
}

test "ActiveRequestTracker waitForCompletion with no requests" {
    var tracker = ActiveRequestTracker.init();
    const completed = tracker.waitForCompletion(100);
    try std.testing.expect(completed);
}

test "ActiveRequestTracker waitForCompletion with timeout" {
    var tracker = ActiveRequestTracker.init();
    tracker.increment();

    const completed = tracker.waitForCompletion(50);
    try std.testing.expect(!completed);

    tracker.decrement();
}
