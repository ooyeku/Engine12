const std = @import("std");
const ast = @import("ast.zig");

pub const Parser = struct {
    allocator: std.mem.Allocator,

    pub const ParseError = error{
        UnclosedVariable,
        UnclosedBlock,
        UnclosedComment,
        OutOfMemory,
    };


    pub fn freeAST(self: *Parser, template_ast: ast.TemplateAST) void {
        self.freeNodes(template_ast.nodes);
        self.allocator.free(template_ast.nodes);
    }

    fn freeNodes(self: *Parser, nodes: []const ast.TemplateAST.Node) void {
        for (nodes) |node| {
            switch (node) {
                .variable, .raw_variable => |v| {
                    self.allocator.free(v.path);
                    for (v.filters) |f| {
                        self.allocator.free(f.args);
                    }
                    self.allocator.free(v.filters);
                },
                .if_block => |ib| {

                    switch (ib.condition) {
                        .simple => |v| {
                            self.allocator.free(v.path);
                            for (v.filters) |f| {
                                self.allocator.free(f.args);
                            }
                            self.allocator.free(v.filters);
                        },
                        .negated => |n| {
                            self.allocator.free(n.inner.path);
                            for (n.inner.filters) |f| {
                                self.allocator.free(f.args);
                            }
                            self.allocator.free(n.inner.filters);
                        },
                        .comparison => |c| {
                            self.allocator.free(c.left.path);
                            for (c.left.filters) |f| {
                                self.allocator.free(f.args);
                            }
                            self.allocator.free(c.left.filters);
                        },
                    }

                    self.freeNodes(ib.true_block.nodes);
                    self.allocator.free(ib.true_block.nodes);

                    if (ib.false_block) |fb| {
                        self.freeNodes(fb.nodes);
                        self.allocator.free(fb.nodes);
                    }
                },
                .for_block => |fb| {
                    self.allocator.free(fb.collection_path);
                    self.freeNodes(fb.block.nodes);
                    self.allocator.free(fb.block.nodes);
                    if (fb.else_block) |eb| {
                        self.freeNodes(eb.nodes);
                        self.allocator.free(eb.nodes);
                    }
                },
                .block => |b| {
                    self.freeNodes(b.content.nodes);
                    self.allocator.free(b.content.nodes);
                },
                .text, .comment, .include, .extends => {},
            }
        }
    }



    pub fn parse(self: *Parser, template: []const u8) ParseError!ast.TemplateAST {
        var nodes = std.ArrayListUnmanaged(ast.TemplateAST.Node){};
        errdefer nodes.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < template.len) {

            const remaining = template[pos..];
            const var_pos = std.mem.indexOf(u8, remaining, "{{");
            const block_pos = std.mem.indexOf(u8, remaining, "{%");
            const comment_pos = std.mem.indexOf(u8, remaining, "{#");


            var next_pos: ?usize = null;
            var token_kind: enum { variable, block, comment } = .variable;

            if (var_pos) |vp| {
                next_pos = vp;
                token_kind = .variable;
            }
            if (block_pos) |bp| {
                if (next_pos == null or bp < next_pos.?) {
                    next_pos = bp;
                    token_kind = .block;
                }
            }
            if (comment_pos) |cp| {
                if (next_pos == null or cp < next_pos.?) {
                    next_pos = cp;
                    token_kind = .comment;
                }
            }

            if (next_pos) |np| {

                if (np > 0) {
                    try nodes.append(self.allocator, .{ .text = remaining[0..np] });
                }

                const token_start = pos + np;

                switch (token_kind) {
                    .variable => {
                        const end = std.mem.indexOf(u8, template[token_start + 2 ..], "}}") orelse
                            return error.UnclosedVariable;
                        const content = template[token_start + 2 .. token_start + 2 + end];
                        const is_raw = content.len > 0 and content[0] == '!';
                        const var_str = if (is_raw) content[1..] else content;
                        const var_node = try self.parseVariable(std.mem.trim(u8, var_str, " \t\n"));
                        if (is_raw) {
                            try nodes.append(self.allocator, .{ .raw_variable = var_node });
                        } else {
                            try nodes.append(self.allocator, .{ .variable = var_node });
                        }
                        pos = token_start + 2 + end + 2;
                    },
                    .block => {
                        const end = std.mem.indexOf(u8, template[token_start + 2 ..], "%}") orelse
                            return error.UnclosedBlock;
                        const content = template[token_start + 2 .. token_start + 2 + end];
                        const trimmed = std.mem.trim(u8, content, " \t\n");
                        const after_block = token_start + 2 + end + 2;


                        if (std.mem.startsWith(u8, trimmed, "if ") or std.mem.eql(u8, trimmed, "if")) {
                            const if_result = try self.parseIfBlock(template, after_block, trimmed);
                            try nodes.append(self.allocator, .{ .if_block = if_result.block });
                            pos = if_result.end_pos;
                        } else if (std.mem.startsWith(u8, trimmed, "for ")) {
                            const for_result = try self.parseForBlock(template, after_block, trimmed);
                            try nodes.append(self.allocator, .{ .for_block = for_result.block });
                            pos = for_result.end_pos;
                        } else if (std.mem.startsWith(u8, trimmed, "include ")) {
                            const include_node = try self.parseInclude(trimmed);
                            try nodes.append(self.allocator, .{ .include = include_node });
                            pos = after_block;
                        } else if (std.mem.startsWith(u8, trimmed, "extends ")) {
                            const extends_node = try self.parseExtends(trimmed);
                            try nodes.append(self.allocator, .{ .extends = extends_node });
                            pos = after_block;
                        } else if (std.mem.startsWith(u8, trimmed, "block ")) {
                            const block_result = try self.parseBlock(template, after_block, trimmed);
                            try nodes.append(self.allocator, .{ .block = block_result.block });
                            pos = block_result.end_pos;
                        } else if (std.mem.startsWith(u8, trimmed, "endif") or
                            std.mem.startsWith(u8, trimmed, "endfor") or
                            std.mem.startsWith(u8, trimmed, "endblock") or
                            std.mem.startsWith(u8, trimmed, "else") or
                            std.mem.startsWith(u8, trimmed, "elif"))
                        {

                            break;
                        } else {

                            pos = after_block;
                        }
                    },
                    .comment => {
                        const end = std.mem.indexOf(u8, template[token_start + 2 ..], "#}") orelse
                            return error.UnclosedComment;
                        const content = template[token_start + 2 .. token_start + 2 + end];
                        try nodes.append(self.allocator, .{ .comment = .{ .content = content } });
                        pos = token_start + 2 + end + 2;
                    },
                }
            } else {

                if (remaining.len > 0) {
                    try nodes.append(self.allocator, .{ .text = remaining });
                }
                break;
            }
        }

        return ast.TemplateAST{ .nodes = try nodes.toOwnedSlice(self.allocator) };
    }

    fn parseVariable(self: *Parser, input: []const u8) ParseError!ast.TemplateAST.VariableNode {
        const pipe_pos = std.mem.indexOfScalar(u8, input, '|');

        const var_path_str = if (pipe_pos) |p|
            std.mem.trim(u8, input[0..p], " \t\n")
        else
            std.mem.trim(u8, input, " \t\n");

        var path = try self.parsePath(var_path_str);

        var filters = std.ArrayListUnmanaged(ast.TemplateAST.Filter){};
        if (pipe_pos) |p| {
            const filter_str = std.mem.trim(u8, input[p + 1 ..], " \t\n");
            try self.parseFilters(filter_str, &filters);
        }

        return .{ .path = try path.toOwnedSlice(self.allocator), .filters = try filters.toOwnedSlice(self.allocator) };
    }

    fn parsePath(self: *Parser, path_str: []const u8) ParseError!std.ArrayListUnmanaged([]const u8) {
        var result = std.ArrayListUnmanaged([]const u8){};
        if (path_str.len == 0) return result;


        if (std.mem.startsWith(u8, path_str, "../")) {
            try result.append(self.allocator, "..");
            var rest = try self.parsePath(path_str[3..]);
            try result.appendSlice(self.allocator, rest.items);
            rest.deinit(self.allocator);
            return result;
        }
        if (std.mem.eql(u8, path_str, "..")) {
            try result.append(self.allocator, "..");
            return result;
        }


        var str = path_str;
        if (str.len > 0 and str[0] == '.') str = str[1..];


        var iter = std.mem.splitScalar(u8, str, '.');
        while (iter.next()) |segment| {
            if (segment.len > 0) {
                try result.append(self.allocator, segment);
            }
        }

        return result;
    }

    fn parseFilters(self: *Parser, filter_str: []const u8, result: *std.ArrayList(ast.TemplateAST.Filter)) !void {
        var iter = std.mem.splitScalar(u8, filter_str, '|');
        while (iter.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\n");
            if (trimmed.len > 0) {
                try result.append(self.allocator, try self.parseOneFilter(trimmed));
            }
        }
    }

    fn parseOneFilter(self: *Parser, filter_str: []const u8) ParseError!ast.TemplateAST.Filter {
        if (std.mem.indexOfScalar(u8, filter_str, ':')) |colon| {
            const name = std.mem.trim(u8, filter_str[0..colon], " \t\n");
            var args = std.ArrayListUnmanaged([]const u8){};
            var iter = std.mem.splitScalar(u8, filter_str[colon + 1 ..], ':');
            while (iter.next()) |arg| {
                const trimmed = std.mem.trim(u8, arg, " \t\n");
                if (trimmed.len > 0) {
                    try args.append(self.allocator, trimmed);
                }
            }
            return .{ .name = name, .args = try args.toOwnedSlice(self.allocator) };
        }
        return .{ .name = std.mem.trim(u8, filter_str, " \t\n"), .args = &[_][]const u8{} };
    }

    fn parseIfBlock(self: *Parser, template: []const u8, content_start: usize, block_content: []const u8) ParseError!struct {
        block: ast.TemplateAST.IfBlock,
        end_pos: usize,
    } {
        const condition_str = std.mem.trim(u8, block_content[2..], " \t\n");
        const condition = try self.parseCondition(condition_str);


        var true_parser = Parser{ .allocator = self.allocator };
        const true_result = try true_parser.parseUntilEnd(template, content_start);

        var false_block: ?ast.TemplateAST = null;
        var final_end_pos = true_result.end_pos;


        if (true_result.end_pos < template.len) {
            const after = template[true_result.end_pos..];
            if (std.mem.startsWith(u8, after, "{% else")) {
                const else_close = std.mem.indexOf(u8, after, "%}") orelse template.len;
                const else_content_start = true_result.end_pos + else_close + 2;
                var else_parser = Parser{ .allocator = self.allocator };
                const else_result = try else_parser.parseUntilEnd(template, else_content_start);
                false_block = ast.TemplateAST{ .nodes = else_result.nodes };
                final_end_pos = try self.findEndTag(template, else_result.end_pos, "endif");
            } else if (std.mem.startsWith(u8, after, "{% endif")) {
                final_end_pos = try self.findEndTag(template, true_result.end_pos, "endif");
            }
        }

        return .{
            .block = .{
                .condition = condition,
                .true_block = ast.TemplateAST{ .nodes = true_result.nodes },
                .elif_blocks = &[_]ast.TemplateAST.ElifBlock{},
                .false_block = false_block,
            },
            .end_pos = final_end_pos,
        };
    }

    fn parseForBlock(self: *Parser, template: []const u8, content_start: usize, block_content: []const u8) ParseError!struct {
        block: ast.TemplateAST.ForBlock,
        end_pos: usize,
    } {
        const for_content = std.mem.trim(u8, block_content[3..], " \t\n");
        var collection_path: []const []const u8 = &[_][]const u8{};
        var item_name: []const u8 = "item";

        if (std.mem.indexOf(u8, for_content, "|")) |pipe1| {
            const collection_str = std.mem.trim(u8, for_content[0..pipe1], " \t\n");
            var path_list = try self.parsePath(collection_str);
            collection_path = try path_list.toOwnedSlice(self.allocator);

            if (std.mem.indexOf(u8, for_content[pipe1 + 1 ..], "|")) |pipe2| {
                item_name = std.mem.trim(u8, for_content[pipe1 + 1 .. pipe1 + 1 + pipe2], " \t\n");
            }
        }

        var body_parser = Parser{ .allocator = self.allocator };
        const body_result = try body_parser.parseUntilEnd(template, content_start);
        const final_end_pos = try self.findEndTag(template, body_result.end_pos, "endfor");

        return .{
            .block = .{
                .collection_path = collection_path,
                .item_name = item_name,
                .block = ast.TemplateAST{ .nodes = body_result.nodes },
                .else_block = null,
            },
            .end_pos = final_end_pos,
        };
    }

    fn parseBlock(self: *Parser, template: []const u8, content_start: usize, block_content: []const u8) ParseError!struct {
        block: ast.TemplateAST.BlockNode,
        end_pos: usize,
    } {
        const name = std.mem.trim(u8, block_content[5..], " \t\n");

        var content_parser = Parser{ .allocator = self.allocator };
        const content_result = try content_parser.parseUntilEnd(template, content_start);
        const final_end_pos = try self.findEndTag(template, content_result.end_pos, "endblock");

        return .{
            .block = .{ .name = name, .content = ast.TemplateAST{ .nodes = content_result.nodes } },
            .end_pos = final_end_pos,
        };
    }

    fn parseUntilEnd(self: *Parser, template: []const u8, start: usize) ParseError!struct {
        nodes: []const ast.TemplateAST.Node,
        end_pos: usize,
    } {
        var nodes = std.ArrayListUnmanaged(ast.TemplateAST.Node){};
        errdefer nodes.deinit(self.allocator);

        var pos = start;
        while (pos < template.len) {
            const remaining = template[pos..];
            const var_pos = std.mem.indexOf(u8, remaining, "{{");
            const block_pos = std.mem.indexOf(u8, remaining, "{%");
            const comment_pos = std.mem.indexOf(u8, remaining, "{#");

            var next_pos: ?usize = null;
            var token_kind: enum { variable, block, comment } = .variable;

            if (var_pos) |vp| {
                next_pos = vp;
                token_kind = .variable;
            }
            if (block_pos) |bp| {
                if (next_pos == null or bp < next_pos.?) {
                    next_pos = bp;
                    token_kind = .block;
                }
            }
            if (comment_pos) |cp| {
                if (next_pos == null or cp < next_pos.?) {
                    next_pos = cp;
                    token_kind = .comment;
                }
            }

            if (next_pos) |np| {
                if (np > 0) {
                    try nodes.append(self.allocator, .{ .text = remaining[0..np] });
                }

                const token_start = pos + np;

                if (token_kind == .block) {
                    const end = std.mem.indexOf(u8, template[token_start + 2 ..], "%}") orelse break;
                    const content = template[token_start + 2 .. token_start + 2 + end];
                    const trimmed = std.mem.trim(u8, content, " \t\n");


                    if (std.mem.startsWith(u8, trimmed, "endif") or
                        std.mem.startsWith(u8, trimmed, "endfor") or
                        std.mem.startsWith(u8, trimmed, "endblock") or
                        std.mem.startsWith(u8, trimmed, "else") or
                        std.mem.startsWith(u8, trimmed, "elif"))
                    {
                        return .{ .nodes = try nodes.toOwnedSlice(self.allocator), .end_pos = token_start };
                    }

                    const after_block = token_start + 2 + end + 2;

                    if (std.mem.startsWith(u8, trimmed, "if ")) {
                        const if_result = try self.parseIfBlock(template, after_block, trimmed);
                        try nodes.append(self.allocator, .{ .if_block = if_result.block });
                        pos = if_result.end_pos;
                    } else if (std.mem.startsWith(u8, trimmed, "for ")) {
                        const for_result = try self.parseForBlock(template, after_block, trimmed);
                        try nodes.append(self.allocator, .{ .for_block = for_result.block });
                        pos = for_result.end_pos;
                    } else {
                        pos = after_block;
                    }
                } else if (token_kind == .variable) {
                    const end = std.mem.indexOf(u8, template[token_start + 2 ..], "}}") orelse break;
                    const content = template[token_start + 2 .. token_start + 2 + end];
                    const is_raw = content.len > 0 and content[0] == '!';
                    const var_str = if (is_raw) content[1..] else content;
                    const var_node = try self.parseVariable(std.mem.trim(u8, var_str, " \t\n"));
                    if (is_raw) {
                        try nodes.append(self.allocator, .{ .raw_variable = var_node });
                    } else {
                        try nodes.append(self.allocator, .{ .variable = var_node });
                    }
                    pos = token_start + 2 + end + 2;
                } else {
                    const end = std.mem.indexOf(u8, template[token_start + 2 ..], "#}") orelse break;
                    try nodes.append(self.allocator, .{ .comment = .{ .content = template[token_start + 2 .. token_start + 2 + end] } });
                    pos = token_start + 2 + end + 2;
                }
            } else {
                if (remaining.len > 0) {
                    try nodes.append(self.allocator, .{ .text = remaining });
                }
                break;
            }
        }

        return .{ .nodes = try nodes.toOwnedSlice(self.allocator), .end_pos = pos };
    }

    fn findEndTag(self: *Parser, template: []const u8, start: usize, tag: []const u8) ParseError!usize {
        _ = self;
        const after = template[start..];


        var needle: [32]u8 = undefined;
        const search_str = std.fmt.bufPrint(&needle, "{s} {s}", .{ "{%", tag }) catch return template.len;

        if (std.mem.indexOf(u8, after, search_str)) |pos| {
            const tag_start = start + pos;
            if (std.mem.indexOf(u8, template[tag_start..], "%}")) |close| {
                return tag_start + close + 2;
            }
        }
        return template.len;
    }

    fn parseCondition(self: *Parser, input: []const u8) ParseError!ast.TemplateAST.Condition {
        const trimmed = std.mem.trim(u8, input, " \t\n");


        if (std.mem.startsWith(u8, trimmed, "not ")) {
            const inner = std.mem.trim(u8, trimmed[4..], " \t\n");
            return .{ .negated = .{ .inner = try self.parseVariable(inner) } };
        }


        const operators = [_]struct { op: []const u8, val: ast.TemplateAST.ComparisonOp }{
            .{ .op = "==", .val = .eq },
            .{ .op = "!=", .val = .ne },
            .{ .op = "<=", .val = .le },
            .{ .op = ">=", .val = .ge },
            .{ .op = "<", .val = .lt },
            .{ .op = ">", .val = .gt },
        };

        for (operators) |entry| {
            if (std.mem.indexOf(u8, trimmed, entry.op)) |pos| {
                const left = std.mem.trim(u8, trimmed[0..pos], " \t\n");
                const right = std.mem.trim(u8, trimmed[pos + entry.op.len ..], " \t\n");
                return .{
                    .comparison = .{
                        .left = try self.parseVariable(left),
                        .operator = entry.val,
                        .right = self.parseComparisonValue(right),
                    },
                };
            }
        }


        return .{ .simple = try self.parseVariable(trimmed) };
    }

    fn parseComparisonValue(self: *Parser, input: []const u8) ast.TemplateAST.ComparisonValue {
        _ = self;
        const trimmed = std.mem.trim(u8, input, " \t\n");


        if (trimmed.len >= 2 and (trimmed[0] == '"' or trimmed[0] == '\'')) {
            return .{ .literal_string = trimmed[1 .. trimmed.len - 1] };
        }


        if (std.mem.eql(u8, trimmed, "true")) return .{ .literal_bool = true };
        if (std.mem.eql(u8, trimmed, "false")) return .{ .literal_bool = false };


        if (std.fmt.parseInt(i64, trimmed, 10)) |val| {
            return .{ .literal_int = val };
        } else |_| {}

        return .{ .literal_string = trimmed };
    }

    fn parseInclude(self: *Parser, trimmed: []const u8) ParseError!ast.TemplateAST.IncludeNode {
        _ = self;
        const after = std.mem.trim(u8, trimmed[7..], " \t\n");
        if (after.len >= 2 and (after[0] == '"' or after[0] == '\'')) {
            const quote = after[0];
            if (std.mem.indexOfScalar(u8, after[1..], quote)) |end| {
                return .{ .file_path = after[1 .. 1 + end], .params = &[_]ast.TemplateAST.IncludeParam{} };
            }
        }
        return .{ .file_path = "", .params = &[_]ast.TemplateAST.IncludeParam{} };
    }

    fn parseExtends(self: *Parser, trimmed: []const u8) ParseError!ast.TemplateAST.ExtendsNode {
        _ = self;
        const after = std.mem.trim(u8, trimmed[7..], " \t\n");
        if (after.len >= 2 and (after[0] == '"' or after[0] == '\'')) {
            const quote = after[0];
            if (std.mem.indexOfScalar(u8, after[1..], quote)) |end| {
                return .{ .parent_path = after[1 .. 1 + end] };
            }
        }
        return .{ .parent_path = "" };
    }
};


test "parse empty template" {
    var parser = Parser{ .allocator = std.testing.allocator };
    const result = try parser.parse("");
    defer std.testing.allocator.free(result.nodes);
    try std.testing.expectEqual(result.nodes.len, 0);
}

test "parse simple text" {
    var parser = Parser{ .allocator = std.testing.allocator };
    const result = try parser.parse("Hello World");
    defer parser.freeAST(result);
    try std.testing.expectEqual(result.nodes.len, 1);
    try std.testing.expect(std.meta.activeTag(result.nodes[0]) == .text);
    try std.testing.expectEqualStrings(result.nodes[0].text, "Hello World");
}

test "parse variable" {
    var parser = Parser{ .allocator = std.testing.allocator };
    const result = try parser.parse("{{ .name }}");
    defer parser.freeAST(result);
    try std.testing.expectEqual(result.nodes.len, 1);
    try std.testing.expect(std.meta.activeTag(result.nodes[0]) == .variable);
}

test "parse if block" {
    var parser = Parser{ .allocator = std.testing.allocator };
    const result = try parser.parse("{% if .visible %}Yes{% endif %}");
    defer parser.freeAST(result);
    try std.testing.expectEqual(result.nodes.len, 1);
    try std.testing.expect(std.meta.activeTag(result.nodes[0]) == .if_block);
}

test "parse comment" {
    var parser = Parser{ .allocator = std.testing.allocator };
    const result = try parser.parse("{# This is a comment #}");
    defer parser.freeAST(result);
    try std.testing.expectEqual(result.nodes.len, 1);
    try std.testing.expect(std.meta.activeTag(result.nodes[0]) == .comment);
}
