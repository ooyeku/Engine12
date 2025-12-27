const std = @import("std");
const json_module = @import("../data/json.zig");
const Response = @import("../http/response.zig").Response;
const model_utils = @import("model.zig");
const ORM = @import("orm.zig").ORM;

pub fn Model(comptime T: type) type {
    return struct {
        const Self = @This();

        pub fn toJson(instance: T, allocator: std.mem.Allocator) ![]const u8 {
            return json_module.Json.serialize(T, instance, allocator);
        }

        pub fn toJsonArray(items: []const T, allocator: std.mem.Allocator) ![]const u8 {
            return json_module.Json.serializeArray(T, items, allocator);
        }

        pub fn toJsonList(list: std.ArrayListUnmanaged(T), allocator: std.mem.Allocator) ![]const u8 {
            return json_module.Json.serializeArray(T, list.items, allocator);
        }

        pub fn toResponse(instance: T, allocator: std.mem.Allocator) Response {
            return Response.jsonFrom(T, instance, allocator);
        }

        pub fn toResponseArray(items: []const T, allocator: std.mem.Allocator) Response {
            const json_str = json_module.Json.serializeArray(T, items, allocator) catch {
                return Response.serverError("Failed to serialize array");
            };
            defer allocator.free(json_str);

            const persistent_json = std.heap.page_allocator.dupe(u8, json_str) catch {
                return Response.serverError("Failed to allocate response");
            };
            return Response.json(persistent_json);
        }

        pub fn toResponseList(list: std.ArrayListUnmanaged(T), allocator: std.mem.Allocator) Response {
            return Self.toResponseArray(list.items, allocator);
        }

        pub fn fromJson(json_str: []const u8, allocator: std.mem.Allocator) !T {
            return json_module.Json.deserialize(T, json_str, allocator);
        }

        pub fn tableName() []const u8 {
            return model_utils.inferTableName(T);
        }

        pub fn fieldNames() *const [std.meta.fields(T).len][]const u8 {
            return model_utils.getFieldNames(T);
        }
    };
}

pub fn ModelWithORM(comptime T: type) type {
    return struct {
        const Self = @This();

        orm: *ORM,

        pub fn init(orm: *ORM) Self {
            return Self{ .orm = orm };
        }

        pub fn create(self: Self, instance: T) !T {
            try self.orm.create(T, instance);

            const id = self.orm.db.lastInsertRowId() catch {
                var all_result = try self.orm.findAllManaged(T);
                defer all_result.deinit();
                if (all_result.isEmpty()) return error.FailedToCreate;

                var max_id: i64 = 0;
                for (all_result.getItems()) |item| {
                    const id_field = @field(item, "id");
                    if (id_field > max_id) {
                        max_id = id_field;
                    }
                }

                const max_result_opt = try self.orm.findManaged(T, max_id);
                if (max_result_opt) |result| {
                    var mutable_result = result;
                    defer mutable_result.deinit();
                    if (mutable_result.first()) |found| {
                        return try Self.copyInstance(found, self.orm.allocator);
                    }
                }
                return error.FailedToCreate;
            };

            const result_opt = try self.orm.findManaged(T, id);
            if (result_opt) |result| {
                var mutable_result = result;
                defer mutable_result.deinit();
                if (mutable_result.first()) |found| {
                    return try Self.copyInstance(found, self.orm.allocator);
                }
            }
            return error.FailedToCreate;
        }

        pub fn find(self: Self, id: i64) !?T {
            const result_opt = try self.orm.findManaged(T, id);
            if (result_opt) |result| {
                var mutable_result = result;
                defer mutable_result.deinit();
                if (mutable_result.first()) |found| {
                    return try Self.copyInstance(found, self.orm.allocator);
                }
            }
            return null;
        }

        pub fn findAll(self: Self) !std.ArrayListUnmanaged(T) {
            var result = try self.orm.findAllManaged(T);
            defer result.deinit();

            var items = std.ArrayListUnmanaged(T){};
            for (result.getItems()) |item| {
                try items.append(self.orm.allocator, try Self.copyInstance(item, self.orm.allocator));
            }
            return items;
        }

        pub fn update(self: Self, id: i64, instance: T) !?T {
            try self.orm.update(T, instance);
            return try self.find(id);
        }

        pub fn delete(self: Self, id: i64) !bool {
            const existing = try self.find(id);
            if (existing == null) return false;
            try self.orm.delete(T, id);
            return true;
        }

        fn copyInstance(instance: T, allocator: std.mem.Allocator) !T {
            var copy = instance;

            inline for (std.meta.fields(T)) |field| {
                const field_type = field.type;
                const field_value = @field(instance, field.name);

                if (@typeInfo(field_type) == .pointer) {
                    const ptr_info = @typeInfo(field_type).pointer;
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        @field(copy, field.name) = try allocator.dupe(u8, field_value);
                    }
                } else if (@typeInfo(field_type) == .optional) {
                    const opt_info = @typeInfo(field_type).optional;
                    if (@typeInfo(opt_info.child) == .pointer) {
                        const ptr_info = @typeInfo(opt_info.child).pointer;
                        if (ptr_info.size == .slice and ptr_info.child == u8) {
                            if (field_value) |value| {
                                @field(copy, field.name) = try allocator.dupe(u8, value);
                            }
                        }
                    }
                }
            }

            return copy;
        }
    };
}

pub fn ModelStats(comptime T: type, comptime StatsType: type) type {
    return struct {
        const Self = @This();

        orm: *ORM,

        pub fn init(orm: *ORM) Self {
            return Self{ .orm = orm };
        }

        pub fn calculate(self: Self, callback: fn ([]const T, std.mem.Allocator) anyerror!StatsType) !StatsType {
            var result = try self.orm.findAllManaged(T);
            defer result.deinit();
            return try callback(result.getItems(), self.orm.allocator);
        }

        pub fn toJson(self: Self, stats: StatsType, allocator: std.mem.Allocator) ![]const u8 {
            _ = self;
            return json_module.Json.serialize(StatsType, stats, allocator);
        }

        pub fn toResponse(self: Self, stats: StatsType, allocator: std.mem.Allocator) Response {
            _ = self;
            return Response.jsonFrom(StatsType, stats, allocator);
        }
    };
}

test "Model toJson" {
    const TestStruct = struct {
        id: i64,
        name: []const u8,
    };

    const TestModel = Model(TestStruct);
    const instance = TestStruct{ .id = 1, .name = "test" };

    const json_str = try TestModel.toJson(instance, std.testing.allocator);
    defer std.testing.allocator.free(json_str);
    defer std.testing.allocator.free(instance.name);

    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"name\":\"test\"") != null);
}

test "Model toJsonArray" {
    const TestStruct = struct {
        id: i64,
    };

    const TestModel = Model(TestStruct);
    const items = [_]TestStruct{
        TestStruct{ .id = 1 },
        TestStruct{ .id = 2 },
    };

    const json_str = try TestModel.toJsonArray(&items, std.testing.allocator);
    defer std.testing.allocator.free(json_str);

    try std.testing.expect(std.mem.startsWith(u8, json_str, "["));
    try std.testing.expect(std.mem.endsWith(u8, json_str, "]"));
}

test "Model tableName" {
    const TestStruct = struct {
        id: i64,
    };

    const TestModel = Model(TestStruct);
    const table = TestModel.tableName();

    try std.testing.expectEqualStrings("TestStruct", table);
}

test "Model fieldNames" {
    const TestStruct = struct {
        id: i64,
        name: []const u8,
        age: i32,
    };

    const TestModel = Model(TestStruct);
    const fields = TestModel.fieldNames();

    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("id", fields[0]);
    try std.testing.expectEqualStrings("name", fields[1]);
    try std.testing.expectEqualStrings("age", fields[2]);
}
