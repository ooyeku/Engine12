
const std = @import("std");
const pg = @import("pg");
const driver_mod = @import("driver.zig");
const PostgresConfig = driver_mod.PostgresConfig;

pub const PostgresDatabase = struct {
    pool: *pg.Pool,
    allocator: std.mem.Allocator,
    config: PostgresConfig,

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

    pub fn close(self: *PostgresDatabase) void {
        self.pool.deinit();
    }

    pub fn execute(self: *PostgresDatabase, sql: []const u8) !void {
        var result = self.pool.query(sql, .{}) catch |err| {
            std.debug.print("[PostgreSQL Error] Failed to execute: {s}\n", .{sql});
            std.debug.print("  Error: {}\n", .{err});
            return error.QueryFailed;
        };
        defer result.deinit();

        while (result.next()) |_| {}
    }

    pub fn executeWithRowsAffected(self: *PostgresDatabase, sql: []const u8) !i64 {
        var result = self.pool.query(sql, .{}) catch |err| {
            std.debug.print("[PostgreSQL Error] Failed to execute: {s}\n", .{sql});
            std.debug.print("  Error: {}\n", .{err});
            return error.QueryFailed;
        };
        defer result.deinit();

        var count: i64 = 0;
        while (result.next()) |_| {
            count += 1;
        }

        return count;
    }

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

        while (result.next()) |_| {}
    }

    pub fn beginTransaction(self: *PostgresDatabase) !PostgresTransaction {
        try self.execute("BEGIN");
        return PostgresTransaction{
            .db = self,
            .committed = false,
            .rolled_back = false,
        };
    }

    pub fn lastInsertRowId(_: *PostgresDatabase) !i64 {
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

pub const PostgresQueryResult = struct {
    result: pg.Pool.Result,
    allocator: std.mem.Allocator,
    column_count_cache: ?usize = null,

    pub fn next(self: *PostgresQueryResult) ?PostgresRow {
        if (self.result.next()) |row| {
            return PostgresRow{
                .row = row,
                .allocator = self.allocator,
            };
        }
        return null;
    }

    pub fn columnCount(self: *PostgresQueryResult) usize {
        if (self.column_count_cache) |count| {
            return count;
        }
        return 0;
    }

    pub fn deinit(self: *PostgresQueryResult) void {
        self.result.deinit();
    }

    pub fn drain(self: *PostgresQueryResult) void {
        self.result.drain();
    }
};

pub const PostgresRow = struct {
    row: pg.Pool.Result.Row,
    allocator: std.mem.Allocator,

    pub fn getText(self: PostgresRow, col_index: usize) ?[]const u8 {
        return self.row.get([]const u8, col_index);
    }

    pub fn getInt64(self: PostgresRow, col_index: usize) i64 {
        return self.row.get(i64, col_index) orelse 0;
    }

    pub fn getDouble(self: PostgresRow, col_index: usize) f64 {
        return self.row.get(f64, col_index) orelse 0.0;
    }

    pub fn getBool(self: PostgresRow, col_index: usize) bool {
        return self.row.get(bool, col_index) orelse false;
    }

    pub fn isNull(self: PostgresRow, col_index: usize) bool {
        const val = self.row.get(?i64, col_index);
        return val == null;
    }

    pub fn getTextAlloc(self: PostgresRow, allocator: std.mem.Allocator, col_index: usize) !?[]u8 {
        const text = self.getText(col_index) orelse return null;
        return try allocator.dupe(u8, text);
    }
};

pub const PostgresTransaction = struct {
    db: *PostgresDatabase,
    committed: bool,
    rolled_back: bool,

    pub fn commit(self: *PostgresTransaction) !void {
        if (self.committed or self.rolled_back) {
            return error.TransactionFailed;
        }
        try self.db.execute("COMMIT");
        self.committed = true;
    }

    pub fn rollback(self: *PostgresTransaction) !void {
        if (self.committed or self.rolled_back) {
            return error.TransactionFailed;
        }
        try self.db.execute("ROLLBACK");
        self.rolled_back = true;
    }

    pub fn execute(self: *PostgresTransaction, sql: []const u8) !void {
        try self.db.execute(sql);
    }

    pub fn query(self: *PostgresTransaction, sql: []const u8) !PostgresQueryResult {
        return try self.db.query(sql);
    }

    pub fn executeWithParams(self: *PostgresTransaction, sql: []const u8, params: anytype) !void {
        try self.db.executeWithParams(sql, params);
    }

    pub fn queryWithParams(self: *PostgresTransaction, sql: []const u8, params: anytype) !PostgresQueryResult {
        return try self.db.queryWithParams(sql, params);
    }

    pub fn deinit(self: *PostgresTransaction) void {
        if (!self.committed and !self.rolled_back) {
            self.rollback() catch |err| {
                std.debug.print("[PostgreSQL] Warning: Failed to rollback transaction: {}\n", .{err});
            };
        }
    }
};

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

    pub fn acquire(self: *PostgresConnectionPool) !PostgresDatabase {
        if (self.pool == null) {
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

    pub fn release(_: *PostgresConnectionPool, _: PostgresDatabase) void {
    }

    pub fn deinit(self: *PostgresConnectionPool) void {
        if (self.pool) |pool| {
            pool.deinit();
            self.pool = null;
        }
    }
};

pub fn convertPlaceholders(allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    var param_index: usize = 1;
    var i: usize = 0;

    while (i < sql.len) {
        if (sql[i] == '?') {
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

