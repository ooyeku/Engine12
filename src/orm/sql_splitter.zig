const std = @import("std");

/// Split SQL into individual statements, handling edge cases like semicolons
/// inside strings, comments, and dollar-quoted strings.
///
/// Edge cases handled:
/// - Semicolons inside single-quoted strings: `'value; here'`
/// - Semicolons inside double-quoted identifiers: `"column;name"`
/// - Dollar-quoted strings: `$$value; here$$`
/// - SQL comments: `-- comment;` and `/* comment; */`
/// - Trailing semicolons (empty statements are ignored)
///
/// Example:
/// ```zig
/// const sql = "CREATE TABLE users (id INT); CREATE INDEX idx ON users(id);";
/// const statements = try splitStatements(sql, allocator);
/// defer allocator.free(statements);
/// // statements[0] = "CREATE TABLE users (id INT)"
/// // statements[1] = "CREATE INDEX idx ON users(id)"
/// ```
pub fn splitStatements(sql: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    var statements = std.ArrayListUnmanaged([]const u8){};
    errdefer statements.deinit(allocator);

    if (sql.len == 0) {
        return &[_][]const u8{};
    }

    var state: enum {
        normal,
        single_quote,
        double_quote,
        dollar_quote,
        line_comment,
        block_comment,
    } = .normal;

    var dollar_tag: []const u8 = "";
    var statement_start: usize = 0;
    var i: usize = 0;

    while (i < sql.len) {
        const c = sql[i];
        const next_char = if (i + 1 < sql.len) sql[i + 1] else 0;

        switch (state) {
            .normal => {
                switch (c) {
                    '\'' => {
                        state = .single_quote;
                    },
                    '"' => {
                        state = .double_quote;
                    },
                    '$' => {
                        // Check for dollar-quoted string: $tag$ or $$tag$$
                        if (i + 1 < sql.len and sql[i + 1] == '$') {
                            // $$...$$ format
                            state = .dollar_quote;
                            dollar_tag = "$$";
                            i += 1; // Skip second $
                        } else {
                            // $tag$...$tag$ format - find the tag
                            const tag_start = i + 1;
                            var tag_end = tag_start;
                            while (tag_end < sql.len and sql[tag_end] != '$') {
                                tag_end += 1;
                            }
                            if (tag_end < sql.len) {
                                dollar_tag = sql[tag_start..tag_end];
                                state = .dollar_quote;
                                i = tag_end; // Skip to the closing $ of tag
                            }
                        }
                    },
                    '-' => {
                        if (next_char == '-') {
                            // Skip the comment - update statement_start to skip comment text
                            state = .line_comment;
                            i += 1; // Skip second -
                            // If we're at the start of a potential statement, skip whitespace
                            if (statement_start == i - 1) {
                                statement_start = i + 1;
                            }
                        }
                    },
                    '/' => {
                        if (next_char == '*') {
                            // Skip the comment - update statement_start to skip comment text
                            state = .block_comment;
                            i += 1; // Skip *
                            // If we're at the start of a potential statement, skip whitespace
                            if (statement_start == i - 1) {
                                statement_start = i + 1;
                            }
                        }
                    },
                    ';' => {
                        // Found statement separator
                        const statement = trimWhitespace(sql[statement_start..i]);
                        if (statement.len > 0) {
                            try statements.append(allocator, statement);
                        }
                        statement_start = i + 1;
                    },
                    else => {},
                }
            },
            .single_quote => {
                if (c == '\'') {
                    // Check for escaped quote: ''
                    if (i + 1 < sql.len and sql[i + 1] == '\'') {
                        i += 1; // Skip escaped quote
                    } else {
                        state = .normal;
                    }
                }
            },
            .double_quote => {
                if (c == '"') {
                    // Check for escaped quote: ""
                    if (i + 1 < sql.len and sql[i + 1] == '"') {
                        i += 1; // Skip escaped quote
                    } else {
                        state = .normal;
                    }
                }
            },
            .dollar_quote => {
                if (c == '$') {
                    if (dollar_tag.len == 0) {
                        // This shouldn't happen, but handle it
                        state = .normal;
                    } else if (std.mem.eql(u8, dollar_tag, "$$")) {
                        // Check for closing $$
                        if (i + 1 < sql.len and sql[i + 1] == '$') {
                            state = .normal;
                            i += 1; // Skip second $
                            dollar_tag = "";
                        }
                    } else {
                        // Check for closing $tag$
                        if (i + dollar_tag.len + 1 < sql.len) {
                            const potential_close = sql[i + 1..i + 1 + dollar_tag.len];
                            if (std.mem.eql(u8, potential_close, dollar_tag) and
                                i + 1 + dollar_tag.len < sql.len and
                                sql[i + 1 + dollar_tag.len] == '$')
                            {
                                state = .normal;
                                i += dollar_tag.len + 1; // Skip tag and closing $
                                dollar_tag = "";
                            }
                        }
                    }
                }
            },
            .line_comment => {
                if (c == '\n' or c == '\r') {
                    state = .normal;
                    // Update statement_start to skip the comment (including newline)
                    if (statement_start < i) {
                        statement_start = i + 1;
                    }
                }
            },
            .block_comment => {
                if (c == '*' and next_char == '/') {
                    state = .normal;
                    i += 1; // Skip /
                    // Update statement_start to skip the comment
                    if (statement_start < i - 1) {
                        statement_start = i + 1;
                    }
                }
            },
        }

        i += 1;
    }

    // Add final statement (if any)
    if (statement_start < sql.len) {
        const statement = trimWhitespace(sql[statement_start..]);
        if (statement.len > 0) {
            try statements.append(allocator, statement);
        }
    }

    return statements.toOwnedSlice(allocator);
}

/// Trim leading and trailing whitespace from a string
fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;

    // Trim leading whitespace
    while (start < end and std.ascii.isWhitespace(s[start])) {
        start += 1;
    }

    // Trim trailing whitespace
    while (end > start and std.ascii.isWhitespace(s[end - 1])) {
        end -= 1;
    }

    return s[start..end];
}

// Tests
test "splitStatements - single statement" {
    const allocator = std.testing.allocator;
    const sql = "CREATE TABLE users (id INT PRIMARY KEY)";
    const statements = try splitStatements(sql, allocator);
    defer allocator.free(statements);

    try std.testing.expectEqual(@as(usize, 1), statements.len);
    try std.testing.expectEqualStrings("CREATE TABLE users (id INT PRIMARY KEY)", statements[0]);
}

test "splitStatements - multiple statements" {
    const allocator = std.testing.allocator;
    const sql = "CREATE TABLE users (id INT); CREATE INDEX idx ON users(id);";
    const statements = try splitStatements(sql, allocator);
    defer allocator.free(statements);

    try std.testing.expectEqual(@as(usize, 2), statements.len);
    try std.testing.expectEqualStrings("CREATE TABLE users (id INT)", statements[0]);
    try std.testing.expectEqualStrings("CREATE INDEX idx ON users(id)", statements[1]);
}

test "splitStatements - semicolon in single-quoted string" {
    const allocator = std.testing.allocator;
    const sql = "INSERT INTO users (name) VALUES ('John; Doe'); SELECT * FROM users;";
    const statements = try splitStatements(sql, allocator);
    defer allocator.free(statements);

    try std.testing.expectEqual(@as(usize, 2), statements.len);
    try std.testing.expectEqualStrings("INSERT INTO users (name) VALUES ('John; Doe')", statements[0]);
    try std.testing.expectEqualStrings("SELECT * FROM users", statements[1]);
}

test "splitStatements - escaped single quote" {
    const allocator = std.testing.allocator;
    const sql = "INSERT INTO users (name) VALUES ('John''s Name'); SELECT * FROM users;";
    const statements = try splitStatements(sql, allocator);
    defer allocator.free(statements);

    try std.testing.expectEqual(@as(usize, 2), statements.len);
    try std.testing.expectEqualStrings("INSERT INTO users (name) VALUES ('John''s Name')", statements[0]);
}

test "splitStatements - semicolon in double-quoted identifier" {
    const allocator = std.testing.allocator;
    const sql = "CREATE TABLE \"table;name\" (id INT); SELECT * FROM \"table;name\";";
    const statements = try splitStatements(sql, allocator);
    defer allocator.free(statements);

    try std.testing.expectEqual(@as(usize, 2), statements.len);
    try std.testing.expectEqualStrings("CREATE TABLE \"table;name\" (id INT)", statements[0]);
    try std.testing.expectEqualStrings("SELECT * FROM \"table;name\"", statements[1]);
}

test "splitStatements - dollar-quoted string $$" {
    const allocator = std.testing.allocator;
    const sql = "CREATE FUNCTION test() RETURNS TEXT AS $$ SELECT 'value; here'; $$ LANGUAGE sql;";
    const statements = try splitStatements(sql, allocator);
    defer allocator.free(statements);

    try std.testing.expectEqual(@as(usize, 1), statements.len);
    try std.testing.expectEqualStrings("CREATE FUNCTION test() RETURNS TEXT AS $$ SELECT 'value; here'; $$ LANGUAGE sql", statements[0]);
}

test "splitStatements - dollar-quoted string with tag" {
    const allocator = std.testing.allocator;
    const sql = "CREATE FUNCTION test() RETURNS TEXT AS $body$ SELECT 'value; here'; $body$ LANGUAGE sql;";
    const statements = try splitStatements(sql, allocator);
    defer allocator.free(statements);

    try std.testing.expectEqual(@as(usize, 1), statements.len);
    try std.testing.expectEqualStrings("CREATE FUNCTION test() RETURNS TEXT AS $body$ SELECT 'value; here'; $body$ LANGUAGE sql", statements[0]);
}

test "splitStatements - line comment with semicolon" {
    const allocator = std.testing.allocator;
    const sql = "CREATE TABLE users (id INT); -- This is a comment; with semicolon\nSELECT * FROM users;";
    const statements = try splitStatements(sql, allocator);
    defer allocator.free(statements);

    try std.testing.expectEqual(@as(usize, 2), statements.len);
    try std.testing.expectEqualStrings("CREATE TABLE users (id INT)", statements[0]);
    try std.testing.expectEqualStrings("SELECT * FROM users", statements[1]);
}

test "splitStatements - block comment with semicolon" {
    const allocator = std.testing.allocator;
    const sql = "CREATE TABLE users (id INT); /* This is a comment; with semicolon */ SELECT * FROM users;";
    const statements = try splitStatements(sql, allocator);
    defer allocator.free(statements);

    try std.testing.expectEqual(@as(usize, 2), statements.len);
    try std.testing.expectEqualStrings("CREATE TABLE users (id INT)", statements[0]);
    try std.testing.expectEqualStrings("SELECT * FROM users", statements[1]);
}

test "splitStatements - trailing semicolon" {
    const allocator = std.testing.allocator;
    const sql = "CREATE TABLE users (id INT);";
    const statements = try splitStatements(sql, allocator);
    defer allocator.free(statements);

    try std.testing.expectEqual(@as(usize, 1), statements.len);
    try std.testing.expectEqualStrings("CREATE TABLE users (id INT)", statements[0]);
}

test "splitStatements - multiple trailing semicolons" {
    const allocator = std.testing.allocator;
    const sql = "CREATE TABLE users (id INT);;;";
    const statements = try splitStatements(sql, allocator);
    defer allocator.free(statements);

    try std.testing.expectEqual(@as(usize, 1), statements.len);
    try std.testing.expectEqualStrings("CREATE TABLE users (id INT)", statements[0]);
}

test "splitStatements - empty string" {
    const allocator = std.testing.allocator;
    const sql = "";
    const statements = try splitStatements(sql, allocator);
    defer allocator.free(statements);

    try std.testing.expectEqual(@as(usize, 0), statements.len);
}

test "splitStatements - whitespace only" {
    const allocator = std.testing.allocator;
    const sql = "   \n\t  ";
    const statements = try splitStatements(sql, allocator);
    defer allocator.free(statements);

    try std.testing.expectEqual(@as(usize, 0), statements.len);
}

test "splitStatements - complex migration" {
    const allocator = std.testing.allocator;
    const sql =
        \\CREATE TABLE users (
        \\  id SERIAL PRIMARY KEY,
        \\  name VARCHAR(255) NOT NULL
        \\);
        \\CREATE INDEX idx_users_name ON users(name);
        \\CREATE FUNCTION get_user_count() RETURNS INTEGER AS $$
        \\  SELECT COUNT(*) FROM users;
        \\$$ LANGUAGE sql;
    ;
    const statements = try splitStatements(sql, allocator);
    defer allocator.free(statements);

    try std.testing.expectEqual(@as(usize, 3), statements.len);
    try std.testing.expect(std.mem.indexOf(u8, statements[0], "CREATE TABLE users") != null);
    try std.testing.expect(std.mem.indexOf(u8, statements[1], "CREATE INDEX") != null);
    try std.testing.expect(std.mem.indexOf(u8, statements[2], "CREATE FUNCTION") != null);
}

