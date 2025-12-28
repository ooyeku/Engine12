const std = @import("std");

/// Environment variable loader supporting .env files and system environment variables.
/// System env vars take precedence over .env file values.
pub const Env = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMap([]const u8),
    owned_keys: std.ArrayList([]const u8),
    owned_values: std.ArrayList([]const u8),

    pub fn init(alloc: std.mem.Allocator) Env {
        return Env{
            .allocator = alloc,
            .values = std.StringHashMap([]const u8).init(alloc),
            .owned_keys = std.ArrayList([]const u8){},
            .owned_values = std.ArrayList([]const u8){},
        };
    }

    pub fn deinit(self: *Env) void {
        for (self.owned_keys.items) |key| {
            self.allocator.free(key);
        }
        for (self.owned_values.items) |val| {
            self.allocator.free(val);
        }
        self.owned_keys.deinit(self.allocator);
        self.owned_values.deinit(self.allocator);
        self.values.deinit();
    }

    /// Load environment variables from a .env file.
    /// File values are overwritten by system env vars.
    pub fn loadFile(self: *Env, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // .env file is optional
                return;
            }
            return err;
        };
        defer file.close();

        // Read entire file into memory for simplicity
        const max_size = 1024 * 1024; // 1MB max for .env file
        const contents = file.readToEndAlloc(self.allocator, max_size) catch |err| {
            return err;
        };
        defer self.allocator.free(contents);

        // Parse line by line
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            try self.parseLine(line);
        }
    }

    pub fn parseLine(self: *Env, line: []const u8) !void {
        // Trim whitespace and carriage return
        var trimmed = std.mem.trim(u8, line, " \t\r\n");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') {
            return;
        }

        // Find the '=' separator
        const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse return;

        const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
        var value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

        if (key.len == 0) return;

        // Remove surrounding quotes from value
        if (value.len >= 2) {
            if ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\''))
            {
                value = value[1 .. value.len - 1];
            } else {
                // Handle inline comments for unquoted values: KEY=value # comment
                if (std.mem.indexOfScalar(u8, value, '#')) |hash_pos| {
                    // Only treat as comment if preceded by whitespace
                    if (hash_pos > 0 and (value[hash_pos - 1] == ' ' or value[hash_pos - 1] == '\t')) {
                        value = std.mem.trim(u8, value[0..hash_pos], " \t");
                    }
                }
            }
        }

        // Check if system env already has this (system takes precedence)
        if (std.posix.getenv(key) != null) {
            return;
        }

        // Store the value
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        try self.owned_keys.append(self.allocator, key_copy);

        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.owned_values.append(self.allocator, value_copy);

        try self.values.put(key_copy, value_copy);
    }

    /// Get a string value from env (file or system).
    pub fn get(self: *const Env, key: []const u8) ?[]const u8 {
        // System env takes precedence
        if (std.posix.getenv(key)) |sys_val| {
            return sys_val;
        }
        return self.values.get(key);
    }

    /// Get a string value with a default.
    pub fn getOrDefault(self: *const Env, key: []const u8, default: []const u8) []const u8 {
        return self.get(key) orelse default;
    }

    /// Get a required string value or return error.
    pub fn require(self: *const Env, key: []const u8) ![]const u8 {
        return self.get(key) orelse {
            std.debug.print("[Config] Error: Required environment variable '{s}' is not set\n", .{key});
            return error.MissingEnvVar;
        };
    }

    /// Get an integer value.
    pub fn getInt(self: *const Env, comptime T: type, key: []const u8, default: T) T {
        const str = self.get(key) orelse return default;
        return std.fmt.parseInt(T, str, 10) catch default;
    }

    /// Get a boolean value (supports: true, false, 1, 0, yes, no).
    pub fn getBool(self: *const Env, key: []const u8, default: bool) bool {
        const str = self.get(key) orelse return default;
        if (std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "1") or std.mem.eql(u8, str, "yes")) {
            return true;
        }
        if (std.mem.eql(u8, str, "false") or std.mem.eql(u8, str, "0") or std.mem.eql(u8, str, "no")) {
            return false;
        }
        return default;
    }

    /// Get an enum value by name.
    pub fn getEnum(self: *const Env, comptime E: type, key: []const u8, default: E) E {
        const str = self.get(key) orelse return default;
        return std.meta.stringToEnum(E, str) orelse default;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Env.init and deinit" {
    var env = Env.init(std.testing.allocator);
    defer env.deinit();
}

test "Env.parseLine basic" {
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    try env.parseLine("KEY=value");
    try std.testing.expectEqualStrings("value", env.values.get("KEY").?);
}

test "Env.parseLine with quotes" {
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    try env.parseLine("KEY1=\"quoted value\"");
    try env.parseLine("KEY2='single quoted'");

    try std.testing.expectEqualStrings("quoted value", env.values.get("KEY1").?);
    try std.testing.expectEqualStrings("single quoted", env.values.get("KEY2").?);
}

test "Env.parseLine skips comments and empty lines" {
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    try env.parseLine("# This is a comment");
    try env.parseLine("");
    try env.parseLine("   ");
    try env.parseLine("VALID=yes");

    try std.testing.expectEqual(@as(usize, 1), env.values.count());
    try std.testing.expectEqualStrings("yes", env.values.get("VALID").?);
}

test "Env.getInt" {
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    try env.parseLine("PORT=8080");
    try env.parseLine("INVALID=abc");

    try std.testing.expectEqual(@as(u16, 8080), env.getInt(u16, "PORT", 3000));
    try std.testing.expectEqual(@as(u16, 3000), env.getInt(u16, "INVALID", 3000));
    try std.testing.expectEqual(@as(u16, 3000), env.getInt(u16, "MISSING", 3000));
}

test "Env.getBool" {
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    try env.parseLine("ENABLED=true");
    try env.parseLine("DISABLED=false");
    try env.parseLine("YES_VAL=yes");
    try env.parseLine("ONE_VAL=1");

    try std.testing.expect(env.getBool("ENABLED", false));
    try std.testing.expect(!env.getBool("DISABLED", true));
    try std.testing.expect(env.getBool("YES_VAL", false));
    try std.testing.expect(env.getBool("ONE_VAL", false));
    try std.testing.expect(env.getBool("MISSING", true));
}

test "Env.getEnum" {
    const TestEnum = enum { development, staging, production };

    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    try env.parseLine("ENV=production");
    try env.parseLine("INVALID=unknown");

    try std.testing.expectEqual(TestEnum.production, env.getEnum(TestEnum, "ENV", .development));
    try std.testing.expectEqual(TestEnum.development, env.getEnum(TestEnum, "INVALID", .development));
    try std.testing.expectEqual(TestEnum.development, env.getEnum(TestEnum, "MISSING", .development));
}
