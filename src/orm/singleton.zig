const std = @import("std");
const Database = @import("database.zig").Database;
const ConnectionPool = @import("database.zig").ConnectionPool;
const ConnectionPoolConfig = @import("database.zig").ConnectionPoolConfig;
const ORM = @import("orm.zig").ORM;

/// Configuration for DatabaseSingleton with connection pooling
pub const DatabasePoolConfig = struct {
    /// Number of connections in the pool (default: 50)
    pool_size: usize = 50,
    /// Whether to enable WAL mode (already enabled by default in Database.open)
    enable_wal: bool = true,
    /// Idle timeout for connections in milliseconds (default: 10 minutes)
    idle_timeout_ms: u64 = 600000,
    /// Acquire timeout in milliseconds (default: 10 seconds)
    acquire_timeout_ms: u64 = 10000,
};

/// Thread-safe database singleton pattern with lock-free access
/// Provides a global database/ORM instance that can be safely accessed from multiple threads
/// Uses atomic initialization check to eliminate mutex contention on hot path
///
/// Example:
/// ```zig
/// // Initialize singleton once at startup
/// try DatabaseSingleton.init("myapp.db", allocator);
/// defer DatabaseSingleton.deinit();
///
/// // Access from anywhere in your application (lock-free!)
/// const orm = try DatabaseSingleton.get();
/// const todos = try orm.findAll(Todo);
/// ```
pub const DatabaseSingleton = struct {
    var global_db: ?Database = null;
    var global_orm: ?ORM = null;
    var global_pool: ?ConnectionPool = null;
    var global_allocator: ?std.mem.Allocator = null;
    var init_mutex: std.Thread.Mutex = .{};
    // Atomic flag for lock-free access after initialization
    var initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var use_pool: bool = false;

    /// Initialize the database singleton (single connection mode)
    /// Opens the database and creates the ORM instance
    /// Thread-safe: can be called multiple times safely (idempotent)
    /// Uses double-checked locking for efficient thread-safe initialization
    ///
    /// Example:
    /// ```zig
    /// try DatabaseSingleton.init("myapp.db", allocator);
    /// ```
    pub fn init(db_path: []const u8, allocator: std.mem.Allocator) !void {
        // Fast path: already initialized (lock-free check)
        if (initialized.load(.acquire)) {
            return;
        }

        // Slow path: need to initialize
        init_mutex.lock();
        defer init_mutex.unlock();

        // Double-check after acquiring lock
        if (initialized.load(.acquire)) {
            return;
        }

        global_db = try Database.open(db_path, allocator);
        global_orm = ORM.init(global_db.?, allocator);
        global_allocator = allocator;
        use_pool = false;

        // Release barrier ensures all writes are visible before setting initialized
        initialized.store(true, .release);
    }

    /// Initialize the database singleton with connection pooling
    /// Enables concurrent database access with multiple connections
    /// Thread-safe: can be called multiple times safely (idempotent)
    ///
    /// Example:
    /// ```zig
    /// try DatabaseSingleton.initWithPool("myapp.db", .{
    ///     .pool_size = 4,
    /// }, allocator);
    /// ```
    pub fn initWithPool(db_path: []const u8, config: DatabasePoolConfig, allocator: std.mem.Allocator) !void {
        // Fast path: already initialized (lock-free check)
        if (initialized.load(.acquire)) {
            return;
        }

        // Slow path: need to initialize
        init_mutex.lock();
        defer init_mutex.unlock();

        // Double-check after acquiring lock
        if (initialized.load(.acquire)) {
            return;
        }

        // Initialize connection pool
        global_pool = ConnectionPool.init(db_path, .{
            .max_connections = config.pool_size,
            .idle_timeout_ms = config.idle_timeout_ms,
            .acquire_timeout_ms = config.acquire_timeout_ms,
        }, allocator);

        // Get first connection for ORM (always available)
        global_db = try global_pool.?.acquire();
        global_orm = ORM.init(global_db.?, allocator);
        global_allocator = allocator;
        use_pool = true;

        // Release barrier ensures all writes are visible before setting initialized
        initialized.store(true, .release);
    }

    /// Get the ORM instance
    /// Returns a pointer to the thread-safe ORM instance
    /// Lock-free: uses atomic check instead of mutex
    ///
    /// Example:
    /// ```zig
    /// const orm = try DatabaseSingleton.get();
    /// const todo = try orm.find(Todo, 1);
    /// ```
    pub fn get() !*ORM {
        // Lock-free check with acquire semantics
        if (!initialized.load(.acquire)) {
            return error.DatabaseNotInitialized;
        }

        // Safe to access after acquire barrier
        if (global_orm) |*orm| {
            return orm;
        }

        return error.DatabaseNotInitialized;
    }

    /// Get the database instance directly
    /// Returns a pointer to the thread-safe Database instance
    /// Lock-free: uses atomic check instead of mutex
    ///
    /// Example:
    /// ```zig
    /// const db = try DatabaseSingleton.getDatabase();
    /// try db.execute("SELECT * FROM users");
    /// ```
    pub fn getDatabase() !*Database {
        // Lock-free check with acquire semantics
        if (!initialized.load(.acquire)) {
            return error.DatabaseNotInitialized;
        }

        // Safe to access after acquire barrier
        if (global_db) |*db| {
            return db;
        }

        return error.DatabaseNotInitialized;
    }

    /// Acquire a connection from the pool (if using pool mode)
    /// Returns a new connection that must be released with releaseConnection()
    /// Falls back to the singleton database if not using pool mode
    pub fn acquireConnection() !Database {
        if (!initialized.load(.acquire)) {
            return error.DatabaseNotInitialized;
        }

        if (use_pool) {
            if (global_pool) |*pool| {
                return pool.acquire();
            }
        }

        // Return the singleton database if not using pool
        if (global_db) |db| {
            return db;
        }

        return error.DatabaseNotInitialized;
    }

    /// Release a connection back to the pool
    /// Only needed when using pool mode with acquireConnection()
    pub fn releaseConnection(db: Database) void {
        if (use_pool) {
            if (global_pool) |*pool| {
                pool.release(db);
            }
        }
        // In single connection mode, do nothing (connection is reused)
    }

    /// Check if the singleton has been initialized
    /// Lock-free: uses atomic check
    pub fn isInitialized() bool {
        return initialized.load(.acquire);
    }

    /// Check if using connection pool mode
    pub fn isUsingPool() bool {
        return use_pool and initialized.load(.acquire);
    }

    /// Deinitialize the singleton
    /// Closes the database connection and cleans up resources
    /// Thread-safe: should be called once at application shutdown
    ///
    /// Example:
    /// ```zig
    /// defer DatabaseSingleton.deinit();
    /// ```
    pub fn deinit() void {
        init_mutex.lock();
        defer init_mutex.unlock();

        if (!initialized.load(.acquire)) {
            return;
        }

        if (use_pool) {
            if (global_pool) |*pool| {
                // Release the ORM's connection back to pool before closing
                if (global_db) |db| {
                    pool.release(db);
                }
                pool.deinit();
            }
            global_pool = null;
        } else {
            if (global_db) |*db| {
                db.close();
            }
        }

        global_db = null;
        global_orm = null;
        global_allocator = null;
        use_pool = false;
        initialized.store(false, .release);
    }
};

// Tests
test "DatabaseSingleton init and get" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";

    try DatabaseSingleton.init(test_db_path, allocator);
    defer DatabaseSingleton.deinit();

    try std.testing.expect(DatabaseSingleton.isInitialized());

    const orm = try DatabaseSingleton.get();
    _ = orm; // Use ORM

    const db = try DatabaseSingleton.getDatabase();
    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)");
}

test "DatabaseSingleton idempotent init" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";

    try DatabaseSingleton.init(test_db_path, allocator);
    defer DatabaseSingleton.deinit();

    // Second init should not error
    try DatabaseSingleton.init(test_db_path, allocator);
}

test "DatabaseSingleton error when not initialized" {
    // Ensure not initialized
    if (DatabaseSingleton.isInitialized()) {
        DatabaseSingleton.deinit();
    }

    const result = DatabaseSingleton.get();
    try std.testing.expectError(error.DatabaseNotInitialized, result);
}
