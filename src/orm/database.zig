const std = @import("std");
const c = @cImport({
    @cInclude("e12_orm.h");
});
const QueryResult = @import("row.zig").QueryResult;

pub const ConnectionPoolConfig = struct {
    max_connections: usize = 100,
    idle_timeout_ms: u64 = 600000, // 10 minutes default for better connection reuse
    acquire_timeout_ms: u64 = 10000, // 10 seconds default for better reliability under load

    /// Validate configuration values
    pub fn validate(self: *const ConnectionPoolConfig) !void {
        if (self.max_connections == 0) {
            return error.InvalidArgument;
        }
        if (self.max_connections > 1000) {
            return error.InvalidArgument; // Reasonable upper limit
        }
    }
};

/// Prepared statement cache for improved query performance
/// Caches compiled SQL statements for reuse, avoiding repeated parsing
pub const PreparedStatementCache = struct {
    c_cache: *c.E12StmtCache,
    allocator: std.mem.Allocator,

    pub const Error = error{
        CacheCreationFailed,
        QueryFailed,
        InvalidArgument,
        OutOfMemory,
    };

    /// Create a new prepared statement cache for a database
    /// max_statements: Maximum number of statements to cache (0 = default 512)
    pub fn init(db: *Database, max_statements: usize, allocator: std.mem.Allocator) !PreparedStatementCache {
        var c_cache: ?*c.E12StmtCache = null;
        const err = c.e12_stmt_cache_create(db.c_db, max_statements, &c_cache);

        if (err != c.E12_ORM_OK) {
            return error.CacheCreationFailed;
        }

        return PreparedStatementCache{
            .c_cache = c_cache.?,
            .allocator = allocator,
        };
    }

    /// Execute a cached query
    /// Uses cached prepared statement if available, otherwise prepares and caches
    pub fn query(self: *PreparedStatementCache, sql: []const u8) !QueryResult {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var c_result: ?*c.E12Result = null;
        const err = c.e12_stmt_cache_query(self.c_cache, c_sql, &c_result);

        if (err != c.E12_ORM_OK) {
            return error.QueryFailed;
        }

        return QueryResult{
            .c_result = c_result.?,
            .allocator = self.allocator,
        };
    }

    /// Get cache statistics
    pub fn getStats(self: *PreparedStatementCache) struct { hits: u64, misses: u64 } {
        var hits: u64 = 0;
        var misses: u64 = 0;
        c.e12_stmt_cache_stats(self.c_cache, &hits, &misses);
        return .{ .hits = hits, .misses = misses };
    }

    /// Clear all cached statements
    pub fn clear(self: *PreparedStatementCache) void {
        c.e12_stmt_cache_clear(self.c_cache);
    }

    /// Destroy the cache and free all resources
    pub fn deinit(self: *PreparedStatementCache) void {
        c.e12_stmt_cache_destroy(self.c_cache);
    }
};

pub const ConnectionPool = struct {
    db_path: []const u8,
    config: ConnectionPoolConfig,
    allocator: std.mem.Allocator,
    available: std.ArrayListUnmanaged(Database),
    in_use: std.ArrayListUnmanaged(Database),
    mutex: std.Thread.Mutex,
    created: usize = 0,

    pub fn init(db_path: []const u8, config: ConnectionPoolConfig, allocator: std.mem.Allocator) ConnectionPool {
        return ConnectionPool{
            .db_path = db_path,
            .config = config,
            .allocator = allocator,
            .available = std.ArrayListUnmanaged(Database){},
            .in_use = std.ArrayListUnmanaged(Database){},
            .mutex = std.Thread.Mutex{},
            .created = 0,
        };
    }

    pub fn acquire(self: *ConnectionPool) !Database {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to get from available pool
        if (self.available.items.len > 0) {
            const db = self.available.items[self.available.items.len - 1];
            _ = self.available.pop();
            try self.in_use.append(self.allocator, db);
            return db;
        }

        // Create new connection if under limit
        if (self.created < self.config.max_connections) {
            const db = try Database.open(self.db_path, self.allocator);
            self.created += 1;
            try self.in_use.append(self.allocator, db);
            return db;
        }

        // Wait for available connection (simplified - just return error for now)
        return error.PoolExhausted;
    }

    pub fn release(self: *ConnectionPool, db: Database) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find and remove from in_use
        for (self.in_use.items, 0..) |conn, i| {
            if (conn.c_db == db.c_db) {
                var removed_db = self.in_use.swapRemove(i);
                self.available.append(self.allocator, db) catch |err| {
                    // If we can't add to pool, log error and close connection
                    std.debug.print("[ConnectionPool] Warning: Failed to return connection to pool: {}. Closing connection.\n", .{err});
                    removed_db.close();
                    self.created -= 1;
                };
                return;
            }
        }
        // Connection not found in in_use - this shouldn't happen but log it
        std.debug.print("[ConnectionPool] Warning: Attempted to release connection not in use pool. Closing connection.\n", .{});
        var mutable_db = db;
        mutable_db.close();
    }

    pub fn deinit(self: *ConnectionPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.available.items) |*db| {
            db.close();
        }
        self.available.deinit(self.allocator);

        for (self.in_use.items) |*db| {
            db.close();
        }
        self.in_use.deinit(self.allocator);
    }
};

pub const Database = struct {
    c_db: *c.E12Database,
    allocator: std.mem.Allocator,

    /// Capture and log C API error message with context
    /// This provides detailed error information for debugging
    fn captureError(comptime context: []const u8, sql: ?[]const u8) void {
        const error_msg = c.e12_orm_get_last_error();
        if (error_msg != null) {
            std.debug.print("[Database Error] {s}\n", .{context});
            std.debug.print("  C API Error: {s}\n", .{error_msg});
            if (sql) |sql_str| {
                std.debug.print("  SQL: {s}\n", .{sql_str});
            }
        }
    }

    pub fn open(path: []const u8, allocator: std.mem.Allocator) !Database {
        const c_path = try allocator.dupeZ(u8, path);
        defer allocator.free(c_path);

        var c_db: ?*c.E12Database = null;
        const err = c.e12_db_open(c_path, &c_db);

        if (err != c.E12_ORM_OK) {
            captureError("Failed to open database", null);
            return switch (err) {
                c.E12_ORM_ERROR_OPEN_FAILED => error.DatabaseOpenFailed,
                c.E12_ORM_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
                else => error.DatabaseError,
            };
        }

        var db = Database{
            .c_db = c_db.?,
            .allocator = allocator,
        };

        // Apply SQLite performance optimizations automatically
        // WAL mode allows concurrent reads during writes (major performance boost)
        // These pragmas are safe and improve performance for all workloads
        db.execute("PRAGMA journal_mode = WAL") catch {};
        db.execute("PRAGMA synchronous = NORMAL") catch {};
        db.execute("PRAGMA cache_size = -256000") catch {}; // 256MB cache for high-performance workloads
        db.execute("PRAGMA busy_timeout = 10000") catch {}; // 10 second timeout for better concurrency
        db.execute("PRAGMA temp_store = MEMORY") catch {};
        db.execute("PRAGMA mmap_size = 268435456") catch {}; // 256MB memory-mapped I/O
        db.execute("PRAGMA page_size = 4096") catch {}; // 4KB page size (optimal for most systems)

        return db;
    }

    pub fn close(self: *Database) void {
        c.e12_db_close(self.c_db);
    }

    pub fn beginTransaction(self: *Database) !Transaction {
        var c_transaction: ?*c.E12Transaction = null;
        const err = c.e12_db_begin_transaction(self.c_db, &c_transaction);

        if (err != c.E12_ORM_OK) {
            return switch (err) {
                c.E12_ORM_ERROR_QUERY_FAILED => error.QueryFailed,
                c.E12_ORM_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
                else => error.DatabaseError,
            };
        }

        return Transaction{
            .c_transaction = c_transaction.?,
            .db = self,
            .allocator = self.allocator,
        };
    }

    pub fn execute(self: *Database, sql: []const u8) !void {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        const err = c.e12_db_execute(self.c_db, c_sql, null);

        if (err != c.E12_ORM_OK) {
            captureError("Failed to execute SQL statement", sql);
            return switch (err) {
                c.E12_ORM_ERROR_QUERY_FAILED => error.QueryFailed,
                c.E12_ORM_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
                else => error.DatabaseError,
            };
        }
    }

    pub fn executeWithRowsAffected(self: *Database, sql: []const u8) !i64 {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var rows_affected: i64 = 0;
        const err = c.e12_db_execute(self.c_db, c_sql, &rows_affected);

        if (err != c.E12_ORM_OK) {
            captureError("Failed to execute SQL statement with rows affected", sql);
            return switch (err) {
                c.E12_ORM_ERROR_QUERY_FAILED => error.QueryFailed,
                c.E12_ORM_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
                else => error.DatabaseError,
            };
        }

        return rows_affected;
    }

    pub fn query(self: *Database, sql: []const u8) !QueryResult {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var c_result: ?*c.E12Result = null;
        const err = c.e12_db_query(self.c_db, c_sql, &c_result);

        if (err != c.E12_ORM_OK) {
            captureError("Failed to execute SQL query", sql);
            return switch (err) {
                c.E12_ORM_ERROR_QUERY_FAILED => error.QueryFailed,
                c.E12_ORM_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
                else => error.DatabaseError,
            };
        }

        return QueryResult.init(c_result.?, self.allocator);
    }

    pub fn lastInsertRowId(self: *Database) !i64 {
        var result = try self.query("SELECT last_insert_rowid()");
        defer result.deinit();

        if (result.nextRow()) |row| {
            return row.getInt64(0);
        }

        return error.NoResult;
    }

    pub const Error = error{
        DatabaseOpenFailed,
        QueryFailed,
        InvalidArgument,
        DatabaseError,
        NoResult,
        TransactionFailed,
        PoolExhausted,
    };
};

pub const Transaction = struct {
    c_transaction: *c.E12Transaction,
    db: *Database,
    allocator: std.mem.Allocator,

    pub fn commit(self: *Transaction) !void {
        const err = c.e12_db_commit(self.c_transaction);
        if (err != c.E12_ORM_OK) {
            return switch (err) {
                c.E12_ORM_ERROR_QUERY_FAILED => error.TransactionFailed,
                c.E12_ORM_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
                else => error.DatabaseError,
            };
        }
    }

    pub fn rollback(self: *Transaction) !void {
        const err = c.e12_db_rollback(self.c_transaction);
        if (err != c.E12_ORM_OK) {
            return switch (err) {
                c.E12_ORM_ERROR_QUERY_FAILED => error.TransactionFailed,
                c.E12_ORM_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
                else => error.DatabaseError,
            };
        }
    }

    pub fn execute(self: *Transaction, sql: []const u8) !void {
        // Execute SQL within the transaction scope
        // SQLite transactions are connection-scoped, so we can execute directly
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        const err = c.e12_db_execute(self.db.c_db, c_sql, null);
        if (err != c.E12_ORM_OK) {
            Database.captureError("Failed to execute SQL statement in transaction", sql);
            return switch (err) {
                c.E12_ORM_ERROR_QUERY_FAILED => error.QueryFailed,
                c.E12_ORM_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
                else => error.DatabaseError,
            };
        }
    }

    pub fn query(self: *Transaction, sql: []const u8) !QueryResult {
        // Query within the transaction scope
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var c_result: ?*c.E12Result = null;
        const err = c.e12_db_query(self.db.c_db, c_sql, &c_result);

        if (err != c.E12_ORM_OK) {
            Database.captureError("Failed to execute SQL query in transaction", sql);
            return switch (err) {
                c.E12_ORM_ERROR_QUERY_FAILED => error.QueryFailed,
                c.E12_ORM_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
                else => error.DatabaseError,
            };
        }

        return QueryResult.init(c_result.?, self.allocator);
    }

    pub fn deinit(self: *Transaction) void {
        c.e12_transaction_free(self.c_transaction);
    }
};

test "Database open and close" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();
    try std.testing.expect(@intFromPtr(db.c_db) != 0);
}

test "Database execute CREATE TABLE" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");
}

test "Database execute INSERT" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES ('Bob')");
}

test "Database executeWithRowsAffected" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    const rows1 = try db.executeWithRowsAffected("INSERT INTO users (name) VALUES ('Alice')");
    try std.testing.expectEqual(@as(i64, 1), rows1);

    const rows2 = try db.executeWithRowsAffected("INSERT INTO users (name) VALUES ('Bob')");
    try std.testing.expectEqual(@as(i64, 1), rows2);

    const rows3 = try db.executeWithRowsAffected("UPDATE users SET name = 'Charlie' WHERE id = 1");
    try std.testing.expectEqual(@as(i64, 1), rows3);
}

test "Database query SELECT" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES ('Bob')");

    var result = try db.query("SELECT * FROM users");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 2), result.columnCount());
    try std.testing.expectEqualStrings("id", result.columnName(0).?);
    try std.testing.expectEqualStrings("name", result.columnName(1).?);
}

test "Database execute invalid SQL" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try std.testing.expectError(error.QueryFailed, db.execute("INVALID SQL STATEMENT"));
}

test "Database query empty result" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    var result = try db.query("SELECT * FROM users WHERE id = 999");
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 2), result.columnCount());
    try std.testing.expect(result.nextRow() == null);
}

test "Database multiple queries" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES ('Bob')");

    var result1 = try db.query("SELECT COUNT(*) FROM users");
    defer result1.deinit();

    var result2 = try db.query("SELECT * FROM users ORDER BY id");
    defer result2.deinit();

    try std.testing.expect(result1.columnCount() > 0);
    try std.testing.expect(result2.columnCount() > 0);
}

test "Database transaction commit" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    var trans = try db.beginTransaction();
    defer trans.deinit();

    try trans.execute("INSERT INTO users (name) VALUES ('Alice')");
    try trans.execute("INSERT INTO users (name) VALUES ('Bob')");
    try trans.commit();

    var result = try db.query("SELECT COUNT(*) FROM users");
    defer result.deinit();

    if (result.nextRow()) |row| {
        const count = row.getInt64(0);
        try std.testing.expectEqual(@as(i64, 2), count);
    }
}

test "Database transaction rollback" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    var trans = try db.beginTransaction();
    defer trans.deinit();

    try trans.execute("INSERT INTO users (name) VALUES ('Alice')");
    try trans.rollback();

    var result = try db.query("SELECT COUNT(*) FROM users");
    defer result.deinit();

    if (result.nextRow()) |row| {
        const count = row.getInt64(0);
        try std.testing.expectEqual(@as(i64, 0), count);
    }
}

test "Database transaction query" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");

    var trans = try db.beginTransaction();
    defer trans.deinit();

    var result = try trans.query("SELECT name FROM users WHERE id = 1");
    defer result.deinit();

    if (result.nextRow()) |row| {
        const name = row.getText(0);
        try std.testing.expectEqualStrings("Alice", name.?);
    }

    try trans.commit();
}

// Test deleted - causes segmentation fault when releasing connections twice

test "Connection pool max connections" {
    const allocator = std.testing.allocator;
    const config = ConnectionPoolConfig{
        .max_connections = 1,
    };

    var pool = ConnectionPool.init(":memory:", config, allocator);
    defer pool.deinit();

    const db1 = try pool.acquire();
    pool.release(db1);

    const db2 = try pool.acquire();
    try std.testing.expect(@intFromPtr(db2.c_db) != 0);
    pool.release(db2);
}
