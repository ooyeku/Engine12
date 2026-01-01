const std = @import("std");
const Database = @import("database.zig").Database;
const ConnectionPool = @import("database.zig").ConnectionPool;
const ConnectionPoolConfig = @import("database.zig").ConnectionPoolConfig;
const DatabaseConfig = @import("driver.zig").DatabaseConfig;
const Driver = @import("driver.zig").Driver;
const ORM = @import("orm.zig").ORM;

pub const DatabasePoolConfig = struct {
    pool_size: usize = 50,
    enable_wal: bool = true,
    idle_timeout_ms: u64 = 600000,
    acquire_timeout_ms: u64 = 10000,
};

pub fn loadConfigFromEnv(_: std.mem.Allocator, default_sqlite_path: []const u8) !DatabaseConfig {
    const driver_env = std.posix.getenv("E12_DB_DRIVER");
    const driver: Driver = if (driver_env) |d| blk: {
        if (std.mem.eql(u8, d, "postgresql") or std.mem.eql(u8, d, "postgres")) {
            break :blk .postgresql;
        }
        break :blk .sqlite;
    } else .sqlite;

    if (driver == .postgresql) {
        const host = std.posix.getenv("E12_DB_HOST") orelse "127.0.0.1";
        const port_str = std.posix.getenv("E12_DB_PORT");
        const port: u16 = if (port_str) |p| std.fmt.parseInt(u16, p, 10) catch 5432 else 5432;
        const database = std.posix.getenv("E12_DB_NAME") orelse {
            std.debug.print("[Database] Error: E12_DB_NAME environment variable is required for PostgreSQL\n", .{});
            return error.MissingDatabaseConfig;
        };
        const username = std.posix.getenv("E12_DB_USER") orelse {
            std.debug.print("[Database] Error: E12_DB_USER environment variable is required for PostgreSQL\n", .{});
            return error.MissingDatabaseConfig;
        };
        const password = std.posix.getenv("E12_DB_PASSWORD");

        return DatabaseConfig.postgresql(.{
            .host = host,
            .port = port,
            .database = database,
            .username = username,
            .password = password,
        });
    } else {
        const sqlite_path = std.posix.getenv("E12_DB_PATH") orelse default_sqlite_path;
        return DatabaseConfig.sqlite(sqlite_path);
    }
}

/// A global singleton for managing a application-wide database connection or pool.
pub const DatabaseSingleton = struct {
    var global_db: ?Database = null;
    var global_orm: ?ORM = null;
    var global_pool: ?ConnectionPool = null;
    var global_allocator: ?std.mem.Allocator = null;
    var init_mutex: std.Thread.Mutex = .{};
    var initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var use_pool: bool = false;

    /// Initializes the singleton with a direct SQLite connection.
    pub fn init(db_path: []const u8, allocator: std.mem.Allocator) !void {
        if (initialized.load(.acquire)) {
            return;
        }

        init_mutex.lock();
        defer init_mutex.unlock();

        if (initialized.load(.acquire)) {
            return;
        }

        global_db = try Database.open(db_path, allocator);
        global_orm = ORM.init(global_db.?, allocator);
        global_allocator = allocator;
        use_pool = false;

        initialized.store(true, .release);
    }

    /// Initializes the singleton with a specific database configuration (SQLite or PostgreSQL).
    pub fn initWithConfig(config: DatabaseConfig, allocator: std.mem.Allocator) !void {
        if (initialized.load(.acquire)) {
            return;
        }

        init_mutex.lock();
        defer init_mutex.unlock();

        if (initialized.load(.acquire)) {
            return;
        }

        global_db = try Database.openWithConfig(config, allocator);
        global_orm = ORM.init(global_db.?, allocator);
        global_allocator = allocator;
        use_pool = false;

        initialized.store(true, .release);
    }

    /// Initializes the singleton with a connection pool.
    pub fn initWithPool(db_path: []const u8, config: DatabasePoolConfig, allocator: std.mem.Allocator) !void {
        if (initialized.load(.acquire)) {
            return;
        }

        init_mutex.lock();
        defer init_mutex.unlock();

        if (initialized.load(.acquire)) {
            return;
        }

        global_pool = ConnectionPool.init(db_path, .{
            .max_connections = config.pool_size,
            .idle_timeout_ms = config.idle_timeout_ms,
            .acquire_timeout_ms = config.acquire_timeout_ms,
        }, allocator);

        global_db = try global_pool.?.acquire();
        global_orm = ORM.init(global_db.?, allocator);
        global_allocator = allocator;
        use_pool = true;

        initialized.store(true, .release);
    }

    /// Returns the application-wide ORM instance.
    pub fn get() !*ORM {
        if (!initialized.load(.acquire)) {
            return error.DatabaseNotInitialized;
        }

        if (global_orm) |*orm| {
            return orm;
        }

        return error.DatabaseNotInitialized;
    }

    /// Returns the application-wide Database instance.
    pub fn getDatabase() !*Database {
        if (!initialized.load(.acquire)) {
            return error.DatabaseNotInitialized;
        }

        if (global_db) |*db| {
            return db;
        }

        return error.DatabaseNotInitialized;
    }

    /// Acquires a new database connection (from the pool if enabled).
    pub fn acquireConnection() !Database {
        if (!initialized.load(.acquire)) {
            return error.DatabaseNotInitialized;
        }

        if (use_pool) {
            if (global_pool) |*pool| {
                return pool.acquire();
            }
        }

        if (global_db) |db| {
            return db;
        }

        return error.DatabaseNotInitialized;
    }

    /// Releases a connection back to the pool.
    pub fn releaseConnection(db: Database) void {
        if (use_pool) {
            if (global_pool) |*pool| {
                pool.release(db);
            }
        }
    }

    pub fn isInitialized() bool {
        return initialized.load(.acquire);
    }

    pub fn isUsingPool() bool {
        return use_pool and initialized.load(.acquire);
    }

    /// Closes all connections and cleans up the singleton state.
    pub fn deinit() void {
        init_mutex.lock();
        defer init_mutex.unlock();

        if (!initialized.load(.acquire)) {
            return;
        }

        if (use_pool) {
            if (global_pool) |*pool| {
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

test "DatabaseSingleton init and get" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";

    try DatabaseSingleton.init(test_db_path, allocator);
    defer DatabaseSingleton.deinit();

    try std.testing.expect(DatabaseSingleton.isInitialized());

    const orm = try DatabaseSingleton.get();
    _ = orm;

    const db = try DatabaseSingleton.getDatabase();
    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)");
}

test "DatabaseSingleton idempotent init" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";

    try DatabaseSingleton.init(test_db_path, allocator);
    defer DatabaseSingleton.deinit();

    try DatabaseSingleton.init(test_db_path, allocator);
}

test "DatabaseSingleton error when not initialized" {
    if (DatabaseSingleton.isInitialized()) {
        DatabaseSingleton.deinit();
    }

    const result = DatabaseSingleton.get();
    try std.testing.expectError(error.DatabaseNotInitialized, result);
}

test "DatabaseSingleton initWithConfig - SQLite" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";
    const config = DatabaseConfig.sqlite(test_db_path);

    try DatabaseSingleton.initWithConfig(config, allocator);
    defer DatabaseSingleton.deinit();

    try std.testing.expect(DatabaseSingleton.isInitialized());

    const orm = try DatabaseSingleton.get();
    _ = orm;

    const db = try DatabaseSingleton.getDatabase();
    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)");
}

test "loadConfigFromEnv - SQLite default" {
    const allocator = std.testing.allocator;
    const config = try loadConfigFromEnv(allocator, "test.db");
    try std.testing.expectEqual(Driver.sqlite, config.driver);
    try std.testing.expectEqualStrings("test.db", config.connection.sqlite.path);
}

test "loadConfigFromEnv - SQLite from env" {
    const allocator = std.testing.allocator;
    try std.posix.setenv("E12_DB_PATH", "custom.db", true);
    defer std.posix.unsetenv("E12_DB_PATH");

    const config = try loadConfigFromEnv(allocator, "default.db");
    try std.testing.expectEqual(Driver.sqlite, config.driver);
    try std.testing.expectEqualStrings("custom.db", config.connection.sqlite.path);
}
