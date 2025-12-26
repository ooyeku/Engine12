const std = @import("std");
const ast = @import("ast.zig");
const escape = @import("escape.zig");
const filters = @import("filters.zig");

pub const Codegen = struct {
    pub fn generateRenderFunction(
        ast_tree: ast.TemplateAST,
        comptime context_type: type,
    ) type {
        return struct {
            pub fn render(ctx: context_type, allocator: std.mem.Allocator) ![]const u8 {
                var buffer = std.ArrayListUnmanaged(u8){};
                defer buffer.deinit(allocator);

                try renderNodes(ast_tree.nodes, ctx, &buffer, allocator);

                return buffer.toOwnedSlice(allocator);
            }

            fn renderNodes(
                nodes: []const ast.TemplateAST.Node,
                ctx: context_type,
                buffer: *std.ArrayListUnmanaged(u8),
                allocator: std.mem.Allocator,
            ) (std.mem.Allocator.Error || error{InvalidVariablePath})!void {
                for (nodes) |node| {
                    try renderNode(node, ctx, buffer, allocator);
                }
            }

            fn renderNode(
                node: ast.TemplateAST.Node,
                ctx: context_type,
                buffer: *std.ArrayListUnmanaged(u8),
                allocator: std.mem.Allocator,
            ) (std.mem.Allocator.Error || error{InvalidVariablePath})!void {
                switch (node) {
                    .text => |text| {
                        try buffer.appendSlice(allocator, text);
                    },
                    .variable => |var_node| {
                        const initial_value = try getVariableValue(var_node.path, ctx, allocator);
                        const value = if (var_node.filters.len > 0) blk: {
                            defer allocator.free(initial_value);
                            break :blk try applyFilters(initial_value, var_node.filters, allocator);
                        } else initial_value;
                        defer allocator.free(value);

                        const escaped = try escape.Escape.escapeHtml(allocator, value);
                        defer allocator.free(escaped);
                        try buffer.appendSlice(allocator, escaped);
                    },
                    .raw_variable => |var_node| {
                        const initial_value = try getVariableValue(var_node.path, ctx, allocator);
                        const value = if (var_node.filters.len > 0) blk: {
                            defer allocator.free(initial_value);
                            break :blk try applyFilters(initial_value, var_node.filters, allocator);
                        } else initial_value;
                        defer allocator.free(value);

                        try buffer.appendSlice(allocator, value);
                    },
                    .if_block => |if_node| {
                        const is_true = try evaluateCondition(if_node.condition, ctx, allocator);
                        if (is_true) {
                            try renderNodes(if_node.true_block.nodes, ctx, buffer, allocator);
                        } else {
                            // Check elif blocks
                            var elif_matched = false;
                            for (if_node.elif_blocks) |elif_block| {
                                const elif_true = try evaluateCondition(elif_block.condition, ctx, allocator);
                                if (elif_true) {
                                    try renderNodes(elif_block.block.nodes, ctx, buffer, allocator);
                                    elif_matched = true;
                                    break;
                                }
                            }
                            if (!elif_matched) {
                                if (if_node.false_block) |false_block| {
                                    try renderNodes(false_block.nodes, ctx, buffer, allocator);
                                }
                            }
                        }
                    },
                    .for_block => |for_node| {
                        const collection_value = try getCollectionValue(for_node.collection_path, ctx, allocator);
                        defer collection_value.deinit();

                        var index: usize = 0;
                        while (index < collection_value.len) : (index += 1) {
                            const item_value = try collection_value.getItem(index, allocator);
                            defer item_value.deinit();

                            try renderNodesWithLoopVars(for_node.block.nodes, ctx, for_node.item_name, item_value.value, index, collection_value.len, buffer, allocator);
                        }
                    },
                    .include => |include_node| {
                        // TODO: Implement proper include with @embedFile
                        const include_placeholder = try std.fmt.allocPrint(allocator, "<!-- Include: {s} -->\n", .{include_node.file_path});
                        defer allocator.free(include_placeholder);
                        try buffer.appendSlice(allocator, include_placeholder);
                    },
                    .comment => |_| {
                        // Comments are not rendered
                    },
                    .extends => |_| {
                        // Extends is handled at template compilation level
                    },
                    .block => |block_node| {
                        // For now, render block content directly
                        try renderNodes(block_node.content.nodes, ctx, buffer, allocator);
                    },
                }
            }

            fn evaluateCondition(
                condition: ast.TemplateAST.Condition,
                ctx: context_type,
                allocator: std.mem.Allocator,
            ) !bool {
                switch (condition) {
                    .simple => |var_node| {
                        const value = try getVariableValue(var_node.path, ctx, allocator);
                        defer allocator.free(value);
                        return isTruthy(value);
                    },
                    .negated => |neg| {
                        const value = try getVariableValue(neg.inner.path, ctx, allocator);
                        defer allocator.free(value);
                        return !isTruthy(value);
                    },
                    .comparison => |cmp| {
                        const left_value = try getVariableValue(cmp.left.path, ctx, allocator);
                        defer allocator.free(left_value);

                        const right_value: []const u8 = switch (cmp.right) {
                            .variable => |v| try getVariableValue(v.path, ctx, allocator),
                            .literal_string => |s| try allocator.dupe(u8, s),
                            .literal_int => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
                            .literal_bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
                        };
                        defer allocator.free(right_value);

                        return switch (cmp.operator) {
                            .eq => std.mem.eql(u8, left_value, right_value),
                            .ne => !std.mem.eql(u8, left_value, right_value),
                            .lt => compareValues(left_value, right_value) < 0,
                            .le => compareValues(left_value, right_value) <= 0,
                            .gt => compareValues(left_value, right_value) > 0,
                            .ge => compareValues(left_value, right_value) >= 0,
                        };
                    },
                }
            }

            fn compareValues(left: []const u8, right: []const u8) i32 {
                // Try numeric comparison first
                const left_num = std.fmt.parseInt(i64, left, 10) catch null;
                const right_num = std.fmt.parseInt(i64, right, 10) catch null;

                if (left_num != null and right_num != null) {
                    const l = left_num.?;
                    const r = right_num.?;
                    if (l < r) return -1;
                    if (l > r) return 1;
                    return 0;
                }

                // Fall back to string comparison
                return switch (std.mem.order(u8, left, right)) {
                    .lt => -1,
                    .eq => 0,
                    .gt => 1,
                };
            }
            fn getVariableValue(
                path: []const []const u8,
                ctx: context_type,
                allocator: std.mem.Allocator,
            ) ![]const u8 {
                if (path.len == 0) {
                    return formatValue(ctx, allocator);
                }

                return getVariableValueImpl(ctx, path, allocator);
            }

            fn applyFilters(
                value: []const u8,
                filter_list: []const ast.TemplateAST.Filter,
                allocator: std.mem.Allocator,
            ) ![]const u8 {
                var current_value = value;
                var needs_free = false;

                for (filter_list) |filter| {
                    const filter_name = filter.name;
                    const filtered = blk: {
                        if (std.mem.eql(u8, filter_name, "uppercase")) {
                            break :blk try filters.Filters.uppercase(current_value, allocator);
                        } else if (std.mem.eql(u8, filter_name, "lowercase")) {
                            break :blk try filters.Filters.lowercase(current_value, allocator);
                        } else if (std.mem.eql(u8, filter_name, "trim")) {
                            break :blk try filters.Filters.trim(current_value, allocator);
                        } else if (std.mem.eql(u8, filter_name, "capitalize")) {
                            break :blk try filters.Filters.capitalize(current_value, allocator);
                        } else if (std.mem.eql(u8, filter_name, "truncate")) {
                            const max_len = if (filter.args.len > 0)
                                std.fmt.parseInt(usize, filter.args[0], 10) catch 50
                            else
                                50;
                            break :blk try filters.Filters.truncate(current_value, max_len, allocator);
                        } else if (std.mem.eql(u8, filter_name, "replace")) {
                            const from = if (filter.args.len > 0) filter.args[0] else "";
                            const to = if (filter.args.len > 1) filter.args[1] else "";
                            break :blk try filters.Filters.replace(current_value, from, to, allocator);
                        } else if (std.mem.eql(u8, filter_name, "json")) {
                            break :blk try filters.Filters.json(current_value, allocator);
                        } else if (std.mem.eql(u8, filter_name, "nl2br")) {
                            break :blk try filters.Filters.nl2br(current_value, allocator);
                        } else if (std.mem.eql(u8, filter_name, "escape_js")) {
                            break :blk try filters.Filters.escapeJs(current_value, allocator);
                        } else if (std.mem.eql(u8, filter_name, "escape_url")) {
                            break :blk try filters.Filters.escapeUrl(current_value, allocator);
                        } else if (std.mem.eql(u8, filter_name, "default")) {
                            const default_val = if (filter.args.len > 0) filter.args[0] else "";
                            const value_opt: ?[]const u8 = if (current_value.len > 0) current_value else null;
                            const result = filters.Filters.default(value_opt, default_val);
                            break :blk try allocator.dupe(u8, result);
                        } else {
                            // Unknown filter - pass through unchanged
                            break :blk try allocator.dupe(u8, current_value);
                        }
                    };

                    if (needs_free) {
                        allocator.free(current_value);
                    }
                    current_value = filtered;
                    needs_free = true;
                }

                if (!needs_free) {
                    return try allocator.dupe(u8, value);
                }

                return current_value;
            }

            fn getVariableValueImpl(value: anytype, path: []const []const u8, allocator: std.mem.Allocator) ![]const u8 {
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
                        if (ptr_info.size == .slice) {
                            return formatValue(value, allocator);
                        }
                        return error.InvalidVariablePath;
                    },
                    else => {
                        return error.InvalidVariablePath;
                    },
                }
            }

            fn getCollectionValue(collection_path: []const []const u8, ctx: context_type, allocator: std.mem.Allocator) !CollectionWrapper {
                return getCollectionValueImpl(ctx, collection_path, allocator);
            }

            fn getCollectionValueImpl(value: anytype, path: []const []const u8, allocator: std.mem.Allocator) !CollectionWrapper {
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
                                    return wrapCollection(field_value);
                                } else {
                                    return getCollectionValueImpl(field_value, path[1..], allocator);
                                }
                            }
                        }

                        return error.InvalidVariablePath;
                    },
                    else => {
                        return error.InvalidVariablePath;
                    },
                }
            }

            fn wrapCollection(collection: anytype) !CollectionWrapper {
                const T = @TypeOf(collection);
                const type_info = @typeInfo(T);

                return switch (type_info) {
                    .pointer => |ptr_info| switch (ptr_info.size) {
                        .slice => {
                            return CollectionWrapper.initSlice(collection, ptr_info.child);
                        },
                        else => error.InvalidVariablePath,
                    },
                    .array => |array_info| {
                        return CollectionWrapper.initArray(collection, array_info.child);
                    },
                    .@"struct" => {
                        if (@hasDecl(T, "items") and @hasDecl(T, "capacity")) {
                            const ItemType = @TypeOf(collection.items[0]);
                            return CollectionWrapper.initArrayList(collection, ItemType);
                        }
                        return error.InvalidVariablePath;
                    },
                    else => error.InvalidVariablePath,
                };
            }

            fn renderNodesWithLoopVars(
                nodes: []const ast.TemplateAST.Node,
                ctx: context_type,
                item_name: []const u8,
                item_value: []const u8,
                index: usize,
                total: usize,
                buffer: *std.ArrayListUnmanaged(u8),
                allocator: std.mem.Allocator,
            ) !void {
                const loop_ctx = LoopContext{
                    .parent_ctx = ctx,
                    .item_name = item_name,
                    .item_value = item_value,
                    .index = index,
                    .total = total,
                };

                try renderNodesWithContext(nodes, loop_ctx, buffer, allocator);
            }

            fn renderNodesWithContext(
                nodes: []const ast.TemplateAST.Node,
                ctx: anytype,
                buffer: *std.ArrayListUnmanaged(u8),
                allocator: std.mem.Allocator,
            ) (std.mem.Allocator.Error || error{InvalidVariablePath})!void {
                for (nodes) |node| {
                    try renderNodeWithContext(node, ctx, buffer, allocator);
                }
            }

            fn renderNodeWithContext(
                node: ast.TemplateAST.Node,
                ctx: anytype,
                buffer: *std.ArrayListUnmanaged(u8),
                allocator: std.mem.Allocator,
            ) (std.mem.Allocator.Error || error{InvalidVariablePath})!void {
                switch (node) {
                    .text => |text| {
                        try buffer.appendSlice(allocator, text);
                    },
                    .variable => |var_node| {
                        const initial_value = try getVariableValueWithContext(var_node.path, ctx, allocator);
                        const value = if (var_node.filters.len > 0) blk: {
                            defer allocator.free(initial_value);
                            break :blk try applyFilters(initial_value, var_node.filters, allocator);
                        } else initial_value;
                        defer allocator.free(value);

                        const escaped = try escape.Escape.escapeHtml(allocator, value);
                        defer allocator.free(escaped);
                        try buffer.appendSlice(allocator, escaped);
                    },
                    .raw_variable => |var_node| {
                        const initial_value = try getVariableValueWithContext(var_node.path, ctx, allocator);
                        const value = if (var_node.filters.len > 0) blk: {
                            defer allocator.free(initial_value);
                            break :blk try applyFilters(initial_value, var_node.filters, allocator);
                        } else initial_value;
                        defer allocator.free(value);

                        try buffer.appendSlice(allocator, value);
                    },
                    .if_block => |if_node| {
                        const is_true = try evaluateConditionWithContext(if_node.condition, ctx, allocator);
                        if (is_true) {
                            try renderNodesWithContext(if_node.true_block.nodes, ctx, buffer, allocator);
                        } else {
                            // Check elif blocks
                            var elif_matched = false;
                            for (if_node.elif_blocks) |elif_block| {
                                const elif_true = try evaluateConditionWithContext(elif_block.condition, ctx, allocator);
                                if (elif_true) {
                                    try renderNodesWithContext(elif_block.block.nodes, ctx, buffer, allocator);
                                    elif_matched = true;
                                    break;
                                }
                            }
                            if (!elif_matched) {
                                if (if_node.false_block) |false_block| {
                                    try renderNodesWithContext(false_block.nodes, ctx, buffer, allocator);
                                }
                            }
                        }
                    },
                    .for_block => |for_node| {
                        const collection_value = try getCollectionValueWithContext(for_node.collection_path, ctx, allocator);
                        defer collection_value.deinit();

                        var index: usize = 0;
                        while (index < collection_value.len) : (index += 1) {
                            const item_value = try collection_value.getItem(index, allocator);
                            defer item_value.deinit();

                            const T = @TypeOf(ctx);
                            const is_loop_ctx = @hasField(T, "item_name") and @hasField(T, "parent_ctx") and @hasField(T, "index");

                            if (is_loop_ctx) {
                                const nested_loop_ctx = LoopContext{
                                    .parent_ctx = ctx.parent_ctx, // Go back to original context, losing outer loop item
                                    .item_name = for_node.item_name,
                                    .item_value = item_value.value,
                                    .index = index,
                                    .total = collection_value.len,
                                };
                                try renderNodesWithContext(for_node.block.nodes, nested_loop_ctx, buffer, allocator);
                            } else {
                                try renderNodesWithLoopVars(for_node.block.nodes, ctx, for_node.item_name, item_value.value, index, collection_value.len, buffer, allocator);
                            }
                        }
                    },
                    .include => |include_node| {
                        const include_placeholder = try std.fmt.allocPrint(allocator, "<!-- Include: {s} -->\n", .{include_node.file_path});
                        defer allocator.free(include_placeholder);
                        try buffer.appendSlice(allocator, include_placeholder);
                    },
                    .comment => |_| {
                        // Comments are not rendered
                    },
                    .extends => |_| {
                        // Extends is handled at template compilation level
                    },
                    .block => |block_node| {
                        // For now, render block content directly
                        try renderNodesWithContext(block_node.content.nodes, ctx, buffer, allocator);
                    },
                }
            }

            fn evaluateConditionWithContext(
                condition: ast.TemplateAST.Condition,
                ctx: anytype,
                allocator: std.mem.Allocator,
            ) !bool {
                switch (condition) {
                    .simple => |var_node| {
                        const value = try getVariableValueWithContext(var_node.path, ctx, allocator);
                        defer allocator.free(value);
                        return isTruthy(value);
                    },
                    .negated => |neg| {
                        const value = try getVariableValueWithContext(neg.inner.path, ctx, allocator);
                        defer allocator.free(value);
                        return !isTruthy(value);
                    },
                    .comparison => |cmp| {
                        const left_value = try getVariableValueWithContext(cmp.left.path, ctx, allocator);
                        defer allocator.free(left_value);

                        const right_value: []const u8 = switch (cmp.right) {
                            .variable => |v| try getVariableValueWithContext(v.path, ctx, allocator),
                            .literal_string => |s| try allocator.dupe(u8, s),
                            .literal_int => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
                            .literal_bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
                        };
                        defer allocator.free(right_value);

                        return switch (cmp.operator) {
                            .eq => std.mem.eql(u8, left_value, right_value),
                            .ne => !std.mem.eql(u8, left_value, right_value),
                            .lt => compareValues(left_value, right_value) < 0,
                            .le => compareValues(left_value, right_value) <= 0,
                            .gt => compareValues(left_value, right_value) > 0,
                            .ge => compareValues(left_value, right_value) >= 0,
                        };
                    },
                }
            }

            fn getVariableValueWithContext(path: []const []const u8, ctx: anytype, allocator: std.mem.Allocator) ![]const u8 {
                const T = @TypeOf(ctx);
                const is_loop_ctx = @hasField(T, "item_name") and @hasField(T, "parent_ctx") and @hasField(T, "index");

                if (is_loop_ctx) {
                    if (path.len > 0 and std.mem.eql(u8, path[0], "..")) {
                        if (path.len == 1) {
                            return error.InvalidVariablePath;
                        }
                        return getVariableValueImpl(ctx.parent_ctx, path[1..], allocator);
                    }

                    if (path.len == 1) {
                        if (std.mem.eql(u8, path[0], ctx.item_name)) {
                            return try allocator.dupe(u8, ctx.item_value);
                        }
                        if (std.mem.eql(u8, path[0], "index")) {
                            return try std.fmt.allocPrint(allocator, "{d}", .{ctx.index});
                        }
                        if (std.mem.eql(u8, path[0], "first")) {
                            const first_str = if (ctx.index == 0) "true" else "false";
                            return try allocator.dupe(u8, first_str);
                        }
                        if (std.mem.eql(u8, path[0], "last")) {
                            const last_str = if (ctx.index == ctx.total - 1) "true" else "false";
                            return try allocator.dupe(u8, last_str);
                        }
                        if (std.mem.eql(u8, path[0], "length")) {
                            return try std.fmt.allocPrint(allocator, "{d}", .{ctx.total});
                        }
                        if (std.mem.eql(u8, path[0], "revindex")) {
                            return try std.fmt.allocPrint(allocator, "{d}", .{ctx.total - ctx.index - 1});
                        }
                    }
                    return getVariableValueImpl(ctx.parent_ctx, path, allocator);
                }
                if (path.len > 0 and std.mem.eql(u8, path[0], "..")) {
                    return error.InvalidVariablePath;
                }
                return getVariableValueImpl(ctx, path, allocator);
            }

            fn getCollectionValueWithContext(collection_path: []const []const u8, ctx: anytype, allocator: std.mem.Allocator) !CollectionWrapper {
                const T = @TypeOf(ctx);
                const is_loop_ctx = @hasField(T, "item_name") and @hasField(T, "parent_ctx") and @hasField(T, "index");

                if (is_loop_ctx) {
                    return getCollectionValueImpl(ctx.parent_ctx, collection_path, allocator);
                }
                return getCollectionValueImpl(ctx, collection_path, allocator);
            }

            const LoopContext = struct {
                parent_ctx: context_type,
                item_name: []const u8,
                item_value: []const u8,
                index: usize,
                total: usize,
            };

            const CollectionWrapper = struct {
                const CollectionData = union(enum) {
                    slice: *const anyopaque,
                    array: *const anyopaque,
                    array_list: *const anyopaque,
                };

                data: CollectionData,
                len: usize,
                get_item_fn: *const fn (*const anyopaque, usize, std.mem.Allocator) (std.mem.Allocator.Error || error{InvalidVariablePath})![]const u8,

                fn initSlice(collection: anytype, comptime ItemType: type) CollectionWrapper {
                    _ = ItemType; // Used for type checking at comptime
                    const CollectionType = @TypeOf(collection);
                    return CollectionWrapper{
                        .data = .{ .slice = @as(*const anyopaque, @ptrCast(&collection)) },
                        .len = collection.len,
                        .get_item_fn = &struct {
                            fn getItem(ptr: *const anyopaque, idx: usize, alloc: std.mem.Allocator) (std.mem.Allocator.Error || error{InvalidVariablePath})![]const u8 {
                                const slice_ptr: *const CollectionType = @ptrCast(@alignCast(ptr));
                                const slice = slice_ptr.*;
                                if (idx >= slice.len) return error.InvalidVariablePath;
                                const item = slice[idx];
                                return formatValue(item, alloc);
                            }
                        }.getItem,
                    };
                }

                fn initArray(collection: anytype, comptime ItemType: type) CollectionWrapper {
                    _ = ItemType; // Used for type checking at comptime
                    const CollectionType = @TypeOf(collection);
                    return CollectionWrapper{
                        .data = .{ .array = @as(*const anyopaque, @ptrCast(&collection)) },
                        .len = collection.len,
                        .get_item_fn = &struct {
                            fn getItem(ptr: *const anyopaque, idx: usize, alloc: std.mem.Allocator) (std.mem.Allocator.Error || error{InvalidVariablePath})![]const u8 {
                                const array_ptr: *const CollectionType = @ptrCast(@alignCast(ptr));
                                const array = array_ptr.*;
                                if (idx >= array.len) return error.InvalidVariablePath;
                                const item = array[idx];
                                return formatValue(item, alloc);
                            }
                        }.getItem,
                    };
                }

                fn initArrayList(collection: anytype, comptime ItemType: type) CollectionWrapper {
                    _ = ItemType; // Used for type checking at comptime
                    const CollectionType = @TypeOf(collection);
                    return CollectionWrapper{
                        .data = .{ .array_list = @as(*const anyopaque, @ptrCast(&collection)) },
                        .len = collection.items.len,
                        .get_item_fn = &struct {
                            fn getItem(ptr: *const anyopaque, idx: usize, alloc: std.mem.Allocator) (std.mem.Allocator.Error || error{InvalidVariablePath})![]const u8 {
                                const list_ptr: *const CollectionType = @ptrCast(@alignCast(ptr));
                                const list = list_ptr.*;
                                if (idx >= list.items.len) return error.InvalidVariablePath;
                                const item = list.items[idx];
                                return formatValue(item, alloc);
                            }
                        }.getItem,
                    };
                }

                fn deinit(self: CollectionWrapper) void {
                    _ = self;
                }

                fn getItem(self: CollectionWrapper, index: usize, allocator: std.mem.Allocator) !struct {
                    value: []const u8,
                    item_allocator: std.mem.Allocator,
                    fn deinit(item: @This()) void {
                        item.item_allocator.free(item.value);
                    }
                } {
                    if (index >= self.len) {
                        return error.InvalidVariablePath;
                    }

                    const ptr = switch (self.data) {
                        .slice => |p| p,
                        .array => |p| p,
                        .array_list => |p| p,
                    };
                    const value_str = try self.get_item_fn(ptr, index, allocator);

                    return .{
                        .value = value_str,
                        .item_allocator = allocator,
                    };
                }
            };

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
                    .int => try std.fmt.allocPrint(allocator, "{d}", .{value}),
                    .float => try std.fmt.allocPrint(allocator, "{d}", .{value}),
                    .bool => {
                        const bool_str = if (value) "true" else "false";
                        return try allocator.dupe(u8, bool_str);
                    },
                    .optional => |_| {
                        if (value) |v| {
                            return formatValue(v, allocator);
                        } else {
                            return try allocator.dupe(u8, "");
                        }
                    },
                    else => try std.fmt.allocPrint(allocator, "{any}", .{value}),
                };
            }

            fn isTruthy(value: []const u8) bool {
                if (value.len == 0) return false;

                var lower_buf: [256]u8 = undefined;
                const lower = if (value.len <= 256) blk: {
                    for (value, 0..) |char, i| {
                        lower_buf[i] = std.ascii.toLower(char);
                    }
                    break :blk lower_buf[0..value.len];
                } else value; // Fallback to original if too long (rare case)

                if (std.mem.eql(u8, lower, "false")) return false;
                if (std.mem.eql(u8, lower, "0")) return false;
                if (std.mem.eql(u8, lower, "null")) return false;
                if (std.mem.eql(u8, lower, "nil")) return false;

                if (std.mem.eql(u8, lower, "true")) return true;
                if (std.mem.eql(u8, lower, "1")) return true;

                return true;
            }
        };
    }
};
