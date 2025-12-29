const std = @import("std");

/// Supported database backends.
pub const Driver = enum {
    sqlite,
    postgresql,

    /// Returns the base placeholder character for the driver.
    pub fn placeholder(self: Driver, index: usize) []const u8 {
        return switch (self) {
            .sqlite => "?",
            .postgresql => blk: {
                _ = index;
                break :blk "$";
            },
        };
    }

    /// Returns the SQL snippet for an auto-incrementing primary key.
    pub fn autoIncrementType(self: Driver) []const u8 {
        return switch (self) {
            .sqlite => "INTEGER PRIMARY KEY AUTOINCREMENT",
            .postgresql => "SERIAL PRIMARY KEY",
        };
    }

    /// Returns the SQL type for boolean values.
    pub fn booleanType(self: Driver) []const u8 {
        return switch (self) {
            .sqlite => "INTEGER",
            .postgresql => "BOOLEAN",
        };
    }

    /// Indicates if the driver requires a RETURNING clause to get the last insert ID.
    pub fn needsReturning(self: Driver) bool {
        return switch (self) {
            .sqlite => false,
            .postgresql => true,
        };
    }
};

/// Configuration for SQLite database connections.
pub const SqliteConfig = struct {
    /// Path to the SQLite database file. Use ":memory:" for transient in-memory databases.
    path: []const u8,
    /// Whether to enable Write-Ahead Logging (WAL) mode for better concurrency.
    wal_mode: bool = true,
    /// Size of the page cache in kilobytes.
    cache_size_kb: i32 = 256000,
    /// Maximum time in milliseconds to wait for a database lock to be released.
    busy_timeout_ms: u32 = 10000,
};

/// Configuration for PostgreSQL database connections.
pub const PostgresConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5432,
    database: []const u8,
    username: []const u8,
    password: ?[]const u8 = null,
    /// Number of concurrent connections to maintain in the connection pool.
    pool_size: u16 = 5,
    /// Connection timeout in milliseconds.
    connect_timeout_ms: u32 = 10000,
    /// Authentication handshake timeout in milliseconds.
    auth_timeout_ms: u32 = 10000,
};

/// Universal database configuration that can represent any supported backend.
pub const DatabaseConfig = struct {
    driver: Driver,
    connection: ConnectionUnion,

    pub const ConnectionUnion = union(Driver) {
        sqlite: SqliteConfig,
        postgresql: PostgresConfig,
    };

    /// Helper to create a basic SQLite configuration.
    pub fn sqlite(path: []const u8) DatabaseConfig {
        return .{
            .driver = .sqlite,
            .connection = .{ .sqlite = .{ .path = path } },
        };
    }

    /// Helper to create a SQLite configuration with custom options.
    pub fn sqliteWithOptions(config: SqliteConfig) DatabaseConfig {
        return .{
            .driver = .sqlite,
            .connection = .{ .sqlite = config },
        };
    }

    /// Helper to create a PostgreSQL configuration.
    pub fn postgresql(config: PostgresConfig) DatabaseConfig {
        return .{
            .driver = .postgresql,
            .connection = .{ .postgresql = config },
        };
    }

    /// Parses a database connection URI (e.g., postgres://user:pass@host:port/db) into a configuration object.
    pub fn postgresqlFromUri(uri_string: []const u8, allocator: std.mem.Allocator) !DatabaseConfig {
        const uri = try std.Uri.parse(uri_string);

        const host = if (uri.host) |h| switch (h) {
            .raw => |raw| raw,
            .percent_encoded => |pe| pe,
        } else "127.0.0.1";

        const port: u16 = uri.port orelse 5432;

        const database = if (uri.path.len > 1) uri.path[1..] else "";

        var username: []const u8 = "postgres";
        var password: ?[]const u8 = null;

        if (uri.user) |user_info| {
            username = switch (user_info.raw) {
                .raw => |raw| raw,
                .percent_encoded => |pe| pe,
            };
        }

        if (uri.password) |pass| {
            password = switch (pass) {
                .raw => |raw| raw,
                .percent_encoded => |pe| pe,
            };
        }

        _ = allocator;

        return .{
            .driver = .postgresql,
            .connection = .{ .postgresql = .{
                .host = host,
                .port = port,
                .database = database,
                .username = username,
                .password = password,
            } },
        };
    }
};

pub const Dialect = struct {
    driver: Driver,

    pub fn init(driver: Driver) Dialect {
        return .{ .driver = driver };
    }

    pub fn formatPlaceholder(self: Dialect, buffer: []u8, index: usize) []const u8 {
        return switch (self.driver) {
            .sqlite => {
                buffer[0] = '?';
                return buffer[0..1];
            },
            .postgresql => {
                return std.fmt.bufPrint(buffer, "${d}", .{index}) catch buffer[0..1];
            },
        };
    }

    pub fn formatLimitOffset(self: Dialect, buffer: []u8, limit: ?usize, offset_val: ?usize) []const u8 {
        _ = self;
        var len: usize = 0;

        if (limit) |l| {
            const written = std.fmt.bufPrint(buffer[len..], " LIMIT {d}", .{l}) catch return buffer[0..0];
            len += written.len;
        }

        if (offset_val) |o| {
            const written = std.fmt.bufPrint(buffer[len..], " OFFSET {d}", .{o}) catch return buffer[0..0];
            len += written.len;
        }

        return buffer[0..len];
    }

    pub fn translateType(self: Dialect, sql_type: []const u8) []const u8 {
        return switch (self.driver) {
            .sqlite => sql_type,
            .postgresql => {
                if (std.mem.eql(u8, sql_type, "INTEGER PRIMARY KEY AUTOINCREMENT")) {
                    return "SERIAL PRIMARY KEY";
                }
                return sql_type;
            },
        };
    }
};

test "DatabaseConfig.sqlite" {
    const config = DatabaseConfig.sqlite("test.db");
    try std.testing.expectEqual(Driver.sqlite, config.driver);
    try std.testing.expectEqualStrings("test.db", config.connection.sqlite.path);
}

test "DatabaseConfig.postgresql" {
    const config = DatabaseConfig.postgresql(.{
        .database = "testdb",
        .username = "testuser",
    });
    try std.testing.expectEqual(Driver.postgresql, config.driver);
    try std.testing.expectEqualStrings("testdb", config.connection.postgresql.database);
    try std.testing.expectEqualStrings("testuser", config.connection.postgresql.username);
}

test "Dialect.formatPlaceholder" {
    var buffer: [16]u8 = undefined;

    const sqlite_dialect = Dialect.init(.sqlite);
    try std.testing.expectEqualStrings("?", sqlite_dialect.formatPlaceholder(&buffer, 1));
    try std.testing.expectEqualStrings("?", sqlite_dialect.formatPlaceholder(&buffer, 5));

    const pg_dialect = Dialect.init(.postgresql);
    try std.testing.expectEqualStrings("$1", pg_dialect.formatPlaceholder(&buffer, 1));
    try std.testing.expectEqualStrings("$5", pg_dialect.formatPlaceholder(&buffer, 5));
}
