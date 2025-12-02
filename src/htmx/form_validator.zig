const std = @import("std");
const FormParser = @import("form.zig").FormParser;
const errors_mod = @import("errors.zig");

/// Type-safe form validator that parses form data directly into structs
/// Provides automatic type conversion, validation, and error collection
///
/// Example:
/// ```zig
/// const TodoForm = struct {
///     title: []const u8,
///     priority: []const u8 = "medium",
///     completed: bool = false,
/// };
///
/// var validator = FormValidator.init(form_parser, allocator);
/// defer validator.deinit();
///
/// const todo = validator.parseInto(TodoForm) catch |err| {
///     if (validator.hasErrors()) {
///         return htmx.errors.multipleValidationErrors(validator.getErrors());
///     }
///     return htmx.errors.errorFragment("Failed to parse form");
/// };
/// ```
pub const FormValidator = struct {
    parser: FormParser,
    errors: std.ArrayListUnmanaged(errors_mod.ValidationError),
    allocator: std.mem.Allocator,

    /// Initialize a form validator from a form parser
    pub fn init(parser: FormParser, allocator: std.mem.Allocator) FormValidator {
        return .{
            .parser = parser,
            .errors = std.ArrayListUnmanaged(errors_mod.ValidationError){},
            .allocator = allocator,
        };
    }

    /// Clean up validation errors
    pub fn deinit(self: *FormValidator) void {
        self.errors.deinit(self.allocator);
    }

    /// Parse form data directly into a struct
    /// Automatically handles type conversion, required fields, and validation
    ///
    /// Supported field types:
    /// - `[]const u8` - String values (required by default)
    /// - `?[]const u8` - Optional strings
    /// - `i64`, `i32`, etc. - Integer values
    /// - `?i64`, `?i32`, etc. - Optional integers
    /// - `bool` - Boolean values (parsed from "true", "1", "yes")
    /// - `?bool` - Optional booleans
    ///
    /// Default values are supported using struct field initialization:
    /// ```zig
    /// const Form = struct {
    ///     title: []const u8,           // Required
    ///     priority: []const u8 = "medium", // Optional with default
    ///     completed: bool = false,     // Optional with default
    /// };
    /// ```
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

            // Parse field based on type
            if (field_type == []const u8) {
                // Required string field
                if (self.parser.getRequired(field_name)) |value| {
                    @field(result, field_name) = value;
                } else |err| {
                    if (err == error.MissingFormField) {
                        try self.addError(field_name, "Field is required");
                        // Skip this field - error already added
                    } else {
                        return err;
                    }
                }
            } else if (field_type == ?[]const u8) {
                // Optional string field
                const value = self.parser.get(field_name) catch |err| {
                    try self.addError(field_name, "Failed to parse field");
                    return err;
                };
                @field(result, field_name) = value;
            } else if (field_type == bool) {
                // Required boolean field
                const value = self.parser.getBool(field_name) catch |err| {
                    try self.addError(field_name, "Failed to parse boolean");
                    return err;
                };
                @field(result, field_name) = value;
            } else if (field_type == ?bool) {
                // Optional boolean field
                const value = self.parser.getBool(field_name) catch false;
                @field(result, field_name) = value;
            } else if (field_type == i64) {
                // Required integer field
                const value = self.parser.getInt(field_name) catch |err| {
                    if (err == error.MissingFormField) {
                        try self.addError(field_name, "Field is required");
                        // Skip this field - error already added
                    } else {
                        try self.addError(field_name, "Invalid integer format");
                        return err;
                    }
                };
                if (value) |v| {
                    @field(result, field_name) = v;
                } else {
                    // Value was null - error already added above
                }
            } else if (field_type == ?i64) {
                // Optional integer field
                const value = self.parser.getInt(field_name) catch null;
                @field(result, field_name) = value;
            } else {
                // Unsupported type
                try self.addError(field_name, "Unsupported field type");
            }
        }

        // If there are validation errors, return error
        if (self.errors.items.len > 0) {
            return error.ValidationFailed;
        }

        return result;
    }

    /// Add a validation error
    fn addError(self: *FormValidator, field: []const u8, message: []const u8) !void {
        try self.errors.append(self.allocator, errors_mod.ValidationError{
            .field = field,
            .message = message,
        });
    }

    /// Add a custom validator for a field
    /// The validator function should return true if the value is valid
    pub fn validate(self: *FormValidator, field: []const u8, validator: fn([]const u8) bool, message: []const u8) void {
        const value = self.parser.get(field) catch |err| {
            if (err == error.MissingFormField) {
                // Field is missing, skip validation (handled by required check)
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

    /// Check if validation has errors
    pub fn hasErrors(self: *const FormValidator) bool {
        return self.errors.items.len > 0;
    }

    /// Get all validation errors
    pub fn getErrors(self: *const FormValidator) []const errors_mod.ValidationError {
        return self.errors.items;
    }

    /// Clear all validation errors
    pub fn clearErrors(self: *FormValidator) void {
        self.errors.clearAndFree(self.allocator);
    }
};

// Tests
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

test "FormValidator.parseInto - with defaults" {
    const allocator = std.testing.allocator;
    const body = "title=Test";
    const parser = FormParser.init(body, allocator);
    var validator = FormValidator.init(parser, allocator);
    defer validator.deinit();

    const TodoForm = struct {
        title: []const u8,
        priority: []const u8 = "medium",
        completed: bool = false,
    };

    const form = try validator.parseInto(TodoForm);
    defer allocator.free(form.title);

    try std.testing.expectEqualStrings("Test", form.title);
    try std.testing.expectEqualStrings("medium", form.priority);
    try std.testing.expect(!form.completed);
    try std.testing.expect(!validator.hasErrors());
}

test "FormValidator.parseInto - missing required field" {
    const allocator = std.testing.allocator;
    const body = "priority=high";
    const parser = FormParser.init(body, allocator);
    var validator = FormValidator.init(parser, allocator);
    defer validator.deinit();

    const TodoForm = struct {
        title: []const u8,
        priority: []const u8,
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

