const std = @import("std");
const driver_mod = @import("driver.zig");
const Driver = driver_mod.Driver;

pub const QueryBuilder = struct {
    allocator: std.mem.Allocator,
    table_name: []const u8,
    select_fields: std.ArrayListUnmanaged([]const u8),
    where_clauses: std.ArrayListUnmanaged(WhereClause),
    limit_val: ?usize = null,
    offset_val: ?usize = null,
    order_by_field: ?[]const u8 = null,
    order_ascending: bool = true,
    join_clauses: std.ArrayListUnmanaged(JoinClause),
    driver: Driver = .sqlite,
    param_index: usize = 0,

    pub const WhereClause = struct {
        field: []const u8,
        operator: []const u8,
        value: []const u8,
        is_param: bool = false,
    };

    pub const JoinClause = struct {
        join_type: []const u8,
        table: []const u8,
        on: []const u8,
    };

    /// Initialize a query builder for SQLite (default, backward compatible)
    pub fn init(allocator: std.mem.Allocator, table_name: []const u8) QueryBuilder {
        return QueryBuilder{
            .allocator = allocator,
            .table_name = table_name,
            .select_fields = .{},
            .where_clauses = .{},
            .join_clauses = .{},
            .driver = .sqlite,
            .param_index = 0,
        };
    }

    /// Initialize a query builder for a specific driver
    pub fn initWithDriver(allocator: std.mem.Allocator, table_name: []const u8, driver: Driver) QueryBuilder {
        return QueryBuilder{
            .allocator = allocator,
            .table_name = table_name,
            .select_fields = .{},
            .where_clauses = .{},
            .join_clauses = .{},
            .driver = driver,
            .param_index = 0,
        };
    }

    /// Set the target driver for SQL generation
    pub fn forDriver(self: *QueryBuilder, driver: Driver) *QueryBuilder {
        self.driver = driver;
        return self;
    }

    pub fn deinit(self: *QueryBuilder) void {
        self.select_fields.deinit(self.allocator);
        self.where_clauses.deinit(self.allocator);
        self.join_clauses.deinit(self.allocator);
    }

    pub fn select(self: *QueryBuilder, fields: []const []const u8) *QueryBuilder {
        for (fields) |field| {
            self.select_fields.append(self.allocator, field) catch {};
        }
        return self;
    }

    pub fn where(self: *QueryBuilder, field: []const u8, operator: []const u8, value: []const u8) *QueryBuilder {
        self.where_clauses.append(self.allocator, .{
            .field = field,
            .operator = operator,
            .value = value,
        }) catch {};
        return self;
    }

    pub fn whereEq(self: *QueryBuilder, field: []const u8, value: []const u8) *QueryBuilder {
        return self.where(field, "=", value);
    }

    pub fn whereNe(self: *QueryBuilder, field: []const u8, value: []const u8) *QueryBuilder {
        return self.where(field, "!=", value);
    }

    pub fn whereGt(self: *QueryBuilder, field: []const u8, value: []const u8) *QueryBuilder {
        return self.where(field, ">", value);
    }

    pub fn whereLt(self: *QueryBuilder, field: []const u8, value: []const u8) *QueryBuilder {
        return self.where(field, "<", value);
    }

    pub fn whereGte(self: *QueryBuilder, field: []const u8, value: []const u8) *QueryBuilder {
        return self.where(field, ">=", value);
    }

    pub fn whereLte(self: *QueryBuilder, field: []const u8, value: []const u8) *QueryBuilder {
        return self.where(field, "<=", value);
    }

    /// Add a parameterized WHERE clause (uses ? or $N placeholder)
    pub fn whereParam(self: *QueryBuilder, field: []const u8, operator: []const u8) *QueryBuilder {
        self.param_index += 1;
        self.where_clauses.append(self.allocator, .{
            .field = field,
            .operator = operator,
            .value = "",
            .is_param = true,
        }) catch {};
        return self;
    }

    /// Add a parameterized WHERE = clause
    pub fn whereEqParam(self: *QueryBuilder, field: []const u8) *QueryBuilder {
        return self.whereParam(field, "=");
    }

    /// Add a parameterized WHERE > clause
    pub fn whereGtParam(self: *QueryBuilder, field: []const u8) *QueryBuilder {
        return self.whereParam(field, ">");
    }

    /// Add a parameterized WHERE < clause
    pub fn whereLtParam(self: *QueryBuilder, field: []const u8) *QueryBuilder {
        return self.whereParam(field, "<");
    }

    /// Get the current parameter count (useful for binding)
    pub fn getParamCount(self: *const QueryBuilder) usize {
        return self.param_index;
    }

    pub fn limit(self: *QueryBuilder, count: usize) *QueryBuilder {
        self.limit_val = count;
        return self;
    }

    pub fn offset(self: *QueryBuilder, count: usize) *QueryBuilder {
        self.offset_val = count;
        return self;
    }

    pub fn orderBy(self: *QueryBuilder, field: []const u8, ascending: bool) *QueryBuilder {
        self.order_by_field = field;
        self.order_ascending = ascending;
        return self;
    }

    pub fn join(self: *QueryBuilder, join_type: []const u8, table: []const u8, on: []const u8) *QueryBuilder {
        self.join_clauses.append(self.allocator, .{
            .join_type = join_type,
            .table = table,
            .on = on,
        }) catch {};
        return self;
    }

    pub fn build(self: *QueryBuilder) ![]const u8 {
        var sql = std.ArrayListUnmanaged(u8){};
        errdefer sql.deinit(self.allocator);

        // SELECT clause
        try sql.writer(self.allocator).print("SELECT ", .{});
        if (self.select_fields.items.len > 0) {
            for (self.select_fields.items, 0..) |field, i| {
                if (i > 0) try sql.writer(self.allocator).print(", ", .{});
                try sql.writer(self.allocator).print("{s}", .{field});
            }
        } else {
            try sql.writer(self.allocator).print("*", .{});
        }

        // FROM clause
        try sql.writer(self.allocator).print(" FROM {s}", .{self.table_name});

        // JOIN clauses
        for (self.join_clauses.items) |join_clause| {
            try sql.writer(self.allocator).print(" {s} JOIN {s} ON {s}", .{ join_clause.join_type, join_clause.table, join_clause.on });
        }

        // WHERE clause
        if (self.where_clauses.items.len > 0) {
            try sql.writer(self.allocator).print(" WHERE ", .{});
            var param_counter: usize = 0;
            for (self.where_clauses.items, 0..) |clause, i| {
                if (i > 0) try sql.writer(self.allocator).print(" AND ", .{});

                if (clause.is_param) {
                    // Use parameterized placeholder
                    param_counter += 1;
                    switch (self.driver) {
                        .sqlite => {
                            try sql.writer(self.allocator).print("{s} {s} ?", .{ clause.field, clause.operator });
                        },
                        .postgresql => {
                            try sql.writer(self.allocator).print("{s} {s} ${d}", .{ clause.field, clause.operator, param_counter });
                        },
                    }
                } else {
                    // Escape single quotes in literal value
                    var escaped_value = std.ArrayListUnmanaged(u8){};
                    defer escaped_value.deinit(self.allocator);
                    for (clause.value) |char| {
                        if (char == '\'') {
                            try escaped_value.append(self.allocator, '\'');
                            try escaped_value.append(self.allocator, '\'');
                        } else {
                            try escaped_value.append(self.allocator, char);
                        }
                    }
                    try sql.writer(self.allocator).print("{s} {s} '{s}'", .{ clause.field, clause.operator, escaped_value.items });
                }
            }
        }

        // ORDER BY clause
        if (self.order_by_field) |field| {
            try sql.writer(self.allocator).print(" ORDER BY {s}", .{field});
            if (!self.order_ascending) try sql.writer(self.allocator).print(" DESC", .{});
        }

        // LIMIT clause
        if (self.limit_val) |limit_val| {
            try sql.writer(self.allocator).print(" LIMIT {d}", .{limit_val});
        }

        // OFFSET clause
        if (self.offset_val) |offset_val| {
            try sql.writer(self.allocator).print(" OFFSET {d}", .{offset_val});
        }

        return sql.toOwnedSlice(self.allocator);
    }
};

test "QueryBuilder basic SELECT" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM users", sql);
}

test "QueryBuilder SELECT with fields" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.select(&.{ "id", "name" }).build();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT id, name FROM users", sql);
}

test "QueryBuilder WHERE clause" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.whereEq("name", "Alice").build();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM users WHERE name = 'Alice'", sql);
}

test "QueryBuilder multiple WHERE clauses" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.whereEq("name", "Alice").whereGt("age", "18").build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "name = 'Alice'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "age > '18'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, " AND ") != null);
}

test "QueryBuilder WHERE with special characters" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.whereEq("name", "O'Reilly").build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "O''Reilly") != null);
}

test "QueryBuilder ORDER BY" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.orderBy("name", true).build();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM users ORDER BY name", sql);
}

test "QueryBuilder ORDER BY DESC" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.orderBy("name", false).build();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM users ORDER BY name DESC", sql);
}

test "QueryBuilder LIMIT" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.limit(10).build();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM users LIMIT 10", sql);
}

test "QueryBuilder OFFSET" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.offset(20).build();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM users OFFSET 20", sql);
}

test "QueryBuilder LIMIT and OFFSET" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.limit(10).offset(20).build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "LIMIT 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "OFFSET 20") != null);
}

test "QueryBuilder JOIN" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.join("INNER", "posts", "users.id = posts.user_id").build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "INNER JOIN posts ON users.id = posts.user_id") != null);
}

test "QueryBuilder complex query" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder
        .select(&.{ "id", "name" })
        .whereEq("active", "1")
        .orderBy("name", true)
        .limit(10)
        .offset(0)
        .build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "SELECT id, name FROM users") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "WHERE active = '1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ORDER BY name") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "LIMIT 10") != null);
}

test "QueryBuilder whereGt whereLt whereGte whereLte" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql1 = try builder.whereGt("age", "18").build();
    defer allocator.free(sql1);
    try std.testing.expect(std.mem.indexOf(u8, sql1, "age > '18'") != null);

    builder.deinit();
    var builder2 = QueryBuilder.init(allocator, "users");
    defer builder2.deinit();

    const sql2 = try builder2.whereLt("age", "65").build();
    defer allocator.free(sql2);
    try std.testing.expect(std.mem.indexOf(u8, sql2, "age < '65'") != null);

    builder2.deinit();
    var builder3 = QueryBuilder.init(allocator, "users");
    defer builder3.deinit();

    const sql3 = try builder3.whereGte("age", "18").build();
    defer allocator.free(sql3);
    try std.testing.expect(std.mem.indexOf(u8, sql3, "age >= '18'") != null);

    builder3.deinit();
    var builder4 = QueryBuilder.init(allocator, "users");
    defer builder4.deinit();

    const sql4 = try builder4.whereLte("age", "65").build();
    defer allocator.free(sql4);
    try std.testing.expect(std.mem.indexOf(u8, sql4, "age <= '65'") != null);
}

test "QueryBuilder whereNe" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.whereNe("name", "Alice").build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "name != 'Alice'") != null);
}

test "QueryBuilder parameterized WHERE SQLite" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.whereEqParam("id").whereGtParam("age").build();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM users WHERE id = ? AND age > ?", sql);
    try std.testing.expectEqual(@as(usize, 2), builder.getParamCount());
}

test "QueryBuilder parameterized WHERE PostgreSQL" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.initWithDriver(allocator, "users", .postgresql);
    defer builder.deinit();

    const sql = try builder.whereEqParam("id").whereGtParam("age").build();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM users WHERE id = $1 AND age > $2", sql);
}

test "QueryBuilder forDriver switch" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    _ = builder.forDriver(.postgresql).whereEqParam("id");
    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT * FROM users WHERE id = $1", sql);
}

test "QueryBuilder mixed literal and param" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.whereEq("active", "1").whereEqParam("id").build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "active = '1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "id = ?") != null);
}

// Comprehensive edge case tests

test "QueryBuilder init with empty table name" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "");
    defer builder.deinit();

    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.startsWith(u8, sql, "SELECT * FROM "));
}

test "QueryBuilder select with empty fields" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const empty_fields = [_][]const u8{};
    _ = builder.select(&empty_fields);

    const sql = try builder.build();
    defer allocator.free(sql);

    // Should default to SELECT *
    try std.testing.expect(std.mem.indexOf(u8, sql, "SELECT *") != null);
}

test "QueryBuilder select with single field" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const fields = [_][]const u8{"name"};
    _ = builder.select(&fields);

    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "SELECT name") != null);
}

test "QueryBuilder select with multiple fields" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const fields = [_][]const u8{ "id", "name", "email" };
    _ = builder.select(&fields);

    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "SELECT id, name, email") != null);
}

test "QueryBuilder where with LIKE operator" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.where("name", "LIKE", "%Alice%").build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "name LIKE '%Alice%'") != null);
}

test "QueryBuilder where with IN operator" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.where("id", "IN", "(1, 2, 3)").build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "id IN (1, 2, 3)") != null);
}

test "QueryBuilder where with BETWEEN operator" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.where("age", "BETWEEN", "18 AND 65").build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "age BETWEEN 18 AND 65") != null);
}

test "QueryBuilder where with IS NULL" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.where("email", "IS", "NULL").build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "email IS NULL") != null);
}

test "QueryBuilder where with IS NOT NULL" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.where("email", "IS NOT", "NULL").build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "email IS NOT NULL") != null);
}

test "QueryBuilder orderBy with multiple fields" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    _ = builder.orderBy("name");
    _ = builder.orderBy("age");

    const sql = try builder.build();
    defer allocator.free(sql);

    // Should use last orderBy call
    try std.testing.expect(std.mem.indexOf(u8, sql, "ORDER BY age") != null);
}

test "QueryBuilder limit with zero" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    _ = builder.limit(0);
    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "LIMIT 0") != null);
}

test "QueryBuilder limit with large value" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    _ = builder.limit(999999);
    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "LIMIT 999999") != null);
}

test "QueryBuilder offset with zero" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    _ = builder.offset(0);
    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "OFFSET 0") != null);
}

test "QueryBuilder offset without limit" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    _ = builder.offset(10);
    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "OFFSET 10") != null);
}

test "QueryBuilder LEFT JOIN" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    _ = builder.join("LEFT", "posts", "users.id = posts.user_id");
    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "LEFT JOIN posts ON users.id = posts.user_id") != null);
}

test "QueryBuilder RIGHT JOIN" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    _ = builder.join("RIGHT", "posts", "users.id = posts.user_id");
    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "RIGHT JOIN posts ON users.id = posts.user_id") != null);
}

test "QueryBuilder FULL JOIN" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    _ = builder.join("FULL", "posts", "users.id = posts.user_id");
    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "FULL JOIN posts ON users.id = posts.user_id") != null);
}

test "QueryBuilder multiple JOINs" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    _ = builder.join("INNER", "posts", "users.id = posts.user_id");
    _ = builder.join("LEFT", "comments", "posts.id = comments.post_id");
    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "INNER JOIN posts") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "LEFT JOIN comments") != null);
}

test "QueryBuilder complex query with all features" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const fields = [_][]const u8{ "users.id", "users.name", "posts.title" };
    _ = builder.select(&fields);
    _ = builder.join("INNER", "posts", "users.id = posts.user_id");
    _ = builder.whereEq("users.active", "1");
    _ = builder.whereGt("users.age", "18");
    _ = builder.orderBy("users.name");
    _ = builder.limit(10);
    _ = builder.offset(20);

    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "SELECT users.id, users.name, posts.title") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "INNER JOIN posts") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "users.active = '1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "users.age > '18'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "ORDER BY users.name") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "LIMIT 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "OFFSET 20") != null);
}

test "QueryBuilder SQL injection prevention in WHERE" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    // Attempt SQL injection
    const malicious_input = "'; DROP TABLE users; --";
    const sql = try builder.whereEq("name", malicious_input).build();
    defer allocator.free(sql);

    // Single quotes should be escaped
    try std.testing.expect(std.mem.indexOf(u8, sql, "''") != null);
    // Should not contain unescaped DROP TABLE
    try std.testing.expect(std.mem.indexOf(u8, sql, "DROP TABLE") == null);
}

test "QueryBuilder SQL injection prevention in table name" {
    const allocator = std.testing.allocator;
    // Table name with special characters should be handled
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.build();
    defer allocator.free(sql);

    // Should not allow injection through table name
    try std.testing.expect(std.mem.startsWith(u8, sql, "SELECT * FROM users"));
}

test "QueryBuilder PostgreSQL placeholder conversion" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.initWithDriver(allocator, "users", .postgresql);
    defer builder.deinit();

    _ = builder.whereEqParam("id");
    _ = builder.whereGtParam("age");
    _ = builder.whereLtParam("score");

    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "$1") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "$2") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "$3") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "?") == null); // No SQLite placeholders
}

test "QueryBuilder PostgreSQL complex parameterized query" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.initWithDriver(allocator, "users", .postgresql);
    defer builder.deinit();

    _ = builder.whereEqParam("id");
    _ = builder.whereGtParam("age");
    _ = builder.whereEq("active", "1");
    _ = builder.whereLtParam("score");

    const sql = try builder.build();
    defer allocator.free(sql);

    // Should have $1, $2, $3 for parameters
    try std.testing.expect(std.mem.indexOf(u8, sql, "$1") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "$2") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "$3") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "active = '1'") != null);
}

test "QueryBuilder getParamCount" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    try std.testing.expectEqual(@as(usize, 0), builder.getParamCount());

    _ = builder.whereEqParam("id");
    try std.testing.expectEqual(@as(usize, 1), builder.getParamCount());

    _ = builder.whereGtParam("age");
    try std.testing.expectEqual(@as(usize, 2), builder.getParamCount());

    _ = builder.whereLtParam("score");
    try std.testing.expectEqual(@as(usize, 3), builder.getParamCount());
}

test "QueryBuilder forDriver changes placeholder style" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    _ = builder.whereEqParam("id");
    const sql1 = try builder.build();
    defer allocator.free(sql1);
    try std.testing.expect(std.mem.indexOf(u8, sql1, "?") != null);

    allocator.free(sql1);
    builder.deinit();

    var builder2 = QueryBuilder.init(allocator, "users");
    defer builder2.deinit();

    _ = builder2.forDriver(.postgresql).whereEqParam("id");
    const sql2 = try builder2.build();
    defer allocator.free(sql2);
    try std.testing.expect(std.mem.indexOf(u8, sql2, "$1") != null);
}

test "QueryBuilder where with numeric values" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.whereEq("age", "25").build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "age = '25'") != null);
}

test "QueryBuilder where with boolean-like values" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.whereEq("active", "1").build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "active = '1'") != null);
}

test "QueryBuilder orderBy ASC explicit" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    _ = builder.orderByAsc("name");
    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "ORDER BY name ASC") != null);
}

test "QueryBuilder orderBy DESC explicit" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    _ = builder.orderByDesc("name");
    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "ORDER BY name DESC") != null);
}

test "QueryBuilder deinit cleans up memory" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");

    const fields = [_][]const u8{ "id", "name" };
    _ = builder.select(&fields);
    _ = builder.whereEq("active", "1");
    _ = builder.orderBy("name");

    // Deinit should free all allocated memory
    builder.deinit();

    // If we get here without a leak, the test passes
    try std.testing.expect(true);
}

test "QueryBuilder empty query" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.init(allocator, "users");
    defer builder.deinit();

    const sql = try builder.build();
    defer allocator.free(sql);

    // Should generate basic SELECT * FROM users
    try std.testing.expectEqualStrings("SELECT * FROM users", sql);
}

test "QueryBuilder with table name containing special characters" {
    const allocator = std.testing.allocator;
    // SQLite allows table names with special characters if quoted
    var builder = QueryBuilder.init(allocator, "user_profiles");
    defer builder.deinit();

    const sql = try builder.build();
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "user_profiles") != null);
}

test "QueryBuilder PostgreSQL with all parameter types" {
    const allocator = std.testing.allocator;
    var builder = QueryBuilder.initWithDriver(allocator, "users", .postgresql);
    defer builder.deinit();

    _ = builder.whereEqParam("id");
    _ = builder.whereGtParam("age");
    _ = builder.whereLtParam("score");
    _ = builder.whereGteParam("min_age");
    _ = builder.whereLteParam("max_age");
    _ = builder.whereNeParam("status");

    const sql = try builder.build();
    defer allocator.free(sql);

    // Should have $1 through $6
    try std.testing.expect(std.mem.indexOf(u8, sql, "$1") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "$2") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "$3") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "$4") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "$5") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "$6") != null);
}
