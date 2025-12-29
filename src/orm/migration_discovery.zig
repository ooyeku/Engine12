const std = @import("std");
const Migration = @import("migration.zig").Migration;
const MigrationRegistry = @import("migration.zig").MigrationRegistry;

pub fn discoverMigrations(
    allocator: std.mem.Allocator,
    migrations_dir: []const u8,
) !MigrationRegistry {
    var registry = MigrationRegistry.init(allocator);

    var dir = std.fs.cwd().openDir(migrations_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("[Engine12] Warning: Could not open migrations directory '{s}': {}\n", .{ migrations_dir, err });
        return registry;
    };
    defer dir.close();

    var iterator = dir.iterate();
    const MigrationFileInfo = struct {
        version: u32,
        name: []const u8,
        path: []const u8,
    };
    var migration_files = try std.ArrayList(MigrationFileInfo).initCapacity(allocator, 10);
    defer {
        for (migration_files.items) |item| {
            allocator.free(item.name);
            allocator.free(item.path);
        }
        migration_files.deinit(allocator);
    }

    const init_path = try std.fmt.allocPrint(allocator, "{s}/init.zig", .{migrations_dir});
    defer allocator.free(init_path);

    const init_file_result = std.fs.cwd().openFile(init_path, .{});
    if (init_file_result) |init_file| {
        init_file.close();
        std.debug.print("[Engine12] Info: migrations/init.zig found. For comptime imports, use @import(\"migrations/init.zig\") directly.\n", .{});
    } else |err| {
        if (err != error.FileNotFound) {
            std.debug.print("[Engine12] Warning: Could not read migrations/init.zig: {}\n", .{err});
        }
    }

    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;

        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".zig")) continue;
        if (std.mem.eql(u8, name, "init.zig")) continue;

        const underscore_pos = std.mem.indexOfScalar(u8, name, '_') orelse {
            std.debug.print("[Engine12] Warning: Skipping migration file '{s}' (doesn't match pattern: number_name.zig)\n", .{name});
            continue;
        };

        const version_str = name[0..underscore_pos];
        const version = std.fmt.parseInt(u32, version_str, 10) catch {
            std.debug.print("[Engine12] Warning: Skipping migration file '{s}' (invalid version number)\n", .{name});
            continue;
        };

        const name_start = underscore_pos + 1;
        const name_end = name.len - 4;
        const migration_name = try allocator.dupe(u8, name[name_start..name_end]);
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ migrations_dir, name });

        try migration_files.append(allocator, .{
            .version = version,
            .name = migration_name,
            .path = full_path,
        });
    }

    std.mem.sort(MigrationFileInfo, migration_files.items, {}, struct {
        fn lessThan(_: void, a: MigrationFileInfo, b: MigrationFileInfo) bool {
            return a.version < b.version;
        }
    }.lessThan);

    for (migration_files.items) |file_info| {
        const migration = parseMigrationFile(allocator, file_info.path, file_info.version, file_info.name) catch |err| {
            std.debug.print("[Engine12] Warning: Failed to parse migration file '{s}': {}\n", .{ file_info.path, err });
            continue;
        };

        try registry.add(migration);
    }

    return registry;
}

fn parseMigrationFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    version: u32,
    name: []const u8,
) !Migration {
    const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024);
    defer allocator.free(content);


    const init_start = std.mem.indexOf(u8, content, "Migration.init") orelse {
        return error.InvalidMigrationFormat;
    };

    var pos = init_start + "Migration.init".len;

    while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n' or content[pos] == '(')) {
        pos += 1;
    }

    while (pos < content.len and (content[pos] == '0' or content[pos] == '1' or content[pos] == '2' or content[pos] == '3' or content[pos] == '4' or content[pos] == '5' or content[pos] == '6' or content[pos] == '7' or content[pos] == '8' or content[pos] == '9')) {
        pos += 1;
    }

    while (pos < content.len and (content[pos] == ',' or content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n')) {
        pos += 1;
    }

    if (pos >= content.len or content[pos] != '"') {
        return error.InvalidMigrationFormat;
    }
    pos += 1;
    while (pos < content.len and content[pos] != '"') {
        if (content[pos] == '\\') pos += 1;
        pos += 1;
    }
    pos += 1;

    while (pos < content.len and (content[pos] == ',' or content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n')) {
        pos += 1;
    }

    var up_sql: []const u8 = undefined;
    var up_allocated = false;

    if (pos < content.len and content[pos] == '"') {
        pos += 1;
        const up_start = pos;
        while (pos < content.len and content[pos] != '"') {
            if (content[pos] == '\\') pos += 1;
            pos += 1;
        }
        up_sql = content[up_start..pos];
        pos += 1;
    } else if (pos < content.len and std.mem.startsWith(u8, content[pos..], "\\\\")) {
        var list = std.ArrayListUnmanaged(u8){};
        defer if (!up_allocated) list.deinit(allocator);

        while (pos < content.len) {
            var line_start_check = pos;
            while (line_start_check < content.len and (content[line_start_check] == ' ' or content[line_start_check] == '\t')) {
                line_start_check += 1;
            }

            if (line_start_check < content.len and std.mem.startsWith(u8, content[line_start_check..], "\\\\")) {
                pos = line_start_check + 2;

                const line_end = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
                try list.appendSlice(allocator, content[pos..line_end]);

                pos = line_end;

                if (pos < content.len and content[pos] == '\n') {
                    pos += 1;

                    var next_check = pos;
                    while (next_check < content.len and (content[next_check] == ' ' or content[next_check] == '\t')) {
                        next_check += 1;
                    }

                    if (next_check < content.len and std.mem.startsWith(u8, content[next_check..], "\\\\")) {
                        try list.append(allocator, '\n');
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else {
                break;
            }
        }
        up_sql = try list.toOwnedSlice(allocator);
        up_allocated = true;
    } else {
        return error.InvalidMigrationFormat;
    }

    while (pos < content.len and (content[pos] == ',' or content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n')) {
        pos += 1;
    }

    var down_sql: []const u8 = undefined;
    var down_allocated = false;

    if (pos < content.len and content[pos] == '"') {
        pos += 1;
        const down_start = pos;
        while (pos < content.len and content[pos] != '"') {
            if (content[pos] == '\\') pos += 1;
            pos += 1;
        }
        down_sql = content[down_start..pos];
        pos += 1;
    } else if (pos < content.len and std.mem.startsWith(u8, content[pos..], "\\\\")) {
        var list = std.ArrayListUnmanaged(u8){};
        defer if (!down_allocated) list.deinit(allocator);

        while (pos < content.len) {
            var line_start_check = pos;
            while (line_start_check < content.len and (content[line_start_check] == ' ' or content[line_start_check] == '\t')) {
                line_start_check += 1;
            }

            if (line_start_check < content.len and std.mem.startsWith(u8, content[line_start_check..], "\\\\")) {
                pos = line_start_check + 2;

                const line_end = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
                try list.appendSlice(allocator, content[pos..line_end]);

                pos = line_end;

                if (pos < content.len and content[pos] == '\n') {
                    pos += 1;

                    var next_check = pos;
                    while (next_check < content.len and (content[next_check] == ' ' or content[next_check] == '\t')) {
                        next_check += 1;
                    }

                    if (next_check < content.len and std.mem.startsWith(u8, content[next_check..], "\\\\")) {
                        try list.append(allocator, '\n');
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else {
                break;
            }
        }
        down_sql = try list.toOwnedSlice(allocator);
        down_allocated = true;
    } else {
        if (up_allocated) allocator.free(up_sql);
        return error.InvalidMigrationFormat;
    }

    const up_copy = if (up_allocated) up_sql else try allocator.dupe(u8, up_sql);
    const down_copy = if (down_allocated) down_sql else try allocator.dupe(u8, down_sql);
    const name_copy = try allocator.dupe(u8, name);

    return Migration.init(version, name_copy, up_copy, down_copy);
}

test "discoverMigrations with empty directory" {
    const allocator = std.testing.allocator;
    const test_dir = "test_migrations_empty";

    std.fs.cwd().makeDir(test_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var registry = try discoverMigrations(allocator, test_dir);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.getMigrations().len);
}

test "discoverMigrations with numbered files" {
    const allocator = std.testing.allocator;
    const test_dir = "test_migrations_numbered";

    std.fs.cwd().makeDir(test_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.fs.cwd().deleteTree(test_dir) catch {};
            try std.fs.cwd().makeDir(test_dir);
        }
    };
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const file1_content =
        \\pub const migration = Migration.init(
        \\    1,
        \\    "create_users",
        \\    "CREATE TABLE users (id INTEGER PRIMARY KEY);",
        \\    "DROP TABLE users;"
        \\);
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/1_create_users.zig", .{test_dir}), .data = file1_content });

    const file2_content =
        \\pub const migration = Migration.init(
        \\    2,
        \\    "add_email",
        \\    "ALTER TABLE users ADD COLUMN email TEXT;",
        \\    "ALTER TABLE users DROP COLUMN email;"
        \\);
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/2_add_email.zig", .{test_dir}), .data = file2_content });

    var registry = try discoverMigrations(allocator, test_dir);
    defer registry.deinit();

    const migrations = registry.getMigrations();
    try std.testing.expectEqual(@as(usize, 2), migrations.len);
    try std.testing.expectEqual(@as(u32, 1), migrations[0].version);
    try std.testing.expectEqual(@as(u32, 2), migrations[1].version);
    try std.testing.expectEqualStrings("create_users", migrations[0].name);
    try std.testing.expectEqualStrings("add_email", migrations[1].name);
}

test "discoverMigrations with non-existent directory" {
    const allocator = std.testing.allocator;

    var registry = try discoverMigrations(allocator, "non_existent_migrations_dir_12345");
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.getMigrations().len);
}
