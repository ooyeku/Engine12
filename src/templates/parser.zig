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
                    const text_start = i;
                    const text_end = token.start;
                    const text = template[text_start..text_end];
                    if (text.len > 0) {
                        result = result ++ &[_]ast.TemplateAST.Node{.{ .text = text }};
                    }
                }
                
                if (token.is_block) {
                    const block_end = std.mem.indexOf(u8, template[token.start + 2..], "%}") orelse {
                        return error.UnclosedBlock;
                    };
                    const block_content = template[token.start + 2..token.start + 2 + block_end];
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
                    } else if (std.mem.startsWith(u8, trimmed, "endif") or std.mem.startsWith(u8, trimmed, "endfor")) {
                        end_pos = i;
                        break;
                    } else if (std.mem.startsWith(u8, trimmed, "else")) {
                        end_pos = i;
                        break;
                    } else {
                        return error.InvalidIfSyntax;
                    }
                } else {
                    const var_end = std.mem.indexOf(u8, template[token.start + 2..], "}}") orelse {
                        return error.UnclosedBlock;
                    };
                    const var_content = template[token.start + 2..token.start + 2 + var_end];
                    
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
        const if_tag_end = std.mem.indexOf(u8, template[if_tag_start + 5..], "%}") orelse {
            return error.UnclosedBlock;
        };
        const if_content = template[if_tag_start + 5..if_tag_start + 5 + if_tag_end];
        
        const condition_str = std.mem.trim(u8, if_content, " \t\n");
        const condition = try parseVariable(condition_str);
        
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
                const else_tag_end = std.mem.indexOf(u8, template[else_tag_start + 7..], "%}") orelse {
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
                const endif_tag_end = std.mem.indexOf(u8, template[endif_tag_start + 8..], "%}") orelse {
                    return error.UnclosedBlock;
                };
                final_end_pos = endif_tag_start + 8 + endif_tag_end + 2;
            } else {
                const endif_tag_start = content_end + endif_pos.?;
                const endif_tag_end = std.mem.indexOf(u8, template[endif_tag_start + 8..], "%}") orelse {
                    return error.UnclosedBlock;
                };
                final_end_pos = endif_tag_start + 8 + endif_tag_end + 2;
            }
        } else if (endif_pos) |ep| {
            const endif_tag_start = content_end + ep;
            const endif_tag_end = std.mem.indexOf(u8, template[endif_tag_start + 8..], "%}") orelse {
                return error.UnclosedBlock;
            };
            final_end_pos = endif_tag_start + 8 + endif_tag_end + 2;
        } else {
            return error.UnclosedBlock;
        }
        
        return .{
            .block = ast.TemplateAST.IfBlock{
                .condition = condition,
                .true_block = true_block,
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
        const for_tag_end = std.mem.indexOf(u8, template[for_tag_start + 6..], "%}") orelse {
            return error.UnclosedBlock;
        };
        const for_content = template[for_tag_start + 6..for_tag_start + 6 + for_tag_end];
        
        const trimmed = std.mem.trim(u8, for_content, " \t\n");
        
        const pipe_pos = std.mem.indexOfScalar(u8, trimmed, '|') orelse {
            return error.InvalidForSyntax;
        };
        
        const collection_str = std.mem.trim(u8, trimmed[0..pipe_pos], " \t\n");
        const collection_path = try parseVariablePath(collection_str);
        
        const after_pipe = trimmed[pipe_pos + 1..];
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
        const endfor_tag_end = std.mem.indexOf(u8, template[endfor_tag_start + 9..], "%}") orelse {
            return error.UnclosedBlock;
        };
        const final_end_pos = endfor_tag_start + 9 + endfor_tag_end + 2;
        
        return .{
            .block = ast.TemplateAST.ForBlock{
                .collection_path = collection_path,
                .item_name = item_name,
                .block = block,
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
    
    fn parseVariable(comptime input: []const u8) !ast.TemplateAST.VariableNode {
        const pipe_pos = std.mem.indexOfScalar(u8, input, '|');
        
        const var_path_str = if (pipe_pos) |pos|
            std.mem.trim(u8, input[0..pos], " \t\n")
        else
            std.mem.trim(u8, input, " \t\n");
        
        const path = try parseVariablePath(var_path_str);
        
        var filters: []const ast.TemplateAST.Filter = &[_]ast.TemplateAST.Filter{};
        if (pipe_pos) |pos| {
            const filter_str = std.mem.trim(u8, input[pos + 1..], " \t\n");
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
        var filters: []const ast.TemplateAST.Filter = &[_]ast.TemplateAST.Filter{};
        var i: usize = 0;
        var start: usize = 0;
        
        while (i < filter_str.len) {
            if (filter_str[i] == '|') {
                const filter_with_args = std.mem.trim(u8, filter_str[start..i], " \t\n");
                if (filter_with_args.len > 0) {
                    const filter_name = blk: {
                        var name_end = filter_with_args.len;
                        var j: usize = 0;
                        while (j < filter_with_args.len) {
                            if (filter_with_args[j] == ' ') {
                                name_end = j;
                                break;
                            }
                            j += 1;
                        }
                        break :blk std.mem.trim(u8, filter_with_args[0..name_end], " \t\n");
                    };
                    
                    filters = filters ++ &[_]ast.TemplateAST.Filter{.{
                        .name = filter_name,
                        .args = &[_][]const u8{}, // Args parsing TODO
                    }};
                }
                start = i + 1;
            }
            i += 1;
        }
        
        const final_filter_str = std.mem.trim(u8, filter_str[start..], " \t\n");
        if (final_filter_str.len > 0) {
            const filter_name = blk: {
                var name_end = final_filter_str.len;
                var j: usize = 0;
                while (j < final_filter_str.len) {
                    if (final_filter_str[j] == ' ') {
                        name_end = j;
                        break;
                    }
                    j += 1;
                }
                break :blk std.mem.trim(u8, final_filter_str[0..name_end], " \t\n");
            };
            
            filters = filters ++ &[_]ast.TemplateAST.Filter{.{
                .name = filter_name,
                .args = &[_][]const u8{}, // Args parsing TODO
            }};
        }
        
        return filters;
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
        const quote_end = std.mem.indexOfScalar(u8, after_include[quote_start + 1..], '"') orelse {
            return error.InvalidIncludePath;
        };
        
        const file_path = after_include[quote_start + 1..quote_start + 1 + quote_end];
        
        if (std.mem.indexOf(u8, file_path, "..") != null) {
            return error.InvalidIncludePath;
        }
        
        return ast.TemplateAST.IncludeNode{
            .file_path = file_path,
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
