// Driver abstraction for multi-database support
// Allows runtime selection between SQLite and PostgreSQL

const std = @import("std");

/// Supported database drivers
pub const Driver = enum {
    sqlite,
    postgresql,

    /// Get the placeholder syntax for this driver
    pub fn placeholder(self: Driver, index: usize) []const u8 {
        return switch (self) {
            .sqlite => "?",
            .postgresql => blk: {
                // PostgreSQL uses $1, $2, etc.
                // This is a simplified version - actual implementation
                // will format dynamically
                _ = index;
                break :blk "$";
            },
        };
    }

    /// Get the auto-increment syntax for primary keys
    pub fn autoIncrementType(self: Driver) []const u8 {
        return switch (self) {
            .sqlite => "INTEGER PRIMARY KEY AUTOINCREMENT",
            .postgresql => "SERIAL PRIMARY KEY",
        };
    }

    /// Get the boolean type name
    pub fn booleanType(self: Driver) []const u8 {
        return switch (self) {
            .sqlite => "INTEGER",
            .postgresql => "BOOLEAN",
        };
    }

    /// Check if RETURNING clause is supported/needed for last insert ID
    pub fn needsReturning(self: Driver) bool {
        return switch (self) {
            .sqlite => false,
            .postgresql => true,
        };
    }
};

/// SQLite-specific connection configuration
pub const SqliteConfig = struct {
    /// Path to the database file
    path: []const u8,
    /// Enable WAL mode (recommended for concurrency)
    wal_mode: bool = true,
    /// Cache size in KB (negative means KB, positive means pages)
    cache_size_kb: i32 = 256000,
    /// Busy timeout in milliseconds
    busy_timeout_ms: u32 = 10000,
};

/// PostgreSQL-specific connection configuration
pub const PostgresConfig = struct {
    /// Database host
    host: []const u8 = "127.0.0.1",
    /// Database port
    port: u16 = 5432,
    /// Database name
    database: []const u8,
    /// Username for authentication
    username: []const u8,
    /// Password for authentication (optional for trust auth)
    password: ?[]const u8 = null,
    /// Connection pool size
    pool_size: u16 = 5,
    /// Connection timeout in milliseconds
    connect_timeout_ms: u32 = 10000,
    /// Authentication timeout in milliseconds
    auth_timeout_ms: u32 = 10000,
};

/// Unified database configuration
pub const DatabaseConfig = struct {
    /// Which driver to use
    driver: Driver,
    /// Driver-specific connection settings
    connection: ConnectionUnion,

    pub const ConnectionUnion = union(Driver) {
        sqlite: SqliteConfig,
        postgresql: PostgresConfig,
    };

    /// Create a SQLite configuration with a path
    pub fn sqlite(path: []const u8) DatabaseConfig {
        return .{
            .driver = .sqlite,
            .connection = .{ .sqlite = .{ .path = path } },
        };
    }

    /// Create a SQLite configuration with full options
    pub fn sqliteWithOptions(config: SqliteConfig) DatabaseConfig {
        return .{
            .driver = .sqlite,
            .connection = .{ .sqlite = config },
        };
    }

    /// Create a PostgreSQL configuration
    pub fn postgresql(config: PostgresConfig) DatabaseConfig {
        return .{
            .driver = .postgresql,
            .connection = .{ .postgresql = config },
        };
    }

    /// Create a PostgreSQL configuration from a connection string
    /// Format: postgresql://user:password@host:port/database
    pub fn postgresqlFromUri(uri_string: []const u8, allocator: std.mem.Allocator) !DatabaseConfig {
        const uri = try std.Uri.parse(uri_string);

        // Extract components
        const host = if (uri.host) |h| switch (h) {
            .raw => |raw| raw,
            .percent_encoded => |pe| pe,
        } else "127.0.0.1";

        const port: u16 = uri.port orelse 5432;

        // Path contains the database name (without leading /)
        const database = if (uri.path.len > 1) uri.path[1..] else "";

        // User info contains username:password
        var username: []const u8 = "postgres";
        var password: ?[]const u8 = null;

        if (uri.user) |user_info| {
            // Parse username
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

        _ = allocator; // Reserved for future string duplication if needed

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

/// SQL dialect utilities for query generation
pub const Dialect = struct {
    driver: Driver,

    pub fn init(driver: Driver) Dialect {
        return .{ .driver = driver };
    }

    /// Format a placeholder for the given parameter index (1-based)
    pub fn formatPlaceholder(self: Dialect, buffer: []u8, index: usize) []const u8 {
        return switch (self.driver) {
            .sqlite => {
                buffer[0] = '?';
                return buffer[0..1];
            },
            .postgresql => {
                // Format as $1, $2, etc.
                return std.fmt.bufPrint(buffer, "${d}", .{index}) catch buffer[0..1];
            },
        };
    }

    /// Get the LIMIT/OFFSET syntax
    /// Both SQLite and PostgreSQL use standard syntax, but this allows for future expansion
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

    /// Check if a SQL type name needs translation
    pub fn translateType(self: Dialect, sql_type: []const u8) []const u8 {
        return switch (self.driver) {
            .sqlite => sql_type,
            .postgresql => {
                // Handle common SQLite to PostgreSQL type mappings
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

