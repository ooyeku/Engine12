const std = @import("std");

/// A wrapper that owns a single value and its associated memory.
/// Automatically frees the value's memory (if it's a slice) on `deinit`.
pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(value: T, allocator: std.mem.Allocator) Self {
            return Self{
                .value = value,
                .allocator = allocator,
            };
        }

        /// Transfers ownership of the value to the caller and disables automatic freeing.
        pub fn take(self: *Self) T {
            const val = self.value;
            self.value = undefined;
            return val;
        }

        pub fn deinit(self: *Self) void {
            const type_info = @typeInfo(T);
            switch (type_info) {
                .pointer => |ptr| {
                    if (ptr.size == .Slice) {
                        self.allocator.free(self.value);
                    }
                },
                else => {},
            }
        }
    };
}

/// A collection of items that manages the memory of both the slice and any heap-allocated fields within the items (e.g., strings).
pub fn OwnedSlice(comptime T: type) type {
    return struct {
        data: std.ArrayListUnmanaged(T),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(data: std.ArrayListUnmanaged(T), allocator: std.mem.Allocator) Self {
            return Self{
                .data = data,
                .allocator = allocator,
            };
        }

        /// Creates an empty managed slice.
        pub fn empty(allocator: std.mem.Allocator) Self {
            return Self{
                .data = std.ArrayListUnmanaged(T){},
                .allocator = allocator,
            };
        }

        /// Returns the slice of items.
        pub fn items(self: *const Self) []const T {
            return self.data.items;
        }

        pub fn itemsMut(self: *Self) []T {
            return self.data.items;
        }

        pub fn len(self: *const Self) usize {
            return self.data.items.len;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.data.items.len == 0;
        }

        /// Returns the first item in the slice, or null if empty.
        pub fn first(self: *const Self) ?T {
            if (self.data.items.len == 0) return null;
            return self.data.items[0];
        }

        /// Transfers ownership of the underlying data list to the caller.
        pub fn take(self: *Self) std.ArrayListUnmanaged(T) {
            const data = self.data;
            self.data = std.ArrayListUnmanaged(T){};
            return data;
        }

        /// Recursively frees memory for all items and the slice itself.
        pub fn deinit(self: *Self) void {
            for (self.data.items) |item| {
                inline for (std.meta.fields(T)) |field| {
                    const FieldType = field.type;
                    const field_info = @typeInfo(FieldType);

                    if (field_info == .pointer) {
                        const ptr_info = field_info.pointer;
                        if (ptr_info.size == .Slice and ptr_info.child == u8) {
                            self.allocator.free(@field(item, field.name));
                        }
                    } else if (field_info == .optional) {
                        const opt_child = @typeInfo(field_info.optional.child);
                        if (opt_child == .pointer) {
                            const ptr_info = opt_child.pointer;
                            if (ptr_info.size == .Slice and ptr_info.child == u8) {
                                if (@field(item, field.name)) |val| {
                                    self.allocator.free(val);
                                }
                            }
                        }
                    }
                }
            }
            self.data.deinit(self.allocator);
        }
    };
}

test "Owned string" {
    const allocator = std.testing.allocator;

    const str = try allocator.dupe(u8, "hello");
    var owned = Owned([]const u8).init(str, allocator);
    defer owned.deinit();

    try std.testing.expectEqualStrings("hello", owned.value);
}

test "Owned take" {
    const allocator = std.testing.allocator;

    const str = try allocator.dupe(u8, "hello");
    var owned = Owned([]const u8).init(str, allocator);

    const taken = owned.take();
    defer allocator.free(taken);

    try std.testing.expectEqualStrings("hello", taken);
}

test "OwnedSlice with struct" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []const u8,
    };

    var list = std.ArrayListUnmanaged(User){};
    try list.append(allocator, User{
        .id = 1,
        .name = try allocator.dupe(u8, "Alice"),
    });
    try list.append(allocator, User{
        .id = 2,
        .name = try allocator.dupe(u8, "Bob"),
    });

    var owned = OwnedSlice(User).init(list, allocator);
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 2), owned.len());
    try std.testing.expectEqualStrings("Alice", owned.items()[0].name);
    try std.testing.expectEqualStrings("Bob", owned.items()[1].name);
}

test "OwnedSlice empty" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []const u8,
    };

    var owned = OwnedSlice(User).empty(allocator);
    defer owned.deinit();

    try std.testing.expect(owned.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), owned.len());
    try std.testing.expect(owned.first() == null);
}

test "OwnedSlice with optional string field" {
    const allocator = std.testing.allocator;

    const User = struct {
        id: i64,
        name: []const u8,
        email: ?[]const u8,
    };

    var list = std.ArrayListUnmanaged(User){};
    try list.append(allocator, User{
        .id = 1,
        .name = try allocator.dupe(u8, "Alice"),
        .email = try allocator.dupe(u8, "alice@example.com"),
    });
    try list.append(allocator, User{
        .id = 2,
        .name = try allocator.dupe(u8, "Bob"),
        .email = null,
    });

    var owned = OwnedSlice(User).init(list, allocator);
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 2), owned.len());
    try std.testing.expectEqualStrings("alice@example.com", owned.items()[0].email.?);
    try std.testing.expect(owned.items()[1].email == null);
}
