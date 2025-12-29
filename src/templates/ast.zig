const std = @import("std");

pub const TemplateAST = struct {
    nodes: []const Node,

    pub const Node = union(enum) {
        text: []const u8,
        variable: VariableNode,
        raw_variable: VariableNode, // {{! ... }}
        if_block: IfBlock,
        for_block: ForBlock,
        include: IncludeNode,
        comment: CommentNode, // {# ... #}
        extends: ExtendsNode, // {% extends "base.zt.html" %}
        block: BlockNode, // {% block name %}...{% endblock %}
    };

    pub const VariableNode = struct {
        path: []const []const u8, // ["user", "name"] for .user.name
        filters: []const Filter,
    };

    /// Enhanced condition supporting comparisons and logical operators
    pub const Condition = union(enum) {
        simple: VariableNode, // {% if .visible %}
        negated: struct { inner: VariableNode }, // {% if not .hidden %}
        comparison: ComparisonExpr, // {% if .count > 0 %}
    };

    pub const ComparisonExpr = struct {
        left: VariableNode,
        operator: ComparisonOp,
        right: ComparisonValue,
    };

    pub const ComparisonOp = enum {
        eq, // ==
        ne, // !=
        lt, // <
        le, // <=
        gt, // >
        ge, // >=
    };

    pub const ComparisonValue = union(enum) {
        variable: VariableNode,
        literal_string: []const u8,
        literal_int: i64,
        literal_bool: bool,
    };

    pub const IfBlock = struct {
        condition: Condition,
        true_block: TemplateAST,
        elif_blocks: []const ElifBlock, // {% elif .other %}
        false_block: ?TemplateAST,
    };

    pub const ElifBlock = struct {
        condition: Condition,
        block: TemplateAST,
    };

    pub const ForBlock = struct {
        collection_path: []const []const u8, // ["todos"]
        item_name: []const u8, // "item"
        block: TemplateAST,
        else_block: ?TemplateAST, // {% else %} for empty collections
    };

    pub const IncludeNode = struct {
        file_path: []const u8,
        params: []const IncludeParam, // {% include "x.html" with foo="bar" %}
    };

    pub const IncludeParam = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const CommentNode = struct {
        content: []const u8,
    };

    pub const ExtendsNode = struct {
        parent_path: []const u8,
    };

    pub const BlockNode = struct {
        name: []const u8,
        content: TemplateAST,
    };

    pub const Filter = struct {
        name: []const u8,
        args: []const []const u8,
    };

    pub fn init(nodes: []const Node) TemplateAST {
        return TemplateAST{ .nodes = nodes };
    }

    pub fn empty() TemplateAST {
        return TemplateAST{ .nodes = &[_]Node{} };
    }

    /// Create a simple condition from a variable node
    pub fn simpleCondition(var_node: VariableNode) Condition {
        return Condition{ .simple = var_node };
    }
};

pub const ParseError = error{
    UnexpectedEndOfInput,
    InvalidVariableSyntax,
    InvalidIfSyntax,
    InvalidForSyntax,
    UnclosedBlock,
    InvalidIncludePath,
    InvalidFilterSyntax,
    InvalidComparisonSyntax,
    InvalidBlockSyntax,
    InvalidExtendsSyntax,
};

test "TemplateAST.init creates AST with nodes" {
    const nodes = [_]TemplateAST.Node{
        .{ .text = "Hello" },
        .{ .text = "World" },
    };
    const ast = TemplateAST.init(&nodes);
    try std.testing.expectEqual(2, ast.nodes.len);
    try std.testing.expectEqualStrings("Hello", ast.nodes[0].text);
    try std.testing.expectEqualStrings("World", ast.nodes[1].text);
}

test "TemplateAST.empty creates empty AST" {
    const ast = TemplateAST.empty();
    try std.testing.expectEqual(0, ast.nodes.len);
}

test "TemplateAST.Node text variant" {
    const node = TemplateAST.Node{ .text = "Plain text content" };
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Node).text, std.meta.activeTag(node));
    try std.testing.expectEqualStrings("Plain text content", node.text);
}

test "TemplateAST.Node variable variant" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"user"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const node = TemplateAST.Node{ .variable = var_node };
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Node).variable, std.meta.activeTag(node));
    try std.testing.expectEqual(1, node.variable.path.len);
    try std.testing.expectEqualStrings("user", node.variable.path[0]);
}

test "TemplateAST.Node raw_variable variant" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"html"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const node = TemplateAST.Node{ .raw_variable = var_node };
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Node).raw_variable, std.meta.activeTag(node));
}

test "TemplateAST.Node comment variant" {
    const comment = TemplateAST.CommentNode{ .content = "This is a comment" };
    const node = TemplateAST.Node{ .comment = comment };
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Node).comment, std.meta.activeTag(node));
    try std.testing.expectEqualStrings("This is a comment", node.comment.content);
}

test "TemplateAST.VariableNode with simple path" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"name"},
        .filters = &[_]TemplateAST.Filter{},
    };
    try std.testing.expectEqual(1, var_node.path.len);
    try std.testing.expectEqualStrings("name", var_node.path[0]);
    try std.testing.expectEqual(0, var_node.filters.len);
}

test "TemplateAST.VariableNode with nested path" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{ "user", "profile", "name" },
        .filters = &[_]TemplateAST.Filter{},
    };
    try std.testing.expectEqual(3, var_node.path.len);
    try std.testing.expectEqualStrings("user", var_node.path[0]);
    try std.testing.expectEqualStrings("profile", var_node.path[1]);
    try std.testing.expectEqualStrings("name", var_node.path[2]);
}

test "TemplateAST.VariableNode with empty path" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{},
        .filters = &[_]TemplateAST.Filter{},
    };
    try std.testing.expectEqual(0, var_node.path.len);
}

test "TemplateAST.VariableNode with single filter" {
    const filter = TemplateAST.Filter{
        .name = "uppercase",
        .args = &[_][]const u8{},
    };
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"name"},
        .filters = &[_]TemplateAST.Filter{filter},
    };
    try std.testing.expectEqual(1, var_node.filters.len);
    try std.testing.expectEqualStrings("uppercase", var_node.filters[0].name);
}

test "TemplateAST.VariableNode with multiple filters" {
    const filters = [_]TemplateAST.Filter{
        .{ .name = "trim", .args = &[_][]const u8{} },
        .{ .name = "uppercase", .args = &[_][]const u8{} },
        .{ .name = "truncate", .args = &[_][]const u8{"50"} },
    };
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"description"},
        .filters = &filters,
    };
    try std.testing.expectEqual(3, var_node.filters.len);
    try std.testing.expectEqualStrings("trim", var_node.filters[0].name);
    try std.testing.expectEqualStrings("uppercase", var_node.filters[1].name);
    try std.testing.expectEqualStrings("truncate", var_node.filters[2].name);
}

test "TemplateAST.Filter with no args" {
    const filter = TemplateAST.Filter{
        .name = "escape",
        .args = &[_][]const u8{},
    };
    try std.testing.expectEqualStrings("escape", filter.name);
    try std.testing.expectEqual(0, filter.args.len);
}

test "TemplateAST.Filter with single arg" {
    const filter = TemplateAST.Filter{
        .name = "truncate",
        .args = &[_][]const u8{"100"},
    };
    try std.testing.expectEqual(1, filter.args.len);
    try std.testing.expectEqualStrings("100", filter.args[0]);
}

test "TemplateAST.Filter with multiple args" {
    const filter = TemplateAST.Filter{
        .name = "replace",
        .args = &[_][]const u8{ "old", "new" },
    };
    try std.testing.expectEqual(2, filter.args.len);
    try std.testing.expectEqualStrings("old", filter.args[0]);
    try std.testing.expectEqualStrings("new", filter.args[1]);
}

test "TemplateAST.Condition simple variant" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"visible"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const condition = TemplateAST.Condition{ .simple = var_node };
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Condition).simple, std.meta.activeTag(condition));
}

test "TemplateAST.Condition negated variant" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"hidden"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const condition = TemplateAST.Condition{ .negated = .{ .inner = var_node } };
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Condition).negated, std.meta.activeTag(condition));
    try std.testing.expectEqualStrings("hidden", condition.negated.inner.path[0]);
}

test "TemplateAST.Condition comparison variant" {
    const left = TemplateAST.VariableNode{
        .path = &[_][]const u8{"count"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const comparison = TemplateAST.ComparisonExpr{
        .left = left,
        .operator = .gt,
        .right = .{ .literal_int = 10 },
    };
    const condition = TemplateAST.Condition{ .comparison = comparison };
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Condition).comparison, std.meta.activeTag(condition));
    try std.testing.expectEqual(TemplateAST.ComparisonOp.gt, condition.comparison.operator);
}

test "TemplateAST.simpleCondition helper" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"active"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const condition = TemplateAST.simpleCondition(var_node);
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Condition).simple, std.meta.activeTag(condition));
}

test "TemplateAST.ComparisonOp all variants" {
    try std.testing.expectEqual(TemplateAST.ComparisonOp.eq, .eq);
    try std.testing.expectEqual(TemplateAST.ComparisonOp.ne, .ne);
    try std.testing.expectEqual(TemplateAST.ComparisonOp.lt, .lt);
    try std.testing.expectEqual(TemplateAST.ComparisonOp.le, .le);
    try std.testing.expectEqual(TemplateAST.ComparisonOp.gt, .gt);
    try std.testing.expectEqual(TemplateAST.ComparisonOp.ge, .ge);
}

test "TemplateAST.ComparisonValue variable variant" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"other"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const value = TemplateAST.ComparisonValue{ .variable = var_node };
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.ComparisonValue).variable, std.meta.activeTag(value));
}

test "TemplateAST.ComparisonValue literal_string variant" {
    const value = TemplateAST.ComparisonValue{ .literal_string = "active" };
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.ComparisonValue).literal_string, std.meta.activeTag(value));
    try std.testing.expectEqualStrings("active", value.literal_string);
}

test "TemplateAST.ComparisonValue literal_int variant" {
    const value = TemplateAST.ComparisonValue{ .literal_int = 42 };
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.ComparisonValue).literal_int, std.meta.activeTag(value));
    try std.testing.expectEqual(42, value.literal_int);
}

test "TemplateAST.ComparisonValue literal_int negative" {
    const value = TemplateAST.ComparisonValue{ .literal_int = -100 };
    try std.testing.expectEqual(-100, value.literal_int);
}

test "TemplateAST.ComparisonValue literal_int zero" {
    const value = TemplateAST.ComparisonValue{ .literal_int = 0 };
    try std.testing.expectEqual(0, value.literal_int);
}

test "TemplateAST.ComparisonValue literal_bool true" {
    const value = TemplateAST.ComparisonValue{ .literal_bool = true };
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.ComparisonValue).literal_bool, std.meta.activeTag(value));
    try std.testing.expectEqual(true, value.literal_bool);
}

test "TemplateAST.ComparisonValue literal_bool false" {
    const value = TemplateAST.ComparisonValue{ .literal_bool = false };
    try std.testing.expectEqual(false, value.literal_bool);
}

test "TemplateAST.ComparisonExpr with eq operator" {
    const left = TemplateAST.VariableNode{
        .path = &[_][]const u8{"status"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const expr = TemplateAST.ComparisonExpr{
        .left = left,
        .operator = .eq,
        .right = .{ .literal_string = "active" },
    };
    try std.testing.expectEqual(TemplateAST.ComparisonOp.eq, expr.operator);
    try std.testing.expectEqualStrings("status", expr.left.path[0]);
    try std.testing.expectEqualStrings("active", expr.right.literal_string);
}

test "TemplateAST.ComparisonExpr with ne operator" {
    const left = TemplateAST.VariableNode{
        .path = &[_][]const u8{"type"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const expr = TemplateAST.ComparisonExpr{
        .left = left,
        .operator = .ne,
        .right = .{ .literal_string = "admin" },
    };
    try std.testing.expectEqual(TemplateAST.ComparisonOp.ne, expr.operator);
}

test "TemplateAST.ComparisonExpr with lt operator" {
    const left = TemplateAST.VariableNode{
        .path = &[_][]const u8{"age"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const expr = TemplateAST.ComparisonExpr{
        .left = left,
        .operator = .lt,
        .right = .{ .literal_int = 18 },
    };
    try std.testing.expectEqual(TemplateAST.ComparisonOp.lt, expr.operator);
    try std.testing.expectEqual(18, expr.right.literal_int);
}

test "TemplateAST.ComparisonExpr with le operator" {
    const left = TemplateAST.VariableNode{
        .path = &[_][]const u8{"count"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const expr = TemplateAST.ComparisonExpr{
        .left = left,
        .operator = .le,
        .right = .{ .literal_int = 100 },
    };
    try std.testing.expectEqual(TemplateAST.ComparisonOp.le, expr.operator);
}

test "TemplateAST.ComparisonExpr with gt operator" {
    const left = TemplateAST.VariableNode{
        .path = &[_][]const u8{"score"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const expr = TemplateAST.ComparisonExpr{
        .left = left,
        .operator = .gt,
        .right = .{ .literal_int = 50 },
    };
    try std.testing.expectEqual(TemplateAST.ComparisonOp.gt, expr.operator);
}

test "TemplateAST.ComparisonExpr with ge operator" {
    const left = TemplateAST.VariableNode{
        .path = &[_][]const u8{"level"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const expr = TemplateAST.ComparisonExpr{
        .left = left,
        .operator = .ge,
        .right = .{ .literal_int = 5 },
    };
    try std.testing.expectEqual(TemplateAST.ComparisonOp.ge, expr.operator);
}

test "TemplateAST.ComparisonExpr comparing two variables" {
    const left = TemplateAST.VariableNode{
        .path = &[_][]const u8{"a"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const right_var = TemplateAST.VariableNode{
        .path = &[_][]const u8{"b"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const expr = TemplateAST.ComparisonExpr{
        .left = left,
        .operator = .eq,
        .right = .{ .variable = right_var },
    };
    try std.testing.expectEqualStrings("a", expr.left.path[0]);
    try std.testing.expectEqualStrings("b", expr.right.variable.path[0]);
}

test "TemplateAST.IfBlock with simple condition" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"show"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const if_block = TemplateAST.IfBlock{
        .condition = .{ .simple = var_node },
        .true_block = TemplateAST.empty(),
        .elif_blocks = &[_]TemplateAST.ElifBlock{},
        .false_block = null,
    };
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Condition).simple, std.meta.activeTag(if_block.condition));
    try std.testing.expectEqual(0, if_block.elif_blocks.len);
    try std.testing.expect(if_block.false_block == null);
}

test "TemplateAST.IfBlock with else block" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"active"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const true_nodes = [_]TemplateAST.Node{.{ .text = "Yes" }};
    const false_nodes = [_]TemplateAST.Node{.{ .text = "No" }};
    const if_block = TemplateAST.IfBlock{
        .condition = .{ .simple = var_node },
        .true_block = TemplateAST.init(&true_nodes),
        .elif_blocks = &[_]TemplateAST.ElifBlock{},
        .false_block = TemplateAST.init(&false_nodes),
    };
    try std.testing.expect(if_block.false_block != null);
    try std.testing.expectEqual(1, if_block.false_block.?.nodes.len);
    try std.testing.expectEqualStrings("No", if_block.false_block.?.nodes[0].text);
}

test "TemplateAST.IfBlock with elif blocks" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"x"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const elif_var = TemplateAST.VariableNode{
        .path = &[_][]const u8{"y"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const elif_blocks = [_]TemplateAST.ElifBlock{
        .{
            .condition = .{ .simple = elif_var },
            .block = TemplateAST.empty(),
        },
    };
    const if_block = TemplateAST.IfBlock{
        .condition = .{ .simple = var_node },
        .true_block = TemplateAST.empty(),
        .elif_blocks = &elif_blocks,
        .false_block = null,
    };
    try std.testing.expectEqual(1, if_block.elif_blocks.len);
}

test "TemplateAST.IfBlock with comparison condition" {
    const left = TemplateAST.VariableNode{
        .path = &[_][]const u8{"count"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const comparison = TemplateAST.ComparisonExpr{
        .left = left,
        .operator = .gt,
        .right = .{ .literal_int = 0 },
    };
    const if_block = TemplateAST.IfBlock{
        .condition = .{ .comparison = comparison },
        .true_block = TemplateAST.empty(),
        .elif_blocks = &[_]TemplateAST.ElifBlock{},
        .false_block = null,
    };
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Condition).comparison, std.meta.activeTag(if_block.condition));
}

test "TemplateAST.IfBlock with negated condition" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"disabled"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const if_block = TemplateAST.IfBlock{
        .condition = .{ .negated = .{ .inner = var_node } },
        .true_block = TemplateAST.empty(),
        .elif_blocks = &[_]TemplateAST.ElifBlock{},
        .false_block = null,
    };
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Condition).negated, std.meta.activeTag(if_block.condition));
}

test "TemplateAST.ElifBlock structure" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"condition"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const nodes = [_]TemplateAST.Node{.{ .text = "Content" }};
    const elif_block = TemplateAST.ElifBlock{
        .condition = .{ .simple = var_node },
        .block = TemplateAST.init(&nodes),
    };
    try std.testing.expectEqual(1, elif_block.block.nodes.len);
}

test "TemplateAST.ForBlock basic structure" {
    const for_block = TemplateAST.ForBlock{
        .collection_path = &[_][]const u8{"items"},
        .item_name = "item",
        .block = TemplateAST.empty(),
        .else_block = null,
    };
    try std.testing.expectEqual(1, for_block.collection_path.len);
    try std.testing.expectEqualStrings("items", for_block.collection_path[0]);
    try std.testing.expectEqualStrings("item", for_block.item_name);
    try std.testing.expect(for_block.else_block == null);
}

test "TemplateAST.ForBlock with nested collection path" {
    const for_block = TemplateAST.ForBlock{
        .collection_path = &[_][]const u8{ "data", "items" },
        .item_name = "item",
        .block = TemplateAST.empty(),
        .else_block = null,
    };
    try std.testing.expectEqual(2, for_block.collection_path.len);
    try std.testing.expectEqualStrings("data", for_block.collection_path[0]);
    try std.testing.expectEqualStrings("items", for_block.collection_path[1]);
}

test "TemplateAST.ForBlock with else block" {
    const else_nodes = [_]TemplateAST.Node{.{ .text = "Empty" }};
    const for_block = TemplateAST.ForBlock{
        .collection_path = &[_][]const u8{"items"},
        .item_name = "item",
        .block = TemplateAST.empty(),
        .else_block = TemplateAST.init(&else_nodes),
    };
    try std.testing.expect(for_block.else_block != null);
    try std.testing.expectEqual(1, for_block.else_block.?.nodes.len);
}

test "TemplateAST.ForBlock with content" {
    const content_nodes = [_]TemplateAST.Node{
        .{ .text = "Item: " },
    };
    const for_block = TemplateAST.ForBlock{
        .collection_path = &[_][]const u8{"todos"},
        .item_name = "todo",
        .block = TemplateAST.init(&content_nodes),
        .else_block = null,
    };
    try std.testing.expectEqual(1, for_block.block.nodes.len);
}

test "TemplateAST.IncludeNode basic" {
    const include = TemplateAST.IncludeNode{
        .file_path = "header.zt.html",
        .params = &[_]TemplateAST.IncludeParam{},
    };
    try std.testing.expectEqualStrings("header.zt.html", include.file_path);
    try std.testing.expectEqual(0, include.params.len);
}

test "TemplateAST.IncludeNode with path" {
    const include = TemplateAST.IncludeNode{
        .file_path = "partials/navbar.zt.html",
        .params = &[_]TemplateAST.IncludeParam{},
    };
    try std.testing.expectEqualStrings("partials/navbar.zt.html", include.file_path);
}

test "TemplateAST.IncludeNode with params" {
    const params = [_]TemplateAST.IncludeParam{
        .{ .name = "title", .value = "Home" },
        .{ .name = "active", .value = "true" },
    };
    const include = TemplateAST.IncludeNode{
        .file_path = "component.zt.html",
        .params = &params,
    };
    try std.testing.expectEqual(2, include.params.len);
    try std.testing.expectEqualStrings("title", include.params[0].name);
    try std.testing.expectEqualStrings("Home", include.params[0].value);
}

test "TemplateAST.IncludeParam structure" {
    const param = TemplateAST.IncludeParam{
        .name = "color",
        .value = "blue",
    };
    try std.testing.expectEqualStrings("color", param.name);
    try std.testing.expectEqualStrings("blue", param.value);
}

test "TemplateAST.CommentNode basic" {
    const comment = TemplateAST.CommentNode{
        .content = "TODO: implement this",
    };
    try std.testing.expectEqualStrings("TODO: implement this", comment.content);
}

test "TemplateAST.CommentNode empty" {
    const comment = TemplateAST.CommentNode{
        .content = "",
    };
    try std.testing.expectEqualStrings("", comment.content);
}

test "TemplateAST.CommentNode with special characters" {
    const comment = TemplateAST.CommentNode{
        .content = "<>&\"'{}[]",
    };
    try std.testing.expectEqualStrings("<>&\"'{}[]", comment.content);
}

test "TemplateAST.ExtendsNode basic" {
    const extends = TemplateAST.ExtendsNode{
        .parent_path = "base.zt.html",
    };
    try std.testing.expectEqualStrings("base.zt.html", extends.parent_path);
}

test "TemplateAST.ExtendsNode with nested path" {
    const extends = TemplateAST.ExtendsNode{
        .parent_path = "layouts/main.zt.html",
    };
    try std.testing.expectEqualStrings("layouts/main.zt.html", extends.parent_path);
}

test "TemplateAST.BlockNode basic" {
    const block = TemplateAST.BlockNode{
        .name = "content",
        .content = TemplateAST.empty(),
    };
    try std.testing.expectEqualStrings("content", block.name);
    try std.testing.expectEqual(0, block.content.nodes.len);
}

test "TemplateAST.BlockNode with content" {
    const content_nodes = [_]TemplateAST.Node{
        .{ .text = "Block content" },
    };
    const block = TemplateAST.BlockNode{
        .name = "header",
        .content = TemplateAST.init(&content_nodes),
    };
    try std.testing.expectEqual(1, block.content.nodes.len);
    try std.testing.expectEqualStrings("Block content", block.content.nodes[0].text);
}

test "TemplateAST.BlockNode with multiple content nodes" {
    const content_nodes = [_]TemplateAST.Node{
        .{ .text = "First" },
        .{ .text = "Second" },
    };
    const block = TemplateAST.BlockNode{
        .name = "main",
        .content = TemplateAST.init(&content_nodes),
    };
    try std.testing.expectEqual(2, block.content.nodes.len);
}

test "TemplateAST complex nested structure" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"title"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const nodes = [_]TemplateAST.Node{
        .{ .text = "Header: " },
        .{ .variable = var_node },
        .{ .text = " - End" },
    };
    const ast = TemplateAST.init(&nodes);
    try std.testing.expectEqual(3, ast.nodes.len);
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Node).text, std.meta.activeTag(ast.nodes[0]));
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Node).variable, std.meta.activeTag(ast.nodes[1]));
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Node).text, std.meta.activeTag(ast.nodes[2]));
}

test "TemplateAST with if block node" {
    const condition_var = TemplateAST.VariableNode{
        .path = &[_][]const u8{"active"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const true_content = [_]TemplateAST.Node{.{ .text = "Active" }};
    const if_block = TemplateAST.IfBlock{
        .condition = .{ .simple = condition_var },
        .true_block = .{ .nodes = &true_content },
        .elif_blocks = &[_]TemplateAST.ElifBlock{},
        .false_block = null,
    };
    const nodes = [_]TemplateAST.Node{
        .{ .if_block = if_block },
    };
    const ast = TemplateAST{ .nodes = &nodes };
    try std.testing.expectEqual(1, ast.nodes.len);
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Node).if_block, std.meta.activeTag(ast.nodes[0]));
}

test "TemplateAST with for block node" {
    const for_block = TemplateAST.ForBlock{
        .collection_path = &[_][]const u8{"items"},
        .item_name = "item",
        .block = TemplateAST.empty(),
        .else_block = null,
    };
    const nodes = [_]TemplateAST.Node{
        .{ .for_block = for_block },
    };
    const ast = TemplateAST{ .nodes = &nodes };
    try std.testing.expectEqual(1, ast.nodes.len);
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Node).for_block, std.meta.activeTag(ast.nodes[0]));
}

test "TemplateAST with all node types" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"x"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const comment = TemplateAST.CommentNode{ .content = "test" };
    const include = TemplateAST.IncludeNode{
        .file_path = "file.html",
        .params = &[_]TemplateAST.IncludeParam{},
    };
    const extends = TemplateAST.ExtendsNode{ .parent_path = "base.html" };
    const block = TemplateAST.BlockNode{
        .name = "test",
        .content = TemplateAST.empty(),
    };
    const if_block = TemplateAST.IfBlock{
        .condition = .{ .simple = var_node },
        .true_block = TemplateAST.empty(),
        .elif_blocks = &[_]TemplateAST.ElifBlock{},
        .false_block = null,
    };
    const for_block = TemplateAST.ForBlock{
        .collection_path = &[_][]const u8{"items"},
        .item_name = "i",
        .block = TemplateAST.empty(),
        .else_block = null,
    };

    const nodes = [_]TemplateAST.Node{
        .{ .text = "text" },
        .{ .variable = var_node },
        .{ .raw_variable = var_node },
        .{ .comment = comment },
        .{ .include = include },
        .{ .extends = extends },
        .{ .block = block },
        .{ .if_block = if_block },
        .{ .for_block = for_block },
    };
    const ast = TemplateAST{ .nodes = &nodes };
    try std.testing.expectEqual(9, ast.nodes.len);
}

test "TemplateAST.VariableNode with deeply nested path" {
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{ "a", "b", "c", "d", "e", "f" },
        .filters = &[_]TemplateAST.Filter{},
    };
    try std.testing.expectEqual(6, var_node.path.len);
    try std.testing.expectEqualStrings("f", var_node.path[5]);
}

test "TemplateAST.Filter with long name" {
    const filter = TemplateAST.Filter{
        .name = "very_long_filter_name_with_underscores",
        .args = &[_][]const u8{},
    };
    try std.testing.expectEqualStrings("very_long_filter_name_with_underscores", filter.name);
}

test "TemplateAST.Filter with many args" {
    const filter = TemplateAST.Filter{
        .name = "custom",
        .args = &[_][]const u8{ "arg1", "arg2", "arg3", "arg4", "arg5" },
    };
    try std.testing.expectEqual(5, filter.args.len);
    try std.testing.expectEqualStrings("arg5", filter.args[4]);
}

test "TemplateAST.ComparisonValue with empty string" {
    const value = TemplateAST.ComparisonValue{ .literal_string = "" };
    try std.testing.expectEqualStrings("", value.literal_string);
}

test "TemplateAST.ComparisonValue with long string" {
    const value = TemplateAST.ComparisonValue{
        .literal_string = "This is a very long string used in comparison",
    };
    try std.testing.expectEqualStrings("This is a very long string used in comparison", value.literal_string);
}

test "TemplateAST.ComparisonValue with large integer" {
    const value = TemplateAST.ComparisonValue{ .literal_int = 9999999 };
    try std.testing.expectEqual(9999999, value.literal_int);
}

test "TemplateAST.IfBlock nested in another IfBlock" {
    const inner_var = TemplateAST.VariableNode{
        .path = &[_][]const u8{"inner"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const inner_if = TemplateAST.IfBlock{
        .condition = .{ .simple = inner_var },
        .true_block = TemplateAST.empty(),
        .elif_blocks = &[_]TemplateAST.ElifBlock{},
        .false_block = null,
    };
    const inner_nodes = [_]TemplateAST.Node{
        .{ .if_block = inner_if },
    };

    const outer_var = TemplateAST.VariableNode{
        .path = &[_][]const u8{"outer"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const outer_if = TemplateAST.IfBlock{
        .condition = .{ .simple = outer_var },
        .true_block = .{ .nodes = &inner_nodes },
        .elif_blocks = &[_]TemplateAST.ElifBlock{},
        .false_block = null,
    };

    try std.testing.expectEqual(1, outer_if.true_block.nodes.len);
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Node).if_block, std.meta.activeTag(outer_if.true_block.nodes[0]));
}

test "TemplateAST.ForBlock nested in IfBlock" {
    const for_block = TemplateAST.ForBlock{
        .collection_path = &[_][]const u8{"items"},
        .item_name = "item",
        .block = TemplateAST.empty(),
        .else_block = null,
    };
    const for_nodes = [_]TemplateAST.Node{
        .{ .for_block = for_block },
    };

    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{"has_items"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const if_block = TemplateAST.IfBlock{
        .condition = .{ .simple = var_node },
        .true_block = .{ .nodes = &for_nodes },
        .elif_blocks = &[_]TemplateAST.ElifBlock{},
        .false_block = null,
    };

    try std.testing.expectEqual(1, if_block.true_block.nodes.len);
    try std.testing.expectEqual(std.meta.Tag(TemplateAST.Node).for_block, std.meta.activeTag(if_block.true_block.nodes[0]));
}

test "TemplateAST.IfBlock with multiple elif blocks" {
    const var1 = TemplateAST.VariableNode{
        .path = &[_][]const u8{"a"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const var2 = TemplateAST.VariableNode{
        .path = &[_][]const u8{"b"},
        .filters = &[_]TemplateAST.Filter{},
    };
    const var3 = TemplateAST.VariableNode{
        .path = &[_][]const u8{"c"},
        .filters = &[_]TemplateAST.Filter{},
    };

    const elif_blocks = [_]TemplateAST.ElifBlock{
        .{ .condition = .{ .simple = var2 }, .block = TemplateAST.empty() },
        .{ .condition = .{ .simple = var3 }, .block = TemplateAST.empty() },
    };

    const if_block = TemplateAST.IfBlock{
        .condition = .{ .simple = var1 },
        .true_block = TemplateAST.empty(),
        .elif_blocks = &elif_blocks,
        .false_block = null,
    };

    try std.testing.expectEqual(2, if_block.elif_blocks.len);
}

test "TemplateAST.Node text with unicode" {
    const node = TemplateAST.Node{ .text = "Hello 世界 🌍" };
    try std.testing.expectEqualStrings("Hello 世界 🌍", node.text);
}

test "TemplateAST.Node text with newlines" {
    const node = TemplateAST.Node{ .text = "Line1\nLine2\nLine3" };
    try std.testing.expectEqualStrings("Line1\nLine2\nLine3", node.text);
}

test "TemplateAST.Node text with special characters" {
    const node = TemplateAST.Node{ .text = "<>&\"'{}[]" };
    try std.testing.expectEqualStrings("<>&\"'{}[]", node.text);
}

test "TemplateAST.VariableNode with filter and nested path" {
    const filter = TemplateAST.Filter{
        .name = "uppercase",
        .args = &[_][]const u8{},
    };
    const var_node = TemplateAST.VariableNode{
        .path = &[_][]const u8{ "user", "name" },
        .filters = &[_]TemplateAST.Filter{filter},
    };
    try std.testing.expectEqual(2, var_node.path.len);
    try std.testing.expectEqual(1, var_node.filters.len);
}

test "ParseError variants exist" {
    const err1: ParseError = error.UnexpectedEndOfInput;
    const err2: ParseError = error.InvalidVariableSyntax;
    const err3: ParseError = error.InvalidIfSyntax;
    const err4: ParseError = error.InvalidForSyntax;
    const err5: ParseError = error.UnclosedBlock;
    const err6: ParseError = error.InvalidIncludePath;
    const err7: ParseError = error.InvalidFilterSyntax;
    const err8: ParseError = error.InvalidComparisonSyntax;
    const err9: ParseError = error.InvalidBlockSyntax;
    const err10: ParseError = error.InvalidExtendsSyntax;

    try std.testing.expectEqual(error.UnexpectedEndOfInput, err1);
    try std.testing.expectEqual(error.InvalidVariableSyntax, err2);
    try std.testing.expectEqual(error.InvalidIfSyntax, err3);
    try std.testing.expectEqual(error.InvalidForSyntax, err4);
    try std.testing.expectEqual(error.UnclosedBlock, err5);
    try std.testing.expectEqual(error.InvalidIncludePath, err6);
    try std.testing.expectEqual(error.InvalidFilterSyntax, err7);
    try std.testing.expectEqual(error.InvalidComparisonSyntax, err8);
    try std.testing.expectEqual(error.InvalidBlockSyntax, err9);
    try std.testing.expectEqual(error.InvalidExtendsSyntax, err10);
}
