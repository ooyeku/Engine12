const std = @import("std");
const E12 = @import("engine12");
const Request = E12.Request;
const Response = E12.Response;
const database = @import("../database.zig");
const models = @import("../models.zig");
const Todo = models.Todo;

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

    // Open list item
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

    // Meta info (tags, due date)
    try buf.appendSlice(allocator, "    <div class=\"todo-meta\">\n");

    // Tags
    if (todo.tags.len > 0) {
        var tags_iter = std.mem.splitSequence(u8, todo.tags, ",");
        while (tags_iter.next()) |tag_raw| {
            const tag = std.mem.trim(u8, tag_raw, " ");
            if (tag.len > 0) {
                var tag_escaped: [128]u8 = undefined;
                const safe_tag = htmlEscape(tag, &tag_escaped);
                try buf.appendSlice(allocator, "      <span class=\"todo-tag\">");
                try buf.appendSlice(allocator, safe_tag);
                try buf.appendSlice(allocator, "</span>\n");
            }
        }
    }

    // Due date
    if (todo.due_date) |due| {
        const now = std.time.timestamp();
        const is_overdue = !todo.completed and due < now;
        const due_class = if (is_overdue) " overdue" else "";

        // Format date
        var date_buf: [32]u8 = undefined;
        const date_str = formatTimestamp(due, &date_buf);

        try buf.appendSlice(allocator, "      <span class=\"todo-due");
        try buf.appendSlice(allocator, due_class);
        try buf.appendSlice(allocator, "\">Due: ");
        try buf.appendSlice(allocator, date_str);
        try buf.appendSlice(allocator, "</span>\n");
    }

    try buf.appendSlice(allocator, "    </div>\n");
    try buf.appendSlice(allocator, "  </div>\n");

    // Actions
    try buf.appendSlice(allocator, "  <div class=\"todo-actions\">\n");

    // Edit button
    try buf.appendSlice(allocator, "    <button class=\"btn-edit\" ");
    try buf.appendSlice(allocator, "hx-get=\"/htmx/todos/");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "/edit\" hx-target=\"#todo-");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "\" hx-swap=\"outerHTML\">Edit</button>\n");

    // Delete button
    try buf.appendSlice(allocator, "    <button class=\"btn-delete\" ");
    try buf.appendSlice(allocator, "hx-delete=\"/htmx/todos/");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "\" hx-target=\"#todo-");
    try buf.appendSlice(allocator, id_str);
    try buf.appendSlice(allocator, "\" hx-swap=\"outerHTML\" ");
    try buf.appendSlice(allocator, "hx-confirm=\"Delete this todo?\">Delete</button>\n");

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
    _ = req;
    // Super simple - just return static HTML to test if the route works
    return Response.fragment("<li class=\"todo-item\"><span class=\"todo-title\">Test Todo</span></li>");
}

/// Handle searching todos
pub fn handleSearchTodos(req: *Request) Response {
    const path = req.path();

    // Get search query from URL or body
    var search_buf: [256]u8 = undefined;
    var search_query: []const u8 = "";

    if (getQueryParam(path, "search")) |q| {
        search_query = urlDecode(q, &search_buf);
    }

    const orm = database.getORM() catch {
        return Response.fragment("<li class=\"error\">Database not initialized</li>");
    };

    var todos = orm.findAll(Todo) catch {
        return Response.fragment("<li class=\"error\">Failed to load todos</li>");
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
        buf.appendSlice(allocator, "<li class=\"empty-state\"><div class=\"empty-state-icon\">🔍</div><p>No matching todos found.</p></li>") catch {};
    }

    return Response.fragment(buf.toOwnedSlice(allocator) catch "");
}

/// Handle creating a new todo (returns HTML fragment for the new item)
pub fn handleCreateTodo(req: *Request) Response {
    const body_str = req.body();

    const title_encoded = getFormValue(body_str, "title") orelse {
        return Response.fragment("<li class=\"error\">Title is required</li>").withStatus(400);
    };

    // Decode title
    var title_buf: [256]u8 = undefined;
    const title = urlDecode(title_encoded, &title_buf);

    if (title.len == 0) {
        return Response.fragment("<li class=\"error\">Title cannot be empty</li>").withStatus(400);
    }

    // Get and decode other fields
    var desc_buf: [1024]u8 = undefined;
    const description = if (getFormValue(body_str, "description")) |d|
        urlDecode(d, &desc_buf)
    else
        "";

    const priority = getFormValue(body_str, "priority") orelse "medium";

    var tags_buf: [256]u8 = undefined;
    const tags = if (getFormValue(body_str, "tags")) |t|
        urlDecode(t, &tags_buf)
    else
        "";

    // Parse due date
    var due_date: ?i64 = null;
    if (getFormValue(body_str, "due_date")) |dd| {
        if (dd.len > 0) {
            due_date = parseDateToTimestamp(dd);
        }
    }

    const orm = database.getORM() catch {
        return Response.fragment("<li class=\"error\">Database not initialized</li>").withStatus(500);
    };

    // Allocate strings
    const title_copy = allocator.dupe(u8, title) catch {
        return Response.fragment("<li class=\"error\">Memory error</li>").withStatus(500);
    };
    const desc_copy = allocator.dupe(u8, description) catch {
        allocator.free(title_copy);
        return Response.fragment("<li class=\"error\">Memory error</li>").withStatus(500);
    };
    const priority_copy = allocator.dupe(u8, priority) catch {
        allocator.free(title_copy);
        allocator.free(desc_copy);
        return Response.fragment("<li class=\"error\">Memory error</li>").withStatus(500);
    };
    const tags_copy = allocator.dupe(u8, tags) catch {
        allocator.free(title_copy);
        allocator.free(desc_copy);
        allocator.free(priority_copy);
        return Response.fragment("<li class=\"error\">Memory error</li>").withStatus(500);
    };

    var todo = Todo{
        .id = 0,
        .user_id = 0,
        .title = title_copy,
        .description = desc_copy,
        .completed = false,
        .priority = priority_copy,
        .due_date = due_date,
        .tags = tags_copy,
        .created_at = std.time.timestamp(),
        .updated_at = std.time.timestamp(),
    };

    orm.create(Todo, todo) catch {
        return Response.fragment("<li class=\"error\">Failed to create todo</li>").withStatus(500);
    };

    todo.id = orm.db.lastInsertRowId() catch 0;

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    renderTodoItem(todo, &buf) catch {
        return Response.fragment("<li class=\"error\">Failed to render todo</li>");
    };

    return Response.fragment(buf.toOwnedSlice(allocator) catch "")
        .htmxTrigger("todoCreated");
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
        return Response.fragment("<li class=\"error\">Invalid ID</li>").withStatus(400);
    }

    const id: i64 = std.fmt.parseInt(i64, id_str, 10) catch {
        return Response.fragment("<li class=\"error\">Invalid ID format</li>").withStatus(400);
    };

    const orm = database.getORM() catch {
        return Response.fragment("<li class=\"error\">Database not initialized</li>").withStatus(500);
    };

    var todo = orm.find(Todo, id) catch {
        return Response.fragment("<li class=\"error\">Todo not found</li>").withStatus(404);
    } orelse {
        return Response.fragment("<li class=\"error\">Todo not found</li>").withStatus(404);
    };

    todo.completed = !todo.completed;
    todo.updated_at = std.time.timestamp();

    orm.update(Todo, todo) catch {
        return Response.fragment("<li class=\"error\">Failed to update todo</li>").withStatus(500);
    };

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    renderTodoItem(todo, &buf) catch {
        return Response.fragment("<li class=\"error\">Failed to render todo</li>");
    };

    return Response.fragment(buf.toOwnedSlice(allocator) catch "")
        .htmxTrigger("todoUpdated");
}

/// Handle getting edit form for a todo
pub fn handleEditTodo(req: *Request) Response {
    const id_str = req.param("id").asString();
    if (id_str.len == 0) {
        return Response.fragment("<li class=\"error\">Invalid ID</li>").withStatus(400);
    }

    const id: i64 = std.fmt.parseInt(i64, id_str, 10) catch {
        return Response.fragment("<li class=\"error\">Invalid ID format</li>").withStatus(400);
    };

    const orm = database.getORM() catch {
        return Response.fragment("<li class=\"error\">Database not initialized</li>").withStatus(500);
    };

    const todo = orm.find(Todo, id) catch {
        return Response.fragment("<li class=\"error\">Todo not found</li>").withStatus(404);
    } orelse {
        return Response.fragment("<li class=\"error\">Todo not found</li>").withStatus(404);
    };

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    // Build edit form
    buf.appendSlice(allocator, "<li id=\"todo-") catch return Response.fragment("<li class=\"error\">Error</li>");
    var id_buf: [20]u8 = undefined;
    const id_fmt = std.fmt.bufPrint(&id_buf, "{d}", .{todo.id}) catch "0";
    buf.appendSlice(allocator, id_fmt) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "\" class=\"todo-item\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    buf.appendSlice(allocator, "  <form class=\"edit-form\" hx-put=\"/htmx/todos/") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, id_fmt) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "\" hx-target=\"#todo-") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, id_fmt) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "\" hx-swap=\"outerHTML\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Title input
    buf.appendSlice(allocator, "    <input type=\"text\" name=\"title\" value=\"") catch return Response.fragment("<li class=\"error\">Error</li>");
    var title_escaped: [512]u8 = undefined;
    buf.appendSlice(allocator, htmlEscape(todo.title, &title_escaped)) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "\" required>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Description input
    buf.appendSlice(allocator, "    <input type=\"text\" name=\"description\" value=\"") catch return Response.fragment("<li class=\"error\">Error</li>");
    var desc_escaped: [2048]u8 = undefined;
    buf.appendSlice(allocator, htmlEscape(todo.description, &desc_escaped)) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "\" placeholder=\"Description\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Priority select
    buf.appendSlice(allocator, "    <select name=\"priority\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    const priorities = [_][]const u8{ "low", "medium", "high" };
    for (priorities) |p| {
        buf.appendSlice(allocator, "      <option value=\"") catch return Response.fragment("<li class=\"error\">Error</li>");
        buf.appendSlice(allocator, p) catch return Response.fragment("<li class=\"error\">Error</li>");
        buf.appendSlice(allocator, "\"") catch return Response.fragment("<li class=\"error\">Error</li>");
        if (std.mem.eql(u8, todo.priority, p)) {
            buf.appendSlice(allocator, " selected") catch return Response.fragment("<li class=\"error\">Error</li>");
        }
        buf.appendSlice(allocator, ">") catch return Response.fragment("<li class=\"error\">Error</li>");
        buf.appendSlice(allocator, p) catch return Response.fragment("<li class=\"error\">Error</li>");
        buf.appendSlice(allocator, "</option>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    }
    buf.appendSlice(allocator, "    </select>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Tags input
    buf.appendSlice(allocator, "    <input type=\"text\" name=\"tags\" value=\"") catch return Response.fragment("<li class=\"error\">Error</li>");
    var tags_escaped: [256]u8 = undefined;
    buf.appendSlice(allocator, htmlEscape(todo.tags, &tags_escaped)) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "\" placeholder=\"Tags\">\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    // Buttons
    buf.appendSlice(allocator, "    <button type=\"submit\" class=\"btn-save\">Save</button>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "    <button type=\"button\" class=\"btn-cancel\" hx-get=\"/htmx/todos/") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, id_fmt) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "/view\" hx-target=\"#todo-") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, id_fmt) catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "\" hx-swap=\"outerHTML\">Cancel</button>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    buf.appendSlice(allocator, "  </form>\n") catch return Response.fragment("<li class=\"error\">Error</li>");
    buf.appendSlice(allocator, "</li>\n") catch return Response.fragment("<li class=\"error\">Error</li>");

    return Response.fragment(buf.toOwnedSlice(allocator) catch "");
}

/// Handle updating a todo
pub fn handleUpdateTodo(req: *Request) Response {
    const id_str = req.param("id").asString();
    if (id_str.len == 0) {
        return Response.fragment("<li class=\"error\">Invalid ID</li>").withStatus(400);
    }

    const id: i64 = std.fmt.parseInt(i64, id_str, 10) catch {
        return Response.fragment("<li class=\"error\">Invalid ID format</li>").withStatus(400);
    };

    const orm = database.getORM() catch {
        return Response.fragment("<li class=\"error\">Database not initialized</li>").withStatus(500);
    };

    var todo = orm.find(Todo, id) catch {
        return Response.fragment("<li class=\"error\">Todo not found</li>").withStatus(404);
    } orelse {
        return Response.fragment("<li class=\"error\">Todo not found</li>").withStatus(404);
    };

    const body_str = req.body();

    // Update fields from form
    if (getFormValue(body_str, "title")) |title_encoded| {
        var title_buf: [256]u8 = undefined;
        const title = urlDecode(title_encoded, &title_buf);
        if (title.len > 0) {
            const title_copy = allocator.dupe(u8, title) catch {
                return Response.fragment("<li class=\"error\">Memory error</li>").withStatus(500);
            };
            todo.title = title_copy;
        }
    }

    if (getFormValue(body_str, "description")) |desc_encoded| {
        var desc_buf: [1024]u8 = undefined;
        const desc = urlDecode(desc_encoded, &desc_buf);
        const desc_copy = allocator.dupe(u8, desc) catch {
            return Response.fragment("<li class=\"error\">Memory error</li>").withStatus(500);
        };
        todo.description = desc_copy;
    }

    if (getFormValue(body_str, "priority")) |priority| {
        const priority_copy = allocator.dupe(u8, priority) catch {
            return Response.fragment("<li class=\"error\">Memory error</li>").withStatus(500);
        };
        todo.priority = priority_copy;
    }

    if (getFormValue(body_str, "tags")) |tags_encoded| {
        var tags_buf: [256]u8 = undefined;
        const tags = urlDecode(tags_encoded, &tags_buf);
        const tags_copy = allocator.dupe(u8, tags) catch {
            return Response.fragment("<li class=\"error\">Memory error</li>").withStatus(500);
        };
        todo.tags = tags_copy;
    }

    todo.updated_at = std.time.timestamp();

    orm.update(Todo, todo) catch {
        return Response.fragment("<li class=\"error\">Failed to update todo</li>").withStatus(500);
    };

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    renderTodoItem(todo, &buf) catch {
        return Response.fragment("<li class=\"error\">Failed to render todo</li>");
    };

    return Response.fragment(buf.toOwnedSlice(allocator) catch "")
        .htmxTrigger("todoUpdated");
}

/// Handle viewing a single todo (for cancel edit)
pub fn handleViewTodo(req: *Request) Response {
    const id_str = req.param("id").asString();
    if (id_str.len == 0) {
        return Response.fragment("<li class=\"error\">Invalid ID</li>").withStatus(400);
    }

    const id: i64 = std.fmt.parseInt(i64, id_str, 10) catch {
        return Response.fragment("<li class=\"error\">Invalid ID format</li>").withStatus(400);
    };

    const orm = database.getORM() catch {
        return Response.fragment("<li class=\"error\">Database not initialized</li>").withStatus(500);
    };

    const todo = orm.find(Todo, id) catch {
        return Response.fragment("<li class=\"error\">Todo not found</li>").withStatus(404);
    } orelse {
        return Response.fragment("<li class=\"error\">Todo not found</li>").withStatus(404);
    };

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    renderTodoItem(todo, &buf) catch {
        return Response.fragment("<li class=\"error\">Failed to render todo</li>");
    };

    return Response.fragment(buf.toOwnedSlice(allocator) catch "");
}

/// Handle deleting a todo
pub fn handleDeleteTodo(req: *Request) Response {
    const id_str = req.param("id").asString();
    if (id_str.len == 0) {
        return Response.fragment("<li class=\"error\">Invalid ID</li>").withStatus(400);
    }

    const id: i64 = std.fmt.parseInt(i64, id_str, 10) catch {
        return Response.fragment("<li class=\"error\">Invalid ID format</li>").withStatus(400);
    };

    const orm = database.getORM() catch {
        return Response.fragment("<li class=\"error\">Database not initialized</li>").withStatus(500);
    };

    orm.delete(Todo, id) catch {
        return Response.fragment("<li class=\"error\">Failed to delete todo</li>").withStatus(500);
    };

    return Response.fragment("")
        .htmxTrigger("todoDeleted");
}

/// Handle getting todo stats
pub fn handleGetStats(req: *Request) Response {
    _ = req;

    const orm = database.getORM() catch {
        return Response.fragment("<div class=\"stat\"><span class=\"stat-value\">Error</span></div>");
    };

    var todos = orm.findAll(Todo) catch {
        return Response.fragment("<div class=\"stat\"><span class=\"stat-value\">Error</span></div>");
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

    // Total
    buf.appendSlice(allocator, "<div class=\"stat\"><span class=\"stat-value\">") catch return Response.fragment("<div class=\"stat\">Error</div>");
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{total}) catch "0") catch return Response.fragment("<div class=\"stat\">Error</div>");
    buf.appendSlice(allocator, "</span><span class=\"stat-label\">Total</span></div>\n") catch return Response.fragment("<div class=\"stat\">Error</div>");

    // Pending
    buf.appendSlice(allocator, "<div class=\"stat\"><span class=\"stat-value\">") catch return Response.fragment("<div class=\"stat\">Error</div>");
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{pending}) catch "0") catch return Response.fragment("<div class=\"stat\">Error</div>");
    buf.appendSlice(allocator, "</span><span class=\"stat-label\">Pending</span></div>\n") catch return Response.fragment("<div class=\"stat\">Error</div>");

    // Completed
    buf.appendSlice(allocator, "<div class=\"stat\"><span class=\"stat-value\">") catch return Response.fragment("<div class=\"stat\">Error</div>");
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{completed}) catch "0") catch return Response.fragment("<div class=\"stat\">Error</div>");
    buf.appendSlice(allocator, "</span><span class=\"stat-label\">Completed</span></div>\n") catch return Response.fragment("<div class=\"stat\">Error</div>");

    // Progress
    buf.appendSlice(allocator, "<div class=\"stat\"><span class=\"stat-value\">") catch return Response.fragment("<div class=\"stat\">Error</div>");
    buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}%", .{progress}) catch "0%") catch return Response.fragment("<div class=\"stat\">Error</div>");
    buf.appendSlice(allocator, "</span><span class=\"stat-label\">Progress</span></div>\n") catch return Response.fragment("<div class=\"stat\">Error</div>");

    // Overdue (optional, shown if any)
    if (overdue > 0) {
        buf.appendSlice(allocator, "<div class=\"stat\" style=\"color:#e74c3c\"><span class=\"stat-value\">") catch return Response.fragment("<div class=\"stat\">Error</div>");
        buf.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{overdue}) catch "0") catch return Response.fragment("<div class=\"stat\">Error</div>");
        buf.appendSlice(allocator, "</span><span class=\"stat-label\">Overdue</span></div>") catch return Response.fragment("<div class=\"stat\">Error</div>");
    }

    return Response.fragment(buf.toOwnedSlice(allocator) catch "");
}

/// Handle clearing all completed todos
pub fn handleClearCompleted(req: *Request) Response {
    const orm = database.getORM() catch {
        return Response.fragment("<li class=\"error\">Database not initialized</li>");
    };

    orm.db.execute("DELETE FROM todos WHERE completed = 1") catch {
        return Response.fragment("<li class=\"error\">Failed to clear completed</li>").withStatus(500);
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
        buf.appendSlice(allocator, "<li class=\"empty-state\"><div class=\"empty-state-icon\">✅</div><p>All caught up! No active todos.</p></li>\n") catch {};
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
        buf.appendSlice(allocator, "<li class=\"empty-state\"><div class=\"empty-state-icon\">📋</div><p>No completed todos yet.</p></li>\n") catch {};
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
        buf.appendSlice(allocator, "<li class=\"empty-state\"><div class=\"empty-state-icon\">📝</div><p>No todos yet. Add one above!</p></li>\n") catch {};
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
