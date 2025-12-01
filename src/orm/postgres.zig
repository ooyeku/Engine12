// PostgreSQL driver implementation using pg.zig
// Provides an engine12-compatible interface for PostgreSQL databases

const std = @import("std");
const pg = @import("pg");
const driver_mod = @import("driver.zig");
const PostgresConfig = driver_mod.PostgresConfig;

/// PostgreSQL database connection wrapper
/// Provides a unified interface compatible with the SQLite Database API
pub const PostgresDatabase = struct {
    pool: *pg.Pool,
    allocator: std.mem.Allocator,
    config: PostgresConfig,

    /// Open a PostgreSQL connection pool
    pub fn open(config: PostgresConfig, allocator: std.mem.Allocator) !PostgresDatabase {
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

        return PostgresDatabase{
            .pool = pool,
            .allocator = allocator,
            .config = config,
        };
    }

    /// Close the connection pool
    pub fn close(self: *PostgresDatabase) void {
        self.pool.deinit();
    }

    /// Execute a SQL statement (INSERT, UPDATE, DELETE, DDL)
    pub fn execute(self: *PostgresDatabase, sql: []const u8) !void {
        var result = self.pool.query(sql, .{}) catch |err| {
            std.debug.print("[PostgreSQL Error] Failed to execute: {s}\n", .{sql});
            std.debug.print("  Error: {}\n", .{err});
            return error.QueryFailed;
        };
        defer result.deinit();

        // Drain results to complete the query
        while (result.next()) |_| {}
    }

    /// Execute a SQL statement and return the number of affected rows
    pub fn executeWithRowsAffected(self: *PostgresDatabase, sql: []const u8) !i64 {
        var result = self.pool.query(sql, .{}) catch |err| {
            std.debug.print("[PostgreSQL Error] Failed to execute: {s}\n", .{sql});
            std.debug.print("  Error: {}\n", .{err});
            return error.QueryFailed;
        };
        defer result.deinit();

        // Count rows affected by draining
        var count: i64 = 0;
        while (result.next()) |_| {
            count += 1;
        }

        return count;
    }

    /// Execute a parameterized SQL query and return results
    pub fn query(self: *PostgresDatabase, sql: []const u8) !PostgresQueryResult {
        const result = self.pool.query(sql, .{}) catch |err| {
            std.debug.print("[PostgreSQL Error] Failed to query: {s}\n", .{sql});
            std.debug.print("  Error: {}\n", .{err});
            return error.QueryFailed;
        };

        return PostgresQueryResult{
            .result = result,
            .allocator = self.allocator,
        };
    }

    /// Execute a parameterized query with bound parameters
    /// Note: PostgreSQL uses $1, $2, etc. for placeholders
    pub fn queryWithParams(
        self: *PostgresDatabase,
        sql: []const u8,
        params: anytype,
    ) !PostgresQueryResult {
        const result = self.pool.query(sql, params) catch |err| {
            std.debug.print("[PostgreSQL Error] Failed to query with params: {s}\n", .{sql});
            std.debug.print("  Error: {}\n", .{err});
            return error.QueryFailed;
        };

        return PostgresQueryResult{
            .result = result,
            .allocator = self.allocator,
        };
    }

    /// Execute a parameterized statement (INSERT, UPDATE, DELETE)
    pub fn executeWithParams(
        self: *PostgresDatabase,
        sql: []const u8,
        params: anytype,
    ) !void {
        var result = self.pool.query(sql, params) catch |err| {
            std.debug.print("[PostgreSQL Error] Failed to execute with params: {s}\n", .{sql});
            std.debug.print("  Error: {}\n", .{err});
            return error.QueryFailed;
        };
        defer result.deinit();

        // Drain to complete
        while (result.next()) |_| {}
    }

    /// Begin a transaction
    pub fn beginTransaction(self: *PostgresDatabase) !PostgresTransaction {
        try self.execute("BEGIN");
        return PostgresTransaction{
            .db = self,
            .committed = false,
            .rolled_back = false,
        };
    }

    /// Get the last insert ID (PostgreSQL requires RETURNING clause)
    /// This method should not be called directly - use RETURNING in your INSERT
    pub fn lastInsertRowId(_: *PostgresDatabase) !i64 {
        // PostgreSQL doesn't have a global last_insert_id
        // Use RETURNING clause in INSERT statements instead
        return error.NotSupported;
    }

    pub const Error = error{
        DatabaseOpenFailed,
        QueryFailed,
        ConnectionFailed,
        AuthenticationFailed,
        NotSupported,
        TransactionFailed,
    };
};

/// PostgreSQL query result wrapper
pub const PostgresQueryResult = struct {
    result: pg.Pool.Result,
    allocator: std.mem.Allocator,
    column_count_cache: ?usize = null,

    /// Get the next row, or null if no more rows
    pub fn next(self: *PostgresQueryResult) ?PostgresRow {
        if (self.result.next()) |row| {
            return PostgresRow{
                .row = row,
                .allocator = self.allocator,
            };
        }
        return null;
    }

    /// Get the number of columns
    pub fn columnCount(self: *PostgresQueryResult) usize {
        if (self.column_count_cache) |count| {
            return count;
        }
        // pg.zig doesn't expose column count directly
        // This would need to be tracked or estimated
        return 0;
    }

    /// Release resources
    pub fn deinit(self: *PostgresQueryResult) void {
        self.result.deinit();
    }

    /// Drain all remaining rows
    pub fn drain(self: *PostgresQueryResult) void {
        self.result.drain();
    }
};

/// PostgreSQL row wrapper
pub const PostgresRow = struct {
    row: pg.Pool.Result.Row,
    allocator: std.mem.Allocator,

    /// Get text value at column index
    pub fn getText(self: PostgresRow, col_index: usize) ?[]const u8 {
        return self.row.get([]const u8, col_index);
    }

    /// Get integer value at column index
    pub fn getInt64(self: PostgresRow, col_index: usize) i64 {
        return self.row.get(i64, col_index) orelse 0;
    }

    /// Get float value at column index
    pub fn getDouble(self: PostgresRow, col_index: usize) f64 {
        return self.row.get(f64, col_index) orelse 0.0;
    }

    /// Get boolean value at column index
    pub fn getBool(self: PostgresRow, col_index: usize) bool {
        return self.row.get(bool, col_index) orelse false;
    }

    /// Check if column value is null
    pub fn isNull(self: PostgresRow, col_index: usize) bool {
        // Try to get as optional type - if null, the optional is null
        const val = self.row.get(?i64, col_index);
        return val == null;
    }

    /// Get text value with allocation (caller owns memory)
    pub fn getTextAlloc(self: PostgresRow, allocator: std.mem.Allocator, col_index: usize) !?[]u8 {
        const text = self.getText(col_index) orelse return null;
        return try allocator.dupe(u8, text);
    }
};

/// PostgreSQL transaction wrapper
pub const PostgresTransaction = struct {
    db: *PostgresDatabase,
    committed: bool,
    rolled_back: bool,

    /// Commit the transaction
    pub fn commit(self: *PostgresTransaction) !void {
        if (self.committed or self.rolled_back) {
            return error.TransactionFailed;
        }
        try self.db.execute("COMMIT");
        self.committed = true;
    }

    /// Rollback the transaction
    pub fn rollback(self: *PostgresTransaction) !void {
        if (self.committed or self.rolled_back) {
            return error.TransactionFailed;
        }
        try self.db.execute("ROLLBACK");
        self.rolled_back = true;
    }

    /// Execute SQL within the transaction
    pub fn execute(self: *PostgresTransaction, sql: []const u8) !void {
        try self.db.execute(sql);
    }

    /// Query within the transaction
    pub fn query(self: *PostgresTransaction, sql: []const u8) !PostgresQueryResult {
        return try self.db.query(sql);
    }

    /// Execute with parameters within the transaction
    pub fn executeWithParams(self: *PostgresTransaction, sql: []const u8, params: anytype) !void {
        try self.db.executeWithParams(sql, params);
    }

    /// Query with parameters within the transaction
    pub fn queryWithParams(self: *PostgresTransaction, sql: []const u8, params: anytype) !PostgresQueryResult {
        return try self.db.queryWithParams(sql, params);
    }

    /// Automatic rollback on deinit if not committed
    pub fn deinit(self: *PostgresTransaction) void {
        if (!self.committed and !self.rolled_back) {
            self.rollback() catch |err| {
                std.debug.print("[PostgreSQL] Warning: Failed to rollback transaction: {}\n", .{err});
            };
        }
    }
};

/// PostgreSQL connection pool wrapper for compatibility
pub const PostgresConnectionPool = struct {
    config: PostgresConfig,
    allocator: std.mem.Allocator,
    pool: ?*pg.Pool = null,

    pub fn init(config: PostgresConfig, allocator: std.mem.Allocator) PostgresConnectionPool {
        return PostgresConnectionPool{
            .config = config,
            .allocator = allocator,
            .pool = null,
        };
    }

    /// Acquire a connection from the pool
    pub fn acquire(self: *PostgresConnectionPool) !PostgresDatabase {
        if (self.pool == null) {
            // Initialize pool on first use
            self.pool = pg.Pool.init(self.allocator, .{
                .size = self.config.pool_size,
                .connect = .{
                    .port = self.config.port,
                    .host = self.config.host,
                },
                .auth = .{
                    .username = self.config.username,
                    .database = self.config.database,
                    .password = self.config.password,
                    .timeout = self.config.auth_timeout_ms,
                },
            }) catch |err| {
                std.debug.print("[PostgreSQL Pool Error] Failed to initialize: {}\n", .{err});
                return error.PoolExhausted;
            };
        }

        return PostgresDatabase{
            .pool = self.pool.?,
            .allocator = self.allocator,
            .config = self.config,
        };
    }

    /// Release a connection back to the pool
    /// For pg.zig, connections are managed internally by the pool
    pub fn release(_: *PostgresConnectionPool, _: PostgresDatabase) void {
        // pg.zig manages its own connection pooling internally
        // No action needed for release
    }

    /// Cleanup the pool
    pub fn deinit(self: *PostgresConnectionPool) void {
        if (self.pool) |pool| {
            pool.deinit();
            self.pool = null;
        }
    }
};

/// Convert SQLite-style placeholder SQL to PostgreSQL-style
/// Replaces ? with $1, $2, $3, etc.
pub fn convertPlaceholders(allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    var param_index: usize = 1;
    var i: usize = 0;

    while (i < sql.len) {
        if (sql[i] == '?') {
            // Replace ? with $N
            var buf: [16]u8 = undefined;
            const placeholder = std.fmt.bufPrint(&buf, "${d}", .{param_index}) catch return error.OutOfMemory;
            try result.appendSlice(allocator, placeholder);
            param_index += 1;
        } else {
            try result.append(allocator, sql[i]);
        }
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

test "convertPlaceholders" {
    const allocator = std.testing.allocator;

    const sql1 = try convertPlaceholders(allocator, "SELECT * FROM users WHERE id = ?");
    defer allocator.free(sql1);
    try std.testing.expectEqualStrings("SELECT * FROM users WHERE id = $1", sql1);

    const sql2 = try convertPlaceholders(allocator, "INSERT INTO users (name, age) VALUES (?, ?)");
    defer allocator.free(sql2);
    try std.testing.expectEqualStrings("INSERT INTO users (name, age) VALUES ($1, $2)", sql2);

    const sql3 = try convertPlaceholders(allocator, "SELECT * FROM users");
    defer allocator.free(sql3);
    try std.testing.expectEqualStrings("SELECT * FROM users", sql3);
}

