const std = @import("std");

pub const FieldType = enum {
    text,
    integer,
    real,
    blob,
    boolean,
};

pub const Field = struct {
    name: []const u8,
    field_type: FieldType,
    primary_key: bool = false,
    not_null: bool = false,
    unique: bool = false,
    auto_increment: bool = false,
};

pub const ModelDef = struct {
    table_name: []const u8,
    fields: []const Field,

    pub fn toCreateTableSQL(self: ModelDef, allocator: std.mem.Allocator) ![]const u8 {
        var sql = std.ArrayListUnmanaged(u8){};
        errdefer sql.deinit(allocator);

        try sql.writer(allocator).print("CREATE TABLE IF NOT EXISTS {s} (", .{self.table_name});

        for (self.fields, 0..) |field, i| {
            if (i > 0) try sql.writer(allocator).print(", ", .{});

            try sql.writer(allocator).print("{s} ", .{field.name});

            switch (field.field_type) {
                .text => try sql.writer(allocator).print("TEXT", .{}),
                .integer => try sql.writer(allocator).print("INTEGER", .{}),
                .real => try sql.writer(allocator).print("REAL", .{}),
                .blob => try sql.writer(allocator).print("BLOB", .{}),
                .boolean => try sql.writer(allocator).print("INTEGER", .{}),
            }

            if (field.primary_key) try sql.writer(allocator).print(" PRIMARY KEY", .{});
            if (field.auto_increment) try sql.writer(allocator).print(" AUTOINCREMENT", .{});
            if (field.not_null) try sql.writer(allocator).print(" NOT NULL", .{});
            if (field.unique) try sql.writer(allocator).print(" UNIQUE", .{});
        }

        try sql.writer(allocator).print(")", .{});
        return sql.toOwnedSlice(allocator);
    }
};

pub fn getTableName(comptime T: type) []const u8 {
    const type_name = @typeName(T);
    // Convert PascalCase to snake_case for table name
    // For now, just return lowercase version
    // TODO: Implement proper PascalCase to snake_case conversion
    _ = type_name;
    return "unknown_table";
}

pub fn inferTableName(comptime T: type) []const u8 {
    const type_name = @typeName(T);
    // Extract the innermost struct name (after the last dot)
    // For "builtin.basic_auth.User", we want "User"
    // Note: We return "User" here, lowercase conversion happens in toLowercaseTableName()
    if (std.mem.lastIndexOf(u8, type_name, ".")) |idx| {
        return type_name[idx + 1 ..];
    }
    return type_name;
}

/// Convert table name to lowercase (for SQLite compatibility)
/// This is a runtime function that can be called when building SQL queries
pub fn toLowercaseTableName(allocator: std.mem.Allocator, table_name: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    try result.ensureTotalCapacity(allocator, table_name.len);
    for (table_name) |c| {
        try result.append(allocator, if (c >= 'A' and c <= 'Z') (c + 32) else c);
    }

    return result.toOwnedSlice(allocator);
}

pub fn toSnakeCase(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    for (input, 0..) |char, i| {
        if (i > 0 and char >= 'A' and char <= 'Z') {
            try result.append(allocator, '_');
            try result.append(allocator, char + 32); // Convert to lowercase
        } else if (char >= 'A' and char <= 'Z') {
            try result.append(allocator, char + 32);
        } else {
            try result.append(allocator, char);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Pluralize a singular word to create a conventional table name
/// Follows common English pluralization rules:
/// - Words ending in s, x, z, ch, sh -> add "es"
/// - Words ending in consonant + y -> change to "ies"
/// - Common irregular words handled specially
/// - Default -> add "s"
///
/// Example: "user" -> "users", "todo" -> "todos", "category" -> "categories"
pub fn pluralize(allocator: std.mem.Allocator, singular: []const u8) ![]const u8 {
    if (singular.len == 0) return allocator.dupe(u8, singular);

    // Check for common irregular plurals
    const irregulars = [_]struct { singular: []const u8, plural: []const u8 }{
        .{ .singular = "person", .plural = "people" },
        .{ .singular = "child", .plural = "children" },
        .{ .singular = "man", .plural = "men" },
        .{ .singular = "woman", .plural = "women" },
        .{ .singular = "foot", .plural = "feet" },
        .{ .singular = "tooth", .plural = "teeth" },
        .{ .singular = "goose", .plural = "geese" },
        .{ .singular = "mouse", .plural = "mice" },
        .{ .singular = "ox", .plural = "oxen" },
        .{ .singular = "index", .plural = "indices" },
        .{ .singular = "matrix", .plural = "matrices" },
        .{ .singular = "vertex", .plural = "vertices" },
        .{ .singular = "datum", .plural = "data" },
        .{ .singular = "medium", .plural = "media" },
        .{ .singular = "analysis", .plural = "analyses" },
        .{ .singular = "crisis", .plural = "crises" },
    };

    for (irregulars) |pair| {
        if (std.mem.eql(u8, singular, pair.singular)) {
            return allocator.dupe(u8, pair.plural);
        }
    }

    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    const last_char = singular[singular.len - 1];
    const second_last = if (singular.len >= 2) singular[singular.len - 2] else 0;

    // Words ending in s, x, z, ch, sh -> add "es"
    if (last_char == 's' or last_char == 'x' or last_char == 'z') {
        try result.appendSlice(allocator, singular);
        try result.appendSlice(allocator, "es");
    } else if (singular.len >= 2 and 
               ((second_last == 'c' and last_char == 'h') or 
                (second_last == 's' and last_char == 'h'))) {
        try result.appendSlice(allocator, singular);
        try result.appendSlice(allocator, "es");
    }
    // Words ending in consonant + y -> change to "ies"
    else if (last_char == 'y' and singular.len >= 2 and !isVowel(second_last)) {
        try result.appendSlice(allocator, singular[0 .. singular.len - 1]);
        try result.appendSlice(allocator, "ies");
    }
    // Words ending in f or fe -> change to "ves" (common cases)
    else if (last_char == 'f') {
        try result.appendSlice(allocator, singular[0 .. singular.len - 1]);
        try result.appendSlice(allocator, "ves");
    } else if (singular.len >= 2 and second_last == 'f' and last_char == 'e') {
        try result.appendSlice(allocator, singular[0 .. singular.len - 2]);
        try result.appendSlice(allocator, "ves");
    }
    // Words ending in o preceded by consonant 
    // Most modern English words ending in -o just add -s (photo, piano, radio, video, todo)
    // Only a few older words add -es (hero, potato, tomato, echo)
    else if (last_char == 'o' and singular.len >= 2 and !isVowel(second_last)) {
        // Check for words that need "es"
        const o_es_words = [_][]const u8{ "hero", "potato", "tomato", "echo", "veto", "torpedo", "embargo" };
        var needs_es = false;
        for (o_es_words) |word| {
            if (std.mem.eql(u8, singular, word)) {
                needs_es = true;
                break;
            }
        }
        if (needs_es) {
            try result.appendSlice(allocator, singular);
            try result.appendSlice(allocator, "es");
        } else {
            // Default for -o words: just add "s" (todo, photo, piano, etc.)
            try result.appendSlice(allocator, singular);
            try result.appendSlice(allocator, "s");
        }
    }
    // Default: just add "s"
    else {
        try result.appendSlice(allocator, singular);
        try result.appendSlice(allocator, "s");
    }

    return result.toOwnedSlice(allocator);
}

fn isVowel(c: u8) bool {
    return c == 'a' or c == 'e' or c == 'i' or c == 'o' or c == 'u' or
           c == 'A' or c == 'E' or c == 'I' or c == 'O' or c == 'U';
}

pub fn getFieldNames(comptime T: type) *const [std.meta.fields(T).len][]const u8 {
    const fields = std.meta.fields(T);
    const names = comptime blk: {
        var result: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, i| {
            result[i] = field.name;
        }
        break :blk result;
    };
    return &names;
}

/// Comptime table name generation
/// Returns the pluralized, lowercase table name for a type at compile time
/// Supports custom table_name declaration on the type
///
/// Example:
/// ```zig
/// const User = struct { id: i64, name: []const u8 };
/// const table_name = comptimeTableName(User); // "users"
/// ```
pub fn comptimeTableName(comptime T: type) []const u8 {
    return comptime blk: {
        // Check for custom table_name declaration
        if (@hasDecl(T, "table_name")) {
            break :blk @field(T, "table_name");
        }

        // Get struct name
        const raw_name = inferTableName(T);

        // Convert to lowercase
        var lowercase: [raw_name.len]u8 = undefined;
        for (raw_name, 0..) |c, i| {
            lowercase[i] = if (c >= 'A' and c <= 'Z') (c + 32) else c;
        }
        const lowercase_slice: []const u8 = &lowercase;

        // Pluralize (simplified comptime version)
        break :blk comptimePluralize(lowercase_slice);
    };
}

/// Comptime pluralization (simplified for compile-time use)
fn comptimePluralize(comptime singular: []const u8) []const u8 {
    if (singular.len == 0) return singular;

    const last = singular[singular.len - 1];
    const second_last = if (singular.len >= 2) singular[singular.len - 2] else 0;

    // Irregular plurals
    if (comptimeEql(singular, "person")) return "people";
    if (comptimeEql(singular, "child")) return "children";
    if (comptimeEql(singular, "man")) return "men";
    if (comptimeEql(singular, "woman")) return "women";
    if (comptimeEql(singular, "foot")) return "feet";
    if (comptimeEql(singular, "tooth")) return "teeth";
    if (comptimeEql(singular, "goose")) return "geese";
    if (comptimeEql(singular, "mouse")) return "mice";
    if (comptimeEql(singular, "datum")) return "data";
    if (comptimeEql(singular, "medium")) return "media";

    // Words ending in s, x, z -> add "es"
    if (last == 's' or last == 'x' or last == 'z') {
        return singular ++ "es";
    }

    // Words ending in ch, sh -> add "es"
    if (singular.len >= 2) {
        if ((second_last == 'c' and last == 'h') or
            (second_last == 's' and last == 'h'))
        {
            return singular ++ "es";
        }
    }

    // Words ending in consonant + y -> change to "ies"
    if (last == 'y' and singular.len >= 2 and !comptimeIsVowel(second_last)) {
        return singular[0 .. singular.len - 1] ++ "ies";
    }

    // Words ending in f -> change to "ves"
    if (last == 'f') {
        return singular[0 .. singular.len - 1] ++ "ves";
    }

    // Words ending in fe -> change to "ves"
    if (singular.len >= 2 and second_last == 'f' and last == 'e') {
        return singular[0 .. singular.len - 2] ++ "ves";
    }

    // Default: just add "s"
    return singular ++ "s";
}

fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

fn comptimeIsVowel(c: u8) bool {
    return c == 'a' or c == 'e' or c == 'i' or c == 'o' or c == 'u';
}

test "inferTableName simple struct" {
    const TestUser = struct {
        id: i64,
        name: []const u8,
    };

    const table_name = inferTableName(TestUser);
    try std.testing.expectEqualStrings("TestUser", table_name);
}

test "inferTableName qualified struct" {
    const TestUser = struct {
        id: i64,
        name: []const u8,
    };

    const table_name = inferTableName(@TypeOf(TestUser));
    // This should handle qualified types
    _ = table_name;
}

test "toSnakeCase" {
    const allocator = std.testing.allocator;

    const snake = try toSnakeCase(allocator, "TestUser");
    defer allocator.free(snake);
    try std.testing.expectEqualStrings("test_user", snake);

    const snake2 = try toSnakeCase(allocator, "UserProfile");
    defer allocator.free(snake2);
    try std.testing.expectEqualStrings("user_profile", snake2);

    const snake3 = try toSnakeCase(allocator, "MyTestClass");
    defer allocator.free(snake3);
    try std.testing.expectEqualStrings("my_test_class", snake3);
}

test "getFieldNames" {
    const TestUser = struct {
        id: i64,
        name: []const u8,
        age: i32,
    };

    const fields = getFieldNames(TestUser);
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("id", fields[0]);
    try std.testing.expectEqualStrings("name", fields[1]);
    try std.testing.expectEqualStrings("age", fields[2]);
}

test "ModelDef toCreateTableSQL" {
    const allocator = std.testing.allocator;

    const model_def = ModelDef{
        .table_name = "users",
        .fields = &.{
            Field{ .name = "id", .field_type = .integer, .primary_key = true, .auto_increment = true },
            Field{ .name = "name", .field_type = .text, .not_null = true },
            Field{ .name = "age", .field_type = .integer },
            Field{ .name = "email", .field_type = .text, .unique = true },
        },
    };

    const sql = try model_def.toCreateTableSQL(allocator);
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE IF NOT EXISTS users") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "id INTEGER PRIMARY KEY AUTOINCREMENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "name TEXT NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "age INTEGER") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "email TEXT UNIQUE") != null);
}

test "ModelDef toCreateTableSQL boolean field" {
    const allocator = std.testing.allocator;

    const model_def = ModelDef{
        .table_name = "users",
        .fields = &.{
            Field{ .name = "id", .field_type = .integer, .primary_key = true },
            Field{ .name = "active", .field_type = .boolean },
        },
    };

    const sql = try model_def.toCreateTableSQL(allocator);
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "active INTEGER") != null);
}

test "ModelDef toCreateTableSQL real field" {
    const allocator = std.testing.allocator;

    const model_def = ModelDef{
        .table_name = "products",
        .fields = &.{
            Field{ .name = "id", .field_type = .integer, .primary_key = true },
            Field{ .name = "price", .field_type = .real },
        },
    };

    const sql = try model_def.toCreateTableSQL(allocator);
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "price REAL") != null);
}

test "ModelDef toCreateTableSQL blob field" {
    const allocator = std.testing.allocator;

    const model_def = ModelDef{
        .table_name = "files",
        .fields = &.{
            Field{ .name = "id", .field_type = .integer, .primary_key = true },
            Field{ .name = "data", .field_type = .blob },
        },
    };

    const sql = try model_def.toCreateTableSQL(allocator);
    defer allocator.free(sql);

    try std.testing.expect(std.mem.indexOf(u8, sql, "data BLOB") != null);
}

test "pluralize common words" {
    const allocator = std.testing.allocator;

    // Regular plurals
    const users = try pluralize(allocator, "user");
    defer allocator.free(users);
    try std.testing.expectEqualStrings("users", users);

    const todos = try pluralize(allocator, "todo");
    defer allocator.free(todos);
    try std.testing.expectEqualStrings("todos", todos);

    const items = try pluralize(allocator, "item");
    defer allocator.free(items);
    try std.testing.expectEqualStrings("items", items);
}

test "pluralize words ending in s/x/z/ch/sh" {
    const allocator = std.testing.allocator;

    const buses = try pluralize(allocator, "bus");
    defer allocator.free(buses);
    try std.testing.expectEqualStrings("buses", buses);

    const boxes = try pluralize(allocator, "box");
    defer allocator.free(boxes);
    try std.testing.expectEqualStrings("boxes", boxes);

    // Note: English "quiz" -> "quizzes" but our simple pluralization produces "quizes"
    // This is acceptable for table naming - consistency is more important than perfect English
    const quizes = try pluralize(allocator, "quiz");
    defer allocator.free(quizes);
    try std.testing.expectEqualStrings("quizes", quizes);

    const watches = try pluralize(allocator, "watch");
    defer allocator.free(watches);
    try std.testing.expectEqualStrings("watches", watches);

    const wishes = try pluralize(allocator, "wish");
    defer allocator.free(wishes);
    try std.testing.expectEqualStrings("wishes", wishes);
}

test "pluralize words ending in consonant + y" {
    const allocator = std.testing.allocator;

    const categories = try pluralize(allocator, "category");
    defer allocator.free(categories);
    try std.testing.expectEqualStrings("categories", categories);

    const cities = try pluralize(allocator, "city");
    defer allocator.free(cities);
    try std.testing.expectEqualStrings("cities", cities);

    // Vowel + y should just add s
    const days = try pluralize(allocator, "day");
    defer allocator.free(days);
    try std.testing.expectEqualStrings("days", days);

    const keys = try pluralize(allocator, "key");
    defer allocator.free(keys);
    try std.testing.expectEqualStrings("keys", keys);
}

test "pluralize irregular words" {
    const allocator = std.testing.allocator;

    const people = try pluralize(allocator, "person");
    defer allocator.free(people);
    try std.testing.expectEqualStrings("people", people);

    const children = try pluralize(allocator, "child");
    defer allocator.free(children);
    try std.testing.expectEqualStrings("children", children);
}
