const std = @import("std");

pub const Json = struct {
    fn estimateJsonSize(comptime T: type) usize {
        const type_info = @typeInfo(T);

        return switch (type_info) {
            .@"struct" => blk: {
                var size: usize = 2; // "{}"
                inline for (std.meta.fields(T)) |field| {
                    size += field.name.len + 4; // "field_name":
                    size += estimateFieldSize(field.type);
                    size += 1; // comma
                }
                break :blk size;
            },
            .int => 20, // Max i64 is 19 digits + sign
            .float => 24, // Max f64 representation
            .bool => 5, // "false"
            .optional => |opt_info| estimateFieldSize(opt_info.child) + 4, // "null"
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return 256; // Default string estimate
                }
                return 128; // Default array estimate
            },
            else => 64, // Default estimate for unknown types
        };
    }

    fn estimateFieldSize(comptime T: type) usize {
        const type_info = @typeInfo(T);

        return switch (type_info) {
            .int => 20,
            .float => 24,
            .bool => 5,
            .optional => |opt_info| estimateFieldSize(opt_info.child) + 4,
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return 256; // Default string estimate with quotes and escaping
                }
                return 128; // Default array estimate
            },
            .@"struct" => estimateJsonSize(T),
            else => 64,
        };
    }

    pub fn serialize(comptime T: type, value: T, allocator: std.mem.Allocator) ![]const u8 {
        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(allocator);

        const estimated_size = comptime estimateJsonSize(T);
        try list.ensureTotalCapacity(allocator, estimated_size);

        try serializeValue(T, value, &list, allocator);
        return list.toOwnedSlice(allocator);
    }

    pub fn deserialize(comptime T: type, json_str: []const u8, allocator: std.mem.Allocator) !T {
        var parser = Parser.init(json_str, allocator);
        defer parser.deinit();
        return try parser.parseStruct(T);
    }

    pub fn serializeArray(comptime T: type, items: []const T, allocator: std.mem.Allocator) ![]const u8 {
        var list = std.ArrayListUnmanaged(u8){};
        defer list.deinit(allocator);

        const item_size = comptime estimateJsonSize(T);
        const estimated_size = 2 + (item_size + 1) * items.len; // [] + items + commas
        try list.ensureTotalCapacity(allocator, estimated_size);

        try list.writer(allocator).print("[", .{});
        for (items, 0..) |item, i| {
            if (i > 0) {
                try list.writer(allocator).print(",", .{});
            }
            try serializeValue(T, item, &list, allocator);
        }
        try list.writer(allocator).print("]", .{});

        return list.toOwnedSlice(allocator);
    }

    pub fn serializeOptional(comptime T: type, value: ?T, allocator: std.mem.Allocator) ![]const u8 {
        if (value) |v| {
            return serialize(T, v, allocator);
        } else {
            const null_str = try allocator.dupe(u8, "null");
            return null_str;
        }
    }

    fn serializeValue(comptime T: type, value: T, list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
        const type_info = @typeInfo(T);

        switch (type_info) {
            .@"struct" => {
                try list.writer(allocator).print("{{", .{});

                inline for (std.meta.fields(T), 0..) |field, i| {
                    if (i > 0) {
                        try list.writer(allocator).print(",", .{});
                    }

                    try list.writer(allocator).print("\"{s}\":", .{field.name});

                    const field_value = @field(value, field.name);
                    try serializeFieldValue(field.type, field_value, list, allocator);
                }

                try list.writer(allocator).print("}}", .{});
            },
            .array => {
                try list.writer(allocator).print("[", .{});
                for (value, 0..) |item, i| {
                    if (i > 0) {
                        try list.writer(allocator).print(",", .{});
                    }
                    try serializeFieldValue(@TypeOf(item), item, list, allocator);
                }
                try list.writer(allocator).print("]", .{});
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice) {
                    try serializeFieldValue(ptr_info.child, value, list, allocator);
                } else {
                    @compileError("Unsupported pointer type for JSON serialization");
                }
            },
            else => {
                try serializeFieldValue(T, value, list, allocator);
            },
        }
    }

    fn serializeFieldValue(comptime T: type, value: T, list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
        const type_info = @typeInfo(T);

        switch (type_info) {
            .int => {
                try list.writer(allocator).print("{}", .{value});
            },
            .float => {
                try list.writer(allocator).print("{d}", .{value});
            },
            .bool => {
                if (value) {
                    try list.writer(allocator).print("true", .{});
                } else {
                    try list.writer(allocator).print("false", .{});
                }
            },
            .optional => |opt_info| {
                if (value) |v| {
                    try serializeFieldValue(opt_info.child, v, list, allocator);
                } else {
                    try list.writer(allocator).print("null", .{});
                }
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice) {
                    if (ptr_info.child == u8) {
                        try escapeString(value, list, allocator);
                    } else {
                        try list.writer(allocator).print("[", .{});
                        for (value, 0..) |item, i| {
                            if (i > 0) {
                                try list.writer(allocator).print(",", .{});
                            }
                            try serializeFieldValue(ptr_info.child, item, list, allocator);
                        }
                        try list.writer(allocator).print("]", .{});
                    }
                } else {
                    @compileError("Unsupported pointer type for JSON serialization");
                }
            },
            .@"struct" => {
                try serializeValue(T, value, list, allocator);
            },
            else => {
                @compileError("Unsupported type for JSON serialization: " ++ @typeName(T));
            },
        }
    }

    fn escapeString(str: []const u8, list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
        try list.writer(allocator).print("\"", .{});
        for (str) |char| {
            switch (char) {
                '"' => try list.writer(allocator).print("\\\"", .{}),
                '\\' => try list.writer(allocator).print("\\\\", .{}),
                '\n' => try list.writer(allocator).print("\\n", .{}),
                '\r' => try list.writer(allocator).print("\\r", .{}),
                '\t' => try list.writer(allocator).print("\\t", .{}),
                else => try list.writer(allocator).print("{c}", .{char}),
            }
        }
        try list.writer(allocator).print("\"", .{});
    }

    const Parser = struct {
        input: []const u8,
        pos: usize,
        allocator: std.mem.Allocator,

        fn init(input: []const u8, allocator: std.mem.Allocator) Parser {
            return Parser{
                .input = input,
                .pos = 0,
                .allocator = allocator,
            };
        }

        fn deinit(self: *Parser) void {
            _ = self;
        }

        fn skipWhitespace(self: *Parser) void {
            while (self.pos < self.input.len and (self.input[self.pos] == ' ' or self.input[self.pos] == '\t' or self.input[self.pos] == '\n' or self.input[self.pos] == '\r')) {
                self.pos += 1;
            }
        }

        fn parseStruct(self: *Parser, comptime T: type) !T {
            self.skipWhitespace();
            if (self.pos >= self.input.len or self.input[self.pos] != '{') {
                std.debug.print("[JSON Parser Error] Expected '{{' at start of struct\n", .{});
                std.debug.print("  Input: {s}\n", .{self.input});
                std.debug.print("  Position: {d}\n", .{self.pos});
                if (self.pos < self.input.len) {
                    const context_start = if (self.pos > 20) self.pos - 20 else 0;
                    const context_end = if (self.pos + 20 < self.input.len) self.pos + 20 else self.input.len;
                    std.debug.print("  Context: {s}\n", .{self.input[context_start..context_end]});
                }
                return error.InvalidJson;
            }
            self.pos += 1;

            var result: T = undefined;
            inline for (std.meta.fields(T)) |field| {
                const field_type = field.type;
                const type_info = @typeInfo(field_type);
                switch (type_info) {
                    .int => @field(result, field.name) = 0,
                    .float => @field(result, field.name) = 0.0,
                    .bool => @field(result, field.name) = false,
                    .optional => @field(result, field.name) = null,
                    .pointer => |ptr_info| {
                        if (ptr_info.size == .slice and ptr_info.child == u8) {
                            @field(result, field.name) = "";
                        }
                    },
                    else => {},
                }
            }

            while (true) {
                self.skipWhitespace();

                if (self.pos >= self.input.len or self.input[self.pos] == '}') {
                    break;
                }

                const field_name = try self.parseString();
                defer self.allocator.free(field_name);

                self.skipWhitespace();

                if (self.pos >= self.input.len or self.input[self.pos] != ':') {
                    return error.InvalidJson;
                }
                self.pos += 1;
                self.skipWhitespace();

                var found = false;
                inline for (std.meta.fields(T)) |field| {
                    if (std.mem.eql(u8, field_name, field.name)) {
                        const field_value = try self.parseFieldValue(field.type);
                        @field(result, field.name) = field_value;
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    _ = try self.skipValue();
                }

                self.skipWhitespace();
                if (self.pos < self.input.len and self.input[self.pos] == ',') {
                    self.pos += 1;
                }
            }

            self.skipWhitespace();
            if (self.pos >= self.input.len or self.input[self.pos] != '}') {
                std.debug.print("[JSON Parser Error] Expected '}}' at end of struct\n", .{});
                std.debug.print("  Input: {s}\n", .{self.input});
                std.debug.print("  Position: {d}\n", .{self.pos});
                return error.InvalidJson;
            }
            self.pos += 1;

            return result;
        }

        fn parseFieldValue(self: *Parser, comptime T: type) !T {
            const type_info = @typeInfo(T);

            switch (type_info) {
                .int => {
                    return try self.parseInt(T);
                },
                .float => {
                    return try self.parseFloat(T);
                },
                .bool => {
                    return try self.parseBool();
                },
                .optional => |opt_info| {
                    self.skipWhitespace();
                    if (self.pos < self.input.len and std.mem.startsWith(u8, self.input[self.pos..], "null")) {
                        self.pos += 4;
                        return null;
                    } else {
                        const value = try self.parseFieldValue(opt_info.child);
                        return value;
                    }
                },
                .pointer => |ptr_info| {
                    if (ptr_info.size == .slice) {
                        if (ptr_info.child == u8) {
                            return try self.parseString();
                        } else {
                            return try self.parseArray(ptr_info.child);
                        }
                    } else {
                        @compileError("Unsupported pointer type for JSON deserialization: " ++ @typeName(T));
                    }
                },
                .@"struct" => {
                    return try self.parseStruct(T);
                },
                else => {
                    @compileError("Unsupported type for JSON deserialization: " ++ @typeName(T));
                },
            }
        }

        fn parseString(self: *Parser) ![]u8 {
            self.skipWhitespace();
            if (self.pos >= self.input.len or self.input[self.pos] != '"') {
                std.debug.print("[JSON Parser Error] Expected '\\\"' at start of string\n", .{});
                std.debug.print("  Input: {s}\n", .{self.input});
                std.debug.print("  Position: {d}\n", .{self.pos});
                return error.InvalidJson;
            }
            self.pos += 1;

            const start = self.pos;
            var escaped = false;

            while (self.pos < self.input.len) {
                if (escaped) {
                    escaped = false;
                    self.pos += 1;
                    continue;
                }

                if (self.input[self.pos] == '\\') {
                    escaped = true;
                    self.pos += 1;
                    continue;
                }

                if (self.input[self.pos] == '"') {
                    break;
                }

                self.pos += 1;
            }

            if (self.pos >= self.input.len) {
                return error.InvalidJson;
            }

            const str = self.input[start..self.pos];
            self.pos += 1; // Skip closing quote

            var result = std.ArrayListUnmanaged(u8){};
            defer result.deinit(self.allocator);

            var i: usize = 0;
            while (i < str.len) {
                if (str[i] == '\\' and i + 1 < str.len) {
                    switch (str[i + 1]) {
                        'n' => try result.append(self.allocator, '\n'),
                        'r' => try result.append(self.allocator, '\r'),
                        't' => try result.append(self.allocator, '\t'),
                        '\\' => try result.append(self.allocator, '\\'),
                        '"' => try result.append(self.allocator, '"'),
                        else => {
                            try result.append(self.allocator, str[i]);
                            try result.append(self.allocator, str[i + 1]);
                        },
                    }
                    i += 2;
                } else {
                    try result.append(self.allocator, str[i]);
                    i += 1;
                }
            }

            return result.toOwnedSlice(self.allocator);
        }

        fn parseArray(self: *Parser, comptime ElementType: type) ![]ElementType {
            self.skipWhitespace();
            if (self.pos >= self.input.len or self.input[self.pos] != '[') {
                std.debug.print("[JSON Parser Error] Expected '[' at start of array\n", .{});
                std.debug.print("  Position: {d}\n", .{self.pos});
                return error.InvalidJson;
            }
            self.pos += 1;

            var items = std.ArrayListUnmanaged(ElementType){};
            errdefer {
                for (items.items) |item| {
                    self.freeValue(ElementType, item);
                }
                items.deinit(self.allocator);
            }

            self.skipWhitespace();

            if (self.pos < self.input.len and self.input[self.pos] == ']') {
                self.pos += 1;
                return items.toOwnedSlice(self.allocator);
            }

            while (true) {
                self.skipWhitespace();

                const element = try self.parseFieldValue(ElementType);
                try items.append(self.allocator, element);

                self.skipWhitespace();

                if (self.pos >= self.input.len) {
                    return error.InvalidJson;
                }

                if (self.input[self.pos] == ']') {
                    self.pos += 1;
                    break;
                }

                if (self.input[self.pos] == ',') {
                    self.pos += 1;
                    continue;
                }

                std.debug.print("[JSON Parser Error] Expected ',' or ']' in array\n", .{});
                return error.InvalidJson;
            }

            return items.toOwnedSlice(self.allocator);
        }

        fn freeValue(self: *Parser, comptime T: type, value: T) void {
            const type_info = @typeInfo(T);
            switch (type_info) {
                .pointer => |ptr_info| {
                    if (ptr_info.size == .slice) {
                        if (ptr_info.child == u8) {
                            self.allocator.free(value);
                        } else {
                            for (value) |item| {
                                self.freeValue(ptr_info.child, item);
                            }
                            self.allocator.free(value);
                        }
                    }
                },
                .@"struct" => {
                    inline for (std.meta.fields(T)) |field| {
                        const field_type_info = @typeInfo(field.type);
                        if (field_type_info == .pointer) {
                            const ptr_info = field_type_info.pointer;
                            if (ptr_info.size == .slice and ptr_info.child == u8) {
                                self.allocator.free(@field(value, field.name));
                            }
                        }
                    }
                },
                else => {}, // Primitives don't need freeing
            }
        }

        fn parseInt(self: *Parser, comptime T: type) !T {
            self.skipWhitespace();
            const start = self.pos;
            var negative = false;

            if (self.pos < self.input.len and self.input[self.pos] == '-') {
                negative = true;
                self.pos += 1;
            }

            while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9') {
                self.pos += 1;
            }

            if (self.pos == start + @as(usize, @intFromBool(negative))) {
                return error.InvalidJson;
            }

            const num_str = self.input[start..self.pos];
            return std.fmt.parseInt(T, num_str, 10);
        }

        fn parseFloat(self: *Parser, comptime T: type) !T {
            self.skipWhitespace();
            const start = self.pos;
            var negative = false;

            if (self.pos < self.input.len and self.input[self.pos] == '-') {
                negative = true;
                self.pos += 1;
            }

            while (self.pos < self.input.len and ((self.input[self.pos] >= '0' and self.input[self.pos] <= '9') or self.input[self.pos] == '.')) {
                self.pos += 1;
            }

            if (self.pos == start + @as(usize, @intFromBool(negative))) {
                return error.InvalidJson;
            }

            const num_str = self.input[start..self.pos];
            return std.fmt.parseFloat(T, num_str);
        }

        fn parseBool(self: *Parser) !bool {
            self.skipWhitespace();
            if (std.mem.startsWith(u8, self.input[self.pos..], "true")) {
                self.pos += 4;
                return true;
            } else if (std.mem.startsWith(u8, self.input[self.pos..], "false")) {
                self.pos += 5;
                return false;
            } else {
                std.debug.print("[JSON Parser Error] Invalid boolean value\n", .{});
                std.debug.print("  Input: {s}\n", .{self.input});
                std.debug.print("  Position: {d}\n", .{self.pos});
                return error.InvalidJson;
            }
        }

        fn skipValue(self: *Parser) !void {
            self.skipWhitespace();
            if (self.pos >= self.input.len) {
                return error.InvalidJson;
            }

            switch (self.input[self.pos]) {
                '"' => {
                    self.pos += 1;
                    while (self.pos < self.input.len and self.input[self.pos] != '"') {
                        if (self.input[self.pos] == '\\') {
                            self.pos += 1;
                        }
                        self.pos += 1;
                    }
                    if (self.pos < self.input.len) {
                        self.pos += 1;
                    }
                },
                't', 'f' => {
                    if (std.mem.startsWith(u8, self.input[self.pos..], "true")) {
                        self.pos += 4;
                    } else if (std.mem.startsWith(u8, self.input[self.pos..], "false")) {
                        self.pos += 5;
                    }
                },
                'n' => {
                    if (std.mem.startsWith(u8, self.input[self.pos..], "null")) {
                        self.pos += 4;
                    }
                },
                '{' => {
                    self.pos += 1;
                    var depth: usize = 1;
                    while (self.pos < self.input.len and depth > 0) {
                        switch (self.input[self.pos]) {
                            '{' => depth += 1,
                            '}' => depth -= 1,
                            else => {},
                        }
                        self.pos += 1;
                    }
                },
                '[' => {
                    self.pos += 1;
                    var depth: usize = 1;
                    while (self.pos < self.input.len and depth > 0) {
                        switch (self.input[self.pos]) {
                            '[' => depth += 1,
                            ']' => depth -= 1,
                            else => {},
                        }
                        self.pos += 1;
                    }
                },
                '-', '0'...'9' => {
                    while (self.pos < self.input.len and ((self.input[self.pos] >= '0' and self.input[self.pos] <= '9') or self.input[self.pos] == '.' or self.input[self.pos] == '-' or self.input[self.pos] == '+' or self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
                        self.pos += 1;
                    }
                },
                else => {
                    return error.InvalidJson;
                },
            }
        }
    };
};

test "Json.serialize simple struct" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        id: i64,
        name: []const u8,
        active: bool,
    };

    const test_value = TestStruct{
        .id = 42,
        .name = "test",
        .active = true,
    };

    const json = try Json.serialize(TestStruct, test_value, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"active\":true") != null);
}

test "Json.deserialize simple struct" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        id: i64,
        name: []const u8,
        active: bool,
    };

    const json = "{\"id\":42,\"name\":\"test\",\"active\":true}";
    const parsed = try Json.deserialize(TestStruct, json, allocator);
    defer allocator.free(parsed.name);

    try std.testing.expectEqual(@as(i64, 42), parsed.id);
    try std.testing.expectEqualStrings("test", parsed.name);
    try std.testing.expect(parsed.active);
}

test "Json.serialize with optional" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        id: i64,
        description: ?[]const u8,
    };

    const test_value1 = TestStruct{ .id = 1, .description = "test" };
    const json1 = try Json.serialize(TestStruct, test_value1, allocator);
    defer allocator.free(json1);

    const test_value2 = TestStruct{ .id = 2, .description = null };
    const json2 = try Json.serialize(TestStruct, test_value2, allocator);
    defer allocator.free(json2);

    try std.testing.expect(std.mem.indexOf(u8, json1, "\"description\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json2, "\"description\":null") != null);
}

test "Json.serializeArray" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        id: i64,
        name: []const u8,
    };

    const items = [_]TestStruct{
        TestStruct{ .id = 1, .name = "one" },
        TestStruct{ .id = 2, .name = "two" },
    };

    const json = try Json.serializeArray(TestStruct, &items, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.startsWith(u8, json, "["));
    try std.testing.expect(std.mem.endsWith(u8, json, "]"));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":2") != null);
}

test "Json escape string" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        message: []const u8,
    };

    const test_value = TestStruct{ .message = "Hello \"world\"\nTest" };
    const json = try Json.serialize(TestStruct, test_value, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\n") != null);
}

test "Json.deserialize string array ([][]const u8)" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        tags: [][]const u8,
    };

    const json = "{\"tags\":[\"hello\",\"world\",\"test\"]}";
    const parsed = try Json.deserialize(TestStruct, json, allocator);
    defer {
        for (parsed.tags) |tag| {
            allocator.free(tag);
        }
        allocator.free(parsed.tags);
    }

    try std.testing.expectEqual(@as(usize, 3), parsed.tags.len);
    try std.testing.expectEqualStrings("hello", parsed.tags[0]);
    try std.testing.expectEqualStrings("world", parsed.tags[1]);
    try std.testing.expectEqualStrings("test", parsed.tags[2]);
}

test "Json.deserialize empty array" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        items: [][]const u8,
    };

    const json = "{\"items\":[]}";
    const parsed = try Json.deserialize(TestStruct, json, allocator);
    defer allocator.free(parsed.items);

    try std.testing.expectEqual(@as(usize, 0), parsed.items.len);
}

test "Json.deserialize struct array" {
    const allocator = std.testing.allocator;
    const Inner = struct {
        id: i64,
        name: []const u8,
    };
    const TestStruct = struct {
        users: []Inner,
    };

    const json = "{\"users\":[{\"id\":1,\"name\":\"Alice\"},{\"id\":2,\"name\":\"Bob\"}]}";
    const parsed = try Json.deserialize(TestStruct, json, allocator);
    defer {
        for (parsed.users) |user| {
            allocator.free(user.name);
        }
        allocator.free(parsed.users);
    }

    try std.testing.expectEqual(@as(usize, 2), parsed.users.len);
    try std.testing.expectEqual(@as(i64, 1), parsed.users[0].id);
    try std.testing.expectEqualStrings("Alice", parsed.users[0].name);
    try std.testing.expectEqual(@as(i64, 2), parsed.users[1].id);
    try std.testing.expectEqualStrings("Bob", parsed.users[1].name);
}
