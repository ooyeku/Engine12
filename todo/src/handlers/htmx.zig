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
    try buf.appendSlice(allocator, "\" class=\"task-item ");
    try buf.appendSlice(allocator, priority_class);
    try buf.appendSlice(allocator, completed_class);
    try buf.appendSlice(allocator, "\">\n");

    // Checkbox with HTMX toggle
    try buf.appendSlice(allocator, "  <input type=\"checkbox\" class=\"task-checkbox\" ");
    try buf.appendSlice(allocator, "hx-post=\"/htmx/todos/");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "/toggle\" hx-target=\"#todo-");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "\" hx-swap=\"outerHTML\"");
    try buf.appendSlice(allocator, checked);
    try buf.appendSlice(allocator, ">\n");

    // Content section
    try buf.appendSlice(allocator, "  <div class=\"task-content\">\n");

    // Title (escaped)
    var title_escaped: [512]u8 = undefined;
    const safe_title = htmlEscape(todo.title, &title_escaped);
    try buf.appendSlice(allocator, "    <div class=\"task-title\">");
    try buf.appendSlice(allocator, safe_title);
    try buf.appendSlice(allocator, "</div>\n");

    // Description (if present)
    if (todo.description.len > 0) {
        var desc_escaped: [2048]u8 = undefined;
        const safe_desc = htmlEscape(todo.description, &desc_escaped);
        try buf.appendSlice(allocator, "    <div class=\"task-desc\">");
        try buf.appendSlice(allocator, safe_desc);
        try buf.appendSlice(allocator, "</div>\n");
    }

    // Meta info (tags, due date) - only show if there's content
    const has_tags = todo.tags.len > 0;
    const has_due = todo.due_date != null;

    if (has_tags or has_due) {
        try buf.appendSlice(allocator, "    <div class=\"task-meta\">\n");

        // Due date first
        if (todo.due_date) |due| {
            // Format date
            var date_buf: [32]u8 = undefined;
            const date_str = formatTimestamp(due, &date_buf);

            try buf.appendSlice(allocator, "      <span class=\"task-date\">");
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
                    try buf.appendSlice(allocator, "      <span class=\"task-tag\">#");
                    try buf.appendSlice(allocator, safe_tag);
                    try buf.appendSlice(allocator, "</span>\n");
                }
            }
        }

        try buf.appendSlice(allocator, "    </div>\n");
    }

    try buf.appendSlice(allocator, "  </div>\n");

    // Actions
    try buf.appendSlice(allocator, "  <div class=\"task-actions\">\n");

    // Edit button (text only)
    try buf.appendSlice(allocator, "    <button class=\"action-btn\" ");
    try buf.appendSlice(allocator, "hx-get=\"/htmx/todos/");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "/edit\" hx-target=\"#todo-");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "\" hx-swap=\"outerHTML\">Edit</button>\n");

    // Delete button (text only) with confirmation
    try buf.appendSlice(allocator, "    <button class=\"action-btn delete\" ");
    try buf.appendSlice(allocator, "hx-delete=\"/htmx/todos/");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "\" hx-target=\"#todo-");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "\" hx-swap=\"outerHTML\" ");
    try buf.appendSlice(allocator, "hx-confirm=\"Delete this task?\">Delete</button>\n");

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

    // Description textarea
    buf.appendSlice(allocator, "    <div class=\"form-group\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "      <label>Description</label>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "      <textarea name=\"description\" rows=\"3\" placeholder=\"Add details...\">") catch return Response.fragment("<li class=\"error\">Error</li>");
    var desc_escaped: [2048]u8 = undefined;
    buf.appendSlice(allocator, htmlEscape(todo.description, &desc_escaped)) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "</textarea>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "    </div>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Priority and Due Date row
    buf.appendSlice(allocator, "    <div class=\"form-row\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Priority select
    buf.appendSlice(allocator, "      <div class=\"form-group\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "        <label>Priority</label>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "        <select name=\"priority\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Low priority
    buf.appendSlice(allocator, "          <option value=\"low\"") catch return Response.fragment("<li class=\"error\">Error</li>");
    if (std.mem.eql(u8, todo.priority, "low")) {
        buf.appendSlice(allocator, " selected") catch return Response.fragment("<li class=\"error\">Error</li>");
    }
    buf.appendSlice(allocator, ">Low</option>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Medium priority
    buf.appendSlice(allocator, "          <option value=\"medium\"") catch return Response.fragment("<li class=\"error\">Error</li>");
    if (std.mem.eql(u8, todo.priority, "medium")) {
        buf.appendSlice(allocator, " selected") catch return Response.fragment("<li class=\"error\">Error</li>");
    }
    buf.appendSlice(allocator, ">Medium</option>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // High priority
    buf.appendSlice(allocator, "          <option value=\"high\"") catch return Response.fragment("<li class=\"error\">Error</li>");
    if (std.mem.eql(u8, todo.priority, "high")) {
        buf.appendSlice(allocator, " selected") catch return Response.fragment("<li class=\"error\">Error</li>");
    }
    buf.appendSlice(allocator, ">High</option>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

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

    buf.appendSlice(allocator, "    </div>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Tags input (full width)
    buf.appendSlice(allocator, "    <div class=\"form-group\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "      <label>Tags</label>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "      <input type=\"text\" name=\"tags\" value=\"") catch return Response.fragment("<li class=\"error\">Error</li>");
    var tags_escaped: [256]u8 = undefined;
    buf.appendSlice(allocator, htmlEscape(todo.tags, &tags_escaped)) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "\" placeholder=\"work, urgent\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");
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

    // Calculate stroke-dashoffset for progress ring
    // Circle circumference = 2 * pi * r = 2 * 3.14159 * 52 = ~327
    const circumference: u32 = 327;
    const offset: u32 = if (progress > 0) circumference - ((progress * circumference) / 100) else circumference;

    // Progress Ring SVG
    buf.appendSlice(allocator, "<div class=\"progress-ring\">\n") catch return Response.fragment("");
    buf.appendSlice(allocator, "<svg width=\"120\" height=\"120\">\n") catch return Response.fragment("");
    buf.appendSlice(allocator, "<circle class=\"bg\" cx=\"60\" cy=\"60\" r=\"52\" />\n") catch return Response.fragment("");
    buf.appendSlice(allocator, "<circle class=\"fg\" cx=\"60\" cy=\"60\" r=\"52\" stroke-dasharray=\"327\" stroke-dashoffset=\"") catch return Response.fragment("");
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{offset}) catch "327") catch return Response.fragment("");
    buf.appendSlice(allocator, "\" />\n</svg>\n") catch return Response.fragment("");
    buf.appendSlice(allocator, "<div class=\"progress-ring-text\">\n") catch return Response.fragment("");
    buf.appendSlice(allocator, "<span class=\"progress-ring-value\">") catch return Response.fragment("");
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}%", .{progress}) catch "0%") catch return Response.fragment("");
    buf.appendSlice(allocator, "</span>\n<span class=\"progress-ring-label\">Complete</span>\n</div>\n</div>\n") catch return Response.fragment("");

    // Also update header stats via OOB swap
    buf.appendSlice(allocator, "<div id=\"header-stats\" hx-swap-oob=\"innerHTML\">\n") catch return Response.fragment("");

    // Total stat
    buf.appendSlice(allocator, "<div class=\"header-stat\"><div class=\"header-stat-value\">") catch return Response.fragment("");
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{total}) catch "0") catch return Response.fragment("");
    buf.appendSlice(allocator, "</div><div class=\"header-stat-label\">Total</div></div>\n") catch return Response.fragment("");

    // Completed stat
    buf.appendSlice(allocator, "<div class=\"header-stat\"><div class=\"header-stat-value gold\">") catch return Response.fragment("");
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{completed}) catch "0") catch return Response.fragment("");
    buf.appendSlice(allocator, "</div><div class=\"header-stat-label\">Complete</div></div>\n") catch return Response.fragment("");

    buf.appendSlice(allocator, "</div>\n") catch return Response.fragment("");

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
        \\    <title>Todo Analytics — Engine12</title>
        \\    <link rel="preconnect" href="https://fonts.googleapis.com">
        \\    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        \\    <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
        \\    <style>
        \\        :root {
        \\            --black: #0a0a0a;
        \\            --black-light: #111111;
        \\            --black-lighter: #181818;
        \\            --black-surface: #1f1f1f;
        \\            --black-elevated: #262626;
        \\            --border: #2a2a2a;
        \\            --border-light: #333333;
        \\            --gold: #f7a41d;
        \\            --gold-dim: rgba(247, 164, 29, 0.12);
        \\            --white: #fafafa;
        \\            --gray-300: #a3a3a3;
        \\            --gray-400: #737373;
        \\            --gray-500: #525252;
        \\            --green: #22c55e;
        \\            --red: #ef4444;
        \\            --red-dim: rgba(239, 68, 68, 0.12);
        \\            --radius: 6px;
        \\            --radius-lg: 10px;
        \\        }
        \\        * { margin: 0; padding: 0; box-sizing: border-box; }
        \\        html, body { height: 100%; overflow: hidden; }
        \\        body {
        \\            font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
        \\            background: var(--black);
        \\            color: var(--white);
        \\            padding: 24px 32px;
        \\            -webkit-font-smoothing: antialiased;
        \\            display: flex;
        \\            flex-direction: column;
        \\        }
        \\        .container { max-width: 1000px; margin: 0 auto; width: 100%; flex: 1; display: flex; flex-direction: column; }
        \\        header {
        \\            display: flex;
        \\            align-items: center;
        \\            gap: 12px;
        \\            margin-bottom: 20px;
        \\            padding-bottom: 16px;
        \\            border-bottom: 1px solid var(--border);
        \\            flex-shrink: 0;
        \\        }
        \\        .logo {
        \\            font-family: 'JetBrains Mono', monospace;
        \\            font-size: 11px;
        \\            font-weight: 600;
        \\            color: var(--black);
        \\            background: var(--gold);
        \\            padding: 6px 10px;
        \\            border-radius: 5px;
        \\        }
        \\        .title-group h1 { font-size: 20px; font-weight: 600; letter-spacing: -0.02em; }
        \\        .title-group p { font-size: 12px; color: var(--gray-400); margin-top: 2px; }
        \\        .content { flex: 1; display: flex; flex-direction: column; gap: 16px; min-height: 0; }
        \\        .analytics-grid {
        \\            display: grid;
        \\            grid-template-columns: repeat(5, 1fr);
        \\            gap: 10px;
        \\        }
        \\        .analytics-grid.three { grid-template-columns: repeat(3, 1fr); }
        \\        .analytics-grid.two { grid-template-columns: repeat(2, 1fr); }
        \\        .card {
        \\            background: var(--black-light);
        \\            border: 1px solid var(--border);
        \\            border-radius: var(--radius-lg);
        \\            padding: 14px 16px;
        \\        }
        \\        .card-label {
        \\            font-size: 10px;
        \\            font-weight: 600;
        \\            color: var(--gray-500);
        \\            text-transform: uppercase;
        \\            letter-spacing: 0.08em;
        \\            margin-bottom: 6px;
        \\        }
        \\        .card-value {
        \\            font-family: 'JetBrains Mono', monospace;
        \\            font-size: 28px;
        \\            font-weight: 600;
        \\            color: var(--white);
        \\            line-height: 1;
        \\            margin-bottom: 4px;
        \\        }
        \\        .card-subtitle { font-size: 11px; color: var(--gray-400); }
        \\        .card.gold { border-color: var(--gold); }
        \\        .card.gold .card-value { color: var(--gold); }
        \\        .card.green { border-color: var(--green); }
        \\        .card.green .card-value { color: var(--green); }
        \\        .card.red { border-left: 3px solid var(--red); background: var(--red-dim); }
        \\        .card.red .card-value { color: var(--red); }
        \\        .progress-container { margin-top: 8px; }
        \\        .progress-bar { background: var(--black-surface); border-radius: 4px; height: 6px; overflow: hidden; }
        \\        .progress-fill { background: var(--gold); height: 100%; border-radius: 4px; transition: width 0.5s ease; }
        \\        .section-title {
        \\            font-size: 10px;
        \\            font-weight: 600;
        \\            color: var(--gray-500);
        \\            text-transform: uppercase;
        \\            letter-spacing: 0.1em;
        \\            margin-bottom: 10px;
        \\        }
        \\        .section { display: flex; flex-direction: column; }
        \\        .btn {
        \\            display: inline-flex;
        \\            align-items: center;
        \\            padding: 10px 20px;
        \\            background: var(--black-light);
        \\            color: var(--gray-300);
        \\            border: 1px solid var(--border);
        \\            border-radius: var(--radius);
        \\            text-decoration: none;
        \\            font-size: 13px;
        \\            font-weight: 500;
        \\            transition: all 0.15s;
        \\            margin-top: auto;
        \\            align-self: flex-start;
        \\        }
        \\        .btn:hover { background: var(--black-elevated); color: var(--white); border-color: var(--gold); }
        \\        @media (max-width: 800px) {
        \\            .analytics-grid { grid-template-columns: repeat(2, 1fr); }
        \\            .analytics-grid.three { grid-template-columns: repeat(3, 1fr); }
        \\        }
        \\        @media (max-width: 500px) {
        \\            body { padding: 16px; }
        \\            .analytics-grid, .analytics-grid.three { grid-template-columns: 1fr 1fr; }
        \\            .card-value { font-size: 22px; }
        \\        }
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="container">
        \\        <header>
        \\            <span class="logo">E12</span>
        \\            <div class="title-group">
        \\                <h1>Analytics</h1>
        \\                <p>Task statistics and insights</p>
        \\            </div>
        \\        </header>
        \\        <div class="content">
        \\        <div class="analytics-grid">
    ) catch return Response.html("<html><body><h1>Error</h1></body></html>").withStatus(500);

    // Total card
    buf.appendSlice(allocator, "<div class=\"card\"><div class=\"card-label\">Total Tasks</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{total}) catch "0") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">All time</div></div>") catch return Response.html("").withStatus(500);

    // Completed card
    buf.appendSlice(allocator, "<div class=\"card green\"><div class=\"card-label\">Completed</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
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
    buf.appendSlice(allocator, "<div class=\"card gold\"><div class=\"card-label\">Progress</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}%", .{progress}) catch "0%") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"progress-container\"><div class=\"progress-bar\"><div class=\"progress-fill\" style=\"width:") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}%", .{progress}) catch "0%") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "\"></div></div></div></div>") catch return Response.html("").withStatus(500);

    // Overdue card (if any)
    if (overdue > 0) {
        buf.appendSlice(allocator, "<div class=\"card red\"><div class=\"card-label\">Overdue</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
        buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{overdue}) catch "0") catch return Response.html("").withStatus(500);
        buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">Need attention</div></div>") catch return Response.html("").withStatus(500);
    }

    buf.appendSlice(allocator, "</div>") catch return Response.html("").withStatus(500);

    // Priority section
    buf.appendSlice(allocator, "<h2 class=\"section-title\">By Priority</h2><div class=\"analytics-grid three\">") catch return Response.html("").withStatus(500);

    // High priority
    buf.appendSlice(allocator, "<div class=\"card red\"><div class=\"card-label\">High</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{high_priority}) catch "0") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">Urgent</div></div>") catch return Response.html("").withStatus(500);

    // Medium priority
    buf.appendSlice(allocator, "<div class=\"card gold\"><div class=\"card-label\">Medium</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{medium_priority}) catch "0") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">Normal</div></div>") catch return Response.html("").withStatus(500);

    // Low priority
    buf.appendSlice(allocator, "<div class=\"card green\"><div class=\"card-label\">Low</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{low_priority}) catch "0") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">Low priority</div></div>") catch return Response.html("").withStatus(500);

    buf.appendSlice(allocator, "</div>") catch return Response.html("").withStatus(500);

    // Organization section
    buf.appendSlice(allocator, "<h2 class=\"section-title\">Organization</h2><div class=\"analytics-grid two\">") catch return Response.html("").withStatus(500);

    // With due dates
    buf.appendSlice(allocator, "<div class=\"card\"><div class=\"card-label\">With Due Dates</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{with_due_dates}) catch "0") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">") catch return Response.html("").withStatus(500);
    if (total > 0) {
        buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}% scheduled", .{(with_due_dates * 100) / total}) catch "0%") catch return Response.html("").withStatus(500);
    } else {
        buf.appendSlice(allocator, "0% scheduled") catch return Response.html("").withStatus(500);
    }
    buf.appendSlice(allocator, "</div></div>") catch return Response.html("").withStatus(500);

    // With tags
    buf.appendSlice(allocator, "<div class=\"card\"><div class=\"card-label\">With Tags</div><div class=\"card-value\">") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{with_tags}) catch "0") catch return Response.html("").withStatus(500);
    buf.appendSlice(allocator, "</div><div class=\"card-subtitle\">Categorized</div></div>") catch return Response.html("").withStatus(500);

    buf.appendSlice(allocator, "</div>") catch return Response.html("").withStatus(500);

    // Back button
    buf.appendSlice(allocator,
        \\        <a href="/htmx" class="btn">Back to Tasks</a>
        \\        </div>
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
