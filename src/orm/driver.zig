
const std = @import("std");

pub const Driver = enum {
    sqlite,
    postgresql,

    pub fn placeholder(self: Driver, index: usize) []const u8 {
        return switch (self) {
            .sqlite => "?",
            .postgresql => blk: {
                _ = index;
                break :blk "$";
            },
        };
    }

    pub fn autoIncrementType(self: Driver) []const u8 {
        return switch (self) {
            .sqlite => "INTEGER PRIMARY KEY AUTOINCREMENT",
            .postgresql => "SERIAL PRIMARY KEY",
        };
    }

    pub fn booleanType(self: Driver) []const u8 {
        return switch (self) {
            .sqlite => "INTEGER",
            .postgresql => "BOOLEAN",
        };
    }

    pub fn needsReturning(self: Driver) bool {
        return switch (self) {
            .sqlite => false,
            .postgresql => true,
        };
    }
};

pub const SqliteConfig = struct {
    path: []const u8,
    wal_mode: bool = true,
    cache_size_kb: i32 = 256000,
    busy_timeout_ms: u32 = 10000,
};

pub const PostgresConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5432,
    database: []const u8,
    username: []const u8,
    password: ?[]const u8 = null,
    pool_size: u16 = 5,
    connect_timeout_ms: u32 = 10000,
    auth_timeout_ms: u32 = 10000,
};

pub const DatabaseConfig = struct {
    driver: Driver,
    connection: ConnectionUnion,

    pub const ConnectionUnion = union(Driver) {
        sqlite: SqliteConfig,
        postgresql: PostgresConfig,
    };

    pub fn sqlite(path: []const u8) DatabaseConfig {
        return .{
            .driver = .sqlite,
            .connection = .{ .sqlite = .{ .path = path } },
        };
    }

    pub fn sqliteWithOptions(config: SqliteConfig) DatabaseConfig {
        return .{
            .driver = .sqlite,
            .connection = .{ .sqlite = config },
        };
    }

    pub fn postgresql(config: PostgresConfig) DatabaseConfig {
        return .{
            .driver = .postgresql,
            .connection = .{ .postgresql = config },
        };
    }

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

