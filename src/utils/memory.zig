const std = @import("std");

pub const Memory = struct {
    pub fn freeStruct(comptime T: type, instance: T, allocator: std.mem.Allocator) void {
        inline for (std.meta.fields(T)) |field| {
            const field_type = field.type;
            const field_value = @field(instance, field.name);
            
            freeFieldValue(field_type, field_value, allocator);
        }
    }

    pub fn freeStructArray(comptime T: type, items: []T, allocator: std.mem.Allocator) void {
        for (items) |item| {
            freeStruct(T, item, allocator);
        }
    }

    fn freeFieldValue(comptime T: type, value: T, allocator: std.mem.Allocator) void {
        const type_info = @typeInfo(T);
        
        switch (type_info) {
            .Pointer => |ptr_info| {
                if (ptr_info.size == .Slice) {
                    if (ptr_info.child == u8) {
                        allocator.free(value);
                    } else {
                        for (value) |item| {
                            freeFieldValue(ptr_info.child, item, allocator);
                        }
                        allocator.free(value);
                    }
                }
            },
            .Optional => |opt_info| {
                if (value) |v| {
                    freeFieldValue(opt_info.child, v, allocator);
                }
            },
            .Struct => {
                inline for (std.meta.fields(T)) |field| {
                    const field_value = @field(value, field.name);
                    freeFieldValue(field.type, field_value, allocator);
                }
            },
            .Array => |arr_info| {
                for (value) |item| {
                    freeFieldValue(arr_info.child, item, allocator);
                }
            },
            else => {
            },
        }
    }
};

test "Memory.freeStruct with string fields" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        id: i64,
        name: []const u8,
        description: []const u8,
    };
    
    const name = try allocator.dupe(u8, "test");
    const desc = try allocator.dupe(u8, "description");
    
    const test_value = TestStruct{
        .id = 1,
        .name = name,
        .description = desc,
    };
    
    Memory.freeStruct(TestStruct, test_value, allocator);
    
}

test "Memory.freeStruct with optional string" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        id: i64,
        name: ?[]const u8,
    };
    
    const name = try allocator.dupe(u8, "test");
    const test1 = TestStruct{ .id = 1, .name = name };
    Memory.freeStruct(TestStruct, test1, allocator);
    
    const test2 = TestStruct{ .id = 2, .name = null };
    Memory.freeStruct(TestStruct, test2, allocator);
}

test "Memory.freeStructArray" {
    const allocator = std.testing.allocator;
    const TestStruct = struct {
        id: i64,
        name: []const u8,
    };
    
    const items = [_]TestStruct{
        TestStruct{ .id = 1, .name = try allocator.dupe(u8, "one") },
        TestStruct{ .id = 2, .name = try allocator.dupe(u8, "two") },
    };
    
    Memory.freeStructArray(TestStruct, &items, allocator);
}

test "Memory.freeStruct with nested struct" {
    const allocator = std.testing.allocator;
    const Inner = struct {
        value: []const u8,
    };
    const Outer = struct {
        id: i64,
        inner: Inner,
    };
    
    const value = try allocator.dupe(u8, "nested");
    const inner = Inner{ .value = value };
    const outer = Outer{ .id = 1, .inner = inner };
    
    Memory.freeStruct(Outer, outer, allocator);
}

