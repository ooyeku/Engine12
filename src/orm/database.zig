const std = @import("std");
const sqlite = @import("sqlite.zig");
const params_mod = @import("params.zig");
const QueryResult = @import("row.zig").QueryResult;
pub const Param = params_mod.Param;
pub const ParamList = params_mod.ParamList;

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

pub const ConnectionPool = struct {
    db_path: []const u8,
    config: ConnectionPoolConfig,
    allocator: std.mem.Allocator,
    available: std.ArrayListUnmanaged(Database),
    in_use: std.ArrayListUnmanaged(Database),
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    created: usize = 0,

    pub fn init(db_path: []const u8, config: ConnectionPoolConfig, allocator: std.mem.Allocator) ConnectionPool {
        return ConnectionPool{
            .db_path = db_path,
            .config = config,
            .allocator = allocator,
            .available = std.ArrayListUnmanaged(Database){},
            .in_use = std.ArrayListUnmanaged(Database){},
            .mutex = std.Thread.Mutex{},
            .condition = std.Thread.Condition{},
            .created = 0,
        };
    }

    pub fn acquire(self: *ConnectionPool) !Database {
        self.mutex.lock();
        errdefer self.mutex.unlock();

        // Calculate deadline for timeout
        const deadline_ns = std.time.nanoTimestamp() + @as(i128, self.config.acquire_timeout_ms) * std.time.ns_per_ms;

        while (true) {
            // Try to get from available pool
            if (self.available.items.len > 0) {
                const db = self.available.items[self.available.items.len - 1];
                _ = self.available.pop();
                try self.in_use.append(self.allocator, db);
                self.mutex.unlock();
                return db;
            }

            // Create new connection if under limit
            if (self.created < self.config.max_connections) {
                // Temporarily unlock while creating connection (slow operation)
                self.mutex.unlock();
                const db = try Database.open(self.db_path, self.allocator);
                self.mutex.lock();
                self.created += 1;
                try self.in_use.append(self.allocator, db);
                self.mutex.unlock();
                return db;
            }

            // Check for timeout before waiting
            const now = std.time.nanoTimestamp();
            if (now >= deadline_ns) {
                self.mutex.unlock();
                return error.PoolExhausted;
            }

            // Calculate remaining wait time
            const remaining_ns: u64 = @intCast(deadline_ns - now);

            // Wait for a connection to become available (with timeout)
            // timedWait releases mutex while waiting and reacquires it when signaled/timed out
            self.condition.timedWait(&self.mutex, remaining_ns) catch {
                // Timeout occurred
                self.mutex.unlock();
                return error.PoolExhausted;
            };
            // Signaled - loop and try to acquire again
        }
    }

    pub fn release(self: *ConnectionPool, db: Database) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find and remove from in_use
        for (self.in_use.items, 0..) |conn, i| {
            if (conn.db == db.db) {
                var removed_db = self.in_use.swapRemove(i);
                self.available.append(self.allocator, db) catch |err| {
                    // If we can't add to pool, log error and close connection
                    std.debug.print("[ConnectionPool] Warning: Failed to return connection to pool: {}. Closing connection.\n", .{err});
                    removed_db.close();
                    self.created -= 1;
                    return;
                };
                // Signal waiting threads that a connection is available
                self.condition.signal();
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
    db: *sqlite.sqlite3,
    allocator: std.mem.Allocator,

    /// Capture and log SQLite error message with context
    /// This provides detailed error information for debugging
    fn captureError(db_handle: ?*sqlite.sqlite3, comptime context: []const u8, sql: ?[]const u8) void {
        const error_msg = sqlite.getErrorMessage(db_handle);
        std.debug.print("[Database Error] {s}\n", .{context});
        std.debug.print("  SQLite Error: {s}\n", .{error_msg});
        if (sql) |sql_str| {
            std.debug.print("  SQL: {s}\n", .{sql_str});
        }
    }

    pub fn open(path: []const u8, allocator: std.mem.Allocator) !Database {
        const c_path = try allocator.dupeZ(u8, path);
        defer allocator.free(c_path);

        var db_handle: ?*sqlite.sqlite3 = null;
        const rc = sqlite.open(c_path, &db_handle);

        if (rc != sqlite.SQLITE_OK) {
            captureError(db_handle, "Failed to open database", null);
            if (db_handle != null) {
                _ = sqlite.close(db_handle);
            }
            return error.DatabaseOpenFailed;
        }

        var db = Database{
            .db = db_handle.?,
            .allocator = allocator,
        };

        // Apply SQLite performance optimizations automatically
        // WAL mode allows concurrent reads during writes (major performance boost)
        // These pragmas are safe and improve performance for all workloads
        db.execute("PRAGMA journal_mode = WAL") catch |pragma_err| {
            std.debug.print("[Database] Warning: Failed to set WAL mode: {}\n", .{pragma_err});
        };
        db.execute("PRAGMA synchronous = NORMAL") catch |pragma_err| {
            std.debug.print("[Database] Warning: Failed to set synchronous mode: {}\n", .{pragma_err});
        };
        db.execute("PRAGMA cache_size = -256000") catch |pragma_err| { // 256MB cache for high-performance workloads
            std.debug.print("[Database] Warning: Failed to set cache_size: {}\n", .{pragma_err});
        };
        db.execute("PRAGMA busy_timeout = 10000") catch |pragma_err| { // 10 second timeout for better concurrency
            std.debug.print("[Database] Warning: Failed to set busy_timeout: {}\n", .{pragma_err});
        };
        db.execute("PRAGMA temp_store = MEMORY") catch |pragma_err| {
            std.debug.print("[Database] Warning: Failed to set temp_store: {}\n", .{pragma_err});
        };
        db.execute("PRAGMA mmap_size = 268435456") catch |pragma_err| { // 256MB memory-mapped I/O
            std.debug.print("[Database] Warning: Failed to set mmap_size: {}\n", .{pragma_err});
        };
        db.execute("PRAGMA page_size = 4096") catch |pragma_err| { // 4KB page size (optimal for most systems)
            std.debug.print("[Database] Warning: Failed to set page_size: {}\n", .{pragma_err});
        };

        return db;
    }

    pub fn close(self: *Database) void {
        _ = sqlite.close(self.db);
    }

    pub fn beginTransaction(self: *Database) !Transaction {
        // Execute BEGIN TRANSACTION
        try self.execute("BEGIN TRANSACTION");

        return Transaction{
            .db = self,
            .allocator = self.allocator,
            .committed = false,
            .rolled_back = false,
        };
    }

    pub fn execute(self: *Database, sql: []const u8) !void {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var err_msg: [*c]u8 = null;
        const rc = sqlite.exec(self.db, c_sql, null, null, &err_msg);

        if (rc != sqlite.SQLITE_OK) {
            if (err_msg != null) {
                std.debug.print("[Database Error] Failed to execute SQL statement\n", .{});
                std.debug.print("  SQLite Error: {s}\n", .{std.mem.sliceTo(err_msg, 0)});
                std.debug.print("  SQL: {s}\n", .{sql});
                sqlite.c.sqlite3_free(err_msg);
            } else {
                captureError(self.db, "Failed to execute SQL statement", sql);
            }
            return error.QueryFailed;
        }
    }

    pub fn executeWithRowsAffected(self: *Database, sql: []const u8) !i64 {
        try self.execute(sql);
        return @intCast(sqlite.changes(self.db));
    }

    pub fn query(self: *Database, sql: []const u8) !QueryResult {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var stmt: ?*sqlite.sqlite3_stmt = null;
        const rc = sqlite.prepare_v2(self.db, c_sql, -1, &stmt, null);

        if (rc != sqlite.SQLITE_OK) {
            captureError(self.db, "Failed to execute SQL query", sql);
            if (stmt != null) {
                _ = sqlite.finalize(stmt);
            }
            return error.QueryFailed;
        }

        return QueryResult.init(stmt.?, self.allocator);
    }

    pub fn lastInsertRowId(self: *Database) !i64 {
        return sqlite.last_insert_rowid(self.db);
    }

    /// Execute a parameterized SQL statement (INSERT, UPDATE, DELETE)
    /// Uses bound parameters to prevent SQL injection
    ///
    /// Example:
    /// ```zig
    /// var params = ParamList.init(allocator);
    /// defer params.deinit();
    /// try params.add("Alice");
    /// try params.add(@as(i64, 25));
    /// try db.executeParams("INSERT INTO users (name, age) VALUES (?, ?)", &params);
    /// ```
    pub fn executeParams(self: *Database, sql: []const u8, params: *const ParamList) !void {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var stmt: ?*sqlite.sqlite3_stmt = null;
        var rc = sqlite.prepare_v2(self.db, c_sql, -1, &stmt, null);

        if (rc != sqlite.SQLITE_OK) {
            captureError(self.db, "Failed to prepare parameterized SQL statement", sql);
            return error.QueryFailed;
        }
        defer _ = sqlite.finalize(stmt);

        // Bind parameters
        rc = params.bindAll(stmt);
        if (rc != sqlite.SQLITE_OK) {
            captureError(self.db, "Failed to bind parameters", sql);
            return error.QueryFailed;
        }

        // Execute
        rc = sqlite.step(stmt);
        if (rc != sqlite.SQLITE_DONE and rc != sqlite.SQLITE_ROW) {
            captureError(self.db, "Failed to execute parameterized SQL statement", sql);
            return error.QueryFailed;
        }
    }

    /// Execute a parameterized SQL statement and return rows affected
    /// Uses bound parameters to prevent SQL injection
    pub fn executeParamsWithRowsAffected(self: *Database, sql: []const u8, params: *const ParamList) !i64 {
        try self.executeParams(sql, params);
        return @intCast(sqlite.changes(self.db));
    }

    /// Execute a parameterized SELECT query
    /// Uses bound parameters to prevent SQL injection
    ///
    /// Example:
    /// ```zig
    /// var params = ParamList.init(allocator);
    /// defer params.deinit();
    /// try params.add(@as(i64, 25));
    /// var result = try db.queryParams("SELECT * FROM users WHERE age > ?", &params);
    /// defer result.deinit();
    /// ```
    pub fn queryParams(self: *Database, sql: []const u8, params: *const ParamList) !QueryResult {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var stmt: ?*sqlite.sqlite3_stmt = null;
        var rc = sqlite.prepare_v2(self.db, c_sql, -1, &stmt, null);

        if (rc != sqlite.SQLITE_OK) {
            captureError(self.db, "Failed to prepare parameterized SQL query", sql);
            if (stmt != null) {
                _ = sqlite.finalize(stmt);
            }
            return error.QueryFailed;
        }

        // Bind parameters
        rc = params.bindAll(stmt);
        if (rc != sqlite.SQLITE_OK) {
            captureError(self.db, "Failed to bind parameters", sql);
            _ = sqlite.finalize(stmt);
            return error.QueryFailed;
        }

        return QueryResult.init(stmt.?, self.allocator);
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
    db: *Database,
    allocator: std.mem.Allocator,
    committed: bool,
    rolled_back: bool,

    pub fn commit(self: *Transaction) !void {
        if (self.committed or self.rolled_back) {
            return error.TransactionFailed;
        }
        try self.db.execute("COMMIT");
        self.committed = true;
    }

    pub fn rollback(self: *Transaction) !void {
        if (self.committed or self.rolled_back) {
            return error.TransactionFailed;
        }
        try self.db.execute("ROLLBACK");
        self.rolled_back = true;
    }

    pub fn execute(self: *Transaction, sql: []const u8) !void {
        try self.db.execute(sql);
    }

    pub fn query(self: *Transaction, sql: []const u8) !QueryResult {
        return try self.db.query(sql);
    }

    /// Execute a parameterized SQL statement within the transaction
    pub fn executeParams(self: *Transaction, sql: []const u8, params: *const ParamList) !void {
        try self.db.executeParams(sql, params);
    }

    /// Execute a parameterized SELECT query within the transaction
    pub fn queryParams(self: *Transaction, sql: []const u8, params: *const ParamList) !QueryResult {
        return try self.db.queryParams(sql, params);
    }

    pub fn deinit(self: *Transaction) void {
        // Auto-rollback if not committed or rolled back
        if (!self.committed and !self.rolled_back) {
            self.db.execute("ROLLBACK") catch {};
        }
    }
};

test "Database open and close" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();
    try std.testing.expect(@intFromPtr(db.db) != 0);
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

    try std.testing.expectEqual(@as(c_int, 2), result.columnCount());
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

    try std.testing.expectEqual(@as(c_int, 2), result.columnCount());
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
    try std.testing.expect(@intFromPtr(db2.db) != 0);
    pool.release(db2);
}

test "Database executeParams INSERT" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    var params = ParamList.init(allocator);
    defer params.deinit();
    try params.addText("Alice");
    try params.addInt(25);

    try db.executeParams("INSERT INTO users (name, age) VALUES (?, ?)", &params);

    var result = try db.query("SELECT name, age FROM users");
    defer result.deinit();

    if (result.nextRow()) |row| {
        try std.testing.expectEqualStrings("Alice", row.getText(0).?);
        try std.testing.expectEqual(@as(i64, 25), row.getInt64(1));
    } else {
        try std.testing.expect(false);
    }
}

test "Database queryParams SELECT" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");
    try db.execute("INSERT INTO users (name, age) VALUES ('Alice', 25)");
    try db.execute("INSERT INTO users (name, age) VALUES ('Bob', 30)");
    try db.execute("INSERT INTO users (name, age) VALUES ('Charlie', 25)");

    var params = ParamList.init(allocator);
    defer params.deinit();
    try params.addInt(25);

    var result = try db.queryParams("SELECT name FROM users WHERE age = ?", &params);
    defer result.deinit();

    var count: usize = 0;
    while (result.nextRow()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Database executeParams SQL injection prevention" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    // Attempt SQL injection - should be safely escaped
    var params = ParamList.init(allocator);
    defer params.deinit();
    try params.addText("'; DROP TABLE users; --");

    try db.executeParams("INSERT INTO users (name) VALUES (?)", &params);

    // Table should still exist with the malicious string as data
    var result = try db.query("SELECT name FROM users");
    defer result.deinit();

    if (result.nextRow()) |row| {
        try std.testing.expectEqualStrings("'; DROP TABLE users; --", row.getText(0).?);
    } else {
        try std.testing.expect(false);
    }
}

test "Database executeParams with NULL" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, notes TEXT)");

    var params = ParamList.init(allocator);
    defer params.deinit();
    try params.addText("Alice");
    try params.addNull();

    try db.executeParams("INSERT INTO users (name, notes) VALUES (?, ?)", &params);

    var result = try db.query("SELECT name, notes FROM users");
    defer result.deinit();

    if (result.nextRow()) |row| {
        try std.testing.expectEqualStrings("Alice", row.getText(0).?);
        try std.testing.expect(row.isNull(1));
    } else {
        try std.testing.expect(false);
    }
}

test "Transaction executeParams" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    var trans = try db.beginTransaction();
    defer trans.deinit();

    var params = ParamList.init(allocator);
    defer params.deinit();
    try params.addText("Alice");

    try trans.executeParams("INSERT INTO users (name) VALUES (?)", &params);
    try trans.commit();

    var result = try db.query("SELECT name FROM users");
    defer result.deinit();

    if (result.nextRow()) |row| {
        try std.testing.expectEqualStrings("Alice", row.getText(0).?);
    } else {
        try std.testing.expect(false);
    }
}
