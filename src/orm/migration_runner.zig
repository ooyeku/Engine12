const std = @import("std");
const Database = @import("database.zig").Database;
const Migration = @import("migration.zig").Migration;
const Schema = @import("schema.zig").Schema;
const Driver = @import("driver.zig").Driver;

pub const MigrationRunner = struct {
    db: *Database,
    allocator: std.mem.Allocator,

    pub fn init(db: *Database, allocator: std.mem.Allocator) MigrationRunner {
        return MigrationRunner{
            .db = db,
            .allocator = allocator,
        };
    }

    pub fn createMigrationsTable(self: *MigrationRunner) !void {
        const driver = self.db.getDriver();

        const sql = if (driver == .postgresql)
            \\CREATE TABLE IF NOT EXISTS schema_migrations (
            \\  version INTEGER PRIMARY KEY,
            \\  name VARCHAR(255) NOT NULL,
            \\  applied_at BIGINT NOT NULL
            \\)
        else
            \\CREATE TABLE IF NOT EXISTS schema_migrations (
            \\  version INTEGER PRIMARY KEY,
            \\  name TEXT NOT NULL,
            \\  applied_at INTEGER NOT NULL
            \\)
        ;
        try self.db.execute(sql);
    }

    pub fn getCurrentVersion(self: *MigrationRunner) !?u32 {
        try self.createMigrationsTable();

        var result = try self.db.query("SELECT MAX(version) FROM schema_migrations");
        defer result.deinit();

        if (result.nextRow()) |row| {
            const version = row.getInt64(0);
            if (version == 0) {
                return null;
            }
            return @as(u32, @intCast(version));
        }

        return null;
    }

    pub fn isApplied(self: *MigrationRunner, version: u32) !bool {
        try self.createMigrationsTable();

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT COUNT(*) FROM schema_migrations WHERE version = {d}",
            .{version},
        );
        defer self.allocator.free(sql);

        var result = try self.db.query(sql);
        defer result.deinit();

        if (result.nextRow()) |row| {
            return row.getInt64(0) > 0;
        }

        return false;
    }

    pub fn runMigrations(self: *MigrationRunner, migrations: []const Migration) !void {
        try self.createMigrationsTable();

        for (migrations) |migration| {
            if (try self.isApplied(migration.version)) {
                continue;
            }

            var trans = try self.db.beginTransaction();
            defer trans.deinit();

            trans.execute(migration.up) catch |err| {
                if (std.mem.indexOf(u8, migration.up, "ALTER TABLE") != null and 
                    std.mem.indexOf(u8, migration.up, "ADD COLUMN") != null) {
                    var table_name_start: ?usize = null;
                    var table_name_end: ?usize = null;
                    var column_name_start: ?usize = null;
                    var column_name_end: ?usize = null;
                    
                    if (std.mem.indexOf(u8, migration.up, "ALTER TABLE")) |alt_pos| {
                        var pos = alt_pos + 11; // Skip "ALTER TABLE"
                        while (pos < migration.up.len and (migration.up[pos] == ' ' or migration.up[pos] == '\t' or migration.up[pos] == '\n')) {
                            pos += 1;
                        }
                        table_name_start = pos;
                        while (pos < migration.up.len and migration.up[pos] != ' ' and migration.up[pos] != '\t' and migration.up[pos] != '\n') {
                            pos += 1;
                        }
                        table_name_end = pos;
                        
                        if (std.mem.indexOfPos(u8, migration.up, pos, "ADD COLUMN")) |add_pos| {
                            pos = add_pos + 10; // Skip "ADD COLUMN"
                            while (pos < migration.up.len and (migration.up[pos] == ' ' or migration.up[pos] == '\t' or migration.up[pos] == '\n')) {
                                pos += 1;
                            }
                            column_name_start = pos;
                            while (pos < migration.up.len and migration.up[pos] != ' ' and migration.up[pos] != '\t' and migration.up[pos] != '\n') {
                                pos += 1;
                            }
                            column_name_end = pos;
                        }
                    }
                    
                    if (table_name_start != null and table_name_end != null and 
                        column_name_start != null and column_name_end != null) {
                        const table_name = migration.up[table_name_start.?..table_name_end.?];
                        const column_name = migration.up[column_name_start.?..column_name_end.?];
                        
                        const column_exists = Schema.columnExists(self.db, table_name, column_name) catch false;
                        if (column_exists) {
                            trans.rollback() catch {};
                            const timestamp = std.time.timestamp();
                            var escaped_name = std.ArrayListUnmanaged(u8){};
                            defer escaped_name.deinit(self.allocator);
                            try escaped_name.ensureTotalCapacity(self.allocator, migration.name.len * 2);
                            for (migration.name) |char| {
                                if (char == '\'') {
                                    try escaped_name.append(self.allocator, '\'');
                                    try escaped_name.append(self.allocator, '\'');
                                } else {
                                    try escaped_name.append(self.allocator, char);
                                }
                            }
                            const driver = self.db.getDriver();
                            const insert_sql = if (driver == .postgresql)
                                try std.fmt.allocPrint(
                                    self.allocator,
                                    "INSERT INTO schema_migrations (version, name, applied_at) VALUES ({d}, '{s}', {d}) ON CONFLICT DO NOTHING",
                                    .{ migration.version, escaped_name.items, timestamp },
                                )
                            else
                                try std.fmt.allocPrint(
                                    self.allocator,
                                    "INSERT OR IGNORE INTO schema_migrations (version, name, applied_at) VALUES ({d}, '{s}', {d})",
                                    .{ migration.version, escaped_name.items, timestamp },
                                );
                            defer self.allocator.free(insert_sql);
                            self.db.execute(insert_sql) catch {
                            };
                            continue;
                        }
                    }
                }
                trans.rollback() catch {};
                return err;
            };

            const timestamp = std.time.timestamp();
            var escaped_name = std.ArrayListUnmanaged(u8){};
            defer escaped_name.deinit(self.allocator);
            try escaped_name.ensureTotalCapacity(self.allocator, migration.name.len * 2);
            for (migration.name) |char| {
                if (char == '\'') {
                    try escaped_name.append(self.allocator, '\'');
                    try escaped_name.append(self.allocator, '\'');
                } else {
                    try escaped_name.append(self.allocator, char);
                }
            }

            const insert_sql = try std.fmt.allocPrint(
                self.allocator,
                "INSERT INTO schema_migrations (version, name, applied_at) VALUES ({d}, '{s}', {d})",
                .{ migration.version, escaped_name.items, timestamp },
            );
            defer self.allocator.free(insert_sql);

            trans.execute(insert_sql) catch |err| {
                trans.rollback() catch {};
                return err;
            };

            trans.commit() catch |err| {
                trans.rollback() catch {};
                return err;
            };
        }
    }

    pub fn rollbackMigration(self: *MigrationRunner, version: u32, migrations: []const Migration) !void {
        try self.createMigrationsTable();

        var migration: ?Migration = null;
        for (migrations) |m| {
            if (m.version == version) {
                migration = m;
                break;
            }
        }

        if (migration == null) {
            return error.MigrationNotFound;
        }

        if (!try self.isApplied(version)) {
            return error.MigrationNotApplied;
        }

        const m = migration.?;

        var trans = try self.db.beginTransaction();
        defer trans.deinit();

        trans.execute(m.down) catch |err| {
            trans.rollback() catch {};
            return err;
        };

        const delete_sql = try std.fmt.allocPrint(
            self.allocator,
            "DELETE FROM schema_migrations WHERE version = {d}",
            .{version},
        );
        defer self.allocator.free(delete_sql);

        trans.execute(delete_sql) catch |err| {
            trans.rollback() catch {};
            return err;
        };

        trans.commit() catch |err| {
            trans.rollback() catch {};
            return err;
        };
    }

    pub const Error = error{
        DuplicateMigrationVersion,
        MigrationNotFound,
        MigrationNotApplied,
    };
};

test "MigrationRunner create migrations table" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var runner = MigrationRunner.init(&db, allocator);
    try runner.createMigrationsTable();

    var result = try db.query("SELECT COUNT(*) FROM schema_migrations");
    defer result.deinit();

    if (result.nextRow()) |row| {
        const count = row.getInt64(0);
        try std.testing.expectEqual(@as(i64, 0), count);
    }
}

test "MigrationRunner getCurrentVersion empty" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var runner = MigrationRunner.init(&db, allocator);
    const version = try runner.getCurrentVersion();
    try std.testing.expect(version == null);
}

test "MigrationRunner runMigrations" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var runner = MigrationRunner.init(&db, allocator);

    const migrations = [_]Migration{
        Migration.init(1, "create_users", "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);", "DROP TABLE users;"),
    };

    try runner.runMigrations(&migrations);

    var result = try db.query("SELECT COUNT(*) FROM users");
    defer result.deinit();

    if (result.nextRow()) |row| {
        const count = row.getInt64(0);
        try std.testing.expectEqual(@as(i64, 0), count);
    }

    const version = try runner.getCurrentVersion();
    try std.testing.expect(version != null);
    try std.testing.expectEqual(@as(u32, 1), version.?);
}

test "MigrationRunner runMigrations multiple" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var runner = MigrationRunner.init(&db, allocator);

    const migrations = [_]Migration{
        Migration.init(1, "create_users", "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);", "DROP TABLE users;"),
        Migration.init(2, "add_email", "ALTER TABLE users ADD COLUMN email TEXT;", "ALTER TABLE users DROP COLUMN email;"),
    };

    try runner.runMigrations(&migrations);

    const version = try runner.getCurrentVersion();
    try std.testing.expect(version != null);
    try std.testing.expectEqual(@as(u32, 2), version.?);

    var result = try db.query("SELECT COUNT(*) FROM users");
    defer result.deinit();
    if (result.nextRow()) |row| {
        try std.testing.expectEqual(@as(i64, 0), row.getInt64(0));
    }
}

test "MigrationRunner rollbackMigration" {
    const allocator = std.testing.allocator;
    var db = try Database.open(":memory:", allocator);
    defer db.close();

    var runner = MigrationRunner.init(&db, allocator);

    const migrations = [_]Migration{
        Migration.init(1, "create_users", "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);", "DROP TABLE users;"),
    };

    try runner.runMigrations(&migrations);
    try runner.rollbackMigration(1, &migrations);

    const version = try runner.getCurrentVersion();
    try std.testing.expect(version == null);
}

