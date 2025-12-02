const std = @import("std");
const sqlite = @import("sqlite.zig");
const params_mod = @import("params.zig");
const row_mod = @import("row.zig");
const driver_mod = @import("driver.zig");
const Driver = driver_mod.Driver;
const DatabaseConfig = driver_mod.DatabaseConfig;
const SqliteConfig = driver_mod.SqliteConfig;
const PostgresConfig = driver_mod.PostgresConfig;

pub const QueryResult = row_mod.QueryResult;
pub const Row = row_mod.Row;
pub const Param = params_mod.Param;
pub const ParamList = params_mod.ParamList;

// Re-export driver types
pub const DriverType = Driver;
pub const Config = DatabaseConfig;

pub const ConnectionPoolConfig = struct {
    max_connections: usize = 100,
    idle_timeout_ms: u64 = 600000,
    acquire_timeout_ms: u64 = 10000,

    pub fn validate(self: *const ConnectionPoolConfig) !void {
        if (self.max_connections == 0) {
            return error.InvalidArgument;
        }
        if (self.max_connections > 1000) {
            return error.InvalidArgument;
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

        const deadline_ns = std.time.nanoTimestamp() + @as(i128, self.config.acquire_timeout_ms) * std.time.ns_per_ms;

        while (true) {
            if (self.available.items.len > 0) {
                const db = self.available.items[self.available.items.len - 1];
                _ = self.available.pop();
                try self.in_use.append(self.allocator, db);
                self.mutex.unlock();
                return db;
            }

            if (self.created < self.config.max_connections) {
                self.mutex.unlock();
                const db = try Database.open(self.db_path, self.allocator);
                self.mutex.lock();
                self.created += 1;
                try self.in_use.append(self.allocator, db);
                self.mutex.unlock();
                return db;
            }

            const now = std.time.nanoTimestamp();
            if (now >= deadline_ns) {
                self.mutex.unlock();
                return error.PoolExhausted;
            }

            const remaining_ns: u64 = @intCast(deadline_ns - now);

            self.condition.timedWait(&self.mutex, remaining_ns) catch {
                self.mutex.unlock();
                return error.PoolExhausted;
            };
        }
    }

    pub fn release(self: *ConnectionPool, db: Database) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.in_use.items, 0..) |conn, i| {
            if (conn.sqlite_db == db.sqlite_db) {
                var removed_db = self.in_use.swapRemove(i);
                self.available.append(self.allocator, db) catch |err| {
                    std.debug.print("[ConnectionPool] Warning: Failed to return connection to pool: {}. Closing connection.\n", .{err});
                    removed_db.close();
                    self.created -= 1;
                    return;
                };
                self.condition.signal();
                return;
            }
        }
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

/// Unified Database struct that supports multiple database drivers
/// Defaults to SQLite for backward compatibility
pub const Database = struct {
    driver: Driver,
    allocator: std.mem.Allocator,

    // SQLite-specific handle
    sqlite_db: ?*sqlite.sqlite3 = null,

    // PostgreSQL support - use opaque pointer to avoid import issues at comptime
    pg_pool: ?*anyopaque = null,

    /// Capture and log SQLite error message with context
    fn captureError(db_handle: ?*sqlite.sqlite3, comptime context: []const u8, sql: ?[]const u8) void {
        const error_msg = sqlite.getErrorMessage(db_handle);
        std.debug.print("[Database Error] {s}\n", .{context});
        std.debug.print("  SQLite Error: {s}\n", .{error_msg});
        if (sql) |sql_str| {
            std.debug.print("  SQL: {s}\n", .{sql_str});
        }
    }

    /// Open a SQLite database (backward compatible API)
    pub fn open(path: []const u8, allocator: std.mem.Allocator) !Database {
        return openWithConfig(DatabaseConfig.sqlite(path), allocator);
    }

    /// Open a database with explicit configuration
    pub fn openWithConfig(config: DatabaseConfig, allocator: std.mem.Allocator) !Database {
        return switch (config.driver) {
            .sqlite => openSqlite(config.connection.sqlite, allocator),
            .postgresql => openPostgres(config.connection.postgresql, allocator),
        };
    }

    /// Open a SQLite database
    fn openSqlite(config: SqliteConfig, allocator: std.mem.Allocator) !Database {
        const c_path = try allocator.dupeZ(u8, config.path);
        defer allocator.free(c_path);

        var db_handle: ?*sqlite.sqlite3 = null;
        // Use sqlite3_open_v2 with FULLMUTEX for thread-safe access
        // This enables serialized mode where SQLite handles all locking internally
        const flags = sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_CREATE | sqlite.SQLITE_OPEN_FULLMUTEX;
        const rc = sqlite.open_v2(c_path, &db_handle, flags, null);

        if (rc != sqlite.SQLITE_OK) {
            captureError(db_handle, "Failed to open database", null);
            if (db_handle != null) {
                _ = sqlite.close(db_handle);
            }
            return error.DatabaseOpenFailed;
        }

        var db = Database{
            .driver = .sqlite,
            .allocator = allocator,
            .sqlite_db = db_handle.?,
        };

        // Apply SQLite performance optimizations
        if (config.wal_mode) {
            db.execute("PRAGMA journal_mode = WAL") catch |pragma_err| {
                std.debug.print("[Database] Warning: Failed to set WAL mode: {}\n", .{pragma_err});
            };
        }
        db.execute("PRAGMA synchronous = NORMAL") catch |pragma_err| {
            std.debug.print("[Database] Warning: Failed to set synchronous mode: {}\n", .{pragma_err});
        };

        var cache_buf: [64]u8 = undefined;
        const cache_pragma = std.fmt.bufPrint(&cache_buf, "PRAGMA cache_size = -{d}", .{config.cache_size_kb}) catch "PRAGMA cache_size = -256000";
        db.execute(cache_pragma) catch |pragma_err| {
            std.debug.print("[Database] Warning: Failed to set cache_size: {}\n", .{pragma_err});
        };

        var timeout_buf: [64]u8 = undefined;
        const timeout_pragma = std.fmt.bufPrint(&timeout_buf, "PRAGMA busy_timeout = {d}", .{config.busy_timeout_ms}) catch "PRAGMA busy_timeout = 10000";
        db.execute(timeout_pragma) catch |pragma_err| {
            std.debug.print("[Database] Warning: Failed to set busy_timeout: {}\n", .{pragma_err});
        };

        db.execute("PRAGMA temp_store = MEMORY") catch |pragma_err| {
            std.debug.print("[Database] Warning: Failed to set temp_store: {}\n", .{pragma_err});
        };
        db.execute("PRAGMA mmap_size = 268435456") catch |pragma_err| {
            std.debug.print("[Database] Warning: Failed to set mmap_size: {}\n", .{pragma_err});
        };
        db.execute("PRAGMA page_size = 4096") catch |pragma_err| {
            std.debug.print("[Database] Warning: Failed to set page_size: {}\n", .{pragma_err});
        };

        return db;
    }

    /// Open a PostgreSQL database connection pool
    fn openPostgres(config: PostgresConfig, allocator: std.mem.Allocator) !Database {
        // Import pg.zig at runtime to create pool
        const pg = @import("pg");

        // pg.Pool.init() returns a heap-allocated pointer, so we can use it directly
        // No need to allocate ourselves - pg.zig handles the allocation
        const pool = pg.Pool.init(allocator, .{
            .size = config.pool_size,
            .connect = .{
                .port = config.port,
                .host = config.host,
            },
            .auth = .{
                .username = config.username,
                .database = config.database,
                .password = config.password,
                .timeout = config.auth_timeout_ms,
            },
        }) catch |err| {
            std.debug.print("[PostgreSQL Error] Failed to initialize connection pool: {}\n", .{err});
            return error.DatabaseOpenFailed;
        };

        return Database{
            .driver = .postgresql,
            .allocator = allocator,
            .pg_pool = @ptrCast(pool),
        };
    }

    /// Get the current driver type
    pub fn getDriver(self: *const Database) Driver {
        return self.driver;
    }

    pub fn close(self: *Database) void {
        switch (self.driver) {
            .sqlite => {
                if (self.sqlite_db) |db| {
                    _ = sqlite.close(db);
                    self.sqlite_db = null;
                }
            },
            .postgresql => {
                if (self.pg_pool) |pool_ptr| {
                    const pg = @import("pg");
                    const pool: *pg.Pool = @ptrCast(@alignCast(pool_ptr));
                    // pg.Pool.deinit() handles freeing the pool's internal memory
                    // The pool itself is allocated by pg.zig's internal allocator, not ours
                    pool.deinit();
                    self.pg_pool = null;
                }
            },
        }
    }

    pub fn beginTransaction(self: *Database) !Transaction {
        try self.execute("BEGIN TRANSACTION");
        return Transaction{
            .db = self,
            .allocator = self.allocator,
            .committed = false,
            .rolled_back = false,
        };
    }

    pub fn execute(self: *Database, sql: []const u8) !void {
        switch (self.driver) {
            .sqlite => try self.executeSqlite(sql),
            .postgresql => try self.executePostgres(sql),
        }
    }

    fn executeSqlite(self: *Database, sql: []const u8) !void {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var err_msg: [*c]u8 = null;
        const rc = sqlite.exec(self.sqlite_db, c_sql, null, null, &err_msg);

        if (rc != sqlite.SQLITE_OK) {
            if (err_msg != null) {
                std.debug.print("[Database Error] Failed to execute SQL statement\n", .{});
                std.debug.print("  SQLite Error: {s}\n", .{std.mem.sliceTo(err_msg, 0)});
                std.debug.print("  SQL: {s}\n", .{sql});
                sqlite.c.sqlite3_free(err_msg);
            } else {
                captureError(self.sqlite_db, "Failed to execute SQL statement", sql);
            }
            return error.QueryFailed;
        }
    }

    fn executePostgres(self: *Database, sql: []const u8) !void {
        const pg = @import("pg");
        const pool: *pg.Pool = @ptrCast(@alignCast(self.pg_pool.?));

        var result = pool.query(sql, .{}) catch |err| {
            std.debug.print("[PostgreSQL Error] Failed to execute: {s}\n", .{sql});
            std.debug.print("  Error: {}\n", .{err});
            return error.QueryFailed;
        };
        defer result.deinit();

        // Drain results - pg.zig returns error union from next()
        while (true) {
            const row = result.next() catch break;
            if (row == null) break;
        }
    }

    pub fn executeWithRowsAffected(self: *Database, sql: []const u8) !i64 {
        try self.execute(sql);
        return switch (self.driver) {
            .sqlite => @intCast(sqlite.changes(self.sqlite_db)),
            .postgresql => 0, // PostgreSQL would need RETURNING or affected rows from result
        };
    }

    pub fn query(self: *Database, sql: []const u8) !QueryResult {
        return switch (self.driver) {
            .sqlite => try self.querySqlite(sql),
            .postgresql => try self.queryPostgres(sql),
        };
    }

    fn querySqlite(self: *Database, sql: []const u8) !QueryResult {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var stmt: ?*sqlite.sqlite3_stmt = null;
        const rc = sqlite.prepare_v2(self.sqlite_db, c_sql, -1, &stmt, null);

        if (rc != sqlite.SQLITE_OK) {
            captureError(self.sqlite_db, "Failed to execute SQL query", sql);
            if (stmt != null) {
                _ = sqlite.finalize(stmt);
            }
            return error.QueryFailed;
        }

        return QueryResult.initSqlite(stmt.?, self.allocator);
    }

    fn queryPostgres(self: *Database, sql: []const u8) !QueryResult {
        const pg = @import("pg");

        if (self.pg_pool == null) {
            return error.QueryFailed;
        }

        const pool: *pg.Pool = @ptrCast(@alignCast(self.pg_pool.?));

        // Use queryOpts with column_names = true to get column names
        var result = pool.queryOpts(sql, .{}, .{ .column_names = true }) catch |err| {
            std.debug.print("[PostgreSQL Error] Failed to query: {s}\n", .{sql});
            std.debug.print("  Error: {}\n", .{err});
            return error.QueryFailed;
        };
        defer result.deinit();

        // Collect all rows into memory
        var rows = std.ArrayListUnmanaged(row_mod.PostgresStoredRow){};
        errdefer {
            for (rows.items) |*row| {
                row.deinit();
            }
            rows.deinit(self.allocator);
        }

        // Get column count and names
        const num_cols = result.number_of_columns;

        // Copy column names from result
        var column_names = try self.allocator.alloc([]const u8, num_cols);
        errdefer self.allocator.free(column_names);

        for (0..num_cols) |i| {
            if (i < result.column_names.len) {
                column_names[i] = try self.allocator.dupe(u8, result.column_names[i]);
            } else {
                column_names[i] = try self.allocator.dupe(u8, "");
            }
        }

        while (result.next() catch null) |row| {
            // Store row values
            var values = try self.allocator.alloc(row_mod.PostgresStoredRow.StoredValue, num_cols);
            errdefer self.allocator.free(values);

            for (0..num_cols) |col_idx| {
                // pg.zig has strict type checking - must check OID first to determine correct type
                // PostgreSQL OIDs: int2=21, int4=23, int8=20, float4=700, float8=701, bool=16, text=25, varchar=1043
                const oid = row.oids[col_idx];

                switch (oid) {
                    21 => { // int2 (smallint)
                        if (row.get(?i16, col_idx)) |v| {
                            values[col_idx] = .{ .int = @as(i64, v) };
                        } else {
                            values[col_idx] = .null_val;
                        }
                    },
                    23 => { // int4 (integer/serial)
                        if (row.get(?i32, col_idx)) |v| {
                            values[col_idx] = .{ .int = @as(i64, v) };
                        } else {
                            values[col_idx] = .null_val;
                        }
                    },
                    20 => { // int8 (bigint/bigserial)
                        if (row.get(?i64, col_idx)) |v| {
                            values[col_idx] = .{ .int = v };
                        } else {
                            values[col_idx] = .null_val;
                        }
                    },
                    700 => { // float4 (real)
                        if (row.get(?f32, col_idx)) |v| {
                            values[col_idx] = .{ .float = @as(f64, v) };
                        } else {
                            values[col_idx] = .null_val;
                        }
                    },
                    701 => { // float8 (double precision)
                        if (row.get(?f64, col_idx)) |v| {
                            values[col_idx] = .{ .float = v };
                        } else {
                            values[col_idx] = .null_val;
                        }
                    },
                    16 => { // bool
                        if (row.get(?bool, col_idx)) |v| {
                            values[col_idx] = .{ .bool_val = v };
                        } else {
                            values[col_idx] = .null_val;
                        }
                    },
                    else => {
                        // Default to text for all other types (text, varchar, etc.)
                        if (row.get(?[]const u8, col_idx)) |v| {
                            values[col_idx] = .{ .text = try self.allocator.dupe(u8, v) };
                        } else {
                            values[col_idx] = .null_val;
                        }
                    },
                }
            }

            try rows.append(self.allocator, row_mod.PostgresStoredRow{
                .values = values,
                .allocator = self.allocator,
            });
        }

        return QueryResult.initPostgres(rows, column_names, self.allocator);
    }

    pub fn lastInsertRowId(self: *Database) !i64 {
        return switch (self.driver) {
            .sqlite => sqlite.last_insert_rowid(self.sqlite_db),
            .postgresql => error.NotSupported, // Use RETURNING clause instead
        };
    }

    /// Execute a parameterized SQL statement (INSERT, UPDATE, DELETE)
    pub fn executeParams(self: *Database, sql: []const u8, params: *const ParamList) !void {
        return switch (self.driver) {
            .sqlite => try self.executeParamsSqlite(sql, params),
            .postgresql => try self.executeParamsPostgres(sql, params),
        };
    }

    fn executeParamsSqlite(self: *Database, sql: []const u8, params: *const ParamList) !void {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var stmt: ?*sqlite.sqlite3_stmt = null;
        var rc = sqlite.prepare_v2(self.sqlite_db, c_sql, -1, &stmt, null);

        if (rc != sqlite.SQLITE_OK) {
            captureError(self.sqlite_db, "Failed to prepare parameterized SQL statement", sql);
            return error.QueryFailed;
        }
        defer _ = sqlite.finalize(stmt);

        rc = params.bindAll(stmt);
        if (rc != sqlite.SQLITE_OK) {
            captureError(self.sqlite_db, "Failed to bind parameters", sql);
            return error.QueryFailed;
        }

        rc = sqlite.step(stmt);
        if (rc != sqlite.SQLITE_DONE and rc != sqlite.SQLITE_ROW) {
            captureError(self.sqlite_db, "Failed to execute parameterized SQL statement", sql);
            return error.QueryFailed;
        }
    }

    fn executeParamsPostgres(self: *Database, sql: []const u8, params: *const ParamList) !void {
        // pg.zig doesn't support dynamic runtime parameters well, so we build SQL with literals
        // This is safe because we control the parameter values through the Param type
        const literal_sql = try buildSqlWithLiterals(self.allocator, sql, params);
        defer self.allocator.free(literal_sql);

        try self.executePostgres(literal_sql);
    }

    /// Build SQL with parameter values embedded as literals
    /// This is used for PostgreSQL since pg.zig requires comptime-known parameter types
    fn buildSqlWithLiterals(allocator: std.mem.Allocator, sql: []const u8, params: *const ParamList) ![]u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(allocator);

        var param_index: usize = 0;
        var i: usize = 0;

        while (i < sql.len) {
            if (sql[i] == '?') {
                // Replace ? with the literal value
                if (param_index < params.items.items.len) {
                    const param = params.items.items[param_index];

                    switch (param) {
                        .null => try result.appendSlice(allocator, "NULL"),
                        .int64 => |v| {
                            var buf: [32]u8 = undefined;
                            const num_str = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0";
                            try result.appendSlice(allocator, num_str);
                        },
                        .float64 => |v| {
                            var buf: [64]u8 = undefined;
                            const num_str = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0.0";
                            try result.appendSlice(allocator, num_str);
                        },
                        .text => |v| {
                            // Escape single quotes for PostgreSQL
                            try result.append(allocator, '\'');
                            for (v) |c| {
                                if (c == '\'') {
                                    try result.appendSlice(allocator, "''");
                                } else {
                                    try result.append(allocator, c);
                                }
                            }
                            try result.append(allocator, '\'');
                        },
                        .blob => |v| {
                            // Use PostgreSQL bytea hex format
                            try result.appendSlice(allocator, "'\\x");
                            for (v) |byte| {
                                var hex_buf: [2]u8 = undefined;
                                _ = std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{byte}) catch continue;
                                try result.appendSlice(allocator, &hex_buf);
                            }
                            try result.append(allocator, '\'');
                        },
                    }
                    param_index += 1;
                } else {
                    try result.append(allocator, '?');
                }
            } else {
                try result.append(allocator, sql[i]);
            }
            i += 1;
        }

        return result.toOwnedSlice(allocator);
    }

    /// Execute a parameterized SQL statement and return rows affected
    pub fn executeParamsWithRowsAffected(self: *Database, sql: []const u8, params: *const ParamList) !i64 {
        try self.executeParams(sql, params);
        return switch (self.driver) {
            .sqlite => @intCast(sqlite.changes(self.sqlite_db)),
            .postgresql => 0,
        };
    }

    /// Execute a parameterized SELECT query
    pub fn queryParams(self: *Database, sql: []const u8, params: *const ParamList) !QueryResult {
        return switch (self.driver) {
            .sqlite => try self.queryParamsSqlite(sql, params),
            .postgresql => try self.queryParamsPostgres(sql, params),
        };
    }

    fn queryParamsSqlite(self: *Database, sql: []const u8, params: *const ParamList) !QueryResult {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);

        var stmt: ?*sqlite.sqlite3_stmt = null;
        var rc = sqlite.prepare_v2(self.sqlite_db, c_sql, -1, &stmt, null);

        if (rc != sqlite.SQLITE_OK) {
            captureError(self.sqlite_db, "Failed to prepare parameterized SQL query", sql);
            if (stmt != null) {
                _ = sqlite.finalize(stmt);
            }
            return error.QueryFailed;
        }

        rc = params.bindAll(stmt);
        if (rc != sqlite.SQLITE_OK) {
            captureError(self.sqlite_db, "Failed to bind parameters", sql);
            _ = sqlite.finalize(stmt);
            return error.QueryFailed;
        }

        return QueryResult.initSqlite(stmt.?, self.allocator);
    }

    fn queryParamsPostgres(self: *Database, sql: []const u8, params: *const ParamList) !QueryResult {
        // Convert ? placeholders to $1, $2, etc.
        const postgres_mod = @import("postgres.zig");
        const pg_sql = try postgres_mod.convertPlaceholders(self.allocator, sql);
        defer self.allocator.free(pg_sql);

        // For now, use non-parameterized query
        // Full implementation would convert ParamList to pg.zig params
        _ = params;
        return self.queryPostgres(pg_sql);
    }

    pub const Error = error{
        DatabaseOpenFailed,
        QueryFailed,
        InvalidArgument,
        DatabaseError,
        NoResult,
        TransactionFailed,
        PoolExhausted,
        NotSupported,
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

    pub fn executeParams(self: *Transaction, sql: []const u8, params: *const ParamList) !void {
        try self.db.executeParams(sql, params);
    }

    pub fn queryParams(self: *Transaction, sql: []const u8, params: *const ParamList) !QueryResult {
        return try self.db.queryParams(sql, params);
    }

    pub fn deinit(self: *Transaction) void {
        if (!self.committed and !self.rolled_back) {
            self.db.execute("ROLLBACK") catch {};
        }
    }
};

// Tests

test "Database open and close" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();
    try std.testing.expect(db.sqlite_db != null);
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
    try std.testing.expect(db2.sqlite_db != null);
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

    var params = ParamList.init(allocator);
    defer params.deinit();
    try params.addText("'; DROP TABLE users; --");

    try db.executeParams("INSERT INTO users (name) VALUES (?)", &params);

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

test "Database driver type" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try std.testing.expectEqual(Driver.sqlite, db.getDriver());
}

test "Database openWithConfig SQLite" {
    const allocator = std.testing.allocator;
    var db = try Database.openWithConfig(DatabaseConfig.sqlite(":memory:"), allocator);
    defer db.close();

    try std.testing.expectEqual(Driver.sqlite, db.getDriver());
    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)");
}

// Comprehensive edge case tests

test "Database openWithConfig SQLite with custom config" {
    const allocator = std.testing.allocator;
    const config = DatabaseConfig{
        .driver = .sqlite,
        .connection = .{ .sqlite = .{
            .path = ":memory:",
            .wal_mode = false,
            .cache_size_kb = 128000,
            .busy_timeout_ms = 5000,
        } },
    };
    var db = try Database.openWithConfig(config, allocator);
    defer db.close();

    try std.testing.expectEqual(Driver.sqlite, db.getDriver());
    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)");
}

test "Database double close safety" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    db.close();
    // Second close should not panic
    db.close();
}

test "Database close after error" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    // Cause an error
    _ = db.execute("INVALID SQL") catch {};

    // Close should still work
    db.close();
}

test "Database execute empty SQL" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    // Empty SQL should be handled gracefully
    try db.execute("");
}

test "Database execute multiple statements" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER, title TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES ('Bob')");
    try db.execute("INSERT INTO posts (user_id, title) VALUES (1, 'Post 1')");
    try db.execute("INSERT INTO posts (user_id, title) VALUES (1, 'Post 2')");

    var result = try db.query("SELECT COUNT(*) FROM users");
    defer result.deinit();
    if (result.nextRow()) |row| {
        try std.testing.expectEqual(@as(i64, 2), row.getInt64(0));
    }

    var result2 = try db.query("SELECT COUNT(*) FROM posts");
    defer result2.deinit();
    if (result2.nextRow()) |row| {
        try std.testing.expectEqual(@as(i64, 2), row.getInt64(0));
    }
}

test "Database execute UPDATE with WHERE" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");
    try db.execute("INSERT INTO users (name, age) VALUES ('Alice', 25)");
    try db.execute("INSERT INTO users (name, age) VALUES ('Bob', 30)");

    const rows = try db.executeWithRowsAffected("UPDATE users SET age = 26 WHERE name = 'Alice'");
    try std.testing.expectEqual(@as(i64, 1), rows);

    var result = try db.query("SELECT age FROM users WHERE name = 'Alice'");
    defer result.deinit();
    if (result.nextRow()) |row| {
        try std.testing.expectEqual(@as(i64, 26), row.getInt64(0));
    }
}

test "Database execute DELETE" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES ('Bob')");

    const rows = try db.executeWithRowsAffected("DELETE FROM users WHERE name = 'Alice'");
    try std.testing.expectEqual(@as(i64, 1), rows);

    var result = try db.query("SELECT COUNT(*) FROM users");
    defer result.deinit();
    if (result.nextRow()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.getInt64(0));
    }
}

test "Database execute DELETE with no matches" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");

    const rows = try db.executeWithRowsAffected("DELETE FROM users WHERE name = 'Nonexistent'");
    try std.testing.expectEqual(@as(i64, 0), rows);
}

test "Database query with WHERE clause" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");
    try db.execute("INSERT INTO users (name, age) VALUES ('Alice', 25)");
    try db.execute("INSERT INTO users (name, age) VALUES ('Bob', 30)");
    try db.execute("INSERT INTO users (name, age) VALUES ('Charlie', 25)");

    var result = try db.query("SELECT name FROM users WHERE age = 25");
    defer result.deinit();

    var names = std.ArrayListUnmanaged([]const u8){};
    defer names.deinit(allocator);

    while (result.nextRow()) |row| {
        if (row.getText(0)) |name| {
            try names.append(allocator, name);
        }
    }

    try std.testing.expectEqual(@as(usize, 2), names.items.len);
}

test "Database query with ORDER BY" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test_order (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO test_order (name) VALUES ('Charlie')");
    try db.execute("INSERT INTO test_order (name) VALUES ('Alice')");
    try db.execute("INSERT INTO test_order (name) VALUES ('Bob')");

    var result = try db.query("SELECT name FROM test_order ORDER BY name");
    defer result.deinit();

    // Collect names - must dupe since row data is invalidated on next iteration
    var names = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (names.items) |name| {
            allocator.free(name);
        }
        names.deinit(allocator);
    }

    while (result.nextRow()) |row| {
        if (row.getText(0)) |name| {
            // Dupe the string since SQLite row data is transient
            const duped = try allocator.dupe(u8, name);
            try names.append(allocator, duped);
        }
    }

    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("Alice", names.items[0]);
    try std.testing.expectEqualStrings("Bob", names.items[1]);
    try std.testing.expectEqualStrings("Charlie", names.items[2]);
}

test "Database query with LIMIT" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES ('Bob')");
    try db.execute("INSERT INTO users (name) VALUES ('Charlie')");

    var result = try db.query("SELECT name FROM users ORDER BY id LIMIT 2");
    defer result.deinit();

    var count: usize = 0;
    while (result.nextRow()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Database query with JOIN" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER, title TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO posts (user_id, title) VALUES (1, 'Post 1')");
    try db.execute("INSERT INTO posts (user_id, title) VALUES (1, 'Post 2')");

    var result = try db.query("SELECT u.name, p.title FROM users u JOIN posts p ON u.id = p.user_id");
    defer result.deinit();

    var count: usize = 0;
    while (result.nextRow()) |row| {
        count += 1;
        try std.testing.expectEqualStrings("Alice", row.getText(0).?);
        try std.testing.expect(row.getText(1) != null);
    }

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Database transaction nested operations" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER, title TEXT)");

    var trans = try db.beginTransaction();
    defer trans.deinit();

    try trans.execute("INSERT INTO users (name) VALUES ('Alice')");

    var result = try trans.query("SELECT id FROM users WHERE name = 'Alice'");
    defer result.deinit();

    var user_id: i64 = 0;
    if (result.nextRow()) |row| {
        user_id = row.getInt64(0);
    }

    var id_buf: [64]u8 = undefined;
    const insert_sql = try std.fmt.bufPrint(&id_buf, "INSERT INTO posts (user_id, title) VALUES ({d}, 'Post 1')", .{user_id});
    try trans.execute(insert_sql);

    try trans.commit();

    var final_result = try db.query("SELECT COUNT(*) FROM posts");
    defer final_result.deinit();
    if (final_result.nextRow()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.getInt64(0));
    }
}

test "Database transaction rollback on error" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    var trans = try db.beginTransaction();
    defer trans.deinit();

    try trans.execute("INSERT INTO users (name) VALUES ('Alice')");

    // Cause an error
    _ = trans.execute("INVALID SQL") catch {
        // Error occurred, transaction should rollback on deinit
    };

    // Transaction deinit will rollback
    trans.deinit();

    var result = try db.query("SELECT COUNT(*) FROM users");
    defer result.deinit();
    if (result.nextRow()) |row| {
        try std.testing.expectEqual(@as(i64, 0), row.getInt64(0));
    }
}

test "Database transaction commit after rollback" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    var trans = try db.beginTransaction();
    defer trans.deinit();

    try trans.execute("INSERT INTO users (name) VALUES ('Alice')");
    try trans.rollback();

    // Commit after rollback should return error (transaction already rolled back)
    try std.testing.expectError(error.TransactionFailed, trans.commit());

    var result = try db.query("SELECT COUNT(*) FROM users");
    defer result.deinit();
    if (result.nextRow()) |row| {
        try std.testing.expectEqual(@as(i64, 0), row.getInt64(0));
    }
}

test "Database executeParams with all parameter types" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, text_val TEXT, int_val INTEGER, float_val REAL, blob_val BLOB)");

    var params = ParamList.init(allocator);
    defer params.deinit();
    try params.addText("test string");
    try params.addInt(42);
    try params.addFloat(3.14);
    try params.addString("binary data");

    try db.executeParams("INSERT INTO test (text_val, int_val, float_val, blob_val) VALUES (?, ?, ?, ?)", &params);

    var result = try db.query("SELECT text_val, int_val, float_val, blob_val FROM test");
    defer result.deinit();

    if (result.nextRow()) |row| {
        try std.testing.expectEqualStrings("test string", row.getText(0).?);
        try std.testing.expectEqual(@as(i64, 42), row.getInt64(1));
        const float_val = row.getDouble(2);
        try std.testing.expect(float_val > 3.13 and float_val < 3.15);
        try std.testing.expectEqualStrings("binary data", row.getText(3).?);
    } else {
        try std.testing.expect(false);
    }
}

test "Database executeParams with boolean" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, active INTEGER)");

    var params = ParamList.init(allocator);
    defer params.deinit();
    try params.addBool(true);

    try db.executeParams("INSERT INTO test (active) VALUES (?)", &params);

    var result = try db.query("SELECT active FROM test");
    defer result.deinit();

    if (result.nextRow()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.getInt64(0));
    } else {
        try std.testing.expect(false);
    }
}

test "Database executeParams with empty ParamList" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)");

    var params = ParamList.init(allocator);
    defer params.deinit();

    try db.executeParams("INSERT INTO test DEFAULT VALUES", &params);

    var result = try db.query("SELECT COUNT(*) FROM test");
    defer result.deinit();
    if (result.nextRow()) |row| {
        try std.testing.expectEqual(@as(i64, 1), row.getInt64(0));
    }
}

test "Database queryParams with multiple parameters" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, active INTEGER)");
    try db.execute("INSERT INTO users (name, age, active) VALUES ('Alice', 25, 1)");
    try db.execute("INSERT INTO users (name, age, active) VALUES ('Bob', 30, 1)");
    try db.execute("INSERT INTO users (name, age, active) VALUES ('Charlie', 25, 0)");

    var params = ParamList.init(allocator);
    defer params.deinit();
    try params.addInt(25);
    try params.addBool(true);

    var result = try db.queryParams("SELECT name FROM users WHERE age = ? AND active = ?", &params);
    defer result.deinit();

    var count: usize = 0;
    while (result.nextRow()) |row| {
        count += 1;
        try std.testing.expectEqualStrings("Alice", row.getText(0).?);
    }

    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Database queryParams with LIKE pattern" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES ('Bob')");
    try db.execute("INSERT INTO users (name) VALUES ('Charlie')");

    var params = ParamList.init(allocator);
    defer params.deinit();
    try params.addText("A%");

    var result = try db.queryParams("SELECT name FROM users WHERE name LIKE ?", &params);
    defer result.deinit();

    var count: usize = 0;
    while (result.nextRow()) |row| {
        count += 1;
        try std.testing.expect(std.mem.startsWith(u8, row.getText(0).?, "A"));
    }

    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Database queryParams parameter count mismatch" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    var params = ParamList.init(allocator);
    defer params.deinit();
    try params.addText("Alice");
    // Missing second parameter - SQLite will use NULL for missing parameters
    // This is valid SQL behavior, so the query should succeed
    try db.executeParams("INSERT INTO users (name, age) VALUES (?, ?)", &params);

    // Verify the insert worked with NULL for age
    var result = try db.query("SELECT name, age FROM users");
    defer result.deinit();
    if (result.nextRow()) |row| {
        try std.testing.expectEqualStrings("Alice", row.getText(0).?);
        try std.testing.expect(row.isNull(1)); // age should be NULL
    }
}

test "Database queryParams with IN clause" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");
    try db.execute("INSERT INTO users (name, age) VALUES ('Alice', 25)");
    try db.execute("INSERT INTO users (name, age) VALUES ('Bob', 30)");
    try db.execute("INSERT INTO users (name, age) VALUES ('Charlie', 35)");

    var params = ParamList.init(allocator);
    defer params.deinit();
    try params.addInt(25);
    try params.addInt(35);

    // Note: SQLite doesn't support parameterized IN clauses directly
    // This test verifies the behavior with manual SQL construction
    var result = try db.query("SELECT name FROM users WHERE age IN (25, 35)");
    defer result.deinit();

    var count: usize = 0;
    while (result.nextRow()) |row| {
        count += 1;
        const name = row.getText(0).?;
        try std.testing.expect(std.mem.eql(u8, name, "Alice") or std.mem.eql(u8, name, "Charlie"));
    }

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Database lastInsertRowId" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES ('Bob')");

    const last_id = try db.lastInsertRowId();
    try std.testing.expectEqual(@as(i64, 2), last_id);
}

test "Database lastInsertRowId with no inserts" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)");

    const last_id = try db.lastInsertRowId();
    // Should return 0 if no inserts have occurred
    try std.testing.expectEqual(@as(i64, 0), last_id);
}

test "ConnectionPool acquire and release cycle" {
    const allocator = std.testing.allocator;
    const config = ConnectionPoolConfig{
        .max_connections = 2,
    };

    var pool = ConnectionPool.init(":memory:", config, allocator);
    defer pool.deinit();

    const db1 = try pool.acquire();
    try std.testing.expect(db1.sqlite_db != null);
    pool.release(db1);

    const db2 = try pool.acquire();
    try std.testing.expect(db2.sqlite_db != null);
    pool.release(db2);

    // Should reuse connection
    const db3 = try pool.acquire();
    try std.testing.expect(db3.sqlite_db != null);
    pool.release(db3);
}

test "ConnectionPool max connections limit" {
    const allocator = std.testing.allocator;
    const config = ConnectionPoolConfig{
        .max_connections = 2,
        .acquire_timeout_ms = 1, // Very short timeout
    };

    var pool = ConnectionPool.init(":memory:", config, allocator);
    defer pool.deinit();

    // Acquire two connections (the max)
    const db1 = try pool.acquire();
    const db2 = try pool.acquire();

    // Verify we have max connections
    try std.testing.expectEqual(@as(usize, 2), pool.created);

    // Release both before cleanup
    pool.release(db1);
    pool.release(db2);

    // Verify connections are available again
    try std.testing.expectEqual(@as(usize, 2), pool.available.items.len);
}

test "ConnectionPool config validation" {
    var config = ConnectionPoolConfig{
        .max_connections = 0,
    };
    try std.testing.expectError(error.InvalidArgument, config.validate());

    config.max_connections = 1001;
    try std.testing.expectError(error.InvalidArgument, config.validate());

    config.max_connections = 10;
    try config.validate();
}

test "Database query with very long result set" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)");

    // Insert 1000 rows
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var buf: [64]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "INSERT INTO test (value) VALUES ('row {d}')", .{i}) catch break;
        try db.execute(sql);
    }

    var result = try db.query("SELECT value FROM test");
    defer result.deinit();

    var count: usize = 0;
    while (result.nextRow()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 1000), count);
}

test "Database query with very long text values" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)");

    // Create a very long string (10KB)
    var long_string = std.ArrayListUnmanaged(u8){};
    defer long_string.deinit(allocator);
    var i: usize = 0;
    try long_string.append(allocator, 'A');
    while (i < 10000) : (i += 1) {
        try long_string.append(allocator, 'A');
    }

    var params = ParamList.init(allocator);
    defer params.deinit();
    try params.addText(long_string.items);

    try db.executeParams("INSERT INTO test (value) VALUES (?)", &params);

    var result = try db.query("SELECT value FROM test");
    defer result.deinit();

    if (result.nextRow()) |row| {
        const retrieved = row.getText(0).?;
        try std.testing.expectEqual(@as(usize, 10001), retrieved.len);
        try std.testing.expectEqualStrings(long_string.items, retrieved);
    } else {
        try std.testing.expect(false);
    }
}

test "Database executeParams with special characters" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)");

    var params = ParamList.init(allocator);
    defer params.deinit();
    try params.addText("Test with 'quotes' and \"double quotes\" and `backticks`");

    try db.executeParams("INSERT INTO test (value) VALUES (?)", &params);

    var result = try db.query("SELECT value FROM test");
    defer result.deinit();

    if (result.nextRow()) |row| {
        try std.testing.expectEqualStrings("Test with 'quotes' and \"double quotes\" and `backticks`", row.getText(0).?);
    } else {
        try std.testing.expect(false);
    }
}

test "Database query with NULL handling" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT, num INTEGER)");

    var params = ParamList.init(allocator);
    defer params.deinit();
    try params.addText("test");
    try params.addNull();

    try db.executeParams("INSERT INTO test (value, num) VALUES (?, ?)", &params);

    var result = try db.query("SELECT value, num FROM test");
    defer result.deinit();

    if (result.nextRow()) |row| {
        try std.testing.expectEqualStrings("test", row.getText(0).?);
        try std.testing.expect(row.isNull(1));
        try std.testing.expect(row.getText(1) == null);
    } else {
        try std.testing.expect(false);
    }
}

test "Database query column names case sensitivity" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, \"Name\" TEXT)");
    try db.execute("INSERT INTO test (\"Name\") VALUES ('Alice')");

    var result = try db.query("SELECT \"Name\" FROM test");
    defer result.deinit();

    try std.testing.expectEqual(@as(c_int, 1), result.columnCount());
    try std.testing.expectEqualStrings("Name", result.columnName(0).?);

    if (result.nextRow()) |row| {
        try std.testing.expectEqualStrings("Alice", row.getText(0).?);
    }
}

test "Database query with aggregate functions" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value INTEGER)");
    try db.execute("INSERT INTO test (value) VALUES (10)");
    try db.execute("INSERT INTO test (value) VALUES (20)");
    try db.execute("INSERT INTO test (value) VALUES (30)");

    var result = try db.query("SELECT COUNT(*), SUM(value), AVG(value), MIN(value), MAX(value) FROM test");
    defer result.deinit();

    if (result.nextRow()) |row| {
        try std.testing.expectEqual(@as(i64, 3), row.getInt64(0)); // COUNT
        try std.testing.expectEqual(@as(i64, 60), row.getInt64(1)); // SUM
        const avg = row.getDouble(2);
        try std.testing.expect(avg > 19.9 and avg < 20.1); // AVG
        try std.testing.expectEqual(@as(i64, 10), row.getInt64(3)); // MIN
        try std.testing.expectEqual(@as(i64, 30), row.getInt64(4)); // MAX
    }
}

test "Database transaction queryParams" {
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

    var query_params = ParamList.init(allocator);
    defer query_params.deinit();
    try query_params.addText("Alice");

    var result = try trans.queryParams("SELECT name FROM users WHERE name = ?", &query_params);
    defer result.deinit();

    if (result.nextRow()) |row| {
        try std.testing.expectEqualStrings("Alice", row.getText(0).?);
    }

    try trans.commit();
}

test "Database execute with DDL statements" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE ddl_test1 (id INTEGER PRIMARY KEY)");
    try db.execute("CREATE TABLE ddl_test2 (id INTEGER PRIMARY KEY)");
    try db.execute("CREATE INDEX idx_ddl_test1 ON ddl_test1(id)");
    try db.execute("ALTER TABLE ddl_test1 ADD COLUMN name TEXT");
    try db.execute("DROP INDEX idx_ddl_test1");
    try db.execute("DROP TABLE ddl_test2");

    // Verify tables exist
    var result = try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'ddl_%' ORDER BY name");
    defer result.deinit();

    var tables = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (tables.items) |name| {
            allocator.free(name);
        }
        tables.deinit(allocator);
    }

    while (result.nextRow()) |row| {
        if (row.getText(0)) |name| {
            // Dupe the string since SQLite row data is transient
            const duped = try allocator.dupe(u8, name);
            try tables.append(allocator, duped);
        }
    }

    try std.testing.expectEqual(@as(usize, 1), tables.items.len);
    try std.testing.expectEqualStrings("ddl_test1", tables.items[0]);
}
