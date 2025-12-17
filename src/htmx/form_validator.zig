const std = @import("std");
const FormParser = @import("form.zig").FormParser;
const errors_mod = @import("errors.zig");

pub const FormValidator = struct {
    parser: FormParser,
    errors: std.ArrayListUnmanaged(errors_mod.ValidationError),
    allocator: std.mem.Allocator,

    pub fn init(parser: FormParser, allocator: std.mem.Allocator) FormValidator {
        return .{
            .parser = parser,
            .errors = std.ArrayListUnmanaged(errors_mod.ValidationError){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FormValidator) void {
        self.errors.deinit(self.allocator);
    }

    pub fn parseInto(self: *FormValidator, comptime T: type) !T {
        const type_info = @typeInfo(T);
        if (type_info != .@"struct") {
            return error.InvalidType;
        }

        var result: T = undefined;
        const fields = type_info.@"struct".fields;

        inline for (fields) |field| {
            const field_name = field.name;
            const field_type = field.type;

            if (field_type == []const u8) {
                if (self.parser.getRequired(field_name)) |value| {
                    @field(result, field_name) = value;
                } else |err| {
                    if (err == error.MissingFormField) {
                        try self.addError(field_name, "Field is required");
                    } else {
                        return err;
                    }
                }
            } else if (field_type == ?[]const u8) {
                const value = self.parser.get(field_name) catch |err| {
                    try self.addError(field_name, "Failed to parse field");
                    return err;
                };
                @field(result, field_name) = value;
            } else if (field_type == bool) {
                const value = self.parser.getBool(field_name) catch |err| {
                    try self.addError(field_name, "Failed to parse boolean");
                    return err;
                };
                @field(result, field_name) = value;
            } else if (field_type == ?bool) {
                if (self.parser.get(field_name)) |maybe_value| {
                    if (maybe_value) |value| {
                        self.allocator.free(value);
                        const bool_val = self.parser.getBool(field_name) catch false;
                        @field(result, field_name) = bool_val;
                    } else {
                        @field(result, field_name) = null;
                    }
                } else |_| {
                    @field(result, field_name) = null;
                }
            } else if (field_type == i64) {
                if (self.parser.getInt(field_name)) |value_opt| {
                    if (value_opt) |v| {
                        @field(result, field_name) = v;
                    } else {
                        try self.addError(field_name, "Field is required");
                        @field(result, field_name) = 0;
                    }
                } else |err| {
                    if (err == error.MissingFormField) {
                        try self.addError(field_name, "Field is required");
                    } else {
                        try self.addError(field_name, "Invalid integer format");
                        return err;
                    }
                    @field(result, field_name) = 0;
                }
            } else if (field_type == ?i64) {
                const value = self.parser.getInt(field_name) catch null;
                @field(result, field_name) = value;
            } else {
                try self.addError(field_name, "Unsupported field type");
            }
        }

        if (self.errors.items.len > 0) {
            return error.ValidationFailed;
        }

        return result;
    }

    fn addError(self: *FormValidator, field: []const u8, message: []const u8) !void {
        try self.errors.append(self.allocator, errors_mod.ValidationError{
            .field = field,
            .message = message,
        });
    }

    pub fn validate(self: *FormValidator, field: []const u8, validator: fn ([]const u8) bool, message: []const u8) void {
        const value = self.parser.get(field) catch |err| {
            if (err == error.MissingFormField) {
                return;
            }
            return;
        };

        if (value) |v| {
            if (!validator(v)) {
                self.addError(field, message) catch {};
            }
            self.allocator.free(v);
        }
    }

    pub fn hasErrors(self: *const FormValidator) bool {
        return self.errors.items.len > 0;
    }

    pub fn getErrors(self: *const FormValidator) []const errors_mod.ValidationError {
        return self.errors.items;
    }

    pub fn clearErrors(self: *FormValidator) void {
        self.errors.clearAndFree(self.allocator);
    }
};

test "FormValidator.parseInto - simple struct" {
    const allocator = std.testing.allocator;
    const body = "title=Test+Todo&priority=high";
    const parser = FormParser.init(body, allocator);
    var validator = FormValidator.init(parser, allocator);
    defer validator.deinit();

    const TodoForm = struct {
        title: []const u8,
        priority: []const u8,
    };

    const form = try validator.parseInto(TodoForm);
    defer allocator.free(form.title);
    defer allocator.free(form.priority);

    try std.testing.expectEqualStrings("Test Todo", form.title);
    try std.testing.expectEqualStrings("high", form.priority);
    try std.testing.expect(!validator.hasErrors());
}

test "FormValidator.parseInto - with optional fields" {
    const allocator = std.testing.allocator;
    const body = "title=Test";
    const parser = FormParser.init(body, allocator);
    var validator = FormValidator.init(parser, allocator);
    defer validator.deinit();

    const TodoForm = struct {
        title: []const u8,
        priority: ?[]const u8,
        completed: ?bool,
    };

    const form = try validator.parseInto(TodoForm);
    defer allocator.free(form.title);
    defer if (form.priority) |p| allocator.free(p);

    try std.testing.expectEqualStrings("Test", form.title);
    try std.testing.expect(form.priority == null); // Not provided
    try std.testing.expect(form.completed == null); // Not provided
    try std.testing.expect(!validator.hasErrors());
}

test "FormValidator.parseInto - missing required field" {
    const allocator = std.testing.allocator;
    const body = "";
    const parser = FormParser.init(body, allocator);
    var validator = FormValidator.init(parser, allocator);
    defer validator.deinit();

    const TodoForm = struct {
        title: []const u8,
    };

    const result = validator.parseInto(TodoForm);
    try std.testing.expectError(error.ValidationFailed, result);
    try std.testing.expect(validator.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), validator.getErrors().len);
    try std.testing.expectEqualStrings("title", validator.getErrors()[0].field);
}

test "FormValidator.parseInto - optional fields" {
    const allocator = std.testing.allocator;
    const body = "title=Test";
    const parser = FormParser.init(body, allocator);
    var validator = FormValidator.init(parser, allocator);
    defer validator.deinit();

    const TodoForm = struct {
        title: []const u8,
        description: ?[]const u8 = null,
    };

    const form = try validator.parseInto(TodoForm);
    defer allocator.free(form.title);
    if (form.description) |desc| {
        allocator.free(desc);
    }

    try std.testing.expectEqualStrings("Test", form.title);
    try std.testing.expect(form.description == null);
}

test "FormValidator.parseInto - boolean fields" {
    const allocator = std.testing.allocator;
    const body = "title=Test&completed=true";
    const parser = FormParser.init(body, allocator);
    var validator = FormValidator.init(parser, allocator);
    defer validator.deinit();

    const TodoForm = struct {
        title: []const u8,
        completed: bool,
    };

    const form = try validator.parseInto(TodoForm);
    defer allocator.free(form.title);

    try std.testing.expectEqualStrings("Test", form.title);
    try std.testing.expect(form.completed);
}

test "FormValidator.parseInto - integer fields" {
    const allocator = std.testing.allocator;
    const body = "id=123&count=42";
    const parser = FormParser.init(body, allocator);
    var validator = FormValidator.init(parser, allocator);
    defer validator.deinit();

    const Form = struct {
        id: i64,
        count: ?i64 = null,
    };

    const form = try validator.parseInto(Form);
    try std.testing.expectEqual(@as(i64, 123), form.id);
    try std.testing.expect(form.count != null);
    try std.testing.expectEqual(@as(i64, 42), form.count.?);
}
