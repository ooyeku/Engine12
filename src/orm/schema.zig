const std = @import("std");
const Database = @import("database.zig").Database;
const QueryResult = @import("row.zig").QueryResult;

/// Information about a database column
pub const ColumnInfo = struct {
    /// Column name
    name: []const u8,
    /// Column type (TEXT, INTEGER, etc.)
    type: []const u8,
    /// Whether the column is NOT NULL
    not_null: bool,
    /// Default value (if any)
    default_value: ?[]const u8,
    /// Whether this is a primary key
    primary_key: bool,
};

/// Database schema introspection utilities
/// Provides functions to inspect database schema structure
pub const Schema = struct {
    /// Check if a column exists in a table
    ///
    /// Example:
    /// ```zig
    /// const exists = try Schema.columnExists(&db, "Todo", "priority");
    /// if (!exists) {
    ///     try db.execute("ALTER TABLE Todo ADD COLUMN priority TEXT");
    /// }
    /// ```
    pub fn columnExists(db: *Database, table: []const u8, column: []const u8) !bool {
        const sql = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "PRAGMA table_info({s})",
            .{table},
        );
        defer std.heap.page_allocator.free(sql);

        var result = try db.query(sql);
        defer result.deinit();

        while (result.nextRow()) |row| {
            // PRAGMA table_info returns: cid, name, type, notnull, dflt_value, pk
            // Column name is at index 1
            if (row.getText(1)) |col_name| {
                if (std.mem.eql(u8, col_name, column)) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Get all columns for a table
    /// Returns an array of ColumnInfo structs
    ///
    /// Example:
    /// ```zig
    /// const columns = try Schema.getColumns(&db, "Todo", allocator);
    /// defer {
    ///     for (columns) |col| {
    ///         allocator.free(col.name);
    ///         allocator.free(col.type);
    ///         if (col.default_value) |dv| allocator.free(dv);
    ///     }
    ///     allocator.free(columns);
    /// }
    /// ```
    pub fn getColumns(db: *Database, table: []const u8, allocator: std.mem.Allocator) ![]ColumnInfo {
        const sql = try std.fmt.allocPrint(
            allocator,
            "PRAGMA table_info({s})",
            .{table},
        );
        defer allocator.free(sql);

        var result = try db.query(sql);
        defer result.deinit();

        var columns = std.ArrayListUnmanaged(ColumnInfo){};
        defer columns.deinit(allocator);

        while (result.nextRow()) |row| {
            // PRAGMA table_info returns: cid, name, type, notnull, dflt_value, pk
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

        return columns.toOwnedSlice(allocator);
    }

    /// Check if a table exists in the database
    ///
    /// Example:
    /// ```zig
    /// const exists = try Schema.tableExists(&db, "Todo");
    /// if (!exists) {
    ///     try db.execute("CREATE TABLE Todo ...");
    /// }
    /// ```
    pub fn tableExists(db: *Database, table: []const u8) !bool {
        const sql = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='{s}'",
            .{table},
        );
        defer std.heap.page_allocator.free(sql);

        var result = try db.query(sql);
        defer result.deinit();

        return (result.nextRow() != null);
    }

    // =========================================================================
    // Idempotent Migration Helpers
    // These methods are safe to call multiple times without error.
    // =========================================================================

    /// Create a table if it doesn't already exist.
    /// Safe to call multiple times (idempotent).
    ///
    /// Example:
    /// ```zig
    /// try Schema.createTableIfNotExists(&db, "users",
    ///     "id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE");
    /// ```
    pub fn createTableIfNotExists(db: *Database, table: []const u8, columns_def: []const u8) !void {
        const sql = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "CREATE TABLE IF NOT EXISTS {s} ({s})",
            .{ table, columns_def },
        );
        defer std.heap.page_allocator.free(sql);
        try db.execute(sql);
    }

    /// Add a column to a table if it doesn't already exist.
    /// Safe to call multiple times (idempotent).
    ///
    /// Example:
    /// ```zig
    /// try Schema.addColumnIfNotExists(&db, "users", "age", "INTEGER DEFAULT 0");
    /// ```
    pub fn addColumnIfNotExists(
        db: *Database,
        table: []const u8,
        column: []const u8,
        column_def: []const u8,
    ) !void {
        // Check if column exists first
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

    /// Create an index if it doesn't already exist.
    /// Safe to call multiple times (idempotent).
    ///
    /// Example:
    /// ```zig
    /// try Schema.createIndexIfNotExists(&db, "idx_users_email", "users", "email");
    /// try Schema.createIndexIfNotExists(&db, "idx_users_name_age", "users", "name, age");
    /// ```
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

    /// Create a unique index if it doesn't already exist.
    /// Safe to call multiple times (idempotent).
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

    /// Drop a table if it exists.
    /// Safe to call multiple times (idempotent).
    pub fn dropTableIfExists(db: *Database, table: []const u8) !void {
        const sql = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "DROP TABLE IF EXISTS {s}",
            .{table},
        );
        defer std.heap.page_allocator.free(sql);
        try db.execute(sql);
    }

    /// Drop an index if it exists.
    /// Safe to call multiple times (idempotent).
    pub fn dropIndexIfExists(db: *Database, index_name: []const u8) !void {
        const sql = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "DROP INDEX IF EXISTS {s}",
            .{index_name},
        );
        defer std.heap.page_allocator.free(sql);
        try db.execute(sql);
    }

    /// Get a list of all tables in the database.
    pub fn getTables(db: *Database, allocator: std.mem.Allocator) ![][]const u8 {
        const sql = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'";

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

    /// Check if an index exists.
    pub fn indexExists(db: *Database, index_name: []const u8) !bool {
        const sql = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "SELECT name FROM sqlite_master WHERE type='index' AND name='{s}'",
            .{index_name},
        );
        defer std.heap.page_allocator.free(sql);

        var result = try db.query(sql);
        defer result.deinit();

        return (result.nextRow() != null);
    }

    /// Schema difference result
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

    /// Compare database schema against expected tables and columns.
    /// Returns differences that need to be addressed.
    ///
    /// Example:
    /// ```zig
    /// const expected = &[_]struct { table: []const u8, columns: []const []const u8 }{
    ///     .{ .table = "users", .columns = &.{ "id", "name", "email" } },
    ///     .{ .table = "posts", .columns = &.{ "id", "title", "user_id" } },
    /// };
    /// var diff = try Schema.diff(&db, expected, allocator);
    /// defer diff.deinit();
    /// if (diff.hasChanges()) { ... }
    /// ```
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

        // Get actual tables
        const actual_tables = try getTables(db, allocator);
        defer {
            for (actual_tables) |t| allocator.free(t);
            allocator.free(actual_tables);
        }

        // Check for missing tables and columns
        for (expected) |exp| {
            if (!try tableExists(db, exp.table)) {
                try missing_tables.append(allocator, try allocator.dupe(u8, exp.table));
            } else {
                // Table exists, check columns
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

        // Check for extra tables (tables in DB but not in expected)
        for (actual_tables) |actual| {
            var found = false;
            for (expected) |exp| {
                if (std.mem.eql(u8, actual, exp.table)) {
                    found = true;
                    break;
                }
            }
            // Skip system tables
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

// Tests
test "Schema.tableExists" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";

    var db = try Database.open(test_db_path, allocator);
    defer db.close();

    // Create a test table
    try db.execute("CREATE TABLE test_table (id INTEGER PRIMARY KEY, name TEXT)");

    // Test table exists
    const exists = try Schema.tableExists(&db, "test_table");
    try std.testing.expect(exists);

    // Test non-existent table
    const not_exists = try Schema.tableExists(&db, "nonexistent");
    try std.testing.expect(!not_exists);
}

test "Schema.columnExists" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";

    var db = try Database.open(test_db_path, allocator);
    defer db.close();

    // Create a test table
    try db.execute("CREATE TABLE test_table (id INTEGER PRIMARY KEY, name TEXT)");

    // Test column exists
    const id_exists = try Schema.columnExists(&db, "test_table", "id");
    try std.testing.expect(id_exists);

    const name_exists = try Schema.columnExists(&db, "test_table", "name");
    try std.testing.expect(name_exists);

    // Test non-existent column
    const not_exists = try Schema.columnExists(&db, "test_table", "nonexistent");
    try std.testing.expect(!not_exists);
}

test "Schema.getColumns" {
    const allocator = std.testing.allocator;
    const test_db_path = ":memory:";

    var db = try Database.open(test_db_path, allocator);
    defer db.close();

    // Create a test table
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

    // Find id column
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
