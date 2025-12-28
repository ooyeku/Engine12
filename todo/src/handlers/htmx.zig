const std = @import("std");
const E12 = @import("engine12");
const Request = E12.Request;
const Response = E12.Response;
const htmx = E12.htmx;
const FormValidator = htmx.FormValidator;
const validators = htmx.validators;
const ParamList = E12.orm.ParamList;
const database = @import("../database.zig");
const models = @import("../models.zig");
const Todo = models.Todo;
const BasicAuthValve = E12.BasicAuthValve;

const allocator = std.heap.page_allocator;

// ============================================================================
// Form Parsing Utilities
// ============================================================================

/// Simple form data parser for application/x-www-form-urlencoded
fn getFormValue(body: []const u8, key: []const u8) ?[]const u8 {
    var iter = std.mem.splitSequence(u8, body, "&");
    while (iter.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
            const k = pair[0..eq_pos];
            const v = pair[eq_pos + 1 ..];
            if (std.mem.eql(u8, k, key)) {
                return v;
            }
        }
    }
    return null;
}

/// URL decode a string
fn urlDecode(input: []const u8, out: []u8) []const u8 {
    var i: usize = 0;
    var j: usize = 0;
    while (i < input.len and j < out.len) {
        if (input[i] == '+') {
            out[j] = ' ';
            i += 1;
        } else if (input[i] == '%' and i + 2 < input.len) {
            const hex = input[i + 1 .. i + 3];
            out[j] = std.fmt.parseInt(u8, hex, 16) catch {
                out[j] = input[i];
                i += 1;
                j += 1;
                continue;
            };
            i += 3;
        } else {
            out[j] = input[i];
            i += 1;
        }
        j += 1;
    }
    return out[0..j];
}

/// Get query parameter from URL
fn getQueryParam(path: []const u8, key: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, path, "?")) |q_pos| {
        const query = path[q_pos + 1 ..];
        var iter = std.mem.splitSequence(u8, query, "&");
        while (iter.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
                const k = pair[0..eq_pos];
                const v = pair[eq_pos + 1 ..];
                if (std.mem.eql(u8, k, key)) {
                    return v;
                }
            }
        }
    }
    return null;
}

// ============================================================================
// HTML Rendering Utilities
// ============================================================================

/// Get priority class based on priority value
fn getPriorityClass(priority: []const u8) []const u8 {
    if (std.mem.eql(u8, priority, "high")) return "priority-high";
    if (std.mem.eql(u8, priority, "low")) return "priority-low";
    return "priority-medium";
}

/// HTML escape special characters
fn htmlEscape(input: []const u8, out: []u8) []const u8 {
    var j: usize = 0;
    for (input) |c| {
        const replacement: []const u8 = switch (c) {
            '<' => "&lt;",
            '>' => "&gt;",
            '&' => "&amp;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => {
                if (j < out.len) {
                    out[j] = c;
                    j += 1;
                }
                continue;
            },
        };
        for (replacement) |r| {
            if (j < out.len) {
                out[j] = r;
                j += 1;
            }
        }
    }
    return out[0..j];
}

/// Render a single todo item as HTML fragment
fn renderTodoItem(todo: Todo, buf: *std.ArrayListUnmanaged(u8)) !void {
    const priority_class = getPriorityClass(todo.priority);
    const completed_class = if (todo.completed) " completed" else "";
    const checked = if (todo.completed) " checked" else "";

    // Build todo ID string
    var id_buf: [20]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{todo.id}) catch "0";

    // Open list item with priority border
    try buf.appendSlice(allocator, "<li id=\"todo-");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "\" class=\"todo-item ");
    try buf.appendSlice(allocator, priority_class);
    try buf.appendSlice(allocator, completed_class);
    try buf.appendSlice(allocator, "\">\n");

    // Checkbox with HTMX toggle
    try buf.appendSlice(allocator, "  <input type=\"checkbox\" class=\"todo-checkbox\" ");
    try buf.appendSlice(allocator, "hx-post=\"/htmx/todos/");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "/toggle\" hx-target=\"#todo-");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "\" hx-swap=\"outerHTML\"");
    try buf.appendSlice(allocator, checked);
    try buf.appendSlice(allocator, ">\n");

    // Content section
    try buf.appendSlice(allocator, "  <div class=\"todo-content\">\n");

    // Title (escaped)
    var title_escaped: [512]u8 = undefined;
    const safe_title = htmlEscape(todo.title, &title_escaped);
    try buf.appendSlice(allocator, "    <div class=\"todo-title\">");
    try buf.appendSlice(allocator, safe_title);
    try buf.appendSlice(allocator, "</div>\n");

    // Description (if present)
    if (todo.description.len > 0) {
        var desc_escaped: [2048]u8 = undefined;
        const safe_desc = htmlEscape(todo.description, &desc_escaped);
        try buf.appendSlice(allocator, "    <div class=\"todo-description\">");
        try buf.appendSlice(allocator, safe_desc);
        try buf.appendSlice(allocator, "</div>\n");
    }

    // Meta info (tags, due date) - only show if there's content
    const has_tags = todo.tags.len > 0;
    const has_due = todo.due_date != null;

    if (has_tags or has_due) {
        try buf.appendSlice(allocator, "    <div class=\"todo-meta\">\n");

        // Due date first
        if (todo.due_date) |due| {
            const now = std.time.timestamp();
            const is_overdue = !todo.completed and due < now;
            const due_class = if (is_overdue) " overdue" else "";

            // Format date
            var date_buf: [32]u8 = undefined;
            const date_str = formatTimestamp(due, &date_buf);

            try buf.appendSlice(allocator, "      <span class=\"todo-due");
            try buf.appendSlice(allocator, due_class);
            try buf.appendSlice(allocator, "\">");
            // Calendar icon SVG
            try buf.appendSlice(allocator, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"3\" y=\"4\" width=\"18\" height=\"18\" rx=\"2\" ry=\"2\"></rect><line x1=\"16\" y1=\"2\" x2=\"16\" y2=\"6\"></line><line x1=\"8\" y1=\"2\" x2=\"8\" y2=\"6\"></line><line x1=\"3\" y1=\"10\" x2=\"21\" y2=\"10\"></line></svg>");
            try buf.appendSlice(allocator, date_str);
            try buf.appendSlice(allocator, "</span>\n");
        }

        // Tags
        if (todo.tags.len > 0) {
            var tags_iter = std.mem.splitSequence(u8, todo.tags, ",");
            while (tags_iter.next()) |tag_raw| {
                const tag = std.mem.trim(u8, tag_raw, " ");
                if (tag.len > 0) {
                    var tag_escaped: [128]u8 = undefined;
                    const safe_tag = htmlEscape(tag, &tag_escaped);
                    try buf.appendSlice(allocator, "      <span class=\"todo-tag\">#");
                    try buf.appendSlice(allocator, safe_tag);
                    try buf.appendSlice(allocator, "</span>\n");
                }
            }
        }

        try buf.appendSlice(allocator, "    </div>\n");
    }

    try buf.appendSlice(allocator, "  </div>\n");

    // Actions
    try buf.appendSlice(allocator, "  <div class=\"todo-actions\">\n");

    // Edit button (icon)
    try buf.appendSlice(allocator, "    <button class=\"btn-icon btn-edit\" title=\"Edit\" ");
    try buf.appendSlice(allocator, "hx-get=\"/htmx/todos/");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "/edit\" hx-target=\"#todo-");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "\" hx-swap=\"outerHTML\">");
    // Edit icon SVG
    try buf.appendSlice(allocator, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7\"></path><path d=\"M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z\"></path></svg>");
    try buf.appendSlice(allocator, "</button>\n");

    // Delete button (icon) with confirmation
    try buf.appendSlice(allocator, "    <button class=\"btn-icon btn-delete\" title=\"Delete\" ");
    try buf.appendSlice(allocator, "hx-delete=\"/htmx/todos/");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "\" hx-target=\"#todo-");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "\" hx-swap=\"outerHTML\" ");
    try buf.appendSlice(allocator, "hx-confirm=\"Are you sure you want to delete this todo?\">");
    // Trash icon SVG
    try buf.appendSlice(allocator, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><polyline points=\"3 6 5 6 21 6\"></polyline><path d=\"M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2\"></path><line x1=\"10\" y1=\"11\" x2=\"10\" y2=\"17\"></line><line x1=\"14\" y1=\"11\" x2=\"14\" y2=\"17\"></line></svg>");
    try buf.appendSlice(allocator, "</button>\n");

    try buf.appendSlice(allocator, "  </div>\n");
    try buf.appendSlice(allocator, "</li>\n");
}

/// Format timestamp to readable date string
fn formatTimestamp(timestamp: i64, buf: []u8) []const u8 {
    // Simple date formatting: YYYY-MM-DD
    const epoch_seconds: u64 = @intCast(if (timestamp > 0) timestamp else 0);
    const secs_per_day: u64 = 86400;
    const days_since_epoch = epoch_seconds / secs_per_day;

    // Calculate year, month, day (simplified)
    var year: u32 = 1970;
    var remaining_days = days_since_epoch;

    while (true) {
        const days_in_year: u64 = if (isLeapYear(year)) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    const days_in_months = if (isLeapYear(year))
        [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u8 = 1;
    for (days_in_months) |dim| {
        if (remaining_days < dim) break;
        remaining_days -= dim;
        month += 1;
    }

    const day: u8 = @intCast(remaining_days + 1);

    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch "Invalid date";
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

// ============================================================================
// Request Handlers
// ============================================================================

/// Handle listing todos (returns HTML fragment for HTMX)
pub fn handleListTodos(req: *Request) Response {
    const page_param = req.queryParam("page") catch null;
    const page = if (page_param) |p| std.fmt.parseInt(usize, p.asString(), 10) catch 1 else 1;
    const per_page: usize = 10;

    const orm = database.getORM() catch {
        return htmx.errors.errorFragment("Database not initialized");
    };

    var todos = orm.findAll(Todo) catch {
        return htmx.errors.errorFragment("Failed to load todos");
    };
    defer todos.deinit(orm.allocator);

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    if (todos.items.len == 0) {
        buf.appendSlice(allocator, "<li class=\"empty-state\"><div class=\"empty-state-icon\"></div><p>No todos yet. Add one above!</p></li>") catch {};
    } else {
        const start_idx = (page - 1) * per_page;
        const end_idx = @min(start_idx + per_page, todos.items.len);

        if (start_idx < todos.items.len) {
            for (todos.items[start_idx..end_idx]) |todo| {
                renderTodoItem(todo, &buf) catch continue;
            }

            // Add infinite scroll trigger if more items exist
            if (end_idx < todos.items.len) {
                const trigger = htmx.nextPageTrigger(allocator, "/htmx/todos/all", page + 1) catch "";
                buf.appendSlice(allocator, trigger) catch {};
                allocator.free(trigger);
            }
        }
    }

    return Response.fragment(buf.toOwnedSlice(allocator) catch "");
}

/// Handle searching todos
pub fn handleSearchTodos(req: *Request) Response {
    const path = req.path();

    // Get search query from URL or body
    var search_buf: [256]u8 = undefined;
    var search_query: []const u8 = "";

    if (getQueryParam(path, "q")) |q| {
        search_query = urlDecode(q, &search_buf);
    }

    // Return empty state if query is too short
    if (search_query.len < 2) {
        const empty = htmx.searchNoResults(allocator, "Type at least 2 characters to search...") catch "";
        defer allocator.free(empty);
        return Response.fragment(empty);
    }

    const orm = database.getORM() catch {
        return htmx.errors.errorFragment("Database not initialized");
    };

    var todos = orm.findAll(Todo) catch {
        return htmx.errors.errorFragment("Failed to load todos");
    };
    defer todos.deinit(orm.allocator);

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    var count: usize = 0;
    const search_lower = std.ascii.lowerString(&search_buf, search_query);

    for (todos.items) |todo| {
        // Search in title, description, and tags
        var title_lower_buf: [512]u8 = undefined;
        const title_lower = std.ascii.lowerString(&title_lower_buf, todo.title);

        var desc_lower_buf: [2048]u8 = undefined;
        const desc_lower = std.ascii.lowerString(&desc_lower_buf, todo.description);

        var tags_lower_buf: [256]u8 = undefined;
        const tags_lower = std.ascii.lowerString(&tags_lower_buf, todo.tags);

        const matches = search_lower.len == 0 or
            std.mem.indexOf(u8, title_lower, search_lower) != null or
            std.mem.indexOf(u8, desc_lower, search_lower) != null or
            std.mem.indexOf(u8, tags_lower, search_lower) != null;

        if (matches) {
            renderTodoItem(todo, &buf) catch continue;
            count += 1;
        }
    }

    if (count == 0) {
        buf.appendSlice(allocator, "<li class=\"empty-state\"><div class=\"empty-state-icon\"></div><p>No matching todos found.</p></li>") catch {};
    }

    return Response.fragment(buf.toOwnedSlice(allocator) catch "");
}

/// Handle creating a new todo (returns HTML fragment for the new item)
pub fn handleCreateTodo(req: *Request) Response {
    // Use type-safe form validator for cleaner code
    const TodoForm = struct {
        title: []const u8,
        description: ?[]const u8,
        priority: ?[]const u8,
        tags: ?[]const u8,
    };

    var form_parser = req.getFormParser();
    var validator = htmx.FormValidator.init(form_parser, req.allocator());
    defer validator.deinit();

    // Use built-in validators for better validation
    validator.validate("title", validators.isRequiredTrimmed, "Title cannot be empty");
    validator.validate("title", validators.minLength(3), "Title must be at least 3 characters");
    validator.validate("title", validators.maxLength(100), "Title too long (max 100 characters)");

    const form = validator.parseInto(TodoForm) catch {
        if (validator.hasErrors()) {
            const error_toast = htmx.toast(allocator, "Please fix validation errors", .err) catch "";
            var oob_builder = htmx.OobSwapBuilder.init(allocator);
            defer oob_builder.deinit();
            return oob_builder
                .primary("")
                .swap("#toast", error_toast)
                .status(400)
                .build();
        }
        return htmx.errors.errorFragment("Failed to parse form");
    };

    // Handle optional fields with defaults
    defer req.allocator().free(form.title);
    defer if (form.description) |d| req.allocator().free(d);
    defer if (form.priority) |p| req.allocator().free(p);
    defer if (form.tags) |t| req.allocator().free(t);

    const description = form.description orelse "";
    const priority = form.priority orelse "medium";
    const tags = form.tags orelse "";

    // Parse due date manually (FormValidator doesn't support custom date parsing yet)
    const due_date = form_parser.getDate("due_date") catch null;

    const orm = database.getORM() catch {
        return htmx.errors.errorFragmentWithStatus("Database not initialized", 500);
    };

    // Get authenticated user - if no auth, use default user_id = 1 for demo purposes
    // In production, you should require authentication
    const user_id: i64 = if (BasicAuthValve.requireAuth(req)) |user| blk: {
        const id = user.id;
        allocator.free(user.username);
        allocator.free(user.email);
        allocator.free(user.password_hash);
        break :blk id;
    } else |_| 1; // Default to user_id = 1 for demo/testing

    // Allocate strings for Todo struct (using page allocator since they persist)
    const title_copy = allocator.dupe(u8, form.title) catch {
        return htmx.errors.errorFragmentWithStatus("Memory error", 500);
    };
    const desc_copy = if (description.len > 0)
        allocator.dupe(u8, description) catch {
            allocator.free(title_copy);
            return htmx.errors.errorFragmentWithStatus("Memory error", 500);
        }
    else
        "";
    const priority_copy = allocator.dupe(u8, priority) catch {
        allocator.free(title_copy);
        if (desc_copy.len > 0) allocator.free(desc_copy);
        return htmx.errors.errorFragmentWithStatus("Memory error", 500);
    };
    const tags_copy = allocator.dupe(u8, tags) catch {
        allocator.free(title_copy);
        if (desc_copy.len > 0) allocator.free(desc_copy);
        allocator.free(priority_copy);
        return htmx.errors.errorFragmentWithStatus("Memory error", 500);
    };

    var todo = Todo{
        .id = 0,
        .user_id = user_id,
        .title = title_copy,
        .description = @constCast(desc_copy),
        .completed = false,
        .priority = priority_copy,
        .due_date = due_date,
        .tags = tags_copy,
        .created_at = std.time.timestamp(),
        .updated_at = std.time.timestamp(),
    };

    const created_id = orm.create(Todo, todo) catch {
        return htmx.errors.errorFragmentWithStatus("Failed to create todo", 500);
    };

    // Invalidate stats cache
    htmx.invalidateCache("todo:stats");

    todo.id = created_id;

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    renderTodoItem(todo, &buf) catch {
        return htmx.errors.errorFragment("Failed to render todo");
    };

    // Use Response.compose() for cleaner fragment composition (Tier 4)
    const success_toast = htmx.toast(allocator, "Todo created successfully!", .success) catch "";

    var composer = Response.compose(allocator);
    defer composer.deinit();

    return composer
        .fragment("#todo-list", buf.toOwnedSlice(allocator) catch "")
        .oob("#toast", success_toast)
        .trigger("todoCreated")
        .status(201)
        .build();
}

/// Parse date string (YYYY-MM-DD) to timestamp
fn parseDateToTimestamp(date_str: []const u8) ?i64 {
    if (date_str.len < 10) return null;

    const year = std.fmt.parseInt(u32, date_str[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, date_str[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, date_str[8..10], 10) catch return null;

    // Calculate days since epoch
    var days: i64 = 0;
    var y: u32 = 1970;
    while (y < year) : (y += 1) {
        days += if (isLeapYear(y)) 366 else 365;
    }

    const days_in_months = if (isLeapYear(year))
        [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += days_in_months[m - 1];
    }

    days += day - 1;

    return days * 86400;
}

/// Handle toggling todo completion
pub fn handleToggleTodo(req: *Request) Response {
    const id_str = req.param("id").asString();
    if (id_str.len == 0) {
        return htmx.errors.validationErrorFragment("id", "Invalid ID");
    }

    const id: i64 = std.fmt.parseInt(i64, id_str, 10) catch {
        return htmx.errors.validationErrorFragment("id", "Invalid ID format");
    };

    const orm = database.getORM() catch {
        return htmx.errors.errorFragmentWithStatus("Database not initialized", 500);
    };

    // Use findOne for simpler single-record lookup (new API)
    var todo = orm.findOne(Todo, id) catch {
        return htmx.errors.notFoundFragment("Todo");
    } orelse {
        return htmx.errors.notFoundFragment("Todo");
    };

    todo.completed = !todo.completed;
    todo.updated_at = std.time.timestamp();

    orm.update(Todo, todo) catch {
        return htmx.errors.errorFragmentWithStatus("Failed to update todo", 500);
    };

    // Invalidate stats cache
    htmx.invalidateCache("todo:stats");

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    renderTodoItem(todo, &buf) catch {
        return htmx.errors.errorFragment("Failed to render todo");
    };

    // Use Response.compose() for cleaner fragment composition (Tier 4)
    const success_toast = htmx.toast(allocator, "Todo updated successfully!", .success) catch "";

    var composer = Response.compose(allocator);
    defer composer.deinit();

    return composer
        .fragment("#todo-item", buf.toOwnedSlice(allocator) catch "")
        .oob("#toast", success_toast)
        .trigger("todoUpdated")
        .build();
}

/// Handle getting edit form for a todo
pub fn handleEditTodo(req: *Request) Response {
    const id_str = req.param("id").asString();
    if (id_str.len == 0) {
        return htmx.errors.validationErrorFragment("id", "Invalid ID");
    }

    const id: i64 = std.fmt.parseInt(i64, id_str, 10) catch {
        return htmx.errors.validationErrorFragment("id", "Invalid ID format");
    };

    const orm = database.getORM() catch {
        return htmx.errors.errorFragmentWithStatus("Database not initialized", 500);
    };

    // Use findOne for simpler single-record lookup (new API)
    const todo = orm.findOne(Todo, id) catch {
        return htmx.errors.notFoundFragment("Todo");
    } orelse {
        return htmx.errors.notFoundFragment("Todo");
    };

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    var id_buf: [20]u8 = undefined;
    const id_fmt = std.fmt.bufPrint(&id_buf, "{d}", .{todo.id}) catch "0";

    // Build beautiful edit form
    buf.appendSlice(allocator, "<li id=\"todo-") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, id_fmt) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    buf.appendSlice(allocator, "  <form class=\"edit-form\" hx-put=\"/htmx/todos/") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, id_fmt) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "\" hx-target=\"#todo-") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, id_fmt) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "\" hx-swap=\"outerHTML\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Title input
    buf.appendSlice(allocator, "    <div class=\"form-group\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "      <label>Title</label>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "      <input type=\"text\" name=\"title\" value=\"") catch return Response.fragment("<li class=\"error\">Error</li>");
    var title_escaped: [512]u8 = undefined;
    buf.appendSlice(allocator, htmlEscape(todo.title, &title_escaped)) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "\" required placeholder=\"Task title\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "    </div>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Description input
    buf.appendSlice(allocator, "    <div class=\"form-group\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "      <label>Description</label>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "      <input type=\"text\" name=\"description\" value=\"") catch return Response.fragment("<li class=\"error\">Error</li>");
    var desc_escaped: [2048]u8 = undefined;
    buf.appendSlice(allocator, htmlEscape(todo.description, &desc_escaped)) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "\" placeholder=\"Add details...\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "    </div>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Priority, Due Date, Tags in a row
    buf.appendSlice(allocator, "    <div class=\"form-row-inline\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Priority select
    buf.appendSlice(allocator, "      <div class=\"form-group\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "        <label>Priority</label>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "        <select name=\"priority\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Low priority
    buf.appendSlice(allocator, "          <option value=\"low\"") catch return Response.fragment("<li class=\"error\">Error</li>");
    if (std.mem.eql(u8, todo.priority, "low")) {
        buf.appendSlice(allocator, " selected") catch return Response.fragment("<li class=\"error\">Error</li>");
    }
    buf.appendSlice(allocator, ">Low Priority</option>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Medium priority
    buf.appendSlice(allocator, "          <option value=\"medium\"") catch return Response.fragment("<li class=\"error\">Error</li>");
    if (std.mem.eql(u8, todo.priority, "medium")) {
        buf.appendSlice(allocator, " selected") catch return Response.fragment("<li class=\"error\">Error</li>");
    }
    buf.appendSlice(allocator, ">Medium Priority</option>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // High priority
    buf.appendSlice(allocator, "          <option value=\"high\"") catch return Response.fragment("<li class=\"error\">Error</li>");
    if (std.mem.eql(u8, todo.priority, "high")) {
        buf.appendSlice(allocator, " selected") catch return Response.fragment("<li class=\"error\">Error</li>");
    }
    buf.appendSlice(allocator, ">High Priority</option>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    buf.appendSlice(allocator, "        </select>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "      </div>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Due date input
    buf.appendSlice(allocator, "      <div class=\"form-group\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "        <label>Due Date</label>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "        <input type=\"date\" name=\"due_date\" value=\"") catch return Response.fragment("<li class=\"error\">Error</li>");
    if (todo.due_date) |due| {
        var date_buf: [32]u8 = undefined;
        const date_str = formatTimestamp(due, &date_buf);
        buf.appendSlice(allocator, date_str) catch return Response.fragment("<li class=\"error\">Error</li>");
    }
    buf.appendSlice(allocator, "\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "      </div>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Tags input
    buf.appendSlice(allocator, "      <div class=\"form-group\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "        <label>Tags</label>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "        <input type=\"text\" name=\"tags\" value=\"") catch return Response.fragment("<li class=\"error\">Error</li>");
    var tags_escaped: [256]u8 = undefined;
    buf.appendSlice(allocator, htmlEscape(todo.tags, &tags_escaped)) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "\" placeholder=\"work, urgent\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "      </div>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    buf.appendSlice(allocator, "    </div>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Action buttons
    buf.appendSlice(allocator, "    <div class=\"form-actions\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "      <button type=\"button\" class=\"btn btn-cancel\" hx-get=\"/htmx/todos/") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, id_fmt) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "/view\" hx-target=\"#todo-") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, id_fmt) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "\" hx-swap=\"outerHTML\">Cancel</button>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "      <button type=\"submit\" class=\"btn btn-save\">Save Changes</button>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "    </div>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    buf.appendSlice(allocator, "  </form>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "</li>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    return Response.fragment(buf.toOwnedSlice(allocator) catch "");
}

/// Handle updating a todo
pub fn handleUpdateTodo(req: *Request) Response {
    const id_str = req.param("id").asString();
    if (id_str.len == 0) {
        return htmx.errors.validationErrorFragment("id", "Invalid ID");
    }

    const id: i64 = std.fmt.parseInt(i64, id_str, 10) catch {
        return htmx.errors.validationErrorFragment("id", "Invalid ID format");
    };

    const orm = database.getORM() catch {
        return htmx.errors.errorFragmentWithStatus("Database not initialized", 500);
    };

    // Use findOne for simpler single-record lookup (new API)
    var todo = orm.findOne(Todo, id) catch {
        return htmx.errors.notFoundFragment("Todo");
    } orelse {
        return htmx.errors.notFoundFragment("Todo");
    };

    var form_parser = req.getFormParser();

    // Validate using built-in validators
    var validator = htmx.FormValidator.init(form_parser, req.allocator());
    defer validator.deinit();

    validator.validate("title", validators.isRequiredTrimmed, "Title cannot be empty");
    validator.validate("title", validators.minLength(3), "Title must be at least 3 characters");
    validator.validate("title", validators.maxLength(100), "Title too long");

    if (validator.hasErrors()) {
        const error_toast = htmx.toast(allocator, "Validation failed", .err) catch "";
        var oob_builder = htmx.OobSwapBuilder.init(allocator);
        defer oob_builder.deinit();
        return oob_builder
            .primary("")
            .swap("#toast", error_toast)
            .status(400)
            .build();
    }

    // Update fields from form
    if (form_parser.get("title") catch null) |title| {
        defer req.allocator().free(title);
        if (title.len > 0) {
            const title_copy = allocator.dupe(u8, title) catch {
                return htmx.errors.errorFragmentWithStatus("Memory error", 500);
            };
            todo.title = title_copy;
        }
    }

    if (form_parser.get("description") catch null) |desc| {
        defer req.allocator().free(desc);
        const desc_copy = allocator.dupe(u8, desc) catch {
            return htmx.errors.errorFragmentWithStatus("Memory error", 500);
        };
        todo.description = desc_copy;
    }

    if (form_parser.get("priority") catch null) |priority| {
        defer req.allocator().free(priority);
        const priority_copy = allocator.dupe(u8, priority) catch {
            return htmx.errors.errorFragmentWithStatus("Memory error", 500);
        };
        todo.priority = priority_copy;
    }

    if (form_parser.get("tags") catch null) |tags| {
        defer req.allocator().free(tags);
        const tags_copy = allocator.dupe(u8, tags) catch {
            return htmx.errors.errorFragmentWithStatus("Memory error", 500);
        };
        todo.tags = tags_copy;
    }

    // Parse due date
    const due_date = form_parser.getDate("due_date") catch null;
    todo.due_date = due_date;

    todo.updated_at = std.time.timestamp();

    orm.update(Todo, todo) catch {
        return htmx.errors.errorFragmentWithStatus("Failed to update todo", 500);
    };

    // Invalidate stats cache
    htmx.invalidateCache("todo:stats");

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    renderTodoItem(todo, &buf) catch {
        return htmx.errors.errorFragment("Failed to render todo");
    };

    return Response.fragment(buf.toOwnedSlice(allocator) catch "")
        .htmxTrigger("todoUpdated");
}

/// Handle viewing a single todo (for cancel edit)
pub fn handleViewTodo(req: *Request) Response {
    const id_str = req.param("id").asString();
    if (id_str.len == 0) {
        return htmx.errors.validationErrorFragment("id", "Invalid ID");
    }

    const id: i64 = std.fmt.parseInt(i64, id_str, 10) catch {
        return htmx.errors.validationErrorFragment("id", "Invalid ID format");
    };

    const orm = database.getORM() catch {
        return htmx.errors.errorFragmentWithStatus("Database not initialized", 500);
    };

    // Use findOne for simpler single-record lookup (new API)
    const todo = orm.findOne(Todo, id) catch {
        return htmx.errors.notFoundFragment("Todo");
    } orelse {
        return htmx.errors.notFoundFragment("Todo");
    };

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    renderTodoItem(todo, &buf) catch {
        return htmx.errors.errorFragment("Failed to render todo");
    };

    return Response.fragment(buf.toOwnedSlice(allocator) catch "");
}

/// Handle deleting a todo
pub fn handleDeleteTodo(req: *Request) Response {
    const id_str = req.param("id").asString();
    if (id_str.len == 0) {
        return htmx.errors.validationErrorFragment("id", "Invalid ID");
    }

    const id: i64 = std.fmt.parseInt(i64, id_str, 10) catch {
        return htmx.errors.validationErrorFragment("id", "Invalid ID format");
    };

    const orm = database.getORM() catch {
        return htmx.errors.errorFragmentWithStatus("Database not initialized", 500);
    };

    orm.delete(Todo, id) catch {
        const error_toast = htmx.toast(allocator, "Failed to delete todo", .err) catch "";
        var oob_builder = htmx.OobSwapBuilder.init(allocator);
        defer oob_builder.deinit();

        return oob_builder
            .primary("")
            .swap("#toast", error_toast)
            .status(500)
            .build();
    };

    // Invalidate stats cache
    htmx.invalidateCache("todo:stats");

    // Use Response.compose() for cleaner fragment composition (Tier 4)
    const success_toast = htmx.toast(allocator, "Todo deleted successfully!", .success) catch "";

    var composer = Response.compose(allocator);
    defer composer.deinit();

    return composer
        .fragment("", "")
        .oob("#toast", success_toast)
        .trigger("todoDeleted")
        .build();
}

/// Handle getting todo stats
pub fn handleGetStats(req: *Request) Response {
    // Use HtmxContext for type-safe access to HTMX request state (Tier 4)
    const ctx = htmx.htmx(req);

    // Only cache for HTMX partial requests (not full page loads)
    const should_cache = ctx.shouldReturnPartial();

    // Try cache first (5 second TTL)
    const cache_key = "todo:stats";
    if (should_cache) {
        if (htmx.getCachedResponse(cache_key)) |entry| {
            return Response.fragment(entry.html);
        }
    }

    const orm = database.getORM() catch {
        return Response.fragment("<div class=\"stat-pill\"><span class=\"value\">!</span><span class=\"label\">error</span></div>");
    };

    var todos = orm.findAll(Todo) catch {
        return Response.fragment("<div class=\"stat-pill\"><span class=\"value\">!</span><span class=\"label\">error</span></div>");
    };
    defer todos.deinit(orm.allocator);

    var total: u32 = 0;
    var completed: u32 = 0;
    var pending: u32 = 0;
    var overdue: u32 = 0;
    const now = std.time.timestamp();

    for (todos.items) |todo| {
        total += 1;
        if (todo.completed) {
            completed += 1;
        } else {
            pending += 1;
            if (todo.due_date) |due| {
                if (due < now) {
                    overdue += 1;
                }
            }
        }
    }

    const progress: u32 = if (total > 0) (completed * 100) / total else 0;

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    var num_buf: [20]u8 = undefined;

    // Total pill
    buf.appendSlice(allocator, "<div class=\"stat-pill\"><span class=\"value\">") catch return Response.fragment("");
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{total}) catch "0") catch return Response.fragment("");
    buf.appendSlice(allocator, "</span><span class=\"label\">total</span></div>\n") catch return Response.fragment("");

    // Pending pill
    buf.appendSlice(allocator, "<div class=\"stat-pill\"><span class=\"value\">") catch return Response.fragment("");
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{pending}) catch "0") catch return Response.fragment("");
    buf.appendSlice(allocator, "</span><span class=\"label\">pending</span></div>\n") catch return Response.fragment("");

    // Completed pill
    buf.appendSlice(allocator, "<div class=\"stat-pill\"><span class=\"value\">") catch return Response.fragment("");
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{completed}) catch "0") catch return Response.fragment("");
    buf.appendSlice(allocator, "</span><span class=\"label\">done</span></div>\n") catch return Response.fragment("");

    // Progress pill (with special styling)
    buf.appendSlice(allocator, "<div class=\"stat-pill progress\"><span class=\"value\">") catch return Response.fragment("");
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}%", .{progress}) catch "0%") catch return Response.fragment("");
    buf.appendSlice(allocator, "</span><span class=\"label\">progress</span></div>\n") catch return Response.fragment("");

    // Overdue pill (only if there are overdue items)
    if (overdue > 0) {
        buf.appendSlice(allocator, "<div class=\"stat-pill\" style=\"background:rgba(248,113,113,0.15);border:1px solid rgba(248,113,113,0.25)\"><span class=\"value\" style=\"color:#f87171\">") catch return Response.fragment("");
        buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{overdue}) catch "0") catch return Response.fragment("");
        buf.appendSlice(allocator, "</span><span class=\"label\" style=\"color:#f87171\">overdue</span></div>") catch return Response.fragment("");
    }

    const html = buf.toOwnedSlice(allocator) catch "";

    // Cache the result for 5 seconds
    htmx.cacheResponse(cache_key, html, 5000) catch {};

    return Response.fragment(html);
}

/// Handle clearing all completed todos
pub fn handleClearCompleted(req: *Request) Response {
    const orm = database.getORM() catch {
        return htmx.errors.errorFragment("Database not initialized");
    };

    // Use parameterized query for consistency and SQL injection prevention
    var params = ParamList.init(allocator);
    defer params.deinit();
    params.addInt(1) catch {
        return htmx.errors.errorFragmentWithStatus("Failed to prepare query", 500);
    };

    orm.db.executeParams("DELETE FROM todos WHERE completed = ?", &params) catch {
        return htmx.errors.errorFragmentWithStatus("Failed to clear completed", 500);
    };

    // Return the updated todo list
    return handleListTodos(req)
        .htmxTrigger("todosCleared");
}

/// Handle page views (active, completed, all)
pub fn handlePageActive(req: *Request) Response {
    _ = req;

    const orm = database.getORM() catch {
        return Response.fragment("<ul id=\"todo-list\" class=\"todo-list\"><li class=\"error\">Database error</li></ul>");
    };

    var todos = orm.findAll(Todo) catch {
        return Response.fragment("<ul id=\"todo-list\" class=\"todo-list\"><li class=\"error\">Failed to load</li></ul>");
    };
    defer todos.deinit(orm.allocator);

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "<ul id=\"todo-list\" class=\"todo-list\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    var count: usize = 0;
    for (todos.items) |todo| {
        if (!todo.completed) {
            renderTodoItem(todo, &buf) catch continue;
            count += 1;
        }
    }

    if (count == 0) {
        buf.appendSlice(allocator, "<li class=\"empty-state\"><div class=\"empty-state-icon\"></div><p>All caught up! No active todos.</p></li>\n") catch {};
    }

    buf.appendSlice(allocator, "</ul>") catch {};

    return Response.fragment(buf.toOwnedSlice(allocator) catch "");
}

pub fn handlePageCompleted(req: *Request) Response {
    _ = req;

    const orm = database.getORM() catch {
        return Response.fragment("<ul id=\"todo-list\" class=\"todo-list\"><li class=\"error\">Database error</li></ul>");
    };

    var todos = orm.findAll(Todo) catch {
        return Response.fragment("<ul id=\"todo-list\" class=\"todo-list\"><li class=\"error\">Failed to load</li></ul>");
    };
    defer todos.deinit(orm.allocator);

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "<ul id=\"todo-list\" class=\"todo-list\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    var count: usize = 0;
    for (todos.items) |todo| {
        if (todo.completed) {
            renderTodoItem(todo, &buf) catch continue;
            count += 1;
        }
    }

    if (count == 0) {
        buf.appendSlice(allocator, "<li class=\"empty-state\"><div class=\"empty-state-icon\"></div><p>No completed todos yet.</p></li>\n") catch {};
    }

    buf.appendSlice(allocator, "</ul>") catch {};

    return Response.fragment(buf.toOwnedSlice(allocator) catch "");
}

pub fn handlePageAll(req: *Request) Response {
    _ = req;

    const orm = database.getORM() catch {
        return Response.fragment("<ul id=\"todo-list\" class=\"todo-list\"><li class=\"error\">Database error</li></ul>");
    };

    var todos = orm.findAll(Todo) catch {
        return Response.fragment("<ul id=\"todo-list\" class=\"todo-list\"><li class=\"error\">Failed to load</li></ul>");
    };
    defer todos.deinit(orm.allocator);

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "<ul id=\"todo-list\" class=\"todo-list\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    if (todos.items.len == 0) {
        buf.appendSlice(allocator, "<li class=\"empty-state\"><div class=\"empty-state-icon\"></div><p>No todos yet. Add one above!</p></li>\n") catch {};
    } else {
        for (todos.items) |todo| {
            renderTodoItem(todo, &buf) catch continue;
        }
    }

    buf.appendSlice(allocator, "</ul>") catch {};

    return Response.fragment(buf.toOwnedSlice(allocator) catch "");
}

/// Handle auth status check
pub fn handleAuthStatus(req: *Request) Response {
    // Check if user is authenticated via Authorization header
    const auth_header = req.header("Authorization");

    if (auth_header) |auth| {
        if (std.mem.startsWith(u8, auth, "Bearer ")) {
            // Token exists - show logged in state
            return Response.fragment(
                \\<div class="user-info">
                \\  <span>👤 <strong>Logged in</strong></span>
                \\  <button class="btn-secondary" onclick="document.body.dispatchEvent(new Event('authLogout'))">Logout</button>
                \\</div>
            );
        }
    }

    // Not authenticated - show login form
    return Response.fragment(
        \\<form class="auth-form" hx-post="/htmx/auth/login" hx-target="#auth-content" hx-swap="innerHTML">
        \\  <input type="text" name="username" placeholder="Username" required>
        \\  <input type="password" name="password" placeholder="Password" required>
        \\  <button type="submit" class="btn-secondary">Login</button>
        \\  <button type="button" class="btn-secondary" hx-get="/htmx/auth/signup-form" hx-target="#auth-content" hx-swap="innerHTML">Sign Up</button>
        \\</form>
    );
}

/// Handle signup form display
pub fn handleSignupForm(req: *Request) Response {
    _ = req;
    return Response.fragment(
        \\<form class="auth-form" hx-post="/htmx/auth/signup" hx-target="#auth-content" hx-swap="innerHTML">
        \\  <input type="text" name="username" placeholder="Username" required>
        \\  <input type="email" name="email" placeholder="Email" required>
        \\  <input type="password" name="password" placeholder="Password" required>
        \\  <button type="submit" class="btn-secondary">Sign Up</button>
        \\  <button type="button" class="btn-secondary" hx-get="/htmx/auth/status" hx-target="#auth-content" hx-swap="innerHTML">Back to Login</button>
        \\</form>
    );
}

/// Handle analytics page - returns full HTML page with detailed statistics
pub fn handleAnalyticsPage(req: *Request) Response {
    _ = req;

    const orm = database.getORM() catch {
        return Response.html("<html><body><h1>Error: Database not initialized</h1></body></html>").withStatus(500);
    };

    var todos = orm.findAll(Todo) catch {
        return Response.html("<html><body><h1>Error: Failed to load todos</h1></body></html>").withStatus(500);
    };
    defer todos.deinit(orm.allocator);

    var total: u32 = 0;
    var completed: u32 = 0;
    var pending: u32 = 0;
    var overdue: u32 = 0;
    var high_priority: u32 = 0;
    var medium_priority: u32 = 0;
    var low_priority: u32 = 0;
    var with_due_dates: u32 = 0;
    var with_tags: u32 = 0;
    const now = std.time.timestamp();

    for (todos.items) |todo| {
        total += 1;
        if (todo.completed) {
            completed += 1;
        } else {
            pending += 1;
            if (todo.due_date) |due| {
                if (due < now) {
                    overdue += 1;
                }
            }
        }

        // Count priorities
        if (std.mem.eql(u8, todo.priority, "high")) {
            high_priority += 1;
        } else if (std.mem.eql(u8, todo.priority, "medium")) {
            medium_priority += 1;
        } else if (std.mem.eql(u8, todo.priority, "low")) {
            low_priority += 1;
        }

        // Count todos with due dates
        if (todo.due_date != null) {
            with_due_dates += 1;
        }

        // Count todos with tags
        if (todo.tags.len > 0) {
            with_tags += 1;
        }
    }

    const progress: u32 = if (total > 0) (completed * 100) / total else 0;

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    var num_buf: [20]u8 = undefined;

    // Build beautiful analytics page with consistent styling
    buf.appendSlice(allocator,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\    <title>Todo Analytics</title>
        \\    <link rel="preconnect" href="https://fonts.googleapis.com">
        \\    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        \\    <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500&family=Space+Grotesk:wght@400;500;600;700&display=swap" rel="stylesheet">
        \\    <style>
        \\        :root {
        \\            --bg-deep: #0a0a0b;
        \\            --bg: #101012;
        \\            --bg-card: #18181b;
        \\            --bg-elevated: #1f1f23;
        \\            --text: #fafafa;
        \\            --text-secondary: #a1a1aa;
        \\            --text-muted: #71717a;
        \\            --border: #27272a;
        \\            --accent: #a78bfa;
        \\            --accent-dim: rgba(167, 139, 250, 0.15);
        \\            --success: #4ade80;
        \\            --success-dim: rgba(74, 222, 128, 0.15);
        \\            --warning: #fbbf24;
        \\            --danger: #f87171;
        \\            --danger-dim: rgba(248, 113, 113, 0.15);
        \\            --radius: 8px;
        \\            --radius-lg: 12px;
        \\        }
        \\        * { margin: 0; padding: 0; box-sizing: border-box; }
        \\        body {
        \\            font-family: 'Space Grotesk', sans-serif;
        \\            background: var(--bg-deep);
        \\            color: var(--text);
        \\            min-height: 100vh;
        \\            padding: 3rem 1.5rem;
        \\        }
        \\        body::before {
        \\            content: '';
        \\            position: fixed;
        \\            top: 0; left: 0; right: 0; bottom: 0;
        \\            background: radial-gradient(ellipse at top, rgba(167, 139, 250, 0.03) 0%, transparent 50%);
        \\            pointer-events: none;
        \\            z-index: -1;
        \\        }
        \\        .container { max-width: 900px; margin: 0 auto; }
        \\        header { text-align: center; margin-bottom: 2.5rem; }
        \\        .header-row { display: flex; align-items: center; justify-content: center; gap: 0.75rem; margin-bottom: 0.5rem; }
        \\        h1 {
        \\            font-size: 2rem;
        \\            font-weight: 700;
        \\            background: linear-gradient(135deg, var(--text) 0%, var(--accent) 100%);
        \\            -webkit-background-clip: text;
        \\            -webkit-text-fill-color: transparent;
        \\            background-clip: text;
        \\        }
        \\        .badge {
        \\            font-family: 'JetBrains Mono', monospace;
        \\            font-size: 0.65rem;
        \\            color: var(--accent);
        \\            background: var(--accent-dim);
        \\            padding: 0.3rem 0.6rem;
        \\            border-radius: 4px;
        \\            border: 1px solid rgba(167, 139, 250, 0.2);
        \\        }
        \\        .subtitle { color: var(--text-muted); font-size: 0.95rem; }
        \\        .analytics-grid {
        \\            display: grid;
        \\            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
        \\            gap: 1rem;
        \\            margin-bottom: 2rem;
        \\        }
        \\        .card {
        \\            background: var(--bg-card);
        \\            border: 1px solid var(--border);
        \\            border-radius: var(--radius-lg);
        \\            padding: 1.5rem;
        \\            transition: transform 0.2s, box-shadow 0.2s;
        \\        }
        \\        .card:hover {
        \\            transform: translateY(-2px);
        \\            box-shadow: 0 8px 25px rgba(0,0,0,0.3);
        \\        }
        \\        .card-label {
        \\            font-size: 0.75rem;
        \\            font-weight: 500;
        \\            color: var(--text-muted);
        \\            text-transform: uppercase;
        \\            letter-spacing: 0.05em;
        \\            margin-bottom: 0.5rem;
        \\        }
        \\        .card-value {
        \\            font-family: 'JetBrains Mono', monospace;
        \\            font-size: 2.5rem;
        \\            font-weight: 600;
        \\            color: var(--text);
        \\            line-height: 1;
        \\            margin-bottom: 0.25rem;
        \\        }
        \\        .card-subtitle { font-size: 0.8rem; color: var(--text-muted); }
        \\        .card.accent { border-color: var(--accent); background: var(--accent-dim); }
        \\        .card.accent .card-value { color: var(--accent); }
        \\        .card.success { border-color: var(--success); }
        \\        .card.success .card-value { color: var(--success); }
        \\        .card.danger { border-color: var(--danger); background: var(--danger-dim); }
        \\        .card.danger .card-value { color: var(--danger); }
        \\        .card.warning { border-color: var(--warning); }
        \\        .card.warning .card-value { color: var(--warning); }
        \\        .progress-container { margin-top: 1rem; }
        \\        .progress-bar {
        \\            background: var(--bg-elevated);
        \\            border-radius: 8px;
        \\            height: 12px;
        \\            overflow: hidden;
        \\        }
        \\        .progress-fill {
        \\            background: linear-gradient(90deg, var(--accent), var(--success));
        \\            height: 100%;
        \\            border-radius: 8px;
        \\            transition: width 0.5s ease;
        \\        }
        \\        .section-title {
        \\            font-size: 0.8rem;
        \\            font-weight: 600;
        \\            color: var(--text-secondary);
        \\            text-transform: uppercase;
        \\            letter-spacing: 0.1em;
        \\            margin: 2rem 0 1rem;
        \\            padding-bottom: 0.5rem;
        \\            border-bottom: 1px solid var(--border);
        \\        }
        \\        .btn {
        \\            display: inline-flex;
        \\            align-items: center;
        \\            gap: 0.5rem;
        \\            padding: 0.75rem 1.5rem;
        \\            background: var(--bg-card);
        \\            color: var(--text-secondary);
        \\            border: 1px solid var(--border);
        \\            border-radius: var(--radius);
        \\            text-decoration: none;
        \\            font-size: 0.9rem;
        \\            font-weight: 500;
        \\            transition: all 0.15s;
        \\            margin-top: 1.5rem;
        \\        }
        \\        .btn:hover { background: var(--bg-elevated); color: var(--text); border-color: var(--accent); }
        \\        @media (max-width: 600px) {
        \\            .analytics-grid { grid-template-columns: 1fr 1fr; }
        \\            .card-value { font-size: 2rem; }
        \\        }
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="container">
        \\        <header>
        \\            <div class="header-row">
        \\                <h1>Analytics</h1>
        \\                <span class="badge">HTMX</span>
        \\            </div>
        \\            <p class="subtitle">Task statistics and insights</p>
        \\        </header>
        \\
        \\        <div class="analytics-grid">
    ) catch return Response.html("<html><body><h1>Error</h1></body></html>").withStatus(500);

    // Total card
    buf.appendSlice(allocator, "<div class=\"card\"><div class=\"card-label\">Total Tasks</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{total}) catch "0") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">All time</div></div>") catch return Response.html("").withStatus(500);

    // Completed card
    buf.appendSlice(allocator, "<div class=\"card success\"><div class=\"card-label\">Completed</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{completed}) catch "0") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">") catch return Response.html("").withStatus(500);
    if (total > 0) {
        buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}% completion", .{(completed * 100) / total}) catch "0%") catch return Response.html("").withStatus(500);
    } else {
        buf.appendSlice(allocator, "0% completion") catch return Response.html("").withStatus(500);
    }
    buf.appendSlice(allocator, "</div></div>") catch return Response.html("").withStatus(500);

    // Pending card
    buf.appendSlice(allocator, "<div class=\"card\"><div class=\"card-label\">Pending</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{pending}) catch "0") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">Remaining</div></div>") catch return Response.html("").withStatus(500);

    // Progress card
    buf.appendSlice(allocator, "<div class=\"card accent\"><div class=\"card-label\">Progress</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}%", .{progress}) catch "0%") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"progress-container\"><div class=\"progress-bar\"><div class=\"progress-fill\" style=\"width:") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}%", .{progress}) catch "0%") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "\"></div></div></div></div>") catch return Response.html("").withStatus(500);

    // Overdue card (if any)
    if (overdue > 0) {
        buf.appendSlice(allocator, "<div class=\"card danger\"><div class=\"card-label\">") catch return Response.html("").withStatus(500);
        // Alert Triangle SVG
        buf.appendSlice(allocator, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z\"></path><line x1=\"12\" y1=\"9\" x2=\"12\" y2=\"13\"></line><line x1=\"12\" y1=\"17\" x2=\"12.01\" y2=\"17\"></line></svg>") catch return Response.html("").withStatus(500);
        buf.appendSlice(allocator, " Overdue</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
        buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{overdue}) catch "0") catch return Response.html("").withStatus(500);
        buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">Need attention</div></div>") catch return Response.html("").withStatus(500);
    }

    buf.appendSlice(allocator, "</div>") catch return Response.html("").withStatus(500);

    // Priority section
    buf.appendSlice(allocator, "<h2 class=\"section-title\">By Priority</h2><div class=\"analytics-grid\">") catch return Response.html("").withStatus(500);

    // High priority
    buf.appendSlice(allocator, "<div class=\"card danger\"><div class=\"card-label\">") catch return Response.html("").withStatus(500);
    // Flame SVG or similar for High
    buf.appendSlice(allocator, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"12\" cy=\"12\" r=\"10\"></circle><line x1=\"12\" y1=\"8\" x2=\"12\" y2=\"12\"></line><line x1=\"12\" y1=\"16\" x2=\"12.01\" y2=\"16\"></line></svg>") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, " High</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{high_priority}) catch "0") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">Urgent</div></div>") catch return Response.html("").withStatus(500);

    // Medium priority
    buf.appendSlice(allocator, "<div class=\"card warning\"><div class=\"card-label\">") catch return Response.html("").withStatus(500);
    // Alert circle or similar
    buf.appendSlice(allocator, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"12\" cy=\"12\" r=\"10\"></circle><line x1=\"12\" y1=\"16\" x2=\"12\" y2=\"12\"></line><line x1=\"12\" y1=\"8\" x2=\"12.01\" y2=\"8\"></line></svg>") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, " Medium</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{medium_priority}) catch "0") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">Normal</div></div>") catch return Response.html("").withStatus(500);

    // Low priority
    buf.appendSlice(allocator, "<div class=\"card success\"><div class=\"card-label\">") catch return Response.html("").withStatus(500);
    // Check circle or arrow down
    buf.appendSlice(allocator, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"12\" cy=\"12\" r=\"10\"></circle><path d=\"M8 12l4 4 4-4\"></path></svg>") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, " Low</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{low_priority}) catch "0") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">Low priority</div></div>") catch return Response.html("").withStatus(500);

    buf.appendSlice(allocator, "</div>") catch return Response.html("").withStatus(500);

    // Organization section
    buf.appendSlice(allocator, "<h2 class=\"section-title\">Organization</h2><div class=\"analytics-grid\">") catch return Response.html("").withStatus(500);

    // With due dates
    buf.appendSlice(allocator, "<div class=\"card\"><div class=\"card-label\">") catch return Response.html("").withStatus(500);
    // Calendar SVG
    buf.appendSlice(allocator, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><rect x=\"3\" y=\"4\" width=\"18\" height=\"18\" rx=\"2\" ry=\"2\"></rect><line x1=\"16\" y1=\"2\" x2=\"16\" y2=\"6\"></line><line x1=\"8\" y1=\"2\" x2=\"8\" y2=\"6\"></line><line x1=\"3\" y1=\"10\" x2=\"21\" y2=\"10\"></line></svg>") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, " With Due Dates</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{with_due_dates}) catch "0") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">") catch return Response.html("").withStatus(500);
    if (total > 0) {
        buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}% scheduled", .{(with_due_dates * 100) / total}) catch "0%") catch return Response.html("").withStatus(500);
    } else {
        buf.appendSlice(allocator, "0% scheduled") catch return Response.html("").withStatus(500);
    }
    buf.appendSlice(allocator, "</div></div>") catch return Response.html("").withStatus(500);

    // With tags
    buf.appendSlice(allocator, "<div class=\"card\"><div class=\"card-label\">") catch return Response.html("").withStatus(500);
    // Tag SVG
    buf.appendSlice(allocator, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M20.59 13.41l-7.17 7.17a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.82z\"></path><line x1=\"7\" y1=\"7\" x2=\"7.01\" y2=\"7\"></line></svg>") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, " With Tags</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{with_tags}) catch "0") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">Categorized</div></div>") catch return Response.html("").withStatus(500);

    buf.appendSlice(allocator, "</div>") catch return Response.html("").withStatus(500);

    // Back button
    buf.appendSlice(allocator,
        \\        <a href="/htmx" class="btn">
        \\            <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="19" y1="12" x2="5" y2="12"></line><polyline points="12 19 5 12 12 5"></polyline></svg>
        \\            Back to Tasks
        \\        </a>
        \\    </div>
        \\</body>
        \\</html>
    ) catch return Response.html("").withStatus(500);

    return Response.html(buf.toOwnedSlice(allocator) catch "");
}

/// Handle filtering todos by priority
pub fn handleFilterByPriority(req: *Request) Response {
    const path = req.path();

    // Get priority from query parameter
    var priority_buf: [32]u8 = undefined;
    var priority: []const u8 = "all";

    if (getQueryParam(path, "priority")) |p| {
        priority = urlDecode(p, &priority_buf);
    }

    const orm = database.getORM() catch {
        return htmx.errors.errorFragment("Database not initialized");
    };

    var todos = orm.findAll(Todo) catch {
        return htmx.errors.errorFragment("Failed to load todos");
    };
    defer todos.deinit(orm.allocator);

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    var count: usize = 0;
    for (todos.items) |todo| {
        const matches = std.mem.eql(u8, priority, "all") or std.mem.eql(u8, todo.priority, priority);
        if (matches) {
            renderTodoItem(todo, &buf) catch continue;
            count += 1;
        }
    }

    if (count == 0) {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "<li class=\"empty-state\"><div class=\"empty-state-icon\"></div><p>No {s} priority todos found.</p></li>", .{priority}) catch "<li class=\"empty-state\">No todos found.</li>";
        buf.appendSlice(allocator, msg) catch {};
    }

    return Response.fragment(buf.toOwnedSlice(allocator) catch "");
}

/// Handle getting completed count for clear button badge
pub fn handleCompletedCount(req: *Request) Response {
    _ = req;

    const orm = database.getORM() catch {
        return Response.fragment("<span class=\"count-badge\">0</span>");
    };

    var todos = orm.findAll(Todo) catch {
        return Response.fragment("<span class=\"count-badge\">0</span>");
    };
    defer todos.deinit(orm.allocator);

    var completed: u32 = 0;
    for (todos.items) |todo| {
        if (todo.completed) {
            completed += 1;
        }
    }

    var num_buf: [20]u8 = undefined;
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    if (completed > 0) {
        buf.appendSlice(allocator, "<span class=\"count-badge\">") catch {};
        buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{completed}) catch "0") catch {};
        buf.appendSlice(allocator, "</span>") catch {};
    }

    return Response.fragment(buf.toOwnedSlice(allocator) catch "");
}

/// Handle toggling all todos (mark all complete/incomplete)
pub fn handleToggleAll(req: *Request) Response {
    const orm = database.getORM() catch {
        return htmx.errors.errorFragmentWithStatus("Database not initialized", 500);
    };

    // Check current state from form data
    var form_parser = req.getFormParser();
    const set_completed = form_parser.getBool("completed") catch true;

    // Use driver-aware SQL
    const completed_val = if (database.getDriver() == .postgresql)
        (if (set_completed) "TRUE" else "FALSE")
    else
        (if (set_completed) "1" else "0");

    const now = std.time.timestamp();
    const sql = std.fmt.allocPrint(orm.allocator, "UPDATE todos SET completed = {s}, updated_at = {}", .{ completed_val, now }) catch {
        return htmx.errors.errorFragmentWithStatus("Memory error", 500);
    };
    defer orm.allocator.free(sql);

    _ = orm.db.execute(sql) catch {
        return htmx.errors.errorFragmentWithStatus("Failed to update todos", 500);
    };

    // Invalidate stats cache
    htmx.invalidateCache("todo:stats");

    // Use Response.compose() for success feedback
    const success_msg = if (set_completed) "All todos marked complete!" else "All todos marked active!";
    const success_toast = htmx.toast(allocator, success_msg, .success) catch "";

    var composer = Response.compose(allocator);
    defer composer.deinit();

    return composer
        .fragment("", "")
        .oob("#toast", success_toast)
        .trigger("todosUpdated")
        .build();
}

/// Handle restoring a deleted todo (for undo functionality)
pub fn handleRestoreTodo(req: *Request) Response {
    // Get todo data from form (sent by undo action)
    var form_parser = req.getFormParser();

    const title = form_parser.get("title") catch null orelse {
        return htmx.errors.errorFragment("Missing title for restore");
    };
    defer req.allocator().free(title);

    const description = form_parser.get("description") catch null orelse "";
    defer if (description.len > 0) req.allocator().free(description);

    const priority = form_parser.get("priority") catch null orelse "medium";
    defer if (!std.mem.eql(u8, priority, "medium")) req.allocator().free(priority);

    const tags = form_parser.get("tags") catch null orelse "";
    defer if (tags.len > 0) req.allocator().free(tags);

    const orm = database.getORM() catch {
        return htmx.errors.errorFragmentWithStatus("Database not initialized", 500);
    };

    // Create copies for the Todo struct
    const title_copy = allocator.dupe(u8, title) catch {
        return htmx.errors.errorFragmentWithStatus("Memory error", 500);
    };
    const desc_copy = if (description.len > 0) allocator.dupe(u8, description) catch "" else "";
    const priority_copy = allocator.dupe(u8, priority) catch "medium";
    const tags_copy = if (tags.len > 0) allocator.dupe(u8, tags) catch "" else "";

    var todo = Todo{
        .id = 0,
        .user_id = 1,
        .title = @constCast(title_copy),
        .description = @constCast(desc_copy),
        .completed = false,
        .priority = @constCast(priority_copy),
        .due_date = null,
        .tags = @constCast(tags_copy),
        .created_at = std.time.timestamp(),
        .updated_at = std.time.timestamp(),
    };

    const created_id = orm.create(Todo, todo) catch {
        return htmx.errors.errorFragmentWithStatus("Failed to restore todo", 500);
    };

    todo.id = created_id;

    // Invalidate stats cache
    htmx.invalidateCache("todo:stats");

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    renderTodoItem(todo, &buf) catch {
        return htmx.errors.errorFragment("Failed to render restored todo");
    };

    const success_toast = htmx.toast(allocator, "Todo restored!", .success) catch "";

    var composer = Response.compose(allocator);
    defer composer.deinit();

    return composer
        .fragment("#todo-list", buf.toOwnedSlice(allocator) catch "")
        .oob("#toast", success_toast)
        .trigger("todoCreated")
        .build();
}
