const std = @import("std");
const Database = @import("database.zig").Database;
const QueryResult = @import("row.zig").QueryResult;
const Driver = @import("driver.zig").Driver;

pub const ColumnInfo = struct {
    name: []const u8,
    type: []const u8,
    not_null: bool,
    default_value: ?[]const u8,
    primary_key: bool,
};

pub const Schema = struct {
    pub fn columnExists(db: *Database, table: []const u8, column: []const u8) !bool {
        const driver = db.getDriver();

        if (driver == .postgresql) {
            const sql = try std.fmt.allocPrint(
                std.heap.page_allocator,
                "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '{s}' AND column_name = '{s}'",
                .{ table, column },
            );
            defer std.heap.page_allocator.free(sql);

            var result = try db.query(sql);
            defer result.deinit();

            return (result.nextRow() != null);
        } else {
            const sql = try std.fmt.allocPrint(
                std.heap.page_allocator,
                "PRAGMA table_info({s})",
                .{table},
            );
            defer std.heap.page_allocator.free(sql);

            var result = try db.query(sql);
            defer result.deinit();

            while (result.nextRow()) |row| {
                if (row.getText(1)) |col_name| {
                    if (std.mem.eql(u8, col_name, column)) {
                        return true;
                    }
                }
            }

            return false;
        }
    }

    pub fn getColumns(db: *Database, table: []const u8, allocator: std.mem.Allocator) ![]ColumnInfo {
        const driver = db.getDriver();

        var columns = std.ArrayListUnmanaged(ColumnInfo){};
        defer columns.deinit(allocator);

        if (driver == .postgresql) {
            const sql = try std.fmt.allocPrint(
                allocator,
                \\SELECT c.column_name, c.data_type, c.is_nullable, c.column_default,
                \\       CASE WHEN pk.column_name IS NOT NULL THEN 1 ELSE 0 END as is_pk
                \\FROM information_schema.columns c
                \\LEFT JOIN (
                \\    SELECT kcu.column_name
                \\    FROM information_schema.table_constraints tc
                \\    JOIN information_schema.key_column_usage kcu
                \\        ON tc.constraint_name = kcu.constraint_name
                \\        AND tc.table_schema = kcu.table_schema
                \\    WHERE tc.constraint_type = 'PRIMARY KEY'
                \\        AND tc.table_schema = 'public'
                \\        AND tc.table_name = '{s}'
                \\) pk ON c.column_name = pk.column_name
                \\WHERE c.table_schema = 'public' AND c.table_name = '{s}'
                \\ORDER BY c.ordinal_position
            ,
                .{ table, table },
            );
            defer allocator.free(sql);

            var result = try db.query(sql);
            defer result.deinit();

            while (result.nextRow()) |row| {
                const name = row.getText(0) orelse continue;
                const type_str = row.getText(1) orelse continue;
                const is_nullable_str = row.getText(2) orelse "YES";
                const default_val = row.getText(3);
                const pk = row.getInt64(4);

                const name_copy = try allocator.dupe(u8, name);
                errdefer allocator.free(name_copy);
                const type_copy = try allocator.dupe(u8, type_str);
                errdefer allocator.free(type_copy);
                const default_copy = if (default_val) |dv| try allocator.dupe(u8, dv) else null;
                errdefer if (default_copy) |dv| allocator.free(dv);

                try columns.append(allocator, ColumnInfo{
                    .name = name_copy,
                    .type = type_copy,
                    .not_null = std.mem.eql(u8, is_nullable_str, "NO"),
                    .default_value = default_copy,
                    .primary_key = (pk != 0),
                });
            }
        } else {
            const sql = try std.fmt.allocPrint(
                allocator,
                "PRAGMA table_info({s})",
                .{table},
            );
            defer allocator.free(sql);

            var result = try db.query(sql);
            defer result.deinit();

            while (result.nextRow()) |row| {
                const name = row.getText(1) orelse continue;
                const type_str = row.getText(2) orelse continue;
                const notnull = row.getInt64(3);
                const default_val = row.getText(4);
                const pk = row.getInt64(5);

                const name_copy = try allocator.dupe(u8, name);
                errdefer allocator.free(name_copy);
                const type_copy = try allocator.dupe(u8, type_str);
                errdefer allocator.free(type_copy);
                const default_copy = if (default_val) |dv| try allocator.dupe(u8, dv) else null;
                errdefer if (default_copy) |dv| allocator.free(dv);

                try columns.append(allocator, ColumnInfo{
                    .name = name_copy,
                    .type = type_copy,
                    .not_null = (notnull != 0),
                    .default_value = default_copy,
                    .primary_key = (pk != 0),
                });
            }
        }

        return columns.toOwnedSlice(allocator);
    }

    pub fn tableExists(db: *Database, table: []const u8) !bool {
        const driver = db.getDriver();

        const sql = if (driver == .postgresql)
            try std.fmt.allocPrint(
                std.heap.page_allocator,
                "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '{s}'",
                .{table},
            )
        else
            try std.fmt.allocPrint(
                std.heap.page_allocator,
                "SELECT name FROM sqlite_master WHERE type='table' AND name='{s}'",
                .{table},
            );
        defer std.heap.page_allocator.free(sql);

        var result = try db.query(sql);
        defer result.deinit();

        return (result.nextRow() != null);
    }


    pub fn createTableIfNotExists(db: *Database, table: []const u8, columns_def: []const u8) !void {
        const sql = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "CREATE TABLE IF NOT EXISTS {s} ({s})",
            .{ table, columns_def },
        );
        defer std.heap.page_allocator.free(sql);
        try db.execute(sql);
    }

    pub fn addColumnIfNotExists(
        db: *Database,
        table: []const u8,
        column: []const u8,
        column_def: []const u8,
    ) !void {
        if (try columnExists(db, table, column)) {
            return; // Already exists, nothing to do
        }

        const sql = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "ALTER TABLE {s} ADD COLUMN {s} {s}",
            .{ table, column, column_def },
        );
        defer std.heap.page_allocator.free(sql);
        try db.execute(sql);
    }

    pub fn createIndexIfNotExists(
        db: *Database,
        index_name: []const u8,
        table: []const u8,
        columns: []const u8,
    ) !void {
        const sql = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "CREATE INDEX IF NOT EXISTS {s} ON {s} ({s})",
            .{ index_name, table, columns },
        );
        defer std.heap.page_allocator.free(sql);
        try db.execute(sql);
    }

    pub fn createUniqueIndexIfNotExists(
        db: *Database,
        index_name: []const u8,
        table: []const u8,
        columns: []const u8,
    ) !void {
        const sql = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "CREATE UNIQUE INDEX IF NOT EXISTS {s} ON {s} ({s})",
            .{ index_name, table, columns },
        );
        defer std.heap.page_allocator.free(sql);
        try db.execute(sql);
    }

    pub fn dropTableIfExists(db: *Database, table: []const u8) !void {
        const sql = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "DROP TABLE IF EXISTS {s}",
            .{table},
        );
        defer std.heap.page_allocator.free(sql);
        try db.execute(sql);
    }

    pub fn dropIndexIfExists(db: *Database, index_name: []const u8) !void {
        const sql = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "DROP INDEX IF EXISTS {s}",
            .{index_name},
        );
        defer std.heap.page_allocator.free(sql);
        try db.execute(sql);
    }

    pub fn getTables(db: *Database, allocator: std.mem.Allocator) ![][]const u8 {
        const driver = db.getDriver();

        const sql: []const u8 = if (driver == .postgresql)
            "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'"
        else
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'";

        var result = try db.query(sql);
        defer result.deinit();

        var tables = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (tables.items) |t| allocator.free(t);
            tables.deinit(allocator);
        }

        while (result.nextRow()) |row| {
            if (row.getText(0)) |name| {
                try tables.append(allocator, try allocator.dupe(u8, name));
            }
        }

        return tables.toOwnedSlice(allocator);
    }

    pub fn indexExists(db: *Database, index_name: []const u8) !bool {
        const driver = db.getDriver();

        const sql = if (driver == .postgresql)
            try std.fmt.allocPrint(
                std.heap.page_allocator,
                "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname = '{s}'",
                .{index_name},
            )
        else
            try std.fmt.allocPrint(
                std.heap.page_allocator,
                "SELECT name FROM sqlite_master WHERE type='index' AND name='{s}'",
                .{index_name},
            );
        defer std.heap.page_allocator.free(sql);

        var result = try db.query(sql);
        defer result.deinit();

        return (result.nextRow() != null);
    }

    pub const SchemaDiff = struct {
        missing_tables: [][]const u8,
        extra_tables: [][]const u8,
        missing_columns: []struct { table: []const u8, column: []const u8 },
        allocator: std.mem.Allocator,

        pub fn deinit(self: *SchemaDiff) void {
            for (self.missing_tables) |t| self.allocator.free(t);
            self.allocator.free(self.missing_tables);
            for (self.extra_tables) |t| self.allocator.free(t);
            self.allocator.free(self.extra_tables);
            for (self.missing_columns) |mc| {
                self.allocator.free(mc.table);
                self.allocator.free(mc.column);
            }
            self.allocator.free(self.missing_columns);
        }

        pub fn hasChanges(self: *const SchemaDiff) bool {
            return self.missing_tables.len > 0 or
                self.extra_tables.len > 0 or
                self.missing_columns.len > 0;
        }
    };

    pub fn diff(
        db: *Database,
        expected: []const struct { table: []const u8, columns: []const []const u8 },
        allocator: std.mem.Allocator,
    ) !SchemaDiff {
        var missing_tables = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (missing_tables.items) |t| allocator.free(t);
            missing_tables.deinit(allocator);
        }

        var extra_tables = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (extra_tables.items) |t| allocator.free(t);
            extra_tables.deinit(allocator);
        }

        var missing_columns = std.ArrayListUnmanaged(struct { table: []const u8, column: []const u8 }){};
        errdefer {
            for (missing_columns.items) |mc| {
                allocator.free(mc.table);
                allocator.free(mc.column);
            }
            missing_columns.deinit(allocator);
        }

        const actual_tables = try getTables(db, allocator);
        defer {
            for (actual_tables) |t| allocator.free(t);
            allocator.free(actual_tables);
        }

        for (expected) |exp| {
            if (!try tableExists(db, exp.table)) {
                try missing_tables.append(allocator, try allocator.dupe(u8, exp.table));
            } else {
                for (exp.columns) |col| {
                    if (!try columnExists(db, exp.table, col)) {
                        try missing_columns.append(allocator, .{
                            .table = try allocator.dupe(u8, exp.table),
                            .column = try allocator.dupe(u8, col),
                        });
                    }
                }
            }
        }

        for (actual_tables) |actual| {
            var found = false;
            for (expected) |exp| {
                if (std.mem.eql(u8, actual, exp.table)) {
                    found = true;
                    break;
                }
            }
            if (!found and !std.mem.eql(u8, actual, "schema_migrations")) {
                try extra_tables.append(allocator, try allocator.dupe(u8, actual));
            }
        }

        return SchemaDiff{
            .missing_tables = try missing_tables.toOwnedSlice(allocator),
            .extra_tables = try extra_tables.toOwnedSlice(allocator),
            .missing_columns = try missing_columns.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }
};

test "Schema.tableExists" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";

    var db = try Database.open(test_db_path, allocator);
    defer db.close();

    try db.execute("CREATE TABLE test_table (id INTEGER PRIMARY KEY, name TEXT)");

    const exists = try Schema.tableExists(&db, "test_table");
    try std.testing.expect(exists);

    const not_exists = try Schema.tableExists(&db, "nonexistent");
    try std.testing.expect(!not_exists);
}

test "Schema.columnExists" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";

    var db = try Database.open(test_db_path, allocator);
    defer db.close();

    try db.execute("CREATE TABLE test_table (id INTEGER PRIMARY KEY, name TEXT)");

    const id_exists = try Schema.columnExists(&db, "test_table", "id");
    try std.testing.expect(id_exists);

    const name_exists = try Schema.columnExists(&db, "test_table", "name");
    try std.testing.expect(name_exists);

    const not_exists = try Schema.columnExists(&db, "test_table", "nonexistent");
    try std.testing.expect(!not_exists);
}

test "Schema.getColumns" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";

    var db = try Database.open(test_db_path, allocator);
    defer db.close();

    try db.execute("CREATE TABLE test_table (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT 'default')");

    const columns = try Schema.getColumns(&db, "test_table", allocator);
    defer {
        for (columns) |col| {
            allocator.free(col.name);
            allocator.free(col.type);
            if (col.default_value) |dv| allocator.free(dv);
        }
        allocator.free(columns);
    }

    try std.testing.expect(columns.len == 2);

    var found_id = false;
    var found_name = false;
    for (columns) |col| {
        if (std.mem.eql(u8, col.name, "id")) {
            found_id = true;
            try std.testing.expect(col.primary_key);
            try std.testing.expect(std.mem.eql(u8, col.type, "INTEGER"));
        } else if (std.mem.eql(u8, col.name, "name")) {
            found_name = true;
            try std.testing.expect(col.not_null);
            try std.testing.expect(std.mem.eql(u8, col.type, "TEXT"));
            try std.testing.expect(col.default_value != null);
        }
    }

    try std.testing.expect(found_id);
    try std.testing.expect(found_name);
}
