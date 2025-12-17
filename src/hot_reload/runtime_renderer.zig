const std = @import("std");
const escape = @import("../templates/escape.zig");

pub const RuntimeRenderer = struct {
    pub fn render(
        template_content: []const u8,
        comptime Context: type,
        ctx: Context,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < template_content.len) {
            const var_start = std.mem.indexOf(u8, template_content[i..], "{{");
            const block_start = std.mem.indexOf(u8, template_content[i..], "{%");

            var next_token: ?struct { start: usize, is_block: bool } = null;

            if (var_start) |vs| {
                next_token = .{ .start = i + vs, .is_block = false };
            }
            if (block_start) |bs| {
                if (next_token == null or (var_start != null and bs < var_start.?)) {
                    next_token = .{ .start = i + bs, .is_block = true };
                }
            }

            if (next_token) |token| {
                if (token.start > i) {
                    try result.appendSlice(allocator, template_content[i..token.start]);
                }

                if (token.is_block) {
                    const block_end = std.mem.indexOf(u8, template_content[token.start + 2 ..], "%}") orelse {
                        i = template_content.len;
                        continue;
                    };

                    const block_content = std.mem.trim(u8, template_content[token.start + 2 .. token.start + 2 + block_end], " \t\n");

                    if (std.mem.startsWith(u8, block_content, "if ")) {
                        const condition_str = std.mem.trim(u8, block_content[3..], " \t\n");
                        const condition_value = getVariableValue(condition_str, Context, ctx, allocator) catch |err| {
                            if (err == error.InvalidVariablePath) {
                                const endif_pos = findEndif(template_content, token.start + 2 + block_end + 2) orelse {
                                    i = template_content.len;
                                    continue;
                                };
                                i = endif_pos;
                                continue;
                            }
                            return err;
                        };
                        defer allocator.free(condition_value);

                        const is_true = isTruthy(condition_value);

                        const endif_pos = findEndif(template_content, token.start + 2 + block_end + 2) orelse {
                            i = token.start + 2 + block_end + 2;
                            continue;
                        };

                        if (is_true) {
                            const content_start = token.start + 2 + block_end + 2;
                            const content_end = endif_pos;
                            try result.appendSlice(allocator, template_content[content_start..content_end]);
                        }
                        i = endif_pos + 11;
                    } else if (std.mem.eql(u8, block_content, "endif")) {
                        i = token.start + 2 + block_end + 2;
                    } else {
                        try result.appendSlice(allocator, template_content[token.start .. token.start + 2 + block_end + 2]);
                        i = token.start + 2 + block_end + 2;
                    }
                } else {
                    const var_end = std.mem.indexOf(u8, template_content[token.start + 2 ..], "}}") orelse {
                        i = template_content.len;
                        continue;
                    };

                    const var_content = template_content[token.start + 2 .. token.start + 2 + var_end];
                    const is_raw = var_content.len > 0 and var_content[0] == '!';
                    const var_str = if (is_raw) std.mem.trim(u8, var_content[1..], " \t\n") else std.mem.trim(u8, var_content, " \t\n");

                    const value = getVariableValue(var_str, Context, ctx, allocator) catch |err| {
                        if (err == error.InvalidVariablePath) {
                            i = token.start + 2 + var_end + 2;
                            continue;
                        }
                        return err;
                    };
                    defer allocator.free(value);

                    if (is_raw) {
                        try result.appendSlice(allocator, value);
                    } else {
                        const escaped = try escape.Escape.escapeHtml(allocator, value);
                        defer allocator.free(escaped);
                        try result.appendSlice(allocator, escaped);
                    }

                    i = token.start + 2 + var_end + 2;
                }
            } else {
                try result.appendSlice(allocator, template_content[i..]);
                break;
            }
        }

        return result.toOwnedSlice(allocator);
    }

    fn getVariableValue(
        var_path: []const u8,
        comptime Context: type,
        ctx: Context,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const path = if (var_path.len > 0 and var_path[0] == '.') var_path[1..] else var_path;

        var parts = std.ArrayListUnmanaged([]const u8){};
        defer parts.deinit(allocator);

        var start: usize = 0;
        var i: usize = 0;
        while (i < path.len) {
            if (path[i] == '.') {
                if (i > start) {
                    const part = path[start..i];
                    try parts.append(allocator, part);
                }
                start = i + 1;
            }
            i += 1;
        }
        if (start < path.len) {
            try parts.append(allocator, path[start..]);
        }

        return getVariableValueImpl(ctx, parts.items, allocator);
    }

    fn getVariableValueImpl(
        value: anytype,
        path: []const []const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        switch (type_info) {
            .@"struct" => |struct_info| {
                if (path.len == 0) {
                    return error.InvalidVariablePath;
                }

                const field_name = path[0];

                inline for (struct_info.fields) |field| {
                    if (std.mem.eql(u8, field.name, field_name)) {
                        const field_value = @field(value, field.name);

                        if (path.len == 1) {
                            return formatValue(field_value, allocator);
                        } else {
                            return getVariableValueImpl(field_value, path[1..], allocator);
                        }
                    }
                }

                return error.InvalidVariablePath;
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return try allocator.dupe(u8, value);
                }
                return error.InvalidVariablePath;
            },
            else => {
                return formatValue(value, allocator);
            },
        }
    }

    fn formatValue(value: anytype, allocator: std.mem.Allocator) ![]const u8 {
        const T = @TypeOf(value);

        return switch (@typeInfo(T)) {
            .pointer => |ptr_info| switch (ptr_info.size) {
                .slice => {
                    if (ptr_info.child == u8) {
                        return try allocator.dupe(u8, value);
                    } else {
                        return try std.fmt.allocPrint(allocator, "{any}", .{value});
                    }
                },
                else => try std.fmt.allocPrint(allocator, "{any}", .{value}),
            },
            .array => |arr_info| {
                if (arr_info.child == u8) {
                    return try allocator.dupe(u8, &value);
                } else {
                    return try std.fmt.allocPrint(allocator, "{any}", .{value});
                }
            },
            .int => try std.fmt.allocPrint(allocator, "{d}", .{value}),
            .float => try std.fmt.allocPrint(allocator, "{d}", .{value}),
            .bool => {
                const bool_str = if (value) "true" else "false";
                return try allocator.dupe(u8, bool_str);
            },
            .optional => {
                if (value) |val| {
                    return formatValue(val, allocator);
                } else {
                    return try allocator.dupe(u8, "");
                }
            },
            else => {
                return try std.fmt.allocPrint(allocator, "{any}", .{value});
            },
        };
    }

    fn isTruthy(value: []const u8) bool {
        if (value.len == 0) return false;
        if (std.mem.eql(u8, value, "false")) return false;
        if (std.mem.eql(u8, value, "0")) return false;
        if (std.mem.eql(u8, value, "")) return false;
        return true;
    }

    fn findEndif(content: []const u8, start_pos: usize) ?usize {
        if (start_pos >= content.len) return null;
        const endif_start = std.mem.indexOf(u8, content[start_pos..], "{% endif %}") orelse return null;
        return start_pos + endif_start;
    }
};
