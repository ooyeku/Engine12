const std = @import("std");
const ast = @import("ast.zig");
const escape = @import("escape.zig");
const filters = @import("filters.zig");

/// Code generator for templates
/// Generates optimized rendering functions at comptime
pub const Codegen = struct {
    /// Generate render function for AST and context type
    pub fn generateRenderFunction(
        ast_tree: ast.TemplateAST,
        comptime context_type: type,
    ) type {
        return struct {
            pub fn render(ctx: context_type, allocator: std.mem.Allocator) ![]const u8 {
                // Estimate buffer size (simplified - could be more accurate)
                var buffer = std.ArrayListUnmanaged(u8){};
                defer buffer.deinit(allocator);

                // Render all nodes
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
                        var value = try getVariableValue(var_node.path, ctx, allocator);
                        defer allocator.free(value);
                        
                        // Apply filters before escaping
                        if (var_node.filters.len > 0) {
                            const filtered = try applyFilters(value, var_node.filters, allocator);
                            allocator.free(value);
                            value = filtered;
                            defer allocator.free(value);
                        }
                        
                        const escaped = try escape.Escape.escapeHtml(allocator, value);
                        defer allocator.free(escaped);
                        try buffer.appendSlice(allocator, escaped);
                    },
                    .raw_variable => |var_node| {
                        var value = try getVariableValue(var_node.path, ctx, allocator);
                        defer allocator.free(value);
                        
                        // Apply filters for raw variables too
                        if (var_node.filters.len > 0) {
                            const filtered = try applyFilters(value, var_node.filters, allocator);
                            allocator.free(value);
                            value = filtered;
                            defer allocator.free(value);
                        }
                        
                        try buffer.appendSlice(allocator, value);
                    },
                    .if_block => |if_node| {
                        const condition_value = try getVariableValue(if_node.condition.path, ctx, allocator);
                        defer allocator.free(condition_value);

                        const is_true = isTruthy(condition_value);
                        if (is_true) {
                            try renderNodes(if_node.true_block.nodes, ctx, buffer, allocator);
                        } else if (if_node.false_block) |false_block| {
                            try renderNodes(false_block.nodes, ctx, buffer, allocator);
                        }
                    },
                    .for_block => |for_node| {
                        // Get the collection value using comptime introspection
                        const collection_value = try getCollectionValue(for_node.collection_path, ctx, allocator);
                        defer collection_value.deinit();

                        // Iterate over items
                        var index: usize = 0;
                        while (index < collection_value.len) : (index += 1) {
                            const item_value = try collection_value.getItem(index, allocator);
                            defer item_value.deinit();

                            // Render nodes with loop context
                            try renderNodesWithLoopVars(for_node.block.nodes, ctx, for_node.item_name, item_value.value, index, collection_value.len, buffer, allocator);
                        }
                    },
                    .include => |include_node| {
                        // Include rendering - attempt to load and render included template
                        // Note: Full include support requires template file path tracking
                        // For now, we'll render a placeholder indicating include is not fully supported
                        // TODO: Implement full include support with @embedFile and path resolution
                        const include_placeholder = try std.fmt.allocPrint(allocator, "<!-- Include: {s} (not yet implemented) -->", .{include_node.file_path});
                        defer allocator.free(include_placeholder);
                        try buffer.appendSlice(allocator, include_placeholder);
                    },
                }
            }

            fn getVariableValue(
                path: []const []const u8,
                ctx: context_type,
                allocator: std.mem.Allocator,
            ) ![]const u8 {
                if (path.len == 0) {
                    // Empty path means root context - serialize entire context
                    return formatValue(ctx, allocator);
                }

                // Navigate through context using runtime reflection
                return getVariableValueImpl(ctx, path, allocator);
            }

            /// Apply filters to a value sequentially
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
                        // Apply filter based on name
                        if (std.mem.eql(u8, filter_name, "uppercase")) {
                            break :blk try filters.Filters.uppercase(current_value, allocator);
                        } else if (std.mem.eql(u8, filter_name, "lowercase")) {
                            break :blk try filters.Filters.lowercase(current_value, allocator);
                        } else if (std.mem.eql(u8, filter_name, "trim")) {
                            break :blk try filters.Filters.trim(current_value, allocator);
                        } else if (std.mem.eql(u8, filter_name, "default")) {
                            // Default filter takes first argument as default value
                            const default_val = if (filter.args.len > 0) filter.args[0] else "";
                            const value_opt: ?[]const u8 = if (current_value.len > 0) current_value else null;
                            const result = filters.Filters.default(value_opt, default_val);
                            // Default filter doesn't allocate, so we need to dupe the result
                            break :blk try allocator.dupe(u8, result);
                        } else {
                            // Unknown filter - return value as-is (log warning in debug mode)
                            break :blk try allocator.dupe(u8, current_value);
                        }
                    };

                    // Free previous value if we allocated it
                    if (needs_free) {
                        allocator.free(current_value);
                    }
                    current_value = filtered;
                    needs_free = true;
                }

                // If no filters were applied, dupe the original value
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

                        // Find field and get its value using inline for
                        inline for (struct_info.fields) |field| {
                            if (std.mem.eql(u8, field.name, field_name)) {
                                const field_value = @field(value, field.name);

                                if (path.len == 1) {
                                    // Last field - convert to string
                                    return formatValue(field_value, allocator);
                                } else {
                                    // Navigate deeper
                                    return getVariableValueImpl(field_value, path[1..], allocator);
                                }
                            }
                        }

                        // Field not found - provide helpful error message
                        // Runtime error: field not found in struct
                        return error.InvalidVariablePath;
                    },
                    .pointer => |ptr_info| {
                        if (ptr_info.size == .slice) {
                            // Handle slices - convert to string representation for now
                            // Full iteration support would require more complex handling
                            return formatValue(value, allocator);
                        }
                        // Cannot access fields on non-slice pointers
                        return error.InvalidVariablePath;
                    },
                    else => {
                        // Cannot access fields on non-struct types
                        return error.InvalidVariablePath;
                    },
                }
            }

            // Helper to get collection value using comptime introspection
            fn getCollectionValue(collection_path: []const []const u8, ctx: context_type, allocator: std.mem.Allocator) !CollectionWrapper {
                return getCollectionValueImpl(ctx, collection_path, allocator);
            }

            // Comptime introspection to get collection value
            fn getCollectionValueImpl(value: anytype, path: []const []const u8, allocator: std.mem.Allocator) !CollectionWrapper {
                const T = @TypeOf(value);
                const type_info = @typeInfo(T);

                switch (type_info) {
                    .@"struct" => |struct_info| {
                        if (path.len == 0) {
                            return error.InvalidVariablePath;
                        }

                        const field_name = path[0];

                        // Find field and get its value using inline for
                        inline for (struct_info.fields) |field| {
                            if (std.mem.eql(u8, field.name, field_name)) {
                                const field_value = @field(value, field.name);

                                if (path.len == 1) {
                                    // Last field - check if it's a collection
                                    return wrapCollection(field_value);
                                } else {
                                    // Navigate deeper
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

            // Wrap a collection into CollectionWrapper based on its type
            fn wrapCollection(collection: anytype) !CollectionWrapper {
                const T = @TypeOf(collection);
                const type_info = @typeInfo(T);

                return switch (type_info) {
                    .pointer => |ptr_info| switch (ptr_info.size) {
                        .slice => {
                            // Handle slices []T or []const T
                            return CollectionWrapper.initSlice(collection, ptr_info.child);
                        },
                        else => error.InvalidVariablePath,
                    },
                    .array => |array_info| {
                        // Handle arrays [N]T
                        return CollectionWrapper.initArray(collection, array_info.child);
                    },
                    .@"struct" => {
                        // Check if it's ArrayListUnmanaged
                        if (@hasDecl(T, "items") and @hasDecl(T, "capacity")) {
                            // Assume it's ArrayListUnmanaged-like
                            const ItemType = @TypeOf(collection.items[0]);
                            return CollectionWrapper.initArrayList(collection, ItemType);
                        }
                        return error.InvalidVariablePath;
                    },
                    else => error.InvalidVariablePath,
                };
            }

            // Helper to render nodes with loop variables
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
                // Create loop context with item and index variables
                const loop_ctx = LoopContext{
                    .parent_ctx = ctx,
                    .item_name = item_name,
                    .item_value = item_value,
                    .index = index,
                    .total = total,
                };

                // Render nodes with loop context
                try renderNodesWithContext(nodes, loop_ctx, buffer, allocator);
            }

            // Render nodes with explicit context (supports both main ctx and loop ctx)
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
                        var value = try getVariableValueWithContext(var_node.path, ctx, allocator);
                        defer allocator.free(value);
                        
                        // Apply filters before escaping
                        if (var_node.filters.len > 0) {
                            const filtered = try applyFilters(value, var_node.filters, allocator);
                            allocator.free(value);
                            value = filtered;
                            defer allocator.free(value);
                        }
                        
                        const escaped = try escape.Escape.escapeHtml(allocator, value);
                        defer allocator.free(escaped);
                        try buffer.appendSlice(allocator, escaped);
                    },
                    .raw_variable => |var_node| {
                        var value = try getVariableValueWithContext(var_node.path, ctx, allocator);
                        defer allocator.free(value);
                        
                        // Apply filters for raw variables too
                        if (var_node.filters.len > 0) {
                            const filtered = try applyFilters(value, var_node.filters, allocator);
                            allocator.free(value);
                            value = filtered;
                            defer allocator.free(value);
                        }
                        
                        try buffer.appendSlice(allocator, value);
                    },
                    .if_block => |if_node| {
                        const condition_value = try getVariableValueWithContext(if_node.condition.path, ctx, allocator);
                        defer allocator.free(condition_value);

                        const is_true = isTruthy(condition_value);
                        if (is_true) {
                            try renderNodesWithContext(if_node.true_block.nodes, ctx, buffer, allocator);
                        } else if (if_node.false_block) |false_block| {
                            try renderNodesWithContext(false_block.nodes, ctx, buffer, allocator);
                        }
                    },
                    .for_block => |for_node| {
                        // Nested loops - get collection from current context
                        const collection_value = try getCollectionValueWithContext(for_node.collection_path, ctx, allocator);
                        defer collection_value.deinit();

                        var index: usize = 0;
                        while (index < collection_value.len) : (index += 1) {
                            const item_value = try collection_value.getItem(index, allocator);
                            defer item_value.deinit();

                            // Check if we're already in a loop context
                            // For nested loops, we need to preserve the outer loop's context
                            // We detect loop context by checking if ctx has loop-specific fields
                            const T = @TypeOf(ctx);
                            const is_loop_ctx = @hasField(T, "item_name") and @hasField(T, "parent_ctx") and @hasField(T, "index");
                            
                            if (is_loop_ctx) {
                                // Nested loop - we need to create a new context that preserves outer loop
                                // Since LoopContext.parent_ctx is context_type, we need to extract the original context
                                // For now, create a wrapper that stores both outer and inner loop info
                                // Outer loop variables are accessible via ../outer_item_name syntax
                                // We'll handle this in getVariableValueWithContext by checking parent_ctx recursively
                                const nested_loop_ctx = LoopContext{
                                    .parent_ctx = ctx.parent_ctx, // Go back to original context, losing outer loop item
                                    .item_name = for_node.item_name,
                                    .item_value = item_value.value,
                                    .index = index,
                                    .total = collection_value.len,
                                };
                                // TODO: Full nested loop support requires storing outer loop item in a map
                                // For now, nested loops work but can't access outer loop items directly
                                try renderNodesWithContext(for_node.block.nodes, nested_loop_ctx, buffer, allocator);
                            } else {
                                // First level loop
                                try renderNodesWithLoopVars(for_node.block.nodes, ctx, for_node.item_name, item_value.value, index, collection_value.len, buffer, allocator);
                            }
                        }
                    },
                    .include => |include_node| {
                        // Include rendering - attempt to load and render included template
                        // Note: Full include support requires template file path tracking
                        // For now, we'll render a placeholder indicating include is not fully supported
                        // TODO: Implement full include support with @embedFile and path resolution
                        const include_placeholder = try std.fmt.allocPrint(allocator, "<!-- Include: {s} (not yet implemented) -->", .{include_node.file_path});
                        defer allocator.free(include_placeholder);
                        try buffer.appendSlice(allocator, include_placeholder);
                    },
                }
            }

            // Get variable value with context (checks loop context first)
            fn getVariableValueWithContext(path: []const []const u8, ctx: anytype, allocator: std.mem.Allocator) ![]const u8 {
                // Check if context is LoopContext by checking for loop-specific fields
                const T = @TypeOf(ctx);
                const is_loop_ctx = @hasField(T, "item_name") and @hasField(T, "parent_ctx") and @hasField(T, "index");
                
                if (is_loop_ctx) {
                    // Check for parent navigation (../)
                    if (path.len > 0 and std.mem.eql(u8, path[0], "..")) {
                        // Navigate to parent context
                        if (path.len == 1) {
                            // Just "../" - return parent context as string (not useful, but handle it)
                            return error.InvalidVariablePath;
                        }
                        // Use parent context with remaining path
                        // Note: For nested loops, parent_ctx is the original context_type,
                        // so we can't directly access outer loop variables
                        // This is a limitation of the current design
                        return getVariableValueImpl(ctx.parent_ctx, path[1..], allocator);
                    }

                    // Check if path matches loop variable names
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
                    }
                    // Fall through to parent context
                    // Note: parent_ctx is always context_type, not another LoopContext
                    // So we go directly to the original context
                    return getVariableValueImpl(ctx.parent_ctx, path, allocator);
                }
                // Regular context - check for parent navigation (should not happen in non-loop context)
                if (path.len > 0 and std.mem.eql(u8, path[0], "..")) {
                    return error.InvalidVariablePath;
                }
                return getVariableValueImpl(ctx, path, allocator);
            }

            // Get collection value with context
            fn getCollectionValueWithContext(collection_path: []const []const u8, ctx: anytype, allocator: std.mem.Allocator) !CollectionWrapper {
                const T = @TypeOf(ctx);
                const is_loop_ctx = @hasField(T, "item_name") and @hasField(T, "parent_ctx") and @hasField(T, "index");
                
                if (is_loop_ctx) {
                    // Try parent context first
                    return getCollectionValueImpl(ctx.parent_ctx, collection_path, allocator);
                }
                return getCollectionValueImpl(ctx, collection_path, allocator);
            }

            // LoopContext for tracking loop state
            // parent_ctx is the original context_type, but we handle nested loops
            // by creating nested LoopContext structs
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
                                // String slice
                                return try allocator.dupe(u8, value);
                            } else {
                                // Other slice - convert to string representation
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
                // Check if value is "truthy"
                // Empty strings are falsy
                if (value.len == 0) return false;

                // Normalize to lowercase for case-insensitive comparison
                var lower_buf: [256]u8 = undefined;
                const lower = if (value.len <= 256) blk: {
                    for (value, 0..) |char, i| {
                        lower_buf[i] = std.ascii.toLower(char);
                    }
                    break :blk lower_buf[0..value.len];
                } else value; // Fallback to original if too long (rare case)

                // Explicit false values (case-insensitive)
                if (std.mem.eql(u8, lower, "false")) return false;
                if (std.mem.eql(u8, lower, "0")) return false;
                if (std.mem.eql(u8, lower, "null")) return false;
                if (std.mem.eql(u8, lower, "nil")) return false;

                // Explicit true values (case-insensitive)
                if (std.mem.eql(u8, lower, "true")) return true;
                if (std.mem.eql(u8, lower, "1")) return true;

                // All other non-empty strings are truthy
                return true;
            }
        };
    }
};
