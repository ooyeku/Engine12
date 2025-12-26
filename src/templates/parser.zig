const std = @import("std");
const ast = @import("ast.zig");

pub const Parser = struct {
    pub fn parse(comptime template: []const u8) !ast.TemplateAST {
        @setEvalBranchQuota(1000000);
        const parse_result = try parseNodes(template, 0);
        return ast.TemplateAST.init(parse_result.nodes);
    }

    fn parseNodes(
        comptime template: []const u8,
        comptime start: usize,
    ) !struct {
        nodes: []const ast.TemplateAST.Node,
        end_pos: usize,
    } {
        var result: []const ast.TemplateAST.Node = &[_]ast.TemplateAST.Node{};
        var i: usize = start;
        var end_pos: usize = start;

        while (i < template.len) {
            const var_start = std.mem.indexOf(u8, template[i..], "{{");
            const block_start = std.mem.indexOf(u8, template[i..], "{%");
            const comment_start = std.mem.indexOf(u8, template[i..], "{#");

            var next_token: ?struct { start: usize, kind: enum { variable, block, comment } } = null;

            // Find the earliest token - all positions are relative to i
            if (var_start) |vs| {
                next_token = .{ .start = i + vs, .kind = .variable };
            }
            if (block_start) |bs| {
                if (next_token == null or i + bs < next_token.?.start) {
                    next_token = .{ .start = i + bs, .kind = .block };
                }
            }
            if (comment_start) |cs| {
                if (next_token == null or i + cs < next_token.?.start) {
                    next_token = .{ .start = i + cs, .kind = .comment };
                }
            }

            if (next_token) |token| {
                if (token.start > i) {
                    const text_start = i;
                    const text_end = token.start;
                    const text = template[text_start..text_end];
                    if (text.len > 0) {
                        result = result ++ &[_]ast.TemplateAST.Node{.{ .text = text }};
                    }
                }

                switch (token.kind) {
                    .block => {
                        const block_end = std.mem.indexOf(u8, template[token.start + 2 ..], "%}") orelse {
                            return error.UnclosedBlock;
                        };
                        const block_content = template[token.start + 2 .. token.start + 2 + block_end];
                        const block_end_pos = token.start + 2 + block_end + 2;

                        const trimmed = std.mem.trim(u8, block_content, " \t\n");
                        if (std.mem.startsWith(u8, trimmed, "if")) {
                            const if_result = try parseIfBlock(template, block_end_pos);
                            result = result ++ &[_]ast.TemplateAST.Node{.{ .if_block = if_result.block }};
                            i = if_result.end_pos;
                            end_pos = i;
                        } else if (std.mem.startsWith(u8, trimmed, "for")) {
                            const for_result = try parseForBlock(template, block_end_pos);
                            result = result ++ &[_]ast.TemplateAST.Node{.{ .for_block = for_result.block }};
                            i = for_result.end_pos;
                            end_pos = i;
                        } else if (std.mem.startsWith(u8, trimmed, "include")) {
                            const include_node = try parseInclude(block_content);
                            result = result ++ &[_]ast.TemplateAST.Node{.{ .include = include_node }};
                            i = block_end_pos;
                            end_pos = i;
                        } else if (std.mem.startsWith(u8, trimmed, "extends")) {
                            const extends_node = try parseExtends(block_content);
                            result = result ++ &[_]ast.TemplateAST.Node{.{ .extends = extends_node }};
                            i = block_end_pos;
                            end_pos = i;
                        } else if (std.mem.startsWith(u8, trimmed, "block")) {
                            const block_result = try parseBlock(template, block_end_pos);
                            result = result ++ &[_]ast.TemplateAST.Node{.{ .block = block_result.block }};
                            i = block_result.end_pos;
                            end_pos = i;
                        } else if (std.mem.startsWith(u8, trimmed, "endblock")) {
                            end_pos = i;
                            break;
                        } else if (std.mem.startsWith(u8, trimmed, "endif") or std.mem.startsWith(u8, trimmed, "endfor")) {
                            end_pos = i;
                            break;
                        } else if (std.mem.startsWith(u8, trimmed, "else") or std.mem.startsWith(u8, trimmed, "elif")) {
                            end_pos = i;
                            break;
                        } else {
                            return error.InvalidIfSyntax;
                        }
                    },
                    .variable => {
                        const var_end = std.mem.indexOf(u8, template[token.start + 2 ..], "}}") orelse {
                            return error.UnclosedBlock;
                        };
                        const var_content = template[token.start + 2 .. token.start + 2 + var_end];

                        const is_raw = var_content.len > 0 and var_content[0] == '!';
                        const var_str = if (is_raw) var_content[1..] else var_content;

                        const var_node = try parseVariable(std.mem.trim(u8, var_str, " \t\n"));
                        if (is_raw) {
                            result = result ++ &[_]ast.TemplateAST.Node{.{ .raw_variable = var_node }};
                        } else {
                            result = result ++ &[_]ast.TemplateAST.Node{.{ .variable = var_node }};
                        }

                        i = token.start + 2 + var_end + 2;
                        end_pos = i;
                    },
                    .comment => {
                        // Find closing #}
                        const comment_end = std.mem.indexOf(u8, template[token.start + 2 ..], "#}") orelse {
                            return error.UnclosedBlock;
                        };
                        const comment_content = template[token.start + 2 .. token.start + 2 + comment_end];

                        result = result ++ &[_]ast.TemplateAST.Node{.{ .comment = .{ .content = comment_content } }};
                        i = token.start + 2 + comment_end + 2;
                        end_pos = i;
                    },
                }
            } else {
                if (i < template.len) {
                    const text = template[i..];
                    if (text.len > 0) {
                        result = result ++ &[_]ast.TemplateAST.Node{.{ .text = text }};
                    }
                }
                end_pos = template.len;
                break;
            }
        }

        return .{
            .nodes = result,
            .end_pos = end_pos,
        };
    }

    fn parseIfBlock(comptime template: []const u8, comptime start: usize) !struct {
        block: ast.TemplateAST.IfBlock,
        end_pos: usize,
    } {
        const if_start = start - 2; // Go back to {% if
        const if_block_start = std.mem.indexOf(u8, template[if_start..], "{% if") orelse {
            return error.InvalidIfSyntax;
        };
        const if_tag_start = if_start + if_block_start;
        const if_tag_end = std.mem.indexOf(u8, template[if_tag_start + 5 ..], "%}") orelse {
            return error.UnclosedBlock;
        };
        const if_content = template[if_tag_start + 5 .. if_tag_start + 5 + if_tag_end];

        const condition_str = std.mem.trim(u8, if_content, " \t\n");
        const condition = try parseCondition(condition_str);

        const true_block_result = try parseNodes(template, if_tag_start + 5 + if_tag_end + 2);
        const content_end = true_block_result.end_pos;
        const true_block = ast.TemplateAST.init(true_block_result.nodes);

        var false_block: ?ast.TemplateAST = null;
        var final_end_pos = content_end;

        const else_pos = std.mem.indexOf(u8, template[content_end..], "{% else");
        const endif_pos = std.mem.indexOf(u8, template[content_end..], "{% endif");

        if (else_pos) |ep| {
            if (endif_pos == null or ep < endif_pos.?) {
                const else_tag_start = content_end + ep;
                const else_tag_end = std.mem.indexOf(u8, template[else_tag_start + 7 ..], "%}") orelse {
                    return error.UnclosedBlock;
                };
                const else_content_start = else_tag_start + 7 + else_tag_end + 2;

                const false_block_result = try parseNodes(template, else_content_start);
                const false_end_pos = false_block_result.end_pos;
                false_block = ast.TemplateAST.init(false_block_result.nodes);

                const endif_pos_after_else = std.mem.indexOf(u8, template[false_end_pos..], "{% endif") orelse {
                    return error.UnclosedBlock;
                };
                const endif_tag_start = false_end_pos + endif_pos_after_else;
                const endif_tag_end = std.mem.indexOf(u8, template[endif_tag_start + 8 ..], "%}") orelse {
                    return error.UnclosedBlock;
                };
                final_end_pos = endif_tag_start + 8 + endif_tag_end + 2;
            } else {
                const endif_tag_start = content_end + endif_pos.?;
                const endif_tag_end = std.mem.indexOf(u8, template[endif_tag_start + 8 ..], "%}") orelse {
                    return error.UnclosedBlock;
                };
                final_end_pos = endif_tag_start + 8 + endif_tag_end + 2;
            }
        } else if (endif_pos) |ep| {
            const endif_tag_start = content_end + ep;
            const endif_tag_end = std.mem.indexOf(u8, template[endif_tag_start + 8 ..], "%}") orelse {
                return error.UnclosedBlock;
            };
            final_end_pos = endif_tag_start + 8 + endif_tag_end + 2;
        } else {
            return error.UnclosedBlock;
        }

        return .{
            .block = ast.TemplateAST.IfBlock{
                .condition = ast.TemplateAST.Condition{ .simple = condition },
                .true_block = true_block,
                .elif_blocks = &[_]ast.TemplateAST.ElifBlock{},
                .false_block = false_block,
            },
            .end_pos = final_end_pos,
        };
    }

    fn parseForBlock(comptime template: []const u8, comptime start: usize) !struct {
        block: ast.TemplateAST.ForBlock,
        end_pos: usize,
    } {
        const for_start = start - 2; // Go back to {% for
        const for_block_start = std.mem.indexOf(u8, template[for_start..], "{% for") orelse {
            return error.InvalidForSyntax;
        };
        const for_tag_start = for_start + for_block_start;
        const for_tag_end = std.mem.indexOf(u8, template[for_tag_start + 6 ..], "%}") orelse {
            return error.UnclosedBlock;
        };
        const for_content = template[for_tag_start + 6 .. for_tag_start + 6 + for_tag_end];

        const trimmed = std.mem.trim(u8, for_content, " \t\n");

        const pipe_pos = std.mem.indexOfScalar(u8, trimmed, '|') orelse {
            return error.InvalidForSyntax;
        };

        const collection_str = std.mem.trim(u8, trimmed[0..pipe_pos], " \t\n");
        const collection_path = try parseVariablePath(collection_str);

        const after_pipe = trimmed[pipe_pos + 1 ..];
        const item_pipe_pos = std.mem.indexOfScalar(u8, after_pipe, '|') orelse {
            return error.InvalidForSyntax;
        };
        const item_name = std.mem.trim(u8, after_pipe[0..item_pipe_pos], " \t\n");

        const block_result = try parseNodes(template, for_tag_start + 6 + for_tag_end + 2);
        const content_end = block_result.end_pos;
        const block = ast.TemplateAST.init(block_result.nodes);

        const endfor_pos = std.mem.indexOf(u8, template[content_end..], "{% endfor") orelse {
            return error.UnclosedBlock;
        };
        const endfor_tag_start = content_end + endfor_pos;
        const endfor_tag_end = std.mem.indexOf(u8, template[endfor_tag_start + 9 ..], "%}") orelse {
            return error.UnclosedBlock;
        };
        const final_end_pos = endfor_tag_start + 9 + endfor_tag_end + 2;

        return .{
            .block = ast.TemplateAST.ForBlock{
                .collection_path = collection_path,
                .item_name = item_name,
                .block = block,
                .else_block = null,
            },
            .end_pos = final_end_pos,
        };
    }

    fn appendNode(
        existing: []const ast.TemplateAST.Node,
        new_node: ast.TemplateAST.Node,
    ) []const ast.TemplateAST.Node {
        comptime {
            return existing ++ &[_]ast.TemplateAST.Node{new_node};
        }
    }

    /// Parse a condition expression: simple variable, negation, or comparison
    fn parseCondition(comptime input: []const u8) !ast.TemplateAST.Condition {
        const trimmed = std.mem.trim(u8, input, " \t\n");

        // Check for negation: "not .variable"
        if (std.mem.startsWith(u8, trimmed, "not ")) {
            const inner_str = std.mem.trim(u8, trimmed[4..], " \t\n");
            const inner_var = try parseVariable(inner_str);
            return ast.TemplateAST.Condition{ .negated = .{ .inner = inner_var } };
        }

        // Check for comparison operators (in order of specificity)
        const operators = [_]struct { str: []const u8, op: ast.TemplateAST.ComparisonOp }{
            .{ .str = "==", .op = .eq },
            .{ .str = "!=", .op = .ne },
            .{ .str = "<=", .op = .le },
            .{ .str = ">=", .op = .ge },
            .{ .str = "<", .op = .lt },
            .{ .str = ">", .op = .gt },
        };

        for (operators) |op_info| {
            if (std.mem.indexOf(u8, trimmed, op_info.str)) |pos| {
                const left_str = std.mem.trim(u8, trimmed[0..pos], " \t\n");
                const right_str = std.mem.trim(u8, trimmed[pos + op_info.str.len ..], " \t\n");

                const left_var = try parseVariable(left_str);
                const right_value = parseConditionValue(right_str);

                return ast.TemplateAST.Condition{ .comparison = .{
                    .left = left_var,
                    .operator = op_info.op,
                    .right = right_value,
                } };
            }
        }

        // Simple variable condition
        const var_node = try parseVariable(trimmed);
        return ast.TemplateAST.Condition{ .simple = var_node };
    }

    /// Parse the right-hand side of a comparison: variable, string literal, int, or bool
    fn parseConditionValue(comptime input: []const u8) ast.TemplateAST.ComparisonValue {
        const trimmed = std.mem.trim(u8, input, " \t\n");

        // String literal: "value" or 'value'
        if ((trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
            (trimmed.len >= 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))
        {
            return .{ .literal_string = trimmed[1 .. trimmed.len - 1] };
        }

        // Boolean literal
        if (std.mem.eql(u8, trimmed, "true")) {
            return .{ .literal_bool = true };
        }
        if (std.mem.eql(u8, trimmed, "false")) {
            return .{ .literal_bool = false };
        }

        // Try integer
        if (std.fmt.parseInt(i64, trimmed, 10)) |int_val| {
            return .{ .literal_int = int_val };
        } else |_| {}

        // Fall back to variable
        if (parseVariable(trimmed)) |var_node| {
            return .{ .variable = var_node };
        } else |_| {}

        // Default to empty string literal
        return .{ .literal_string = "" };
    }

    fn parseVariable(comptime input: []const u8) !ast.TemplateAST.VariableNode {
        const pipe_pos = std.mem.indexOfScalar(u8, input, '|');

        const var_path_str = if (pipe_pos) |pos|
            std.mem.trim(u8, input[0..pos], " \t\n")
        else
            std.mem.trim(u8, input, " \t\n");

        const path = try parseVariablePath(var_path_str);

        var filters: []const ast.TemplateAST.Filter = &[_]ast.TemplateAST.Filter{};
        if (pipe_pos) |pos| {
            const filter_str = std.mem.trim(u8, input[pos + 1 ..], " \t\n");
            filters = try parseFilters(filter_str);
        }

        return ast.TemplateAST.VariableNode{
            .path = path,
            .filters = filters,
        };
    }

    fn parseVariablePath(comptime path_str: []const u8) ![]const []const u8 {
        if (path_str.len == 0) {
            return error.InvalidVariableSyntax;
        }

        if (std.mem.startsWith(u8, path_str, "../")) {
            const remaining = path_str[3..]; // Skip "../"
            if (remaining.len == 0) {
                return &[_][]const u8{".."};
            }

            if (remaining[0] != '.') {
                return error.InvalidVariableSyntax;
            }

            const rest_path = try parseVariablePath(remaining);

            var parts: []const []const u8 = &[_][]const u8{".."};
            for (rest_path) |part| {
                parts = parts ++ &[_][]const u8{part};
            }
            return parts;
        }

        if (path_str[0] != '.') {
            return error.InvalidVariableSyntax;
        }

        if (path_str.len == 1) {
            return &[_][]const u8{};
        }

        var parts: []const []const u8 = &[_][]const u8{};
        var i: usize = 1; // Skip leading dot
        var start: usize = 1;

        while (i < path_str.len) {
            if (path_str[i] == '.') {
                if (start < i) {
                    parts = parts ++ &[_][]const u8{path_str[start..i]};
                }
                start = i + 1;
            }
            i += 1;
        }

        if (start < path_str.len) {
            parts = parts ++ &[_][]const u8{path_str[start..]};
        }

        return parts;
    }

    fn parseFilters(comptime filter_str: []const u8) ![]const ast.TemplateAST.Filter {
        var filters_result: []const ast.TemplateAST.Filter = &[_]ast.TemplateAST.Filter{};
        var i: usize = 0;
        var start: usize = 0;

        while (i < filter_str.len) {
            if (filter_str[i] == '|') {
                const filter_with_args = std.mem.trim(u8, filter_str[start..i], " \t\n");
                if (filter_with_args.len > 0) {
                    const parsed = parseFilterWithArgs(filter_with_args);
                    filters_result = filters_result ++ &[_]ast.TemplateAST.Filter{parsed};
                }
                start = i + 1;
            }
            i += 1;
        }

        const final_filter_str = std.mem.trim(u8, filter_str[start..], " \t\n");
        if (final_filter_str.len > 0) {
            const parsed = parseFilterWithArgs(final_filter_str);
            filters_result = filters_result ++ &[_]ast.TemplateAST.Filter{parsed};
        }

        return filters_result;
    }

    /// Parse a filter with optional arguments (e.g., "truncate:50" or "replace:old:new")
    fn parseFilterWithArgs(comptime filter_str: []const u8) ast.TemplateAST.Filter {
        // Find first colon for arg separator
        const colon_pos = std.mem.indexOfScalar(u8, filter_str, ':');

        if (colon_pos) |pos| {
            const filter_name = std.mem.trim(u8, filter_str[0..pos], " \t\n");
            const args_str = filter_str[pos + 1 ..];

            // Parse args separated by colons
            var args: []const []const u8 = &[_][]const u8{};
            var arg_start: usize = 0;
            var j: usize = 0;

            while (j < args_str.len) {
                if (args_str[j] == ':') {
                    const arg = std.mem.trim(u8, args_str[arg_start..j], " \t\n");
                    if (arg.len > 0) {
                        args = args ++ &[_][]const u8{arg};
                    }
                    arg_start = j + 1;
                }
                j += 1;
            }

            // Add final arg
            const final_arg = std.mem.trim(u8, args_str[arg_start..], " \t\n");
            if (final_arg.len > 0) {
                args = args ++ &[_][]const u8{final_arg};
            }

            return .{
                .name = filter_name,
                .args = args,
            };
        } else {
            // No args
            const filter_name = std.mem.trim(u8, filter_str, " \t\n");
            return .{
                .name = filter_name,
                .args = &[_][]const u8{},
            };
        }
    }

    fn parseInclude(comptime block_content: []const u8) !ast.TemplateAST.IncludeNode {
        const trimmed = std.mem.trim(u8, block_content, " \t\n");
        if (!std.mem.startsWith(u8, trimmed, "include")) {
            return error.InvalidIncludePath;
        }

        const after_include = std.mem.trim(u8, trimmed[7..], " \t\n");

        const quote_start = std.mem.indexOfScalar(u8, after_include, '"') orelse {
            return error.InvalidIncludePath;
        };
        const quote_end = std.mem.indexOfScalar(u8, after_include[quote_start + 1 ..], '"') orelse {
            return error.InvalidIncludePath;
        };

        const file_path = after_include[quote_start + 1 .. quote_start + 1 + quote_end];

        if (std.mem.indexOf(u8, file_path, "..") != null) {
            return error.InvalidIncludePath;
        }

        return ast.TemplateAST.IncludeNode{
            .file_path = file_path,
            .params = &[_]ast.TemplateAST.IncludeParam{},
        };
    }

    /// Parse {% extends "base.zt.html" %}
    fn parseExtends(comptime block_content: []const u8) !ast.TemplateAST.ExtendsNode {
        const trimmed = std.mem.trim(u8, block_content, " \t\n");
        if (!std.mem.startsWith(u8, trimmed, "extends")) {
            return error.InvalidExtendsSyntax;
        }

        const after_extends = std.mem.trim(u8, trimmed[7..], " \t\n");

        const quote_start = std.mem.indexOfScalar(u8, after_extends, '"') orelse {
            return error.InvalidExtendsSyntax;
        };
        const quote_end = std.mem.indexOfScalar(u8, after_extends[quote_start + 1 ..], '"') orelse {
            return error.InvalidExtendsSyntax;
        };

        const parent_path = after_extends[quote_start + 1 .. quote_start + 1 + quote_end];

        return ast.TemplateAST.ExtendsNode{
            .parent_path = parent_path,
        };
    }

    /// Parse {% block name %}...{% endblock %}
    fn parseBlock(comptime template: []const u8, comptime start: usize) !struct {
        block: ast.TemplateAST.BlockNode,
        end_pos: usize,
    } {
        const block_start = start - 2; // Go back to {% block
        const block_tag_start = std.mem.indexOf(u8, template[block_start..], "{% block") orelse {
            return error.InvalidBlockSyntax;
        };
        const block_tag_actual_start = block_start + block_tag_start;
        const block_tag_end = std.mem.indexOf(u8, template[block_tag_actual_start + 8 ..], "%}") orelse {
            return error.UnclosedBlock;
        };
        const block_name_content = template[block_tag_actual_start + 8 .. block_tag_actual_start + 8 + block_tag_end];
        const block_name = std.mem.trim(u8, block_name_content, " \t\n");

        const content_start = block_tag_actual_start + 8 + block_tag_end + 2;
        const content_result = try parseNodes(template, content_start);
        const content = ast.TemplateAST.init(content_result.nodes);
        const content_end = content_result.end_pos;

        const endblock_pos = std.mem.indexOf(u8, template[content_end..], "{% endblock") orelse {
            return error.UnclosedBlock;
        };
        const endblock_tag_start = content_end + endblock_pos;
        const endblock_tag_end = std.mem.indexOf(u8, template[endblock_tag_start + 11 ..], "%}") orelse {
            return error.UnclosedBlock;
        };
        const final_end_pos = endblock_tag_start + 11 + endblock_tag_end + 2;

        return .{
            .block = ast.TemplateAST.BlockNode{
                .name = block_name,
                .content = content,
            },
            .end_pos = final_end_pos,
        };
    }
};

test "parse simple text" {
    const ast_result = try Parser.parse("Hello World");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqual(ast_result.nodes[0], .text);
    try std.testing.expectEqualStrings(ast_result.nodes[0].text, "Hello World");
}

test "parse variable" {
    const ast_result = try Parser.parse("Hello {{ .name }}");
    try std.testing.expectEqual(ast_result.nodes.len, 3);
    try std.testing.expectEqualStrings(ast_result.nodes[0].text, "Hello ");
    try std.testing.expectEqual(ast_result.nodes[1], .variable);
    try std.testing.expectEqualStrings(ast_result.nodes[2].text, " ");
}

test "parse nested variable path" {
    const ast_result = try Parser.parse("{{ .user.name }}");
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.path.len, 2);
    try std.testing.expectEqualStrings(var_node.path[0], "user");
    try std.testing.expectEqualStrings(var_node.path[1], "name");
}

test "parse raw variable" {
    const ast_result = try Parser.parse("{{! .html }}");
    try std.testing.expectEqual(ast_result.nodes[0], .raw_variable);
}

test "parse filter" {
    const ast_result = try Parser.parse("{{ .name | uppercase }}");
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.filters.len, 1);
    try std.testing.expectEqualStrings(var_node.filters[0].name, "uppercase");
}

test "parse if block" {
    const ast_result = try Parser.parse("{% if .condition %}Yes{% endif %}");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqual(ast_result.nodes[0], .if_block);
}

test "parse for block" {
    const ast_result = try Parser.parse("{% for .items |item| %}{{ item }}{% endfor %}");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqual(ast_result.nodes[0], .for_block);
}


test "parse empty template" {
    const ast_result = try Parser.parse("");
    try std.testing.expectEqual(ast_result.nodes.len, 0);
}

test "parse multiple filters" {
    const ast_result = try Parser.parse("{{ .name | uppercase | trim }}");
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.filters.len, 2);
    try std.testing.expectEqualStrings(var_node.filters[0].name, "uppercase");
    try std.testing.expectEqualStrings(var_node.filters[1].name, "trim");
}

test "parse filter with args" {
    const ast_result = try Parser.parse("{{ .text | truncate:50 }}");
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.filters.len, 1);
    try std.testing.expectEqualStrings(var_node.filters[0].name, "truncate");
    try std.testing.expectEqual(var_node.filters[0].args.len, 1);
    try std.testing.expectEqualStrings(var_node.filters[0].args[0], "50");
}

test "parse filter with multiple args" {
    const ast_result = try Parser.parse("{{ .text | replace:old:new }}");
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.filters[0].args.len, 2);
    try std.testing.expectEqualStrings(var_node.filters[0].args[0], "old");
    try std.testing.expectEqualStrings(var_node.filters[0].args[1], "new");
}

test "parse comment" {
    const ast_result = try Parser.parse("{# this is a comment #}");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqual(ast_result.nodes[0], .comment);
}

test "parse comment with text" {
    const ast_result = try Parser.parse("before{# comment #}after");
    try std.testing.expectEqual(ast_result.nodes.len, 3);
    try std.testing.expectEqualStrings(ast_result.nodes[0].text, "before");
    try std.testing.expectEqual(ast_result.nodes[1], .comment);
    try std.testing.expectEqualStrings(ast_result.nodes[2].text, "after");
}

test "parse adjacent variables" {
    const ast_result = try Parser.parse("{{ .a }}{{ .b }}");
    try std.testing.expectEqual(ast_result.nodes.len, 2);
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
    try std.testing.expectEqual(ast_result.nodes[1], .variable);
}

test "parse if with else" {
    const ast_result = try Parser.parse("{% if .x %}yes{% else %}no{% endif %}");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqual(ast_result.nodes[0], .if_block);
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expect(if_node.false_block != null);
}

test "parse deeply nested path" {
    const ast_result = try Parser.parse("{{ .a.b.c.d }}");
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.path.len, 4);
    try std.testing.expectEqualStrings(var_node.path[0], "a");
    try std.testing.expectEqualStrings(var_node.path[3], "d");
}

test "parse mixed content" {
    const ast_result = try Parser.parse("<div>{{ .title }}</div>");
    try std.testing.expectEqual(ast_result.nodes.len, 3);
    try std.testing.expectEqualStrings(ast_result.nodes[0].text, "<div>");
    try std.testing.expectEqual(ast_result.nodes[1], .variable);
    try std.testing.expectEqualStrings(ast_result.nodes[2].text, "</div>");
}

test "parse whitespace in variable tags" {
    const ast_result = try Parser.parse("{{   .name   }}");
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqualStrings(var_node.path[0], "name");
}

test "parse extends directive" {
    const ast_result = try Parser.parse(
        \\{% extends "base.zt.html" %}
    );
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqual(ast_result.nodes[0], .extends);
    try std.testing.expectEqualStrings(ast_result.nodes[0].extends.parent_path, "base.zt.html");
}

test "parse block directive" {
    const ast_result = try Parser.parse("{% block content %}Hello{% endblock %}");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqual(ast_result.nodes[0], .block);
    try std.testing.expectEqualStrings(ast_result.nodes[0].block.name, "content");
}

test "parse include directive" {
    const ast_result = try Parser.parse(
        \\{% include "header.zt.html" %}
    );
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqual(ast_result.nodes[0], .include);
    try std.testing.expectEqualStrings(ast_result.nodes[0].include.file_path, "header.zt.html");
}

test "parse condition - simple" {
    const ast_result = try Parser.parse("{% if .visible %}show{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition, .simple);
}

test "parse condition - negation" {
    const ast_result = try Parser.parse("{% if not .hidden %}show{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition, .negated);
}

test "parse condition - comparison eq" {
    const ast_result = try Parser.parse(
        \\{% if .status == "active" %}active{% endif %}
    );
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition, .comparison);
}

test "parse for with item name" {
    const ast_result = try Parser.parse("{% for .todos |todo| %}{{ todo }}{% endfor %}");
    const for_node = ast_result.nodes[0].for_block;
    try std.testing.expectEqualStrings(for_node.item_name, "todo");
    try std.testing.expectEqualStrings(for_node.collection_path[0], "todos");
}

test "parse text only template" {
    const ast_result = try Parser.parse("Just plain text with no tags");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqualStrings(ast_result.nodes[0].text, "Just plain text with no tags");
}

test "parse multiple variables in sequence" {
    const ast_result = try Parser.parse("{{ .a }}{{ .b }}{{ .c }}");
    try std.testing.expectEqual(ast_result.nodes.len, 3);
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
    try std.testing.expectEqual(ast_result.nodes[1], .variable);
    try std.testing.expectEqual(ast_result.nodes[2], .variable);
}

test "parse variable at template start" {
    const ast_result = try Parser.parse("{{ .name }} text");
    try std.testing.expectEqual(ast_result.nodes.len, 2);
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
    try std.testing.expectEqualStrings(ast_result.nodes[1].text, " text");
}

test "parse variable at template end" {
    const ast_result = try Parser.parse("text {{ .name }}");
    try std.testing.expectEqual(ast_result.nodes.len, 2);
    try std.testing.expectEqualStrings(ast_result.nodes[0].text, "text ");
    try std.testing.expectEqual(ast_result.nodes[1], .variable);
}

test "parse single variable only" {
    const ast_result = try Parser.parse("{{ .value }}");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
}

test "parse raw variable with whitespace" {
    const ast_result = try Parser.parse("{{!  .html  }}");
    try std.testing.expectEqual(ast_result.nodes[0], .raw_variable);
    const var_node = ast_result.nodes[0].raw_variable;
    try std.testing.expectEqualStrings(var_node.path[0], "html");
}

test "parse raw variable with filter" {
    const ast_result = try Parser.parse("{{! .html | uppercase }}");
    try std.testing.expectEqual(ast_result.nodes[0], .raw_variable);
    const var_node = ast_result.nodes[0].raw_variable;
    try std.testing.expectEqual(var_node.filters.len, 1);
    try std.testing.expectEqualStrings(var_node.filters[0].name, "uppercase");
}

test "parse variable with three filters" {
    const ast_result = try Parser.parse("{{ .name | trim | uppercase | escape }}");
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.filters.len, 3);
    try std.testing.expectEqualStrings(var_node.filters[0].name, "trim");
    try std.testing.expectEqualStrings(var_node.filters[1].name, "uppercase");
    try std.testing.expectEqualStrings(var_node.filters[2].name, "escape");
}

test "parse filter with three args" {
    const ast_result = try Parser.parse("{{ .text | slice:0:10:2 }}");
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.filters[0].args.len, 3);
    try std.testing.expectEqualStrings(var_node.filters[0].args[0], "0");
    try std.testing.expectEqualStrings(var_node.filters[0].args[1], "10");
    try std.testing.expectEqualStrings(var_node.filters[0].args[2], "2");
}

test "parse filter chain with args" {
    const ast_result = try Parser.parse("{{ .text | truncate:50 | uppercase }}");
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.filters.len, 2);
    try std.testing.expectEqualStrings(var_node.filters[0].name, "truncate");
    try std.testing.expectEqual(var_node.filters[0].args.len, 1);
    try std.testing.expectEqualStrings(var_node.filters[1].name, "uppercase");
    try std.testing.expectEqual(var_node.filters[1].args.len, 0);
}

test "parse condition - not equal" {
    const ast_result = try Parser.parse(
        \\{% if .status != "inactive" %}active{% endif %}
    );
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition, .comparison);
    try std.testing.expectEqual(if_node.condition.comparison.operator, .ne);
}

test "parse condition - less than" {
    const ast_result = try Parser.parse("{% if .age < 18 %}minor{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition, .comparison);
    try std.testing.expectEqual(if_node.condition.comparison.operator, .lt);
    try std.testing.expectEqual(if_node.condition.comparison.right, .literal_int);
    try std.testing.expectEqual(if_node.condition.comparison.right.literal_int, 18);
}

test "parse condition - greater than" {
    const ast_result = try Parser.parse("{% if .score > 100 %}high{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition.comparison.operator, .gt);
}

test "parse condition - less than or equal" {
    const ast_result = try Parser.parse("{% if .count <= 10 %}few{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition.comparison.operator, .le);
}

test "parse condition - greater than or equal" {
    const ast_result = try Parser.parse("{% if .age >= 21 %}adult{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition.comparison.operator, .ge);
}

test "parse condition - compare with boolean true" {
    const ast_result = try Parser.parse("{% if .active == true %}yes{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition.comparison.right, .literal_bool);
    try std.testing.expectEqual(if_node.condition.comparison.right.literal_bool, true);
}

test "parse condition - compare with boolean false" {
    const ast_result = try Parser.parse("{% if .disabled == false %}enabled{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition.comparison.right.literal_bool, false);
}

test "parse condition - compare with string single quotes" {
    const ast_result = try Parser.parse("{% if .type == 'admin' %}yes{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition.comparison.right, .literal_string);
    try std.testing.expectEqualStrings(if_node.condition.comparison.right.literal_string, "admin");
}

test "parse condition - compare with variable" {
    const ast_result = try Parser.parse("{% if .a == .b %}match{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition.comparison.right, .variable);
}

test "parse condition - compare with negative integer" {
    const ast_result = try Parser.parse("{% if .temp < -10 %}cold{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition.comparison.right.literal_int, -10);
}

test "parse if block with variables inside" {
    const ast_result = try Parser.parse("{% if .show %}Value: {{ .value }}{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.true_block.nodes.len, 2);
    try std.testing.expectEqualStrings(if_node.true_block.nodes[0].text, "Value: ");
    try std.testing.expectEqual(if_node.true_block.nodes[1], .variable);
}

test "parse if block with comment inside" {
    const ast_result = try Parser.parse("{% if .x %}{# comment #}text{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.true_block.nodes.len, 2);
    try std.testing.expectEqual(if_node.true_block.nodes[0], .comment);
    try std.testing.expectEqualStrings(if_node.true_block.nodes[1].text, "text");
}

test "parse if with else and variables in both branches" {
    const ast_result = try Parser.parse("{% if .flag %}{{ .a }}{% else %}{{ .b }}{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.true_block.nodes.len, 1);
    try std.testing.expectEqual(if_node.true_block.nodes[0], .variable);
    try std.testing.expect(if_node.false_block != null);
    try std.testing.expectEqual(if_node.false_block.?.nodes.len, 1);
    try std.testing.expectEqual(if_node.false_block.?.nodes[0], .variable);
}

test "parse empty if block content" {
    const ast_result = try Parser.parse("{% if .x %}{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.true_block.nodes.len, 0);
}

test "parse empty else block content" {
    const ast_result = try Parser.parse("{% if .x %}content{% else %}{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expect(if_node.false_block != null);
    try std.testing.expectEqual(if_node.false_block.?.nodes.len, 0);
}

test "parse for block with nested variable" {
    const ast_result = try Parser.parse("{% for .users |user| %}{{ user.name }}{% endfor %}");
    const for_node = ast_result.nodes[0].for_block;
    try std.testing.expectEqual(for_node.block.nodes.len, 1);
    try std.testing.expectEqual(for_node.block.nodes[0], .variable);
}

test "parse for block with nested path in collection" {
    const ast_result = try Parser.parse("{% for .data.items |item| %}{{ item }}{% endfor %}");
    const for_node = ast_result.nodes[0].for_block;
    try std.testing.expectEqual(for_node.collection_path.len, 2);
    try std.testing.expectEqualStrings(for_node.collection_path[0], "data");
    try std.testing.expectEqualStrings(for_node.collection_path[1], "items");
}

test "parse for block with text and variable inside" {
    const ast_result = try Parser.parse("{% for .items |x| %}- {{ x }}{% endfor %}");
    const for_node = ast_result.nodes[0].for_block;
    try std.testing.expectEqual(for_node.block.nodes.len, 2);
    try std.testing.expectEqualStrings(for_node.block.nodes[0].text, "- ");
    try std.testing.expectEqual(for_node.block.nodes[1], .variable);
}

test "parse empty for block" {
    const ast_result = try Parser.parse("{% for .items |item| %}{% endfor %}");
    const for_node = ast_result.nodes[0].for_block;
    try std.testing.expectEqual(for_node.block.nodes.len, 0);
}

test "parse multiple comments" {
    const ast_result = try Parser.parse("{# first #}{# second #}{# third #}");
    try std.testing.expectEqual(ast_result.nodes.len, 3);
    try std.testing.expectEqual(ast_result.nodes[0], .comment);
    try std.testing.expectEqual(ast_result.nodes[1], .comment);
    try std.testing.expectEqual(ast_result.nodes[2], .comment);
}

test "parse comment with special characters" {
    const ast_result = try Parser.parse("{# <>&\"' #}");
    try std.testing.expectEqual(ast_result.nodes[0], .comment);
    try std.testing.expectEqualStrings(ast_result.nodes[0].comment.content, " <>&\"' ");
}

test "parse comment with newlines" {
    const ast_result = try Parser.parse(
        \\{# multi
        \\line
        \\comment #}
    );
    try std.testing.expectEqual(ast_result.nodes[0], .comment);
}

test "parse comment only template" {
    const ast_result = try Parser.parse("{# only comment #}");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqual(ast_result.nodes[0], .comment);
}

test "parse unicode in text" {
    const ast_result = try Parser.parse("Hello 世界 🌍");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqualStrings(ast_result.nodes[0].text, "Hello 世界 🌍");
}

test "parse unicode in variable path" {
    const ast_result = try Parser.parse("{{ .こんにちは }}");
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqualStrings(var_node.path[0], "こんにちは");
}

test "parse complex mixed template" {
    const ast_result = try Parser.parse(
        \\<div>
        \\  {# Header #}
        \\  <h1>{{ .title | uppercase }}</h1>
        \\  {% if .items %}
        \\    {% for .items |item| %}
        \\      <li>{{ item }}</li>
        \\    {% endfor %}
        \\  {% endif %}
        \\</div>
    );
    try std.testing.expect(ast_result.nodes.len > 0);
}

test "parse multiple blocks in sequence" {
    const ast_result = try Parser.parse("{% if .a %}A{% endif %}{% if .b %}B{% endif %}");
    try std.testing.expectEqual(ast_result.nodes.len, 2);
    try std.testing.expectEqual(ast_result.nodes[0], .if_block);
    try std.testing.expectEqual(ast_result.nodes[1], .if_block);
}

test "parse variable with very long path" {
    const ast_result = try Parser.parse("{{ .a.b.c.d.e.f.g.h }}");
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.path.len, 8);
    try std.testing.expectEqualStrings(var_node.path[0], "a");
    try std.testing.expectEqualStrings(var_node.path[7], "h");
}

test "parse single dot variable path" {
    const ast_result = try Parser.parse("{{ . }}");
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.path.len, 0);
}

test "parse parent path traversal" {
    const ast_result = try Parser.parse("{{ ../.name }}");
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.path.len, 2);
    try std.testing.expectEqualStrings(var_node.path[0], "..");
    try std.testing.expectEqualStrings(var_node.path[1], "name");
}

test "parse multiple parent traversals" {
    const ast_result = try Parser.parse("{{ ../../.value }}");
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.path.len, 3);
    try std.testing.expectEqualStrings(var_node.path[0], "..");
    try std.testing.expectEqualStrings(var_node.path[1], "..");
    try std.testing.expectEqualStrings(var_node.path[2], "value");
}

test "parse extends with single quotes not supported uses double" {
    const ast_result = try Parser.parse(
        \\{% extends "layout.zt.html" %}
    );
    try std.testing.expectEqual(ast_result.nodes[0], .extends);
}

test "parse block with content" {
    const ast_result = try Parser.parse("{% block main %}<p>Content</p>{% endblock %}");
    const block_node = ast_result.nodes[0].block;
    try std.testing.expectEqualStrings(block_node.name, "main");
    try std.testing.expectEqual(block_node.content.nodes.len, 1);
}

test "parse block with variable inside" {
    const ast_result = try Parser.parse("{% block title %}{{ .page_title }}{% endblock %}");
    const block_node = ast_result.nodes[0].block;
    try std.testing.expectEqual(block_node.content.nodes.len, 1);
    try std.testing.expectEqual(block_node.content.nodes[0], .variable);
}

test "parse multiple blocks" {
    const ast_result = try Parser.parse(
        \\{% block header %}H{% endblock %}{% block footer %}F{% endblock %}
    );
    try std.testing.expectEqual(ast_result.nodes.len, 2);
    try std.testing.expectEqual(ast_result.nodes[0], .block);
    try std.testing.expectEqual(ast_result.nodes[1], .block);
    try std.testing.expectEqualStrings(ast_result.nodes[0].block.name, "header");
    try std.testing.expectEqualStrings(ast_result.nodes[1].block.name, "footer");
}

test "parse empty block" {
    const ast_result = try Parser.parse("{% block empty %}{% endblock %}");
    const block_node = ast_result.nodes[0].block;
    try std.testing.expectEqual(block_node.content.nodes.len, 0);
}

test "parse include with path" {
    const ast_result = try Parser.parse(
        \\{% include "partials/navbar.zt.html" %}
    );
    const include_node = ast_result.nodes[0].include;
    try std.testing.expectEqualStrings(include_node.file_path, "partials/navbar.zt.html");
}

test "parse multiple includes" {
    const ast_result = try Parser.parse(
        \\{% include "header.zt.html" %}{% include "footer.zt.html" %}
    );
    try std.testing.expectEqual(ast_result.nodes.len, 2);
    try std.testing.expectEqual(ast_result.nodes[0], .include);
    try std.testing.expectEqual(ast_result.nodes[1], .include);
}

test "parse mix of all tag types" {
    const ast_result = try Parser.parse(
        \\Text{{ .var }}{# comment #}{% if .x %}yes{% endif %}{{! .raw }}
    );
    try std.testing.expectEqual(ast_result.nodes.len, 5);
    try std.testing.expectEqual(ast_result.nodes[0], .text);
    try std.testing.expectEqual(ast_result.nodes[1], .variable);
    try std.testing.expectEqual(ast_result.nodes[2], .comment);
    try std.testing.expectEqual(ast_result.nodes[3], .if_block);
    try std.testing.expectEqual(ast_result.nodes[4], .raw_variable);
}

test "parse newlines preserved in text" {
    const ast_result = try Parser.parse("line1\nline2\nline3");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqualStrings(ast_result.nodes[0].text, "line1\nline2\nline3");
}

test "parse tabs preserved in text" {
    const ast_result = try Parser.parse("\t\tindented");
    try std.testing.expectEqualStrings(ast_result.nodes[0].text, "\t\tindented");
}

test "parse special characters in text" {
    const ast_result = try Parser.parse("!@#$%^&*()_+-=[]{}|;:',.<>?/");
    try std.testing.expectEqualStrings(ast_result.nodes[0].text, "!@#$%^&*()_+-=[]{}|;:',.<>?/");
}

test "parse html tags in text" {
    const ast_result = try Parser.parse("<div class=\"container\"><p>Text</p></div>");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqualStrings(ast_result.nodes[0].text, "<div class=\"container\"><p>Text</p></div>");
}

test "parse condition with whitespace around operator" {
    const ast_result = try Parser.parse("{% if .count   ==   5 %}match{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition.comparison.operator, .eq);
    try std.testing.expectEqual(if_node.condition.comparison.right.literal_int, 5);
}

test "parse filter with whitespace around colon" {
    const ast_result = try Parser.parse("{{ .text | truncate : 50 }}");
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqualStrings(var_node.filters[0].name, "truncate");
    try std.testing.expectEqual(var_node.filters[0].args.len, 1);
}

test "parse deeply nested variable in nested context" {
    const ast_result = try Parser.parse("{{ .user.profile.settings.theme.color }}");
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.path.len, 5);
    try std.testing.expectEqualStrings(var_node.path[4], "color");
}

test "parse if block at template start" {
    const ast_result = try Parser.parse("{% if .x %}content{% endif %} after");
    try std.testing.expectEqual(ast_result.nodes.len, 2);
    try std.testing.expectEqual(ast_result.nodes[0], .if_block);
    try std.testing.expectEqualStrings(ast_result.nodes[1].text, " after");
}

test "parse if block at template end" {
    const ast_result = try Parser.parse("before {% if .x %}content{% endif %}");
    try std.testing.expectEqual(ast_result.nodes.len, 2);
    try std.testing.expectEqualStrings(ast_result.nodes[0].text, "before ");
    try std.testing.expectEqual(ast_result.nodes[1], .if_block);
}

test "parse for block at template boundaries" {
    const ast_result = try Parser.parse("{% for .items |i| %}{{ i }}{% endfor %}");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqual(ast_result.nodes[0], .for_block);
}

test "parse comment between variables" {
    const ast_result = try Parser.parse("{{ .a }}{# separator #}{{ .b }}");
    try std.testing.expectEqual(ast_result.nodes.len, 3);
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
    try std.testing.expectEqual(ast_result.nodes[1], .comment);
    try std.testing.expectEqual(ast_result.nodes[2], .variable);
}

test "parse variable followed by text followed by variable" {
    const ast_result = try Parser.parse("{{ .first }} middle {{ .second }}");
    try std.testing.expectEqual(ast_result.nodes.len, 3);
    try std.testing.expectEqual(ast_result.nodes[0], .variable);
    try std.testing.expectEqualStrings(ast_result.nodes[1].text, " middle ");
    try std.testing.expectEqual(ast_result.nodes[2], .variable);
}

test "parse comparison with empty string" {
    const ast_result = try Parser.parse(
        \\{% if .name == "" %}empty{% endif %}
    );
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition.comparison.right, .literal_string);
    try std.testing.expectEqualStrings(if_node.condition.comparison.right.literal_string, "");
}

test "parse comparison with zero" {
    const ast_result = try Parser.parse("{% if .count == 0 %}none{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition.comparison.right.literal_int, 0);
}

test "parse nested variable path with filter" {
    const ast_result = try Parser.parse("{{ .user.name | uppercase }}");
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.path.len, 2);
    try std.testing.expectEqual(var_node.filters.len, 1);
}

test "parse raw variable with nested path" {
    const ast_result = try Parser.parse("{{! .data.html }}");
    const var_node = ast_result.nodes[0].raw_variable;
    try std.testing.expectEqual(var_node.path.len, 2);
    try std.testing.expectEqualStrings(var_node.path[0], "data");
    try std.testing.expectEqualStrings(var_node.path[1], "html");
}

test "parse if with negation of nested path" {
    const ast_result = try Parser.parse("{% if not .user.active %}inactive{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition, .negated);
}

test "parse long string literal in comparison" {
    const ast_result = try Parser.parse(
        \\{% if .description == "This is a very long description for testing" %}match{% endif %}
    );
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqualStrings(if_node.condition.comparison.right.literal_string, "This is a very long description for testing");
}

test "parse comparison with string containing spaces" {
    const ast_result = try Parser.parse(
        \\{% if .role == "super admin" %}yes{% endif %}
    );
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqualStrings(if_node.condition.comparison.right.literal_string, "super admin");
}

test "parse filter name with underscores" {
    const ast_result = try Parser.parse("{{ .text | to_upper_case }}");
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqualStrings(var_node.filters[0].name, "to_upper_case");
}

test "parse filter name with numbers" {
    const ast_result = try Parser.parse("{{ .data | base64_encode }}");
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqualStrings(var_node.filters[0].name, "base64_encode");
}

test "parse large integer in comparison" {
    const ast_result = try Parser.parse("{% if .id > 999999 %}large{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition.comparison.right.literal_int, 999999);
}

test "parse whitespace variations in if block" {
    const ast_result = try Parser.parse("{%if .x%}yes{%endif%}");
    try std.testing.expectEqual(ast_result.nodes.len, 1);
    try std.testing.expectEqual(ast_result.nodes[0], .if_block);
}

test "parse whitespace variations in for block" {
    const ast_result = try Parser.parse("{%for .items|item|%}{{ item }}{%endfor%}");
    try std.testing.expectEqual(ast_result.nodes[0], .for_block);
}

test "parse variable path with single character components" {
    const ast_result = try Parser.parse("{{ .a.b.c }}");
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.path.len, 3);
    try std.testing.expectEqualStrings(var_node.path[0], "a");
    try std.testing.expectEqualStrings(var_node.path[1], "b");
    try std.testing.expectEqualStrings(var_node.path[2], "c");
}

test "parse comment with curly braces inside" {
    const ast_result = try Parser.parse("{# { } {{ }} #}");
    try std.testing.expectEqual(ast_result.nodes[0], .comment);
    try std.testing.expectEqualStrings(ast_result.nodes[0].comment.content, " { } {{ }} ");
}

test "parse text with curly brace not forming tag" {
    const ast_result = try Parser.parse("{ single brace }");
    try std.testing.expectEqualStrings(ast_result.nodes[0].text, "{ single brace }");
}

test "parse extends and blocks together" {
    const ast_result = try Parser.parse(
        \\{% extends "base.zt.html" %}{% block content %}Hello{% endblock %}
    );
    try std.testing.expectEqual(ast_result.nodes.len, 2);
    try std.testing.expectEqual(ast_result.nodes[0], .extends);
    try std.testing.expectEqual(ast_result.nodes[1], .block);
}

test "parse complex real world template structure" {
    const ast_result = try Parser.parse(
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>{{ .title }}</title></head>
        \\<body>
        \\  {% if .user %}
        \\    <p>Welcome, {{ .user.name | capitalize }}!</p>
        \\  {% else %}
        \\    <p>Please log in.</p>
        \\  {% endif %}
        \\  {% for .posts |post| %}
        \\    <article>
        \\      <h2>{{ post.title }}</h2>
        \\      <p>{{! post.content }}</p>
        \\    </article>
        \\  {% endfor %}
        \\</body>
        \\</html>
    );
    try std.testing.expect(ast_result.nodes.len > 5);
}

test "parse filter arg with special characters" {
    const ast_result = try Parser.parse("{{ .text | replace:,:; }}");
    const var_node = ast_result.nodes[0].variable;
    try std.testing.expectEqual(var_node.filters[0].args.len, 2);
    try std.testing.expectEqualStrings(var_node.filters[0].args[0], ",");
    try std.testing.expectEqualStrings(var_node.filters[0].args[1], ";");
}

test "parse comparison operator precedence - eq before others" {
    const ast_result = try Parser.parse("{% if .x == 5 %}yes{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqual(if_node.condition.comparison.operator, .eq);
}

test "parse empty string in single quotes" {
    const ast_result = try Parser.parse("{% if .name == '' %}empty{% endif %}");
    const if_node = ast_result.nodes[0].if_block;
    try std.testing.expectEqualStrings(if_node.condition.comparison.right.literal_string, "");
}

test "parse for with whitespace in delimiters" {
    const ast_result = try Parser.parse("{% for .items | item | %}{{ item }}{% endfor %}");
    const for_node = ast_result.nodes[0].for_block;
    try std.testing.expectEqualStrings(for_node.item_name, "item");
}
