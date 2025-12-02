const std = @import("std");
const sqlite = @import("sqlite.zig");
const pg = @import("pg");
const driver_mod = @import("driver.zig");
const Driver = driver_mod.Driver;

// Error types for ORM operations
pub const ORMError = error{
    ColumnMismatch,
    TypeMismatch,
    InvalidData,
    NullValueForNonOptional,
    DeserializationFailed,
};

/// SQLite-specific row implementation
pub const SqliteRow = struct {
    stmt: *sqlite.sqlite3_stmt,

    pub fn getText(self: SqliteRow, col_index: c_int) ?[]const u8 {
        return sqlite.getColumnText(self.stmt, col_index);
    }

    pub fn getInt64(self: SqliteRow, col_index: c_int) i64 {
        return sqlite.column_int64(self.stmt, col_index);
    }

    pub fn getDouble(self: SqliteRow, col_index: c_int) f64 {
        return sqlite.column_double(self.stmt, col_index);
    }

    pub fn isNull(self: SqliteRow, col_index: c_int) bool {
        return sqlite.isColumnNull(self.stmt, col_index);
    }

    pub fn getTextAlloc(self: SqliteRow, allocator: std.mem.Allocator, col_index: c_int) !?[]u8 {
        const text = self.getText(col_index) orelse return null;
        return try allocator.dupe(u8, text);
    }
};

/// PostgreSQL row wrapper that stores column values in memory
pub const PostgresStoredRow = struct {
    values: []StoredValue,
    allocator: std.mem.Allocator,

    pub const StoredValue = union(enum) {
        text: []const u8,
        int: i64,
        float: f64,
        bool_val: bool,
        null_val: void,
    };

    pub fn getText(self: PostgresStoredRow, col_index: usize) ?[]const u8 {
        if (col_index >= self.values.len) return null;
        return switch (self.values[col_index]) {
            .text => |t| t,
            // For other types, return null - caller should use appropriate getter
            else => null,
        };
    }

    pub fn getInt64(self: PostgresStoredRow, col_index: usize) i64 {
        if (col_index >= self.values.len) return 0;
        return switch (self.values[col_index]) {
            .int => |i| i,
            .bool_val => |b| if (b) @as(i64, 1) else @as(i64, 0),
            .text => |t| std.fmt.parseInt(i64, t, 10) catch 0,
            else => 0,
        };
    }

    pub fn getDouble(self: PostgresStoredRow, col_index: usize) f64 {
        if (col_index >= self.values.len) return 0.0;
        return switch (self.values[col_index]) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
            else => 0.0,
        };
    }

    pub fn isNull(self: PostgresStoredRow, col_index: usize) bool {
        if (col_index >= self.values.len) return true;
        return self.values[col_index] == .null_val;
    }

    pub fn deinit(self: *PostgresStoredRow) void {
        for (self.values) |val| {
            switch (val) {
                .text => |t| self.allocator.free(t),
                else => {},
            }
        }
        self.allocator.free(self.values);
    }

    /// Deep copy this row so it owns its own memory
    /// This is needed when returning rows from QueryResult.nextRow() to prevent use-after-free
    pub fn copy(self: PostgresStoredRow, allocator: std.mem.Allocator) !PostgresStoredRow {
        const copied_values = try allocator.alloc(StoredValue, self.values.len);
        errdefer allocator.free(copied_values);

        for (self.values, 0..) |val, i| {
            copied_values[i] = switch (val) {
                .text => |t| .{ .text = try allocator.dupe(u8, t) },
                .int => |i_val| .{ .int = i_val },
                .float => |f| .{ .float = f },
                .bool_val => |b| .{ .bool_val = b },
                .null_val => .null_val,
            };
        }

        return PostgresStoredRow{
            .values = copied_values,
            .allocator = allocator,
        };
    }
};

/// Unified row representation that works with any database driver
/// Provides a driver-agnostic interface for accessing column values
pub const Row = struct {
    driver: Driver,
    data: RowData,

    pub const RowData = union {
        sqlite: SqliteRow,
        postgres: PostgresStoredRow,
    };

    /// Create a Row from a SQLite row
    pub fn fromSqlite(sqlite_row: SqliteRow) Row {
        return Row{
            .driver = .sqlite,
            .data = .{ .sqlite = sqlite_row },
        };
    }

    /// Create a Row from a PostgreSQL stored row
    pub fn fromPostgres(postgres_row: PostgresStoredRow) Row {
        return Row{
            .driver = .postgresql,
            .data = .{ .postgres = postgres_row },
        };
    }

    /// Get text value at column index
    pub fn getText(self: Row, col_index: usize) ?[]const u8 {
        return switch (self.driver) {
            .sqlite => self.data.sqlite.getText(@intCast(col_index)),
            .postgresql => self.data.postgres.getText(col_index),
        };
    }

    /// Get integer value at column index
    pub fn getInt64(self: Row, col_index: usize) i64 {
        return switch (self.driver) {
            .sqlite => self.data.sqlite.getInt64(@intCast(col_index)),
            .postgresql => self.data.postgres.getInt64(col_index),
        };
    }

    /// Get float value at column index
    pub fn getDouble(self: Row, col_index: usize) f64 {
        return switch (self.driver) {
            .sqlite => self.data.sqlite.getDouble(@intCast(col_index)),
            .postgresql => self.data.postgres.getDouble(col_index),
        };
    }

    /// Check if column value is null
    pub fn isNull(self: Row, col_index: usize) bool {
        return switch (self.driver) {
            .sqlite => self.data.sqlite.isNull(@intCast(col_index)),
            .postgresql => self.data.postgres.isNull(col_index),
        };
    }

    /// Get text value with allocation (caller owns memory)
    pub fn getTextAlloc(self: Row, allocator: std.mem.Allocator, col_index: usize) !?[]u8 {
        const text = self.getText(col_index) orelse return null;
        return try allocator.dupe(u8, text);
    }

    // Legacy accessors using c_int for backward compatibility with SQLite code
    pub fn getTextLegacy(self: Row, col_index: c_int) ?[]const u8 {
        return self.getText(@intCast(col_index));
    }

    pub fn getInt64Legacy(self: Row, col_index: c_int) i64 {
        return self.getInt64(@intCast(col_index));
    }

    pub fn getDoubleLegacy(self: Row, col_index: c_int) f64 {
        return self.getDouble(@intCast(col_index));
    }

    pub fn isNullLegacy(self: Row, col_index: c_int) bool {
        return self.isNull(@intCast(col_index));
    }
};

/// Represents the result of a SQL query
/// Works with both SQLite and PostgreSQL drivers
pub const QueryResult = struct {
    driver: Driver,
    allocator: std.mem.Allocator,
    column_count_val: c_int,
    _column_map: ?std.StringHashMap(c_int) = null,
    owns_stmt: bool = true,

    // SQLite-specific data
    sqlite_stmt: ?*sqlite.sqlite3_stmt = null,

    // PostgreSQL-specific data - stored rows and column names
    pg_rows: ?std.ArrayListUnmanaged(PostgresStoredRow) = null,
    pg_column_names: ?[][]const u8 = null,
    pg_row_index: usize = 0,

    /// Initialize a QueryResult for SQLite
    pub fn initSqlite(stmt: *sqlite.sqlite3_stmt, allocator: std.mem.Allocator) QueryResult {
        return QueryResult{
            .driver = .sqlite,
            .allocator = allocator,
            .column_count_val = sqlite.column_count(stmt),
            ._column_map = null,
            .owns_stmt = true,
            .sqlite_stmt = stmt,
        };
    }

    /// Initialize a QueryResult for PostgreSQL with stored rows
    pub fn initPostgres(
        rows: std.ArrayListUnmanaged(PostgresStoredRow),
        column_names: [][]const u8,
        allocator: std.mem.Allocator,
    ) QueryResult {
        return QueryResult{
            .driver = .postgresql,
            .allocator = allocator,
            .column_count_val = @intCast(column_names.len),
            ._column_map = null,
            .owns_stmt = true,
            .pg_rows = rows,
            .pg_column_names = column_names,
            .pg_row_index = 0,
        };
    }

    /// Legacy init for backward compatibility (defaults to SQLite)
    pub fn init(stmt: *sqlite.sqlite3_stmt, allocator: std.mem.Allocator) QueryResult {
        return initSqlite(stmt, allocator);
    }

    /// Build column name -> index mapping (lazy initialization)
    fn buildColumnMap(self: *QueryResult) !std.StringHashMap(c_int) {
        if (self._column_map) |*map| {
            return map.*;
        }

        var column_map = std.StringHashMap(c_int).init(self.allocator);
        errdefer column_map.deinit();

        var i: c_int = 0;
        while (i < self.column_count_val) : (i += 1) {
            if (self.columnName(i)) |name| {
                const name_copy = try self.allocator.dupe(u8, name);
                try column_map.put(name_copy, i);
            }
        }

        self._column_map = column_map;
        return column_map;
    }

    /// Get column index by name
    fn getColumnIndex(self: *QueryResult, field_name: []const u8) !?c_int {
        const column_map = try self.buildColumnMap();
        return column_map.get(field_name);
    }

    /// Get the number of columns in the result
    pub fn columnCount(self: QueryResult) c_int {
        return self.column_count_val;
    }

    /// Get the name of a column by index
    pub fn columnName(self: QueryResult, col_index: c_int) ?[]const u8 {
        return switch (self.driver) {
            .sqlite => if (self.sqlite_stmt) |stmt| sqlite.getColumnName(stmt, col_index) else null,
            .postgresql => {
                if (self.pg_column_names) |names| {
                    const idx: usize = @intCast(col_index);
                    if (idx < names.len) {
                        return names[idx];
                    }
                }
                return null;
            },
        };
    }

    /// Get the next row from the result set
    pub fn nextRow(self: *QueryResult) ?Row {
        return switch (self.driver) {
            .sqlite => {
                if (self.sqlite_stmt) |stmt| {
                    const rc = sqlite.step(stmt);
                    if (rc == sqlite.SQLITE_ROW) {
                        return Row.fromSqlite(SqliteRow{ .stmt = stmt });
                    }
                }
                return null;
            },
            .postgresql => {
                if (self.pg_rows) |rows| {
                    if (self.pg_row_index < rows.items.len) {
                        const source_row = rows.items[self.pg_row_index];
                        self.pg_row_index += 1;
                        // Deep copy the row so it owns its own memory
                        // This prevents use-after-free if QueryResult is deinited while Row is still in use
                        const copied_row = source_row.copy(self.allocator) catch {
                            // If allocation fails, return null
                            return null;
                        };
                        return Row.fromPostgres(copied_row);
                    }
                }
                return null;
            },
        };
    }

    /// Release resources
    pub fn deinit(self: *QueryResult) void {
        if (self._column_map) |*map| {
            var iterator = map.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            map.deinit();
        }

        switch (self.driver) {
            .sqlite => {
                if (self.owns_stmt) {
                    if (self.sqlite_stmt) |stmt| {
                        _ = sqlite.finalize(stmt);
                    }
                }
            },
            .postgresql => {
                // Free PostgreSQL stored rows
                if (self.pg_rows) |*rows| {
                    for (rows.items) |*row| {
                        row.deinit();
                    }
                    rows.deinit(self.allocator);
                }
                // Free column names
                if (self.pg_column_names) |names| {
                    for (names) |name| {
                        self.allocator.free(name);
                    }
                    self.allocator.free(names);
                }
            },
        }
    }

    /// Convert result rows to an ArrayList of structs
    pub fn toArrayList(self: *QueryResult, comptime T: type) !std.ArrayListUnmanaged(T) {
        var list = std.ArrayListUnmanaged(T){};
        errdefer list.deinit(self.allocator);

        const column_map = try self.buildColumnMap();

        // Validate that all struct fields have corresponding columns
        var missing_fields = std.ArrayListUnmanaged([]const u8){};
        defer missing_fields.deinit(self.allocator);

        inline for (std.meta.fields(T)) |field| {
            if (column_map.get(field.name) == null) {
                try missing_fields.append(self.allocator, field.name);
            }
        }

        if (missing_fields.items.len > 0) {
            std.debug.print("[ORM Error] Missing columns for struct fields:\n", .{});
            for (missing_fields.items) |field_name| {
                std.debug.print("  - {s}\n", .{field_name});
            }
            std.debug.print("Available columns:\n", .{});
            var iterator = column_map.iterator();
            while (iterator.next()) |entry| {
                std.debug.print("  - {s}\n", .{entry.key_ptr.*});
            }
            return error.ColumnMismatch;
        }

        // Check for extra columns
        const struct_field_count = std.meta.fields(T).len;
        if (column_map.count() > struct_field_count) {
            std.debug.print("[ORM Error] Extra columns in query result that don't match struct fields:\n", .{});
            std.debug.print("Struct has {d} fields, but query returned {d} columns\n", .{ struct_field_count, column_map.count() });
            std.debug.print("Struct fields:\n", .{});
            inline for (std.meta.fields(T)) |field| {
                std.debug.print("  - {s}\n", .{field.name});
            }
            std.debug.print("Query columns:\n", .{});
            var iterator = column_map.iterator();
            while (iterator.next()) |entry| {
                std.debug.print("  - {s}\n", .{entry.key_ptr.*});
            }
            return error.ColumnMismatch;
        }

        while (self.nextRow()) |row| {
            const item = self.rowToStruct(T, row) catch |err| {
                return err;
            };
            try list.append(self.allocator, item);
        }

        return list;
    }

    fn rowToStruct(self: *QueryResult, comptime T: type, row: Row) !T {
        var instance: T = undefined;
        const column_map = try self.buildColumnMap();

        inline for (std.meta.fields(T)) |field| {
            const col_idx = column_map.get(field.name) orelse {
                std.debug.print("[ORM Error] Field '{s}' not found in query result columns\n", .{field.name});
                return error.ColumnMismatch;
            };

            const field_type = @TypeOf(@field(instance, field.name));
            const col_usize: usize = @intCast(col_idx);

            if (row.isNull(col_usize)) {
                const is_optional = @typeInfo(field_type) == .optional;
                if (is_optional) {
                    @field(instance, field.name) = null;
                } else {
                    @field(instance, field.name) = @as(field_type, switch (@typeInfo(field_type)) {
                        .int => 0,
                        .float => 0.0,
                        .bool => false,
                        else => return error.NullValueForNonOptional,
                    });
                }
            } else {
                switch (@typeInfo(field_type)) {
                    .int => {
                        @field(instance, field.name) = @as(field_type, @intCast(row.getInt64(col_usize)));
                    },
                    .float => {
                        @field(instance, field.name) = @as(field_type, @floatCast(row.getDouble(col_usize)));
                    },
                    .bool => {
                        @field(instance, field.name) = row.getInt64(col_usize) != 0;
                    },
                    .pointer => |ptr_info| {
                        if (ptr_info.size == .slice and ptr_info.child == u8) {
                            const text = row.getText(col_usize) orelse return error.InvalidData;
                            @field(instance, field.name) = try self.allocator.dupe(u8, text);
                        } else {
                            @compileError("ORM error: Unsupported pointer type for field '" ++ field.name ++ "' of type '" ++ @typeName(field_type) ++ "'. " ++
                                "Only slice pointers ([]const u8, []u8) are supported.");
                        }
                    },
                    .optional => |opt_info| {
                        const inner_type = opt_info.child;

                        if (row.isNull(col_usize)) {
                            @field(instance, field.name) = null;
                        } else {
                            switch (@typeInfo(inner_type)) {
                                .int => {
                                    @field(instance, field.name) = @as(inner_type, @intCast(row.getInt64(col_usize)));
                                },
                                .float => {
                                    @field(instance, field.name) = @as(inner_type, @floatCast(row.getDouble(col_usize)));
                                },
                                .bool => {
                                    @field(instance, field.name) = row.getInt64(col_usize) != 0;
                                },
                                .pointer => |ptr_info| {
                                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                                        const text = row.getText(col_usize) orelse return error.InvalidData;
                                        @field(instance, field.name) = try self.allocator.dupe(u8, text);
                                    } else {
                                        @compileError("ORM error: Unsupported optional pointer type for field '" ++ field.name ++ "'.");
                                    }
                                },
                                .@"enum" => {
                                    const enum_int_type = @typeInfo(inner_type).@"enum".tag_type;
                                    const enum_int_value = @as(enum_int_type, @intCast(row.getInt64(col_usize)));
                                    const enum_value = @as(inner_type, @enumFromInt(enum_int_value));
                                    @field(instance, field.name) = enum_value;
                                },
                                else => @compileError("ORM error: Unsupported optional type for field '" ++ field.name ++ "'."),
                            }
                        }
                    },
                    .@"enum" => {
                        const enum_int_type = @typeInfo(field_type).@"enum".tag_type;
                        const enum_int_value = @as(enum_int_type, @intCast(row.getInt64(col_usize)));
                        const enum_value = @as(field_type, @enumFromInt(enum_int_value));
                        @field(instance, field.name) = enum_value;
                    },
                    else => @compileError("ORM error: Unsupported field type '" ++ @typeName(field_type) ++ "' for field '" ++ field.name ++ "'."),
                }
            }
        }

        return instance;
    }
};

// Tests

test "Row getText" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");

    var result = try db.query("SELECT * FROM users");
    defer result.deinit();

    const row = result.nextRow() orelse return error.NoRow;
    const name = row.getText(1);
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("Alice", name.?);
}

test "Row getInt64" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, age INTEGER)");
    try db.execute("INSERT INTO users (age) VALUES (25)");

    var result = try db.query("SELECT * FROM users");
    defer result.deinit();

    const row = result.nextRow() orelse return error.NoRow;
    const id = row.getInt64(0);
    const age = row.getInt64(1);
    try std.testing.expect(id > 0);
    try std.testing.expectEqual(@as(i64, 25), age);
}

test "Row getDouble" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE products (id INTEGER PRIMARY KEY, price REAL)");
    try db.execute("INSERT INTO products (price) VALUES (19.99)");

    var result = try db.query("SELECT * FROM products");
    defer result.deinit();

    const row = result.nextRow() orelse return error.NoRow;
    const price = row.getDouble(1);
    try std.testing.expectApproxEqAbs(@as(f64, 19.99), price, 0.01);
}

test "Row isNull" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");
    try db.execute("INSERT INTO users (name, age) VALUES (NULL, 25)");

    var result = try db.query("SELECT * FROM users");
    defer result.deinit();

    const row = result.nextRow() orelse return error.NoRow;
    try std.testing.expect(row.isNull(1));
    try std.testing.expect(!row.isNull(2));
}

test "Row getTextAlloc" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");

    var result = try db.query("SELECT * FROM users");
    defer result.deinit();

    const row = result.nextRow() orelse return error.NoRow;
    const name = try row.getTextAlloc(allocator, 1);
    defer if (name) |n| allocator.free(n);

    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("Alice", name.?);
}

test "QueryResult columnCount" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    var result = try db.query("SELECT * FROM users");
    defer result.deinit();

    try std.testing.expectEqual(@as(c_int, 3), result.columnCount());
}

test "QueryResult columnName" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    var result = try db.query("SELECT id, name FROM users");
    defer result.deinit();

    try std.testing.expectEqualStrings("id", result.columnName(0).?);
    try std.testing.expectEqualStrings("name", result.columnName(1).?);
    try std.testing.expect(result.columnName(2) == null);
}

test "QueryResult nextRow multiple rows" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES ('Bob')");
    try db.execute("INSERT INTO users (name) VALUES ('Charlie')");

    var result = try db.query("SELECT * FROM users ORDER BY id");
    defer result.deinit();

    var count: u32 = 0;
    while (result.nextRow()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 3), count);
}

test "QueryResult toArrayList" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES ('Bob')");

    var result = try db.query("SELECT * FROM users ORDER BY id");
    defer result.deinit();

    var users = try result.toArrayList(User);
    defer {
        for (users.items) |user| {
            allocator.free(user.name);
        }
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), users.items.len);
    try std.testing.expectEqualStrings("Alice", users.items[0].name);
    try std.testing.expectEqualStrings("Bob", users.items[1].name);
}

test "QueryResult toArrayList with optional fields" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: i64,
        name: ?[]u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");
    try db.execute("INSERT INTO users (name) VALUES (NULL)");

    var result = try db.query("SELECT * FROM users ORDER BY id");
    defer result.deinit();

    var users = try result.toArrayList(User);
    defer {
        for (users.items) |user| {
            if (user.name) |n| allocator.free(n);
        }
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), users.items.len);
    try std.testing.expect(users.items[0].name != null);
    try std.testing.expect(users.items[1].name == null);
}

test "QueryResult toArrayList with boolean" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: i64,
        active: bool,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, active INTEGER)");
    try db.execute("INSERT INTO users (active) VALUES (1)");
    try db.execute("INSERT INTO users (active) VALUES (0)");

    var result = try db.query("SELECT * FROM users ORDER BY id");
    defer result.deinit();

    var users = try result.toArrayList(User);
    defer users.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), users.items.len);
    try std.testing.expect(users.items[0].active == true);
    try std.testing.expect(users.items[1].active == false);
}

test "QueryResult toArrayList column order independence" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const Todo = struct {
        id: i64,
        title: []u8,
        completed: bool,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE todos (completed INTEGER, id INTEGER PRIMARY KEY, title TEXT)");
    try db.execute("INSERT INTO todos (title, completed) VALUES ('Test Todo', 1)");

    var result = try db.query("SELECT id, title, completed FROM todos");
    defer result.deinit();

    var todos = try result.toArrayList(Todo);
    defer {
        for (todos.items) |todo| {
            allocator.free(todo.title);
        }
        todos.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), todos.items.len);
    try std.testing.expectEqualStrings("Test Todo", todos.items[0].title);
    try std.testing.expect(todos.items[0].completed == true);
}

test "QueryResult toArrayList with missing column" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: i64,
        name: []u8,
        email: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");

    var result = try db.query("SELECT id, name FROM users");
    defer result.deinit();

    const users = result.toArrayList(User);
    try std.testing.expectError(error.ColumnMismatch, users);
}

test "QueryResult toArrayList with reordered columns in SELECT" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const Todo = struct {
        id: i64,
        title: []u8,
        description: ?[]u8,
        completed: bool,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE todos (id INTEGER PRIMARY KEY, title TEXT, description TEXT, completed INTEGER)");
    try db.execute("INSERT INTO todos (title, description, completed) VALUES ('Test', 'Description', 1)");

    var result = try db.query("SELECT completed, description, title, id FROM todos");
    defer result.deinit();

    var todos = try result.toArrayList(Todo);
    defer {
        for (todos.items) |todo| {
            allocator.free(todo.title);
            if (todo.description) |desc| allocator.free(desc);
        }
        todos.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), todos.items.len);
    try std.testing.expectEqualStrings("Test", todos.items[0].title);
    try std.testing.expect(todos.items[0].completed == true);
    try std.testing.expect(todos.items[0].description != null);
    if (todos.items[0].description) |desc| {
        try std.testing.expectEqualStrings("Description", desc);
    }
}

// Comprehensive edge case tests

test "Row getText with NULL value" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)");
    try db.execute("INSERT INTO test (value) VALUES (NULL)");

    var result = try db.query("SELECT value FROM test");
    defer result.deinit();

    if (result.nextRow()) |row| {
        try std.testing.expect(row.getText(0) == null);
        try std.testing.expect(row.isNull(0));
    }
}

test "Row getInt64 with NULL value" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value INTEGER)");
    try db.execute("INSERT INTO test (value) VALUES (NULL)");

    var result = try db.query("SELECT value FROM test");
    defer result.deinit();

    if (result.nextRow()) |row| {
        try std.testing.expect(row.isNull(0));
        // getInt64 should return 0 for NULL
        try std.testing.expectEqual(@as(i64, 0), row.getInt64(0));
    }
}

test "Row getDouble with NULL value" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value REAL)");
    try db.execute("INSERT INTO test (value) VALUES (NULL)");

    var result = try db.query("SELECT value FROM test");
    defer result.deinit();

    if (result.nextRow()) |row| {
        try std.testing.expect(row.isNull(0));
        // getDouble should return 0.0 for NULL
        try std.testing.expectEqual(@as(f64, 0.0), row.getDouble(0));
    }
}

test "Row getInt64 with text column" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)");
    try db.execute("INSERT INTO test (value) VALUES ('123')");

    var result = try db.query("SELECT value FROM test");
    defer result.deinit();

    if (result.nextRow()) |row| {
        // getInt64 should parse text as integer
        try std.testing.expectEqual(@as(i64, 123), row.getInt64(0));
    }
}

test "Row getDouble with integer column" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value INTEGER)");
    try db.execute("INSERT INTO test (value) VALUES (42)");

    var result = try db.query("SELECT value FROM test");
    defer result.deinit();

    if (result.nextRow()) |row| {
        // getDouble should convert integer to float
        const float_val = row.getDouble(0);
        try std.testing.expect(float_val > 41.9 and float_val < 42.1);
    }
}

test "Row getText with empty string" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)");
    try db.execute("INSERT INTO test (value) VALUES ('')");

    var result = try db.query("SELECT value FROM test");
    defer result.deinit();

    if (result.nextRow()) |row| {
        const text = row.getText(0);
        try std.testing.expect(text != null);
        try std.testing.expectEqualStrings("", text.?);
    }
}

test "Row getInt64 with large values" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value INTEGER)");
    try db.execute("INSERT INTO test (value) VALUES (9223372036854775807)");
    try db.execute("INSERT INTO test (value) VALUES (-9223372036854775808)");

    var result = try db.query("SELECT value FROM test ORDER BY id");
    defer result.deinit();

    if (result.nextRow()) |row| {
        try std.testing.expectEqual(@as(i64, 9223372036854775807), row.getInt64(0));
    }
    if (result.nextRow()) |row| {
        try std.testing.expectEqual(@as(i64, -9223372036854775808), row.getInt64(0));
    }
}

test "Row getDouble with precision" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value REAL)");
    try db.execute("INSERT INTO test (value) VALUES (3.141592653589793)");

    var result = try db.query("SELECT value FROM test");
    defer result.deinit();

    if (result.nextRow()) |row| {
        const pi = row.getDouble(0);
        try std.testing.expect(pi > 3.14159 and pi < 3.14160);
    }
}

test "QueryResult nextRow with empty result" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)");

    var result = try db.query("SELECT * FROM test");
    defer result.deinit();

    try std.testing.expect(result.nextRow() == null);
    // Calling nextRow again should still return null
    try std.testing.expect(result.nextRow() == null);
}

test "QueryResult nextRow returns null after exhaustion" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test_exhaust (id INTEGER PRIMARY KEY, value TEXT)");
    try db.execute("INSERT INTO test_exhaust (value) VALUES ('test')");

    var result = try db.query("SELECT value FROM test_exhaust");
    defer result.deinit();

    // First call should return a row
    const row1 = result.nextRow();
    try std.testing.expect(row1 != null);

    // Second call should return null (no more rows)
    const row2 = result.nextRow();
    try std.testing.expect(row2 == null);

    // Further calls should also return null
    const row3 = result.nextRow();
    try std.testing.expect(row3 == null);
}

test "QueryResult columnCount with different column types" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, score REAL, active INTEGER)");

    var result = try db.query("SELECT * FROM test");
    defer result.deinit();

    try std.testing.expectEqual(@as(c_int, 5), result.columnCount());
}

test "QueryResult columnName with invalid index" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)");

    var result = try db.query("SELECT id FROM test");
    defer result.deinit();

    // Valid index
    try std.testing.expect(result.columnName(0) != null);
    // Invalid index (out of bounds)
    try std.testing.expect(result.columnName(999) == null);
    try std.testing.expect(result.columnName(-1) == null);
}

test "QueryResult toArrayList with empty result" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    var result = try db.query("SELECT id, name FROM users");
    defer result.deinit();

    var users = try result.toArrayList(User);
    defer {
        for (users.items) |user| {
            allocator.free(user.name);
        }
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 0), users.items.len);
}

test "QueryResult toArrayList with many rows" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: i64,
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    // Insert 100 rows
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var buf: [64]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "INSERT INTO users (name) VALUES ('User {d}')", .{i}) catch break;
        try db.execute(sql);
    }

    var result = try db.query("SELECT id, name FROM users ORDER BY id");
    defer result.deinit();

    var users = try result.toArrayList(User);
    defer {
        for (users.items) |user| {
            allocator.free(user.name);
        }
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 100), users.items.len);
    try std.testing.expectEqual(@as(i64, 1), users.items[0].id);
    try std.testing.expectEqual(@as(i64, 100), users.items[99].id);
}

test "QueryResult toArrayList with all NULL values" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: i64,
        name: ?[]u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES (NULL)");

    var result = try db.query("SELECT id, name FROM users");
    defer result.deinit();

    var users = try result.toArrayList(User);
    defer {
        for (users.items) |user| {
            if (user.name) |n| allocator.free(n);
        }
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), users.items.len);
    try std.testing.expect(users.items[0].name == null);
}

test "QueryResult toArrayList with boolean false" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: i64,
        active: bool,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, active INTEGER)");
    try db.execute("INSERT INTO users (active) VALUES (0)");

    var result = try db.query("SELECT id, active FROM users");
    defer result.deinit();

    var users = try result.toArrayList(User);
    defer users.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), users.items.len);
    try std.testing.expect(users.items[0].active == false);
}

test "QueryResult toArrayList with mixed types" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: i64,
        name: []u8,
        age: i64,
        score: f64,
        active: bool,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, score REAL, active INTEGER)");
    try db.execute("INSERT INTO users (name, age, score, active) VALUES ('Alice', 25, 95.5, 1)");

    var result = try db.query("SELECT id, name, age, score, active FROM users");
    defer result.deinit();

    var users = try result.toArrayList(User);
    defer {
        for (users.items) |user| {
            allocator.free(user.name);
        }
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), users.items.len);
    try std.testing.expectEqualStrings("Alice", users.items[0].name);
    try std.testing.expectEqual(@as(i64, 25), users.items[0].age);
    try std.testing.expect(users.items[0].score > 95.4 and users.items[0].score < 95.6);
    try std.testing.expect(users.items[0].active == true);
}

test "QueryResult toArrayList with enum field" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const Status = enum(u8) {
        pending = 0,
        active = 1,
        completed = 2,
    };

    const Task = struct {
        id: i64,
        status: Status,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE tasks (id INTEGER PRIMARY KEY, status INTEGER)");
    try db.execute("INSERT INTO tasks (status) VALUES (1)");

    var result = try db.query("SELECT id, status FROM tasks");
    defer result.deinit();

    var tasks = try result.toArrayList(Task);
    defer tasks.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), tasks.items.len);
    try std.testing.expectEqual(Status.active, tasks.items[0].status);
}

test "PostgresStoredRow copy deep copy" {
    const allocator = std.testing.allocator;

    var original_values = try allocator.alloc(PostgresStoredRow.StoredValue, 2);
    original_values[0] = .{ .text = try allocator.dupe(u8, "test") };
    original_values[1] = .{ .int = 42 };

    var original = PostgresStoredRow{
        .values = original_values,
        .allocator = allocator,
    };
    defer original.deinit();

    // Copy the row
    var copied = try original.copy(allocator);
    defer copied.deinit();

    // Copied should have same values as original
    try std.testing.expectEqualStrings("test", copied.values[0].text);
    try std.testing.expectEqual(@as(i64, 42), copied.values[1].int);

    // Verify they are independent copies (different pointers)
    try std.testing.expect(original.values[0].text.ptr != copied.values[0].text.ptr);
}

test "PostgresStoredRow getText with int value" {
    const allocator = std.testing.allocator;

    var values = try allocator.alloc(PostgresStoredRow.StoredValue, 1);
    values[0] = .{ .int = 42 };

    var row = PostgresStoredRow{
        .values = values,
        .allocator = allocator,
    };
    defer row.deinit();

    // getText should return null for int value
    try std.testing.expect(row.getText(0) == null);
}

test "PostgresStoredRow getInt64 with text value" {
    const allocator = std.testing.allocator;

    var values = try allocator.alloc(PostgresStoredRow.StoredValue, 1);
    values[0] = .{ .text = try allocator.dupe(u8, "123") };

    var row = PostgresStoredRow{
        .values = values,
        .allocator = allocator,
    };
    defer row.deinit();

    // getInt64 should parse text as integer
    try std.testing.expectEqual(@as(i64, 123), row.getInt64(0));
}

test "PostgresStoredRow getInt64 with bool value" {
    const allocator = std.testing.allocator;

    var values = try allocator.alloc(PostgresStoredRow.StoredValue, 2);
    values[0] = .{ .bool_val = true };
    values[1] = .{ .bool_val = false };

    var row = PostgresStoredRow{
        .values = values,
        .allocator = allocator,
    };
    defer row.deinit();

    try std.testing.expectEqual(@as(i64, 1), row.getInt64(0));
    try std.testing.expectEqual(@as(i64, 0), row.getInt64(1));
}

test "PostgresStoredRow getDouble with int value" {
    const allocator = std.testing.allocator;

    var values = try allocator.alloc(PostgresStoredRow.StoredValue, 1);
    values[0] = .{ .int = 42 };

    var row = PostgresStoredRow{
        .values = values,
        .allocator = allocator,
    };
    defer row.deinit();

    const float_val = row.getDouble(0);
    try std.testing.expect(float_val > 41.9 and float_val < 42.1);
}

test "PostgresStoredRow isNull with null value" {
    const allocator = std.testing.allocator;

    var values = try allocator.alloc(PostgresStoredRow.StoredValue, 1);
    values[0] = .{ .null_val = {} };

    var row = PostgresStoredRow{
        .values = values,
        .allocator = allocator,
    };
    defer row.deinit();

    try std.testing.expect(row.isNull(0));
}

test "PostgresStoredRow isNull with out of bounds" {
    const allocator = std.testing.allocator;

    var values = try allocator.alloc(PostgresStoredRow.StoredValue, 1);
    values[0] = .{ .text = try allocator.dupe(u8, "test") };

    var row = PostgresStoredRow{
        .values = values,
        .allocator = allocator,
    };
    defer row.deinit();

    // Out of bounds should return true (null)
    try std.testing.expect(row.isNull(999));
}

test "PostgresStoredRow getText with out of bounds" {
    const allocator = std.testing.allocator;

    var values = try allocator.alloc(PostgresStoredRow.StoredValue, 1);
    values[0] = .{ .text = try allocator.dupe(u8, "test") };

    var row = PostgresStoredRow{
        .values = values,
        .allocator = allocator,
    };
    defer row.deinit();

    // Out of bounds should return null
    try std.testing.expect(row.getText(999) == null);
}

test "QueryResult columnName case sensitivity" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, \"Name\" TEXT)");
    try db.execute("INSERT INTO test (\"Name\") VALUES ('test')");

    var result = try db.query("SELECT \"Name\" FROM test");
    defer result.deinit();

    try std.testing.expectEqualStrings("Name", result.columnName(0).?);
}

test "QueryResult toArrayList with wrong column count" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: i64,
        name: []u8,
        email: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    var result = try db.query("SELECT id, name FROM users");
    defer result.deinit();

    // Should error because struct has 3 fields but query returns 2
    try std.testing.expectError(error.ColumnMismatch, result.toArrayList(User));
}

test "QueryResult toArrayList with extra columns" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: i64,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    var result = try db.query("SELECT id, name FROM users");
    defer result.deinit();

    // Should error because query returns 2 columns but struct has 1
    try std.testing.expectError(error.ColumnMismatch, result.toArrayList(User));
}

test "QueryResult toArrayList with mismatched types" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    const User = struct {
        id: []u8, // Wrong type - should be i64
        name: []u8,
    };

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
    try db.execute("INSERT INTO users (name) VALUES ('Alice')");

    var result = try db.query("SELECT id, name FROM users");
    defer result.deinit();

    // This should work - id will be converted to string
    var users = try result.toArrayList(User);
    defer {
        for (users.items) |user| {
            allocator.free(user.id);
            allocator.free(user.name);
        }
        users.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), users.items.len);
    // ID should be converted to string
    try std.testing.expect(users.items[0].id.len > 0);
}

test "QueryResult multiple iterations" {
    const allocator = std.testing.allocator;
    const Database = @import("database.zig").Database;

    var db = try Database.open(":memory:", allocator);
    defer db.close();

    try db.execute("CREATE TABLE test_multi_iter (id INTEGER PRIMARY KEY, value TEXT)");
    try db.execute("INSERT INTO test_multi_iter (value) VALUES ('A')");
    try db.execute("INSERT INTO test_multi_iter (value) VALUES ('B')");
    try db.execute("INSERT INTO test_multi_iter (value) VALUES ('C')");

    var result = try db.query("SELECT value FROM test_multi_iter ORDER BY id");
    defer result.deinit();

    var values = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (values.items) |val| {
            allocator.free(val);
        }
        values.deinit(allocator);
    }

    // First iteration - must dupe strings since SQLite row data is transient
    while (result.nextRow()) |row| {
        if (row.getText(0)) |val| {
            const duped = try allocator.dupe(u8, val);
            try values.append(allocator, duped);
        }
    }

    try std.testing.expectEqual(@as(usize, 3), values.items.len);
    try std.testing.expectEqualStrings("A", values.items[0]);
    try std.testing.expectEqualStrings("B", values.items[1]);
    try std.testing.expectEqualStrings("C", values.items[2]);
}

// Note: Zero-width types (void) are not supported by toArrayList
// This test is removed as void fields cause compile errors in the ORM
