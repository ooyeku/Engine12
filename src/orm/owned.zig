const std = @import("std");

/// Owned(T) is a wrapper that explicitly marks a value as owning allocated memory.
/// This helps prevent memory leaks and use-after-free bugs by making ownership
/// explicit in the type system.
///
/// Use this wrapper when returning values that contain allocated memory
/// (like strings from SQLite queries) that the caller must free.
///
/// Example:
/// ```zig
/// fn getName(allocator: std.mem.Allocator) Owned([]const u8) {
///     const name = try allocator.dupe(u8, "Alice");
///     return Owned([]const u8).init(name, allocator);
/// }
///
/// // Caller knows they must free this:
/// var name = getName(allocator);
/// defer name.deinit();
/// std.debug.print("{s}\n", .{name.value});
/// ```
pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Create an Owned wrapper around a value
        pub fn init(value: T, allocator: std.mem.Allocator) Self {
            return Self{
                .value = value,
                .allocator = allocator,
            };
        }

        /// Release ownership and return the raw value
        /// After calling this, the caller is responsible for freeing the memory
        pub fn take(self: *Self) T {
            const val = self.value;
            self.value = undefined;
            return val;
        }

        /// Free the owned memory
        pub fn deinit(self: *Self) void {
            const type_info = @typeInfo(T);
            switch (type_info) {
                .pointer => |ptr| {
                    if (ptr.size == .Slice) {
                        // Slice type like []const u8
                        self.allocator.free(self.value);
                    }
                },
                else => {},
            }
        }
    };
}

/// OwnedSlice is a specialized wrapper for slices of owned values.
/// Each element in the slice has its own allocated memory that needs to be freed.
///
/// Example:
/// ```zig
/// fn getUsers(allocator: std.mem.Allocator) OwnedSlice(User) {
///     // ... fetch users with allocated string fields
///     return OwnedSlice(User).init(users, allocator);
/// }
///
/// var users = getUsers(allocator);
/// defer users.deinit();
/// for (users.items()) |user| {
///     std.debug.print("{s}\n", .{user.name});
/// }
/// ```
pub fn OwnedSlice(comptime T: type) type {
    return struct {
        data: std.ArrayListUnmanaged(T),
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Create an OwnedSlice from an ArrayList
        pub fn init(data: std.ArrayListUnmanaged(T), allocator: std.mem.Allocator) Self {
            return Self{
                .data = data,
                .allocator = allocator,
            };
        }

        /// Create an empty OwnedSlice
        pub fn empty(allocator: std.mem.Allocator) Self {
            return Self{
                .data = std.ArrayListUnmanaged(T){},
                .allocator = allocator,
            };
        }

        /// Get the items as a slice
        pub fn items(self: *const Self) []const T {
            return self.data.items;
        }

        /// Get mutable access to items
        pub fn itemsMut(self: *Self) []T {
            return self.data.items;
        }

        /// Get the length
        pub fn len(self: *const Self) usize {
            return self.data.items.len;
        }

        /// Check if empty
        pub fn isEmpty(self: *const Self) bool {
            return self.data.items.len == 0;
        }

        /// Get first item, or null if empty
        pub fn first(self: *const Self) ?T {
            if (self.data.items.len == 0) return null;
            return self.data.items[0];
        }

        /// Release ownership and return the raw ArrayList
        /// After calling this, the caller is responsible for freeing the memory
        pub fn take(self: *Self) std.ArrayListUnmanaged(T) {
            const data = self.data;
            self.data = std.ArrayListUnmanaged(T){};
            return data;
        }

        /// Free all owned memory (both the slice and string fields in elements)
        pub fn deinit(self: *Self) void {
            // Free string fields in each element
            for (self.data.items) |item| {
                inline for (std.meta.fields(T)) |field| {
                    const FieldType = field.type;
                    const field_info = @typeInfo(FieldType);

                    // Handle []const u8 (string slices)
                    if (field_info == .pointer) {
                        const ptr_info = field_info.pointer;
                        if (ptr_info.size == .Slice and ptr_info.child == u8) {
                            self.allocator.free(@field(item, field.name));
                        }
                    }
                    // Handle ?[]const u8 (optional string slices)
                    else if (field_info == .optional) {
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
            // Free the array itself
            self.data.deinit(self.allocator);
        }
    };
}

// Tests
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
