const std = @import("std");
const ast = @import("ast.zig");

pub const TypeChecker = struct {
    pub fn inferRequiredType(comptime ast_tree: ast.TemplateAST) type {
        _ = ast_tree;

        return struct {};
    }

    pub fn validateContext(
        comptime ast_tree: ast.TemplateAST,
        comptime context_type: type,
    ) void {
        inline for (ast_tree.nodes) |node| {
            validateNode(node, context_type);
        }
    }

    fn validateNode(
        comptime node: ast.TemplateAST.Node,
        comptime context_type: type,
    ) void {
        switch (node) {
            .variable => |var_node| {
                validateVariablePath(var_node.path, context_type);
            },
            .raw_variable => |var_node| {
                validateVariablePath(var_node.path, context_type);
            },
            .if_block => |if_node| {
                validateCondition(if_node.condition, context_type);
                validateContext(if_node.true_block, context_type);
                for (if_node.elif_blocks) |elif_block| {
                    validateCondition(elif_block.condition, context_type);
                    validateContext(elif_block.block, context_type);
                }
                if (if_node.false_block) |false_block| {
                    validateContext(false_block, context_type);
                }
            },
            .for_block => |for_node| {
                validateVariablePath(for_node.collection_path, context_type);
                validateContext(for_node.block, context_type);
                if (for_node.else_block) |else_block| {
                    validateContext(else_block, context_type);
                }
            },
            .include => |_| {},
            .text => |_| {},
            .comment => |_| {},
            .extends => |_| {},
            .block => |block_node| {
                validateContext(block_node.content, context_type);
            },
        }
    }

    fn validateCondition(
        comptime condition: ast.TemplateAST.Condition,
        comptime context_type: type,
    ) void {
        switch (condition) {
            .simple => |var_node| {
                validateVariablePath(var_node.path, context_type);
            },
            .negated => |neg| {
                validateVariablePath(neg.inner.path, context_type);
            },
            .comparison => |cmp| {
                validateVariablePath(cmp.left.path, context_type);
                switch (cmp.right) {
                    .variable => |v| validateVariablePath(v.path, context_type),
                    else => {},
                }
            },
        }
    }

    fn validateVariablePath(
        comptime path: []const []const u8,
        comptime context_type: type,
    ) void {
        if (path.len == 0) {
            return;
        }

        var current_type = context_type;
        var i: usize = 0;

        while (i < path.len) : (i += 1) {
            const field_name = path[i];

            const type_info = @typeInfo(current_type);
            switch (type_info) {
                .@"struct" => |struct_info| {
                    var field_found = false;
                    var field_type: type = void;

                    inline for (struct_info.fields) |field| {
                        if (std.mem.eql(u8, field.name, field_name)) {
                            field_found = true;
                            field_type = field.type;
                            break;
                        }
                    }

                    if (!field_found) {
                        @compileError("Template error: Context type '" ++ @typeName(context_type) ++ "' has no field '" ++ field_name ++ "'. " ++
                            "Available fields in " ++ @typeName(context_type) ++ ": check struct definition.");
                    }

                    const field_type_info = @typeInfo(field_type);
                    switch (field_type_info) {
                        .optional => |optional_info| {
                            current_type = optional_info.child;
                        },
                        else => {
                            current_type = field_type;
                        },
                    }

                    if (i == path.len - 1) {
                        return;
                    }

                    const next_type_info = @typeInfo(current_type);
                    switch (next_type_info) {
                        .array, .pointer => {
                            if (i < path.len - 1) {
                                @compileError("Template error: Cannot access field '" ++ path[i + 1] ++ "' on array/slice type '" ++ @typeName(current_type) ++ "'. " ++
                                    "Arrays and slices cannot be accessed like structs. Use iteration ({% for %}) to access array elements.");
                            }
                        },
                        else => {},
                    }
                },
                else => {
                    @compileError("Template error: Context type '" ++ @typeName(context_type) ++ "' must be a struct. " ++
                        "Templates require a struct context with named fields. Got: " ++ @typeName(context_type));
                },
            }
        }
    }
};

test "validate simple context" {
    comptime {
        const TestAST = ast.TemplateAST.init(&[_]ast.TemplateAST.Node{
            .{ .variable = ast.TemplateAST.VariableNode{
                .path = &[_][]const u8{"name"},
                .filters = &[_]ast.TemplateAST.Filter{},
            } },
        });

        const TestContext = struct {
            name: []const u8,
        };

        TypeChecker.validateContext(TestAST, TestContext);
    }
}

test "validate nested context" {
    comptime {
        const TestAST = ast.TemplateAST.init(&[_]ast.TemplateAST.Node{
            .{ .variable = ast.TemplateAST.VariableNode{
                .path = &[_][]const u8{ "user", "name" },
                .filters = &[_]ast.TemplateAST.Filter{},
            } },
        });

        const TestContext = struct {
            user: struct {
                name: []const u8,
            },
        };

        TypeChecker.validateContext(TestAST, TestContext);
    }
}
