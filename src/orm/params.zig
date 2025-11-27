const std = @import("std");
pub const c = @cImport({
    @cInclude("e12_orm.h");
});

/// Parameter types for SQL prepared statements
/// Matches E12ParamType in the C API
pub const ParamType = enum(u8) {
    null = 0,
    int64 = 1,
    float64 = 2,
    text = 3,
    blob = 4,
};

/// A single parameter value for SQL prepared statements
/// Provides type-safe parameter binding to prevent SQL injection
pub const Param = union(ParamType) {
    null: void,
    int64: i64,
    float64: f64,
    text: []const u8,
    blob: []const u8,

    /// Create a null parameter
    pub fn nullValue() Param {
        return Param{ .null = {} };
    }

    /// Create an integer parameter
    pub fn int(value: i64) Param {
        return Param{ .int64 = value };
    }

    /// Create a float parameter
    pub fn float(value: f64) Param {
        return Param{ .float64 = value };
    }

    /// Create a text parameter
    pub fn string(value: []const u8) Param {
        return Param{ .text = value };
    }

    /// Create a blob parameter
    pub fn bytes(value: []const u8) Param {
        return Param{ .blob = value };
    }

    /// Create a boolean parameter (stored as integer 0 or 1)
    pub fn boolean(value: bool) Param {
        return Param{ .int64 = if (value) 1 else 0 };
    }

    /// Convert any supported Zig type to a Param
    pub fn from(value: anytype) Param {
        const T = @TypeOf(value);
        
        return switch (@typeInfo(T)) {
            .int, .comptime_int => Param{ .int64 = @as(i64, @intCast(value)) },
            .float, .comptime_float => Param{ .float64 = @as(f64, @floatCast(value)) },
            .bool => Param{ .int64 = if (value) 1 else 0 },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return Param{ .text = value };
                } else if (ptr_info.size == .one) {
                    // Handle *const [N:0]u8 (string literals)
                    const child_type = ptr_info.child;
                    if (@typeInfo(child_type) == .array) {
                        const array_info = @typeInfo(child_type).array;
                        if (array_info.child == u8) {
                            const slice: []const u8 = value;
                            return Param{ .text = slice };
                        }
                    }
                    @compileError("Unsupported pointer type for Param.from()");
                } else {
                    @compileError("Unsupported pointer type for Param.from()");
                }
            },
            .optional => {
                if (value) |inner| {
                    return Param.from(inner);
                } else {
                    return Param{ .null = {} };
                }
            },
            .@"enum" => Param{ .int64 = @intFromEnum(value) },
            else => @compileError("Unsupported type for Param.from(): " ++ @typeName(T)),
        };
    }

    /// Convert to C API E12Param structure
    pub fn toC(self: Param) c.E12Param {
        var result: c.E12Param = undefined;
        
        switch (self) {
            .null => {
                result.type = c.E12_PARAM_NULL;
            },
            .int64 => |val| {
                result.type = c.E12_PARAM_INT64;
                result.value.i64 = val;
            },
            .float64 => |val| {
                result.type = c.E12_PARAM_DOUBLE;
                result.value.f64 = val;
            },
            .text => |val| {
                result.type = c.E12_PARAM_TEXT;
                result.value.text.ptr = val.ptr;
                result.value.text.len = val.len;
            },
            .blob => |val| {
                result.type = c.E12_PARAM_BLOB;
                result.value.blob.ptr = val.ptr;
                result.value.blob.len = val.len;
            },
        }
        
        return result;
    }
};

/// A list of parameters for SQL prepared statements
/// Manages an array of parameters that can be passed to parameterized queries
pub const ParamList = struct {
    items: std.ArrayListUnmanaged(Param),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ParamList {
        return ParamList{
            .items = std.ArrayListUnmanaged(Param){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ParamList) void {
        self.items.deinit(self.allocator);
    }

    /// Add a parameter or any supported value type to the list
    /// Accepts either a Param directly or any type that Param.from() supports
    pub fn add(self: *ParamList, value: anytype) !void {
        const T = @TypeOf(value);
        if (T == Param) {
            try self.items.append(self.allocator, value);
        } else {
            try self.items.append(self.allocator, Param.from(value));
        }
    }

    /// Add a null parameter
    pub fn addNull(self: *ParamList) !void {
        try self.items.append(self.allocator, Param.nullValue());
    }

    /// Add an integer parameter
    pub fn addInt(self: *ParamList, value: i64) !void {
        try self.items.append(self.allocator, Param.int(value));
    }

    /// Add a float parameter
    pub fn addFloat(self: *ParamList, value: f64) !void {
        try self.items.append(self.allocator, Param.float(value));
    }

    /// Add a text parameter
    pub fn addString(self: *ParamList, value: []const u8) !void {
        try self.items.append(self.allocator, Param.string(value));
    }

    /// Add a boolean parameter
    pub fn addBool(self: *ParamList, value: bool) !void {
        try self.items.append(self.allocator, Param.boolean(value));
    }

    /// Get the number of parameters
    pub fn len(self: *const ParamList) usize {
        return self.items.items.len;
    }

    /// Get parameters as a slice
    pub fn slice(self: *const ParamList) []const Param {
        return self.items.items;
    }

    /// Convert to C API array (caller must free the returned slice)
    pub fn toC(self: *const ParamList, alloc: std.mem.Allocator) ![]c.E12Param {
        var c_params = try alloc.alloc(c.E12Param, self.items.items.len);
        for (self.items.items, 0..) |param, i| {
            c_params[i] = param.toC();
        }
        return c_params;
    }

    /// Get C-compatible params pointer for use with C API
    /// Returns pointer to internal C param array (rebuilt on each call)
    /// WARNING: The returned pointer is only valid until the next call or deinit
    pub fn cParams(self: *const ParamList) [*c]const c.E12Param {
        if (self.items.items.len == 0) return null;
        
        // Build C params array in place
        // We need to store this somewhere - use a static buffer approach
        // For safety, we'll use thread-local storage pattern
        const S = struct {
            threadlocal var c_buffer: [256]c.E12Param = undefined;
        };
        
        const count = @min(self.items.items.len, S.c_buffer.len);
        for (self.items.items[0..count], 0..) |param, i| {
            S.c_buffer[i] = param.toC();
        }
        
        return @ptrCast(&S.c_buffer);
    }

    /// Get the count of parameters for C API
    pub fn cCount(self: *const ParamList) usize {
        return self.items.items.len;
    }

    /// Add a text parameter (alias for addString for compatibility)
    pub fn addText(self: *ParamList, value: []const u8) !void {
        try self.addString(value);
    }

    /// Reset the parameter list (clear all parameters)
    pub fn reset(self: *ParamList) void {
        self.items.clearRetainingCapacity();
    }
};

/// Create a parameter list from a tuple of values
/// Example: params.fromTuple(.{ 1, "hello", true })
pub fn fromTuple(allocator: std.mem.Allocator, tuple: anytype) !ParamList {
    var list = ParamList.init(allocator);
    errdefer list.deinit();

    const fields = @typeInfo(@TypeOf(tuple)).@"struct".fields;
    inline for (fields) |field| {
        try list.add(@field(tuple, field.name));
    }

    return list;
}

/// Create a fixed-size C param array from a tuple (no allocation needed)
/// Example: const c_params = params.tupleToCArray(.{ 1, "hello" });
pub fn tupleToCArray(tuple: anytype) [@typeInfo(@TypeOf(tuple)).@"struct".fields.len]c.E12Param {
    const fields = @typeInfo(@TypeOf(tuple)).@"struct".fields;
    var result: [fields.len]c.E12Param = undefined;
    
    inline for (fields, 0..) |field, i| {
        result[i] = Param.from(@field(tuple, field.name)).toC();
    }
    
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "Param.from integer" {
    const p = Param.from(@as(i32, 42));
    try std.testing.expectEqual(ParamType.int64, std.meta.activeTag(p));
    try std.testing.expectEqual(@as(i64, 42), p.int64);
}

test "Param.from comptime_int" {
    const p = Param.from(123);
    try std.testing.expectEqual(ParamType.int64, std.meta.activeTag(p));
    try std.testing.expectEqual(@as(i64, 123), p.int64);
}

test "Param.from boolean" {
    const p_true = Param.from(true);
    try std.testing.expectEqual(ParamType.int64, std.meta.activeTag(p_true));
    try std.testing.expectEqual(@as(i64, 1), p_true.int64);

    const p_false = Param.from(false);
    try std.testing.expectEqual(@as(i64, 0), p_false.int64);
}

test "Param.from string slice" {
    const s = "hello";
    const p = Param.from(s);
    try std.testing.expectEqual(ParamType.text, std.meta.activeTag(p));
    try std.testing.expectEqualStrings("hello", p.text);
}

test "Param.from optional with value" {
    const opt: ?i64 = 42;
    const p = Param.from(opt);
    try std.testing.expectEqual(ParamType.int64, std.meta.activeTag(p));
    try std.testing.expectEqual(@as(i64, 42), p.int64);
}

test "Param.from optional null" {
    const opt: ?i64 = null;
    const p = Param.from(opt);
    try std.testing.expectEqual(ParamType.null, std.meta.activeTag(p));
}

const E12ParamType = c.E12ParamType;

test "Param.toC" {
    const p = Param.int(42);
    const c_param = p.toC();
    try std.testing.expectEqual(@as(E12ParamType, c.E12_PARAM_INT64), c_param.type);
    try std.testing.expectEqual(@as(i64, 42), c_param.value.i64);
}

test "ParamList basic operations" {
    const allocator = std.testing.allocator;
    var list = ParamList.init(allocator);
    defer list.deinit();

    try list.addInt(1);
    try list.addString("hello");
    try list.addBool(true);
    try list.addNull();

    try std.testing.expectEqual(@as(usize, 4), list.len());
}

test "ParamList.add with various types" {
    const allocator = std.testing.allocator;
    var list = ParamList.init(allocator);
    defer list.deinit();

    try list.add(@as(i32, 42));
    try list.add("world");
    try list.add(false);

    try std.testing.expectEqual(@as(usize, 3), list.len());
}

test "ParamList.toC" {
    const allocator = std.testing.allocator;
    var list = ParamList.init(allocator);
    defer list.deinit();

    try list.addInt(1);
    try list.addString("test");

    const c_params = try list.toC(allocator);
    defer allocator.free(c_params);

    try std.testing.expectEqual(@as(usize, 2), c_params.len);
    try std.testing.expectEqual(@as(E12ParamType, c.E12_PARAM_INT64), c_params[0].type);
    try std.testing.expectEqual(@as(E12ParamType, c.E12_PARAM_TEXT), c_params[1].type);
}

test "fromTuple" {
    const allocator = std.testing.allocator;
    var list = try fromTuple(allocator, .{ 1, "hello", true });
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 3), list.len());
}

test "tupleToCArray" {
    const c_params = tupleToCArray(.{ 42, "test", false });
    
    try std.testing.expectEqual(@as(usize, 3), c_params.len);
    try std.testing.expectEqual(@as(E12ParamType, c.E12_PARAM_INT64), c_params[0].type);
    try std.testing.expectEqual(@as(i64, 42), c_params[0].value.i64);
    try std.testing.expectEqual(@as(E12ParamType, c.E12_PARAM_TEXT), c_params[1].type);
    try std.testing.expectEqual(@as(E12ParamType, c.E12_PARAM_INT64), c_params[2].type);
    try std.testing.expectEqual(@as(i64, 0), c_params[2].value.i64);
}
