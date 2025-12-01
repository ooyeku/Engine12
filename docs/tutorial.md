# Tutorial: Building Your First Engine12 App

This tutorial will guide you through building a complete web application with Engine12, step by step.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Step 1: Setup Project](#step-1-setup-project)
  - [1.1 Create Project Structure](#11-create-project-structure)
  - [1.2 Initialize Build Files](#12-initialize-build-files)
  - [1.3 Create Source Directory](#13-create-source-directory)
- [Step 2: Basic Server](#step-2-basic-server)
- [Step 3: Add Routes](#step-3-add-routes)
  - [3.1 Update main.zig](#31-update-mainzig)
- [Step 4: Database Integration](#step-4-database-integration)
  - [4.1 Create Database Module](#41-create-database-module)
  - [4.2 Define Todo Model](#42-define-todo-model)
  - [4.3 Update Handlers](#43-update-handlers)
  - [4.4 Initialize Database](#44-initialize-database)
  - [4.5 ORM Convenience Methods](#45-orm-convenience-methods-new)
- [Step 5: Templates](#step-5-templates)
  - [5.1 Create Template File](#51-create-template-file)
  - [5.2 Render Template](#52-render-template)
- [Step 5.5: Hot Reloading (Development Mode)](#step-55-hot-reloading-development-mode)
  - [Using Runtime Templates](#using-runtime-templates)
  - [Static File Hot Reloading](#static-file-hot-reloading)
  - [When to Use Hot Reloading](#when-to-use-hot-reloading)
- [Step 6: Middleware](#step-6-middleware)
  - [6.1 Structured Logging](#61-structured-logging)
  - [6.2 Authentication Middleware](#62-authentication-middleware)
  - [6.3 CORS Middleware](#63-cors-middleware)
  - [6.4 Request ID Middleware](#64-request-id-middleware)
- [Step 7: Deploy](#step-7-deploy)
  - [7.1 Build for Production](#71-build-for-production)
  - [7.2 Run Server](#72-run-server)
  - [7.3 Production Considerations](#73-production-considerations)
  - [7.4 Performance Tuning](#74-performance-tuning)
- [Step 8: OpenAPI Documentation](#step-8-openapi-documentation)
  - [8.1 Enable OpenAPI Documentation](#81-enable-openapi-documentation)
  - [8.2 Accessing the Documentation](#82-accessing-the-documentation)
  - [8.3 Automatic Documentation](#83-automatic-documentation)
  - [8.4 Testing with Swagger UI](#84-testing-with-swagger-ui)
- [Step 9: Advanced Features](#step-9-advanced-features)
  - [9.1 Type-Safe Parameter Parsing](#91-type-safe-parameter-parsing)
  - [9.2 Pagination Helper](#92-pagination-helper)
  - [9.3 Error Response Helpers](#93-error-response-helpers)
  - [9.4 JSON Serialization](#94-json-serialization)
  - [9.5 File Responses](#95-file-responses)
  - [9.6 TryHandler Pattern](#96-tryhandler-pattern-new)
  - [9.7 Response.fromJsonValue](#97-responsefromjsonvalue-new)
  - [9.8 Typed Context Accessors](#98-typed-context-accessors-new)
  - [9.9 Migration Schema Helpers](#99-migration-schema-helpers-new)
- [Step 10: Using Valves](#step-10-using-valves)
  - [10.1 Creating a Simple Valve](#101-creating-a-simple-valve)
  - [10.2 Registering a Valve](#102-registering-a-valve)
  - [10.3 Creating a Valve with Routes](#103-creating-a-valve-with-routes)
  - [10.4 Using Multiple Capabilities](#104-using-multiple-capabilities)
  - [10.5 Lifecycle Hooks](#105-lifecycle-hooks)
  - [10.6 Using Builtin Valves](#106-using-builtin-valves)
  - [10.7 Best Practices](#107-best-practices)
- [Step 11: Using HandlerCtx](#step-11-using-handlerctx)
  - [11.1 Introduction to HandlerCtx](#111-introduction-to-handlerctx)
  - [11.2 Basic Usage](#112-basic-usage)
  - [11.3 Authentication Handling](#113-authentication-handling)
  - [11.4 Parameter Parsing](#114-parameter-parsing)
  - [11.5 Caching with HandlerCtx](#115-caching-with-handlerctx)
  - [11.6 Before and After Comparison](#116-before-and-after-comparison)
- [Step 12: Using Auto-Discovery Features](#step-12-using-auto-discovery-features)
  - [12.1 Migration Auto-Discovery](#121-migration-auto-discovery)
  - [12.2 Static File Auto-Discovery](#122-static-file-auto-discovery)
  - [12.3 Template Auto-Discovery](#123-template-auto-discovery)
  - [12.4 Complete Example with Auto-Discovery](#124-complete-example-with-auto-discovery)
- [Step 13: HTMX Integration](#step-13-htmx-integration)
  - [13.1 Automatic Enablement](#131-automatic-enablement)
  - [13.2 Detecting HTMX Requests](#132-detecting-htmx-requests)
  - [13.3 Creating HTMX Responses](#133-creating-htmx-responses)
  - [13.4 Complete Example](#134-complete-example)
- [Step 14: Service Registry Pattern](#step-14-service-registry-pattern-new)
  - [14.1 Defining a Service](#141-defining-a-service)
  - [14.2 Using the Service Registry](#142-using-the-service-registry)
  - [14.3 Restart Policies](#143-restart-policies)
  - [14.4 Health Monitoring](#144-health-monitoring)
- [Next Steps](#next-steps)

## Prerequisites

- Zig 0.15.1 or later
- Basic understanding of Zig syntax
- A text editor or IDE
- (Optional) Engine12 CLI tool for project scaffolding: `e12 new`

## Understanding Engine12 Imports

Engine12 uses a clean, consistent import structure. All types are re-exported from the main module:

```zig
const E12 = @import("engine12");

// Core types
const Engine12 = E12.Engine12;
const Request = E12.Request;
const Response = E12.Response;
const ServerConfig = E12.ServerConfig;

// ORM types
const ORM = E12.orm.ORM;
const Database = E12.orm.Database;
const Migration = E12.orm.Migration;

// Middleware and utilities
const Json = E12.Json;
const HandlerCtx = E12.HandlerCtx;
const BasicAuthValve = E12.BasicAuthValve;

// WebSocket
const WebSocketManager = E12.WebSocketManager;
const WebSocketRoom = E12.WebSocketRoom;
```

You can also use a single import with a short alias for convenience:

```zig
const E12 = @import("engine12");

pub fn main() !void {
    var app = try E12.Engine12.initDevelopment();
    defer app.deinit();
    
    try app.get("/", handleRoot);
    try app.listen();  // Blocks until shutdown
}

fn handleRoot(req: *E12.Request) E12.Response {
    _ = req;
    return E12.Response.text("Hello!");
}
```

## Step 1: Setup Project

### 1.1 Create Project Structure

**Option 1: Use Engine12 CLI (Recommended)**

The easiest way to start a new Engine12 project is using the CLI tool:

```bash
# Create a new project with recommended structure
e12 new myapp
cd myapp

# The project will be created with:
# - Complete directory structure
# - Example models, validators, auth helpers
# - Database setup with migration discovery
# - Static file and template discovery configured
# - Example handlers using HandlerCtx
# - Ready-to-run main.zig
```

**Option 2: Manual Setup**

If you prefer to set up manually:

```bash
mkdir myapp
cd myapp
```

### 1.2 Initialize Build Files

Create `build.zig.zon`:

```zig
.{
    .name = .myapp,
    .version = "0.1.0",
    .dependencies = .{
        .engine12 = .{
            .url = "git+https://github.com/ooyeku/Engine12.git",
            .hash = "...", // Run `zig fetch --save` to get the hash
        },
    },
}
```

Create `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const engine12_dep = b.dependency("engine12", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.addModule("engine12", engine12_dep.module("engine12"));
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
```

### 1.3 Create Source Directory

```bash
mkdir src
```

## Step 2: Basic Server

Create `src/main.zig`:

```zig
const std = @import("std");
const Engine12 = @import("engine12");
const Request = Engine12.Request;
const Response = Engine12.Response;

fn handleRoot(req: *Request) Response {
    _ = req;
    return Response.text("Hello, World!");
}

pub fn main() !void {
    var app = try Engine12.initDevelopment();
    defer app.deinit();

    try app.get("/", handleRoot);
    try app.listen();  // Blocks until shutdown (Ctrl+C to stop)
}
```

Build and run:

```bash
zig build run
```

Visit `http://127.0.0.1:8080` in your browser. You should see "Hello, World!".

**Note**: `listen()` blocks until the server is stopped. Use `start()` instead if you need the method to return immediately (non-blocking).

### 2.1 Server Configuration

By default, the server runs on `127.0.0.1:8080`. You can customize this using `configure()` or convenience methods:

```zig
pub fn main() !void {
    var app = try Engine12.initDevelopment();
    defer app.deinit();

    // Option 1: Configure with struct
    app.configure(.{
        .host = "0.0.0.0",  // Listen on all interfaces
        .port = 3000,       // Custom port
        .read_timeout = 10000,  // 10 seconds
        .write_timeout = 10000,
    });

    // Option 2: Use convenience methods
    app.setPort(3000);
    app.setHost("0.0.0.0");

    try app.get("/", handleRoot);
    try app.listen();  // Blocks until shutdown, prints status automatically
}
```

**ServerConfig options:**
- `host`: Server bind address (default: `"127.0.0.1"`)
- `port`: Server port (default: `8080`)
- `read_timeout`: Read timeout in ms (default: `10000`)
- `write_timeout`: Write timeout in ms (default: `10000`)

## Step 3: Add Routes

Let's add more routes for a simple todo API.

### 3.1 Update main.zig

```zig
const std = @import("std");
const Engine12 = @import("engine12");
const Request = Engine12.Request;
const Response = Engine12.Response;

var todos = std.ArrayListUnmanaged([]const u8){};

fn handleRoot(req: *Request) Response {
    _ = req;
    return Response.text("Todo API");
}

fn handleGetTodos(req: *Request) Response {
    _ = req;
    var json = std.ArrayListUnmanaged(u8){};
    defer json.deinit(std.heap.page_allocator);

    json.writer(std.heap.page_allocator).print("[", .{}) catch return Response.status(500);
    for (todos.items, 0..) |todo, i| {
        if (i > 0) {
            json.writer(std.heap.page_allocator).print(",", .{}) catch return Response.status(500);
        }
        json.writer(std.heap.page_allocator).print("\"{s}\"", .{todo}) catch return Response.status(500);
    }
    json.writer(std.heap.page_allocator).print("]", .{}) catch return Response.status(500);

    return Response.json(json.items);
}

fn handleCreateTodo(req: *Request) Response {
    const TodoInput = struct {
        title: []const u8,
    };
    
    const input = req.jsonBody(TodoInput) catch {
        return Response.errorResponse("Invalid JSON", 400);
    };
    
    // In production, add to database
    todos.append(std.heap.page_allocator, input.title) catch {
        return Response.serverError("Failed to create todo");
    };
    
    return Response.created().withJson("{\"id\": 1}");
}

fn handleGetTodo(req: *Request) Response {
    const id = req.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };
    _ = id;
    return Response.json("{\"id\": 1, \"title\": \"Sample Todo\"}");
}

fn handleDeleteTodo(req: *Request) Response {
    const id = req.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };
    _ = id;
    return Response.noContent();
}

pub fn main() !void {
    var app = try Engine12.initDevelopment();
    defer app.deinit();

    try app.get("/", handleRoot);
    try app.get("/todos", handleGetTodos);
    try app.post("/todos", handleCreateTodo);
    try app.get("/todos/:id", handleGetTodo);
    try app.delete("/todos/:id", handleDeleteTodo);

    try app.listen();  // Blocks until shutdown
}
```

Test the routes:

```bash
curl http://127.0.0.1:8080/todos
curl -X POST http://127.0.0.1:8080/todos -d '{"title":"Learn Zig"}'
curl http://127.0.0.1:8080/todos/1
curl -X DELETE http://127.0.0.1:8080/todos/1
```

## Step 4: Database Integration

Engine12's ORM supports both **SQLite** and **PostgreSQL** databases. You can easily switch between them with minimal code changes.

**Note**: The ORM maps columns to struct fields by name, not by position. This means column order in your queries doesn't need to match struct field order - the ORM will automatically match columns by name.

**Table Naming Convention**:
The ORM automatically pluralizes struct names for table names:
- `User` struct -> `users` table
- `Todo` struct -> `todos` table
- `Category` struct -> `categories` table

To override this, add a `table_name` declaration to your struct:
```zig
const AppUser = struct {
    pub const table_name = "app_users"; // Custom table name
    id: i64,
    username: []const u8,
};
```

**New in this version**:
- **PostgreSQL support** - Full PostgreSQL integration via pg.zig
- **Multi-driver ORM** - Same API works with SQLite and PostgreSQL
- `whereWithOptions()` - Query with ORDER BY support
- `upsert()` / `upsertIgnore()` - Insert or replace records silently
- `whereManaged()` - Automatic memory management for query results
- Improved error messages with SQL, table name, and context
- Automatic table name pluralization
- `findOne(T, id)` - Simpler single-record lookup returning `?T` directly
- `whereOne(T, condition)` - Returns `?T` for single-result queries  
- `withTransaction(callback)` - Execute operations atomically

### 4.1 Initialize Database

#### SQLite (Default)

**Recommended**: Use Engine12's built-in database initialization:

```zig
pub fn main() !void {
    var app = try Engine12.initDevelopment();
    defer app.deinit();

    // Initialize SQLite database and run migrations automatically
    try app.initDatabaseWithMigrations("todos.db", "src/migrations");

    // Get ORM instance when needed
    const orm = try app.getORM();
    
    // ... rest of code
}
```

#### PostgreSQL

For PostgreSQL, use `DatabaseConfig` with environment variables or explicit configuration:

```zig
const std = @import("std");
const Engine12 = @import("engine12");
const Database = Engine12.orm.Database;
const DatabaseConfig = Engine12.orm.DatabaseConfig;
const ORM = Engine12.orm.ORM;

var global_db: ?Database = null;
var global_orm: ?ORM = null;

pub fn initDatabase() !void {
    // Option 1: Use environment variables
    // Set: DB_DRIVER=postgresql PGHOST=localhost PGDATABASE=myapp PGUSER=myuser
    
    // Option 2: Explicit configuration
    const config = DatabaseConfig.postgresql(.{
        .host = std.posix.getenv("PGHOST") orelse "localhost",
        .port = 5432,
        .database = std.posix.getenv("PGDATABASE") orelse "todos",
        .username = std.posix.getenv("PGUSER") orelse "postgres",
        .password = std.posix.getenv("PGPASSWORD"),
        .pool_size = 10,
    });

    global_db = try Database.openWithConfig(config, std.heap.page_allocator);
    global_orm = ORM.init(global_db.?, std.heap.page_allocator);

    // Run migrations (PostgreSQL-specific syntax is handled automatically)
    try runMigrations();
}

pub fn getORM() !*ORM {
    if (global_orm) |*orm| {
        return orm;
    }
    return error.DatabaseNotInitialized;
}
```

**Running with PostgreSQL:**
```bash
# Using environment variables
DB_DRIVER=postgresql PGUSER=myuser PGDATABASE=myapp zig build run

# Or with explicit password
DB_DRIVER=postgresql PGUSER=myuser PGPASSWORD=secret PGDATABASE=myapp zig build run
```

#### Driver-Specific Migrations

When using PostgreSQL, your migrations should handle driver differences:

```zig
// src/migrations/1_create_todos.zig
const std = @import("std");
const Migration = @import("engine12").orm.Migration;

pub fn getMigration(driver: anytype) Migration {
    const is_postgres = driver == .postgresql;
    
    return Migration.init(
        1,
        "create_todos",
        if (is_postgres)
            \\CREATE TABLE IF NOT EXISTS todos (
            \\  id SERIAL PRIMARY KEY,
            \\  title VARCHAR(255) NOT NULL,
            \\  completed BOOLEAN NOT NULL DEFAULT FALSE,
            \\  created_at BIGINT NOT NULL
            \\)
        else
            \\CREATE TABLE IF NOT EXISTS todos (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  title TEXT NOT NULL,
            \\  completed INTEGER NOT NULL DEFAULT 0,
            \\  created_at INTEGER NOT NULL
            \\)
        ,
        "DROP TABLE IF EXISTS todos"
    );
}
```

**Benefits**:
- Same ORM API for both databases
- Automatic type conversion (boolean, integers, etc.)
- Connection pooling for PostgreSQL
- Thread-safe SQLite access

**Alternative**: If you need more control, you can still create a `database.zig` file:

```zig
const std = @import("std");
const Engine12 = @import("engine12");
const Database = Engine12.orm.Database;
const ORM = Engine12.orm.ORM;

var global_db: ?Database = null;
var global_orm: ?*ORM = null;

pub fn init() !void {
    global_db = try Database.open("todos.db", std.heap.page_allocator);
    // Initialize ORM (database auto-configures performance optimizations)
    global_orm = try ORM.initPtr(global_db.?, std.heap.page_allocator);

    // Use migration auto-discovery
    const migration_discovery = @import("engine12").orm.migration_discovery;
    var registry = try migration_discovery.discoverMigrations(std.heap.page_allocator, "src/migrations");
    defer registry.deinit();
    try global_orm.?.runMigrationsFromRegistry(&registry);
}

pub fn getORM() !*ORM {
    if (global_orm) |orm| {
        return orm;
    }
    return error.DatabaseNotInitialized;
}

pub fn deinit() void {
    if (global_orm) |orm| {
        orm.deinitPtr(std.heap.page_allocator);
    }
    if (global_db) |*db| {
        db.close();
    }
}
```

### 4.2 Define Todo Model

Add to `src/main.zig`:

```zig
const TodoStatus = enum {
    pending,
    in_progress,
    completed,
};

const Todo = struct {
    id: i64,
    title: []u8,
    description: ?[]u8 = null, // Optional field
    completed: bool,
    status: TodoStatus = .pending, // Enum field
    created_at: i64,
    updated_at: i64,
};
```

**Note**: The ORM supports:
- **Enum types**: Automatically converted to integers when saving
- **Optional fields**: Null values are skipped in INSERT/UPDATE operations
- **Parameter binding**: All CRUD operations use parameter binding to prevent SQL injection
- **Statement caching**: Optional prepared statement caching for improved performance

### 4.3 Update Handlers

```zig
fn handleGetTodos(req: *Request) Response {
    _ = req;
    // Get ORM from app singleton (requires database to be initialized)
    const E12 = @import("engine12");
    const orm = E12.Engine12.getORM() catch {
        return Response.status(500).withJson("{\"error\":\"Database error\"}");
    };

    var todos_list = orm.findAll(Todo) catch |err| {
        // Enhanced error handling - error messages now include table name, SQL, and column info
        std.debug.print("Failed to fetch todos: {}\n", .{err});
        return Response.status(500).withJson("{\"error\":\"Failed to fetch todos\"}");
    };
    defer {
        for (todos_list.items) |todo| {
            std.heap.page_allocator.free(todo.title);
        }
        todos_list.deinit(std.heap.page_allocator);
    }

    // Build JSON response
    var json = std.ArrayListUnmanaged(u8){};
    defer json.deinit(std.heap.page_allocator);
    json.writer(std.heap.page_allocator).print("[", .{}) catch return Response.status(500);
    for (todos_list.items, 0..) |todo, i| {
        if (i > 0) json.writer(std.heap.page_allocator).print(",", .{}) catch return Response.status(500);
        json.writer(std.heap.page_allocator).print(
            "{{\"id\":{d},\"title\":\"{s}\",\"completed\":{}}},\"created_at\":{d}}}",
            .{ todo.id, todo.title, todo.completed, todo.created_at }
        ) catch return Response.status(500);
    }
    json.writer(std.heap.page_allocator).print("]", .{}) catch return Response.status(500);

    return Response.json(json.items);
}

fn handleCreateTodo(req: *Request) Response {
    const TodoInput = struct {
        title: []const u8,
    };

    const input = req.jsonBody(TodoInput) catch {
        return Response.badRequest().withJson("{\"error\":\"Invalid JSON\"}");
    };

    // Get ORM from app singleton (requires database to be initialized)
    const E12 = @import("engine12");
    const orm = E12.Engine12.getORM() catch {
        return Response.status(500).withJson("{\"error\":\"Database error\"}");
    };

    const now = std.time.milliTimestamp();
    const title_copy = std.heap.page_allocator.dupe(u8, input.title) catch {
        return Response.status(500).withJson("{\"error\":\"Memory error\"}");
    };

    const todo = Todo{
        .id = 0,
        .title = title_copy,
        .completed = false,
        .created_at = now,
    };

    orm.create(Todo, todo) catch {
        std.heap.page_allocator.free(title_copy);
        return Response.status(500).withJson("{\"error\":\"Create failed\"}");
    };

    const id = orm.db.lastInsertRowId() catch 0;
    var json_buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&json_buf, "{{\"id\":{d}}}", .{id}) catch {
        return Response.status(500).withJson("{\"error\":\"Format error\"}");
    };

    return Response.created().withJson(json);
}
```

### 4.4 Initialize Database

Update `main()`:

```zig
pub fn main() !void {
    var app = try Engine12.initDevelopment();
    defer app.deinit();

    // Initialize database and run migrations automatically
    try app.initDatabaseWithMigrations("todos.db", "src/migrations");

    // ... rest of code
}
```

**Note**: With the recommended approach, you don't need a separate `database.zig` file. The database is managed by Engine12's singleton pattern, and you can access the ORM using `app.getORM()` anywhere in your handlers.

**Security**: All ORM operations (`create()`, `update()`, `find()`, `delete()`) use parameter binding to prevent SQL injection. User input is always safely bound as parameters, never interpolated into SQL strings.

**Performance**: Statement caching is automatically enabled when using `initDatabaseWithMigrations()`, improving query performance by reusing compiled SQL statements.

### 4.5 ORM Convenience Methods (New!)

Engine12 provides convenience methods that simplify common ORM patterns:

#### `findOne` - Simpler Single-Record Lookup

Instead of the verbose `find()` pattern:

```zig
// Old pattern (verbose)
var todo = orm.find(Todo, id) catch {
    return Response.notFound();
} orelse {
    return Response.notFound();
};

// New pattern (cleaner)
var todo = orm.findOne(Todo, id) catch {
    return Response.notFound();
} orelse {
    return Response.notFound();
};
```

The `findOne` method returns `?T` directly without requiring manual memory management for the result set.

#### `whereOne` - Single-Result Conditional Query

For queries that should return at most one result:

```zig
// Find a user by email
const user = orm.whereOne(User, "email = 'john@example.com'") catch {
    return Response.serverError("Database error");
} orelse {
    return Response.notFound("User not found");
};

// With parameters
const user = orm.whereOneParams(User, "email = ?", &params) catch {
    return Response.serverError("Database error");
} orelse {
    return Response.notFound("User not found");
};
```

#### `withTransaction` - Atomic Operations

Execute multiple operations atomically:

```zig
// Execute operations in a transaction
orm.withTransaction(struct {
    pub fn call(tx_orm: *ORM) !void {
        // All operations in here are atomic
        try tx_orm.create(Order, order);
        try tx_orm.create(OrderItem, item1);
        try tx_orm.create(OrderItem, item2);
        try tx_orm.update(Inventory, updated_inventory);
    }
}.call) catch |err| {
    // Transaction automatically rolled back on error
    return Response.serverError("Transaction failed");
};

// Or with a result
const result = orm.withTransactionResult(i64, struct {
    pub fn call(tx_orm: *ORM) !i64 {
        try tx_orm.create(Order, order);
        return tx_orm.db.lastInsertRowId();
    }
}.call) catch |err| {
    return Response.serverError("Transaction failed");
};
```

## Step 5: Templates

Create HTML templates for rendering.

### 5.1 Create Template File

Create `src/templates/index.zt.html`:

```html
<!DOCTYPE html>
<html>
<head>
    <title>{{ .title }}</title>
</head>
<body>
    <h1>{{ .title }}</h1>
    <ul>
        {% for .todos |todo| %}
        <li>
            {{ .todo.title }}
            {% if .todo.completed %}✓{% endif %}
            <small>(Index: {{ .index }})</small>
        </li>
        {% endfor %}
    </ul>
</body>
</html>
```

### 5.2 Render Template

```zig
const templates = Engine12.templates;

fn handleIndex(req: *Request) Response {
    _ = req;
    const template_content = @embedFile("templates/index.zt.html");
    const IndexTemplate = templates.Template.compile(template_content);

    const Context = struct {
        title: []const u8,
        todos: []const Todo,
        page_info: struct {
            author: []const u8,
            version: []const u8,
        },
    };

    const context = Context{
        .title = "My Todos",
        .todos = &[_]Todo{}, // Load from database
        .page_info = .{
            .author = "Engine12",
            .version = "1.0.0",
        },
    };

    const html = IndexTemplate.render(Context, context, std.heap.page_allocator) catch {
        return Response.status(500).text("Template error");
    };
    defer std.heap.page_allocator.free(html);

    return Response.html(html);
}
```

**Template example with iteration and parent context:**

```html
<h1>{{ .title }}</h1>
<p>By {{ .page_info.author }} v{{ .page_info.version }}</p>
<ul>
{% for .todos |todo| %}
    <li>
        {{ .todo.title }}
        {% if .first %}<span>(First)</span>{% endif %}
        {% if .last %}<span>(Last)</span>{% endif %}
        <small>Index: {{ .index }}</small>
        <p>Page author: {{ ../page_info.author }}</p>
    </li>
{% endfor %}
</ul>
```

## Step 5.5: Hot Reloading (Development Mode)

In development mode, Engine12 automatically enables hot reloading for templates and static files. This means you can edit templates and static assets without restarting the server.

### Using Runtime Templates

Instead of using `@embedFile` for templates, you can use `loadTemplate()` for hot reloading:

```zig
const std = @import("std");
const E12 = @import("engine12");

pub fn main() !void {
    var app = try E12.Engine12.initDevelopment();
    defer app.deinit();

    // Load template for hot reloading
    const template = try app.loadTemplate("templates/index.zt.html");

    try app.get("/", handleIndex);
    try app.listen();  // Blocks until shutdown
}

fn handleIndex(req: *E12.Request) E12.Response {
    _ = req;
    
    // Get template content (automatically reloads if changed)
    const template_content = template.getContentString() catch {
        return E12.Response.text("Template error").withStatus(500);
    };
    
    // Use template content with Template.compile() or runtime engine
    // For production, use comptime templates for type safety
    const TemplateType = E12.templates.Template.compile(template_content);
    const html = TemplateType.render(IndexContext, context, allocator) catch {
        return E12.Response.text("Render error").withStatus(500);
    };
    
    return E12.Response.html(html);
}
```

### Static File Hot Reloading

Static files are automatically served without cache headers in development mode:

```zig
// In development mode, cache is automatically disabled
try app.serveStatic("/", "./frontend");

// Changes to CSS, JS, or HTML files are immediately visible
// No need to hard refresh or clear browser cache
```

### When to Use Hot Reloading

- **Development**: Use `loadTemplate()` or `discoverTemplates()` for rapid iteration during development
- **Production**: Use `@embedFile` with comptime templates for type safety and performance

**Note**: Hot reloading only works for templates and static files. Code changes still require server restart.

**Tip**: Use `discoverTemplates()` to automatically load all templates from a directory instead of manually loading each one.

### Using Template Auto-Discovery

Instead of manually loading each template, you can use auto-discovery:

```zig
pub fn main() !void {
    var app = try E12.Engine12.initDevelopment();
    defer app.deinit();

    // Auto-discover all templates
    const templates = try app.discoverTemplates("src/templates");
    defer templates.deinit();

    // Register route that uses discovered template
    try app.get("/", handleIndex);
    try app.listen();  // Blocks until shutdown
}

fn handleIndex(req: *E12.Request) E12.Response {
    _ = req;
    
    // Get template from registry
    const template = templates.get("index") orelse {
        return E12.Response.text("Template not found").withStatus(500);
    };
    
    const context = struct {
        title: []const u8,
        message: []const u8,
    }{
        .title = "Welcome",
        .message = "Hello from Engine12!",
    };
    
    const html = template.render(@TypeOf(context), context, allocator) catch {
        return E12.Response.text("Rendering failed").withStatus(500);
    };
    
    return E12.Response.html(html);
}
```

**Benefits**:
- No manual template loading
- Automatic hot reloading
- Template names extracted from filenames
- Easy template access via registry

### Using Static File Auto-Discovery

Instead of manually registering each static directory:

```zig
// Old way (manual)
// Recommended: Auto-discover and serve all static directories
try app.serveStaticDirectory("static");
// This automatically registers:
// - static/css/ -> /css/*
// - static/js/ -> /js/*
// - static/images/ -> /images/*

// Alternative: Manual registration (if you need more control)
// try app.serveStatic("/css", "static/css");
// try app.serveStatic("/js", "static/js");
// try app.serveStatic("/images", "static/images");

// New way (auto-discovery)
try app.discoverStaticFiles("static");
// Automatically registers all subdirectories:
// - static/css/ -> /css/*
// - static/js/ -> /js/*
// - static/images/ -> /images/*
```

**Benefits**:
- No manual route registration
- Follows convention: directory name becomes route path
- Handles missing directories gracefully

## Step 6: Middleware

Add logging and authentication middleware.

### 6.1 Structured Logging

Engine12 provides built-in structured logging with automatic request/response logging:

```zig
const std = @import("std");
const E12 = @import("engine12");

pub fn main() !void {
    var app = try E12.Engine12.initDevelopment();
    defer app.deinit();

    // Configure logger
    const logger = app.getLogger();
    logger.setFormat(.human); // Human-readable for development
    // For production, use JSON format:
    // logger.setFormat(.json);
    // try logger.setFileDestination("logs/app.log");

    // Enable automatic request/response logging
    // Exclude health check endpoints
    try app.enableRequestLogging(.{
        .exclude_paths = &[_][]const u8{ "/health", "/metrics" },
    });

    try app.get("/", handleRoot);
    try app.listen();  // Blocks until shutdown
}

// Store app reference globally or pass logger to handler
var global_app: ?*E12.Engine12 = null;

fn handleRoot(req: *E12.Request) E12.Response {
    // Custom logging in handlers
    if (global_app) |app| {
        const logger = app.getLogger();
        try logger.info("Root endpoint accessed")
            .field("ip", req.header("X-Real-IP") orelse "unknown")
            .log();
    }
    
    return E12.Response.text("Hello, World!");
}

// In main(), before starting:
global_app = &app;
```

#### Manual Logging

You can also log manually without middleware:

```zig
// Simple logging
try logger.info("Server started").log();

// Logging with fields
try logger.warn("High memory usage")
    .fieldInt("memory_mb", 1024)
    .fieldBool("is_critical", true)
    .log();

// Logging with request context
try logger.fromRequest(req, .info, "Request processed").log();

// Logging errors
try logger.logError("Database connection failed").log();
```

#### Convenience Logging Methods (New!)

For simpler logging without the builder pattern, use convenience methods:

```zig
// Printf-style logging - simplest for formatted messages
logger.infof("User {} logged in from {s}", .{user_id, ip_address});
logger.warnf("Request took {}ms", .{duration_ms});
logger.errorf("Failed to connect to {s}:{}", .{host, port});
logger.debugf("Processing item {}", .{item_id});

// Simple message logging - no formatting needed
logger.infoMsg("Server started successfully");
logger.warnMsg("High memory usage detected");
logger.errorMsg("Database connection lost");
logger.debugMsg("Entering critical section");

// Structured logging with fields (convenience method)
logger.infoWithFields("User action", &[_]Logger.Field{
    .{ .key = "user_id", .value = "123" },
    .{ .key = "action", .value = "login" },
});
```

These convenience methods are especially useful in background tasks:

```zig
fn cleanupOldTodos() void {
    const logger = getLogger() orelse return;
    
    // Old verbose pattern:
    // if (logger.info("Cleanup started")) |entry| { entry.log(); }
    
    // New simple pattern:
    logger.infoMsg("Cleanup started");
    
    // ... cleanup logic ...
    
    logger.infof("Cleaned up {} old todos", .{count});
}
```

#### Multiple Log Destinations

Log to multiple destinations simultaneously:

```zig
const logger = app.getLogger();
try logger.addDestination(.stdout); // Console
try logger.setFileDestination("logs/app.log"); // File
try logger.setSyslogFacility(1); // Syslog (LOG_USER)
```

### 6.2 Authentication Middleware

```zig
fn authMiddleware(req: *Request) MiddlewareResult {
    if (req.header("Authorization")) |auth| {
        // Simple check - in production, validate token
        if (std.mem.eql(u8, auth, "Bearer secret-token")) {
            return .proceed;
        }
    }
    return .abort; // Returns 401 Unauthorized
}

// Apply to specific routes via route groups:
var api = app.group("/api");
api.usePreRequest(authMiddleware);
api.get("/todos", handleGetTodos);
```

### 6.3 CORS Middleware

Add CORS support for cross-origin requests:

```zig
const cors = cors_middleware.CorsMiddleware.init(.{
    .allowed_origins = &[_][]const u8{"http://localhost:3000"},
    .allowed_methods = &[_][]const u8{ "GET", "POST", "PUT", "DELETE" },
    .allowed_headers = &[_][]const u8{"Content-Type", "Authorization"},
    .max_age = 3600,
});

cors.setGlobalConfig();
const cors_mw_fn = cors.preflightMwFn();
try app.usePreRequest(cors_mw_fn);
```

### 6.4 Request ID Middleware

Add Request ID headers for tracing:

```zig
const req_id_mw = request_id_middleware.RequestIdMiddleware.init(.{});
const req_id_mw_fn = req_id_mw.preRequestMwFn();
try app.usePreRequest(req_id_mw_fn);
```

Request IDs are automatically added to response headers and can be accessed in handlers via `req.requestId()`.

## Step 7: Deploy

### 7.1 Build for Production

Update `build.zig` to add release build:

```zig
const release_exe = b.addExecutable(.{
    .name = "myapp",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = .ReleaseSafe, // Optimized build
});
```

Build:

```bash
zig build -Doptimize=ReleaseSafe
```

### 7.2 Run Server

```bash
./zig-out/bin/myapp
```

### 7.3 Production Considerations

- Set environment to production: `Engine12.initProduction()`
- Enable metrics: Already enabled in production profile
- Configure health checks
- Set up process management (systemd, supervisor, etc.)
- Configure logging
- Set up reverse proxy (nginx, etc.)

### 7.4 Performance Tuning

Engine12 uses a multi-threaded architecture with configurable worker threads for high-performance request handling.

**Configure Worker Threads:**

```zig
var app = try Engine12.initProduction();
app.configure(.{
    .host = "0.0.0.0",
    .port = 8080,
    .worker_threads = 16,  // Increase for even higher concurrency (default: 12)
});
```

**Recommendations:**

| Workload Type | Recommended Workers | Notes |
|---------------|---------------------|-------|
| Low traffic | 4-8 | Default (12) is sufficient |
| Medium traffic | 8-16 | Default (12) handles well |
| High traffic | 12-24 | Default (12) optimized for production |
| I/O bound | 2x CPU cores | More workers for waiting on I/O |
| CPU bound | 1x CPU cores | Avoid oversubscription |

**Buffer Configuration:**

```zig
app.configure(.{
    .buffer_size = 16384,       // Request buffer (16KB default)
    .max_header_size = 32768,  // Max header size (32KB default)
    .max_body_size = 10485760,  // Max body size (10MB default)
});
```

**Legacy Single-Threaded Mode:**

For debugging or special cases, set `worker_threads = 0` to use single-threaded mode:

```zig
app.configure(.{
    .worker_threads = 0,  // Single-threaded (legacy behavior)
});
```

## Step 8: OpenAPI Documentation

Engine12 provides automatic OpenAPI 3.0 specification generation and Swagger UI integration. This makes it easy to document and test your API.

### 8.1 Enable OpenAPI Documentation

Add OpenAPI documentation to your app with a single line:

```zig
pub fn main() !void {
    var app = try Engine12.initDevelopment();
    defer app.deinit();

    // Enable OpenAPI documentation
    try app.enableOpenApiDocs("/docs", .{
        .title = "Todo API",
        .version = "1.0.0",
        .description = "A simple todo management API",
    });

    // Your routes...
    try app.get("/", handleRoot);
    try app.restApi("/api/todos", Todo, .{
        .orm = &my_orm,
        .validator = validateTodo,
        .default_limit = 25,   // Default items per page (default: 20)
        .max_limit = 100,      // Max items per page (default: 100)
    });

    try app.listen();  // Blocks until shutdown
}
```

### 8.2 Accessing the Documentation

After starting your server:

1. **Swagger UI**: Visit `http://127.0.0.1:8080/docs` to view the interactive API documentation
2. **OpenAPI JSON**: Visit `http://127.0.0.1:8080/docs/openapi.json` to get the raw OpenAPI specification

### 8.3 Automatic Documentation

When you use `restApi()`, all CRUD endpoints are automatically documented:

- Request/response schemas are generated from your model structs
- Query parameters (filter, sort, pagination) are documented
- Path parameters are documented
- Request body schemas are generated automatically

**Example**: If you have a `Todo` model, the OpenAPI spec will include:
- `GET /api/todos` - List todos with query parameters
- `GET /api/todos/{id}` - Get todo by ID
- `POST /api/todos` - Create todo with request body schema
- `PUT /api/todos/{id}` - Update todo with request body schema
- `DELETE /api/todos/{id}` - Delete todo

### 8.4 Testing with Swagger UI

The Swagger UI interface allows you to:
- Browse all available endpoints
- View request/response schemas
- Test API endpoints directly from the browser
- See example request/response payloads

This is especially useful during development for testing your API without writing separate test clients.

## Step 9: Advanced Features

### 9.1 Type-Safe Parameter Parsing

Use `paramTyped()` and `queryParamTyped()` for type-safe parameter parsing:

```zig
fn handleGetTodo(req: *Request) Response {
    // Type-safe route parameter
    const id = req.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };
    
    // Type-safe query parameters
    const include_completed = req.queryParamTyped(bool, "include_completed") catch false orelse false;
    const limit = req.queryParamTyped(u32, "limit") catch 20 orelse 20;
    
    // Use parameters...
}
```

### 9.2 Pagination Helper

Use the pagination helper for paginated endpoints:

```zig
fn handleGetTodos(req: *Request) Response {
    const pagination = Pagination.fromRequest(req) catch {
        return Response.errorResponse("Invalid pagination", 400);
    };
    
    // Fetch paginated results
    const todos = try fetchTodos(pagination.limit, pagination.offset);
    const total = try countTodos();
    
    // Generate metadata
    const meta = pagination.toResponse(total);
    
    // Return paginated response
    return Response.jsonFrom(PaginatedResponse, .{
        .data = todos,
        .meta = meta,
    }, req.allocator());
}
```

For custom pagination defaults, use `fromRequestWithDefaults`:

```zig
// Default to 50 items per page, max 200
const pagination = Pagination.fromRequestWithDefaults(req, 50, 200) catch {
    return Response.errorResponse("Invalid pagination", 400);
};
```

### 9.3 Error Response Helpers

Use standardized error response helpers:

```zig
// Custom error with status code
return Response.errorResponse("Invalid input", 400);

// Server error
return Response.serverError("Database connection failed");

// Validation error
const errors = try schema.validate();
if (!errors.isEmpty()) {
    return Response.validationError(&errors);
}

// Not found with message
return Response.notFound("Todo not found");
```

### 9.4 Parameterized Queries

The ORM uses parameter binding for all CRUD operations to prevent SQL injection. For custom queries with user input, use `whereParams()`:

```zig
const ParamList = Engine12.orm.ParamList;

fn handleSearchTodos(req: *Request) Response {
    const search_query = req.queryParamTyped([]const u8, "q") orelse "";
    
    const orm = try getORM();
    
    // Build parameterized query
    var params = ParamList.init(req.allocator());
    defer params.deinit();
    try params.addString(search_query);
    
    // Safe - uses parameter binding
    var todos = try orm.whereParams(Todo, "title LIKE ?", &params);
    defer {
        for (todos.items) |todo| {
            allocator.free(todo.title);
        }
        todos.deinit(allocator);
    }
    
    // Return results...
}

// With multiple parameters
fn handleFilterTodos(req: *Request) Response {
    const status = req.queryParamTyped([]const u8, "status") orelse "pending";
    const min_priority = req.queryParamTyped(i32, "min_priority") orelse 0;
    
    var params = ParamList.init(req.allocator());
    defer params.deinit();
    try params.addString(status);
    try params.addInt(min_priority);
    
    var todos = try orm.whereParamsWithOptions(Todo, 
        "status = ? AND priority >= ?", 
        &params,
        .{ .order_by = "created_at", .ascending = false }
    );
    defer {
        for (todos.items) |todo| {
            allocator.free(todo.title);
        }
        todos.deinit(allocator);
    }
    
    // Return results...
}
```

**Security Best Practices:**
- ✅ **Always use parameter binding** for user input: `whereParams()`, `executeParams()`, `queryParams()`
- ✅ **Use ORM methods** (`create()`, `update()`, `find()`, `delete()`) - they use parameter binding automatically
- ❌ **Never interpolate user input** into SQL strings: `std.fmt.allocPrint(allocator, "SELECT * FROM users WHERE name = '{s}'", .{user_input})`
- ❌ **Avoid `where()` with user input** - use `whereParams()` instead

**SQLite Optimizations:**
The database automatically applies performance optimizations when opened:

```zig
// Database.open() automatically configures:
// - WAL mode for concurrent reads/writes
// - 256MB cache size
// - Memory-mapped I/O
// - 10 second busy timeout
var db = try Database.open("app.db", allocator);
var orm = ORM.init(db, allocator);
```

### 9.5 JSON Serialization

Use `fromStruct()` or `jsonFrom()` to automatically serialize structs:

```zig
const todo = Todo{ .id = 1, .title = "Hello", .completed = false };

// New: fromStruct() - cleaner API
return try Response.fromStruct(Todo, todo, allocator);

// Or: fromStructArray() for arrays
const todos = [_]Todo{ todo1, todo2 };
return try Response.fromStructArray(Todo, &todos, allocator);

// Legacy: jsonFrom() still works
return Response.jsonFrom(Todo, todo, allocator);
```

### 9.5 File Responses

Serve files directly from disk:

```zig
// Serve a file with automatic MIME type detection
return try Response.fromFile("static/report.pdf", allocator);

// Create a download response
return Response.download("report.pdf", pdf_data);
```

### 9.6 TryHandler Pattern (New!)

For handlers that may fail, use `getTry`, `postTry`, etc. to simplify error handling:

```zig
// Old pattern (verbose error handling)
fn handleGetUser(req: *Request) Response {
    const id = req.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };
    const orm = getORM() catch {
        return Response.serverError("Database error");
    };
    const user = orm.findOne(User, id) catch {
        return Response.serverError("Query failed");
    } orelse {
        return Response.notFound("User not found");
    };
    return Response.fromStruct(User, user, req.allocator()) catch {
        return Response.serverError("Serialization failed");
    };
}

// New pattern with TryHandler (cleaner)
fn handleGetUserTry(req: *Request) !Response {
    const id = try req.paramTyped(i64, "id");
    const orm = try getORM();
    const user = try orm.findOne(User, id) orelse return Response.notFound("User not found");
    return try Response.fromStruct(User, user, req.allocator());
}

// Register with automatic error conversion
try app.getTry("/users/:id", handleGetUserTry);
try app.postTry("/users", handleCreateUserTry);
try app.putTry("/users/:id", handleUpdateUserTry);
try app.deleteTry("/users/:id", handleDeleteUserTry);
```

Errors are automatically converted to appropriate HTTP responses (400 for validation, 500 for internal errors).

### 9.7 Response.fromJsonValue (New!)

For dynamic JSON responses (e.g., mixed types), use `fromJsonValue`:

```zig
const std = @import("std");

fn handleDynamicJson(req: *Request) Response {
    const allocator = req.allocator();
    
    // Build dynamic JSON using std.json.Value
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("status", .{ .string = "success" });
    try obj.put("count", .{ .integer = 42 });
    
    // Add dynamic array
    var arr = std.json.Array.init(allocator);
    try arr.append(.{ .string = "item1" });
    try arr.append(.{ .integer = 123 });
    try obj.put("items", .{ .array = arr });
    
    const value = std.json.Value{ .object = obj };
    
    // Serialize directly to JSON response
    return Response.fromJsonValue(value, allocator) catch {
        return Response.serverError("Serialization failed");
    };
}
```

### 9.8 Typed Context Accessors (New!)

Pass typed data between middleware and handlers:

```zig
// In middleware - set typed context
fn authMiddleware(req: *Request) MiddlewareResult {
    if (validateToken(req)) |user| {
        // Store typed user in request context
        req.setTyped(User, "current_user", &user);
        return .proceed;
    }
    return .abort;
}

// In handler - retrieve typed context
fn handleProfile(req: *Request) Response {
    // Get typed user from context
    const user = req.getTyped(User, "current_user") orelse {
        return Response.unauthorized("Not authenticated");
    };
    
    return Response.fromStruct(User, user.*, req.allocator()) catch {
        return Response.serverError("Error");
    };
}

// For value types (not pointers)
req.setTypedValue(i64, "user_id", 123);
const user_id = req.getTypedValue(i64, "user_id") orelse 0;
```

### 9.9 Migration Schema Helpers (New!)

Idempotent migration helpers for safer migrations:

```zig
const Schema = @import("engine12").orm.Schema;

pub fn up(db: *Database) !void {
    // Create table only if it doesn't exist
    try Schema.createTableIfNotExists(db, "users", 
        \\id INTEGER PRIMARY KEY,
        \\email TEXT UNIQUE NOT NULL,
        \\created_at INTEGER
    );
    
    // Add column only if it doesn't exist
    try Schema.addColumnIfNotExists(db, "users", "verified", "INTEGER DEFAULT 0");
    
    // Create index only if it doesn't exist
    try Schema.createIndexIfNotExists(db, "users", "idx_users_email", &[_][]const u8{"email"}, true);
}

// Schema diffing for validation
const diff = try Schema.diff(db, expected_schema, allocator);
defer diff.deinit();

if (diff.hasDifferences()) {
    for (diff.missing_tables) |table| {
        std.log.warn("Missing table: {s}", .{table});
    }
    for (diff.missing_columns) |col| {
        std.log.warn("Missing column: {s}.{s}", .{col.table, col.column});
    }
}
```

## Step 10: Using Valves

Valves provide a secure and simple plugin architecture for Engine12. Each valve is an isolated service that integrates deeply with the Engine12 runtime through controlled capabilities.

### 10.1 Creating a Simple Valve

Let's create a logging valve that tracks API requests:

```zig
const std = @import("std");
const E12 = @import("engine12");

const LoggingValve = struct {
    valve: E12.Valve,
    log_file: []const u8,

    pub fn init(log_file: []const u8) LoggingValve {
        return LoggingValve{
            .valve = E12.Valve{
                .metadata = E12.ValveMetadata{
                    .name = "logging",
                    .version = "1.0.0",
                    .description = "Request logging valve",
                    .author = "Engine12 Developer",
                    .required_capabilities = &[_]E12.ValveCapability{ .middleware },
                },
                .init = &LoggingValve.initValve,
                .deinit = &LoggingValve.deinitValve,
            },
            .log_file = log_file,
        };
    }

    pub fn initValve(v: *E12.Valve, ctx: *E12.ValveContext) !void {
        const self = @as(*LoggingValve, @ptrFromInt(@intFromPtr(v) - @offsetOf(LoggingValve, "valve")));
        
        // Register logging middleware
        try ctx.registerMiddleware(&LoggingValve.logMiddleware);
        
        _ = self;
    }

    pub fn deinitValve(v: *E12.Valve) void {
        _ = v;
        // Cleanup if needed
    }

    fn logMiddleware(req: *E12.Request) E12.middleware.MiddlewareResult {
        std.debug.print("[LOG] {s} {s}\n", .{ req.method(), req.path() });
        return .proceed;
    }
};
```

### 10.2 Registering a Valve

Register the valve with your Engine12 app:

```zig
pub fn main() !void {
    var app = try E12.Engine12.initDevelopment();
    defer app.deinit();

    // Register logging valve
    var logging_valve = LoggingValve.init("app.log");
    try app.registerValve(&logging_valve.valve);

    // Register your routes
    try app.get("/", handleRoot);

    try app.listen();  // Blocks until shutdown
}
```

### 10.3 Creating a Valve with Routes

Here's an example of a valve that registers its own routes:

```zig
const ApiValve = struct {
    valve: E12.Valve,

    pub fn init() ApiValve {
        return ApiValve{
            .valve = E12.Valve{
                .metadata = E12.ValveMetadata{
                    .name = "api",
                    .version = "1.0.0",
                    .description = "API routes valve",
                    .author = "Engine12 Developer",
                    .required_capabilities = &[_]E12.ValveCapability{ .routes },
                },
                .init = &ApiValve.initValve,
                .deinit = &ApiValve.deinitValve,
            },
        };
    }

    pub fn initValve(v: *E12.Valve, ctx: *E12.ValveContext) !void {
        // Register API routes
        try ctx.registerRoute("GET", "/api/status", ApiValve.handleStatus);
        try ctx.registerRoute("GET", "/api/version", ApiValve.handleVersion);
    }

    pub fn deinitValve(v: *E12.Valve) void {
        _ = v;
    }

    fn handleStatus(req: *E12.Request) E12.Response {
        _ = req;
        return E12.Response.json("{\"status\":\"ok\"}");
    }

    fn handleVersion(req: *E12.Request) E12.Response {
        _ = req;
        return E12.Response.json("{\"version\":\"1.0.0\"}");
    }
};
```

### 10.4 Using Multiple Capabilities

A valve can request multiple capabilities:

```zig
const FullFeatureValve = struct {
    valve: E12.Valve,

    pub fn init() FullFeatureValve {
        return FullFeatureValve{
            .valve = E12.Valve{
                .metadata = E12.ValveMetadata{
                    .name = "full_feature",
                    .version = "1.0.0",
                    .description = "Full-featured valve",
                    .author = "Engine12 Developer",
                    .required_capabilities = &[_]E12.ValveCapability{
                        .routes,
                        .middleware,
                        .background_tasks,
                        .health_checks,
                    },
                },
                .init = &FullFeatureValve.initValve,
                .deinit = &FullFeatureValve.deinitValve,
            },
        };
    }

    pub fn initValve(v: *E12.Valve, ctx: *E12.ValveContext) !void {
        // Register routes
        try ctx.registerRoute("GET", "/api/feature", FullFeatureValve.handleFeature);
        
        // Register middleware
        try ctx.registerMiddleware(&FullFeatureValve.featureMiddleware);
        
        // Register background task
        try ctx.registerTask("feature_cleanup", FullFeatureValve.cleanupTask, 60000);
        
        // Register health check
        try ctx.registerHealthCheck(&FullFeatureValve.healthCheck);
    }

    pub fn deinitValve(v: *E12.Valve) void {
        _ = v;
    }

    fn handleFeature(req: *E12.Request) E12.Response {
        _ = req;
        return E12.Response.json("{\"feature\":\"enabled\"}");
    }

    fn featureMiddleware(req: *E12.Request) E12.middleware.MiddlewareResult {
        _ = req;
        return .proceed;
    }

    fn cleanupTask() void {
        std.debug.print("[Feature] Running cleanup\n", .{});
    }

    fn healthCheck() E12.types.HealthStatus {
        return .healthy;
    }
};
```

### 10.5 Lifecycle Hooks

Valves can hook into app lifecycle events:

```zig
const LifecycleValve = struct {
    valve: E12.Valve,
    initialized: bool = false,

    pub fn init() LifecycleValve {
        return LifecycleValve{
            .valve = E12.Valve{
                .metadata = E12.ValveMetadata{
                    .name = "lifecycle",
                    .version = "1.0.0",
                    .description = "Lifecycle demo valve",
                    .author = "Engine12 Developer",
                    .required_capabilities = &[_]E12.ValveCapability{},
                },
                .init = &LifecycleValve.initValve,
                .deinit = &LifecycleValve.deinitValve,
                .onAppStart = &LifecycleValve.onStart,
                .onAppStop = &LifecycleValve.onStop,
            },
        };
    }

    pub fn initValve(v: *E12.Valve, ctx: *E12.ValveContext) !void {
        const self = @as(*LifecycleValve, @ptrFromInt(@intFromPtr(v) - @offsetOf(LifecycleValve, "valve")));
        self.initialized = true;
        std.debug.print("[Lifecycle] Valve initialized\n", .{});
        _ = ctx;
    }

    pub fn deinitValve(v: *E12.Valve) void {
        const self = @as(*LifecycleValve, @ptrFromInt(@intFromPtr(v) - @offsetOf(LifecycleValve, "valve")));
        std.debug.print("[Lifecycle] Valve deinitialized\n", .{});
        _ = self;
    }

    pub fn onStart(v: *E12.Valve, ctx: *E12.ValveContext) !void {
        _ = v;
        _ = ctx;
        std.debug.print("[Lifecycle] App started\n", .{});
    }

    pub fn onStop(v: *E12.Valve, ctx: *E12.ValveContext) void {
        _ = v;
        _ = ctx;
        std.debug.print("[Lifecycle] App stopped\n", .{});
    }
};
```

### 10.6 Using Builtin Valves

Engine12 includes production-ready builtin valves. Here's how to use the `BasicAuthValve` for authentication:

```zig
const std = @import("std");
const E12 = @import("engine12");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // Initialize database and ORM
    const db = try E12.orm.Database.open("app.db", allocator);
    var orm_instance = E12.orm.ORM.init(db, allocator);
    
    // Create Engine12 app
    var app = try E12.Engine12.initDevelopment();
    defer app.deinit();
    
    // Create and register auth valve
    var auth_valve = E12.BasicAuthValve.init(.{
        .secret_key = "your-secret-key-change-in-production",
        .orm = &orm_instance,
        .token_expiry_seconds = 3600, // 1 hour
    });
    try app.registerValve(&auth_valve.valve);
    
    // Manually register auth routes (route registration through valve context not yet implemented)
    try app.post("/auth/register", E12.BasicAuthValve.handleRegister);
    try app.post("/auth/login", E12.BasicAuthValve.handleLogin);
    try app.post("/auth/logout", E12.BasicAuthValve.handleLogout);
    try app.get("/auth/me", E12.BasicAuthValve.handleGetMe);
    
    // Register protected route
    try app.get("/protected", handleProtected);
    
    // Start app (migration runs automatically, blocks until shutdown)
    try app.listen();
}

fn handleProtected(req: *E12.Request) E12.Response {
    // Require authentication
    const user = E12.BasicAuthValve.requireAuth(req) catch {
        return E12.Response.errorResponse("Unauthorized", 401);
    };
    defer {
        const allocator = std.heap.page_allocator;
        allocator.free(user.username);
        allocator.free(user.email);
        allocator.free(user.password_hash);
    }
    
    return E12.Response.json("{\"message\":\"Hello, authenticated user!\"}");
}
```

The `BasicAuthValve` provides handler functions for:
- `POST /auth/register` - User registration
- `POST /auth/login` - User login (returns JWT token)
- `POST /auth/logout` - Logout
- `GET /auth/me` - Get current user info
- Automatic authentication middleware for JWT validation

**Note**: Routes must be manually registered after registering the valve, as shown in the example above.

See the [API Reference](../api-reference.md#builtin-valves) for complete documentation.

### 10.7 Best Practices

1. **Declare Only Required Capabilities**: Only request capabilities your valve actually needs
2. **Handle Errors Gracefully**: Check for capability errors and provide clear error messages
3. **Clean Up Resources**: Implement `deinit` to free any allocated resources
4. **Use Lifecycle Hooks**: Use `onAppStart` and `onAppStop` for initialization that depends on app state
5. **Document Your Valve**: Provide clear metadata including description and author
6. **Use Builtin Valves**: Prefer builtin valves like `BasicAuthValve` when they meet your needs

## Step 11: Using HandlerCtx

HandlerCtx is a high-level abstraction that reduces boilerplate code in handlers by 70-80%. It automatically handles common patterns like authentication, ORM access, parameter parsing, caching, and logging.

### 11.1 Introduction to HandlerCtx

HandlerCtx wraps a `Request` and provides convenient methods for common handler operations. It eliminates repetitive code patterns while maintaining Zig's type safety.

**Benefits:**
- **70-80% code reduction**: Eliminates repetitive authentication, ORM access, and parameter parsing boilerplate
- **Consistent error handling**: Standardized error responses with automatic logging
- **Type safety**: Maintains Zig's compile-time guarantees
- **Memory safety**: Automatic memory management via request arena allocator

### 11.2 Basic Usage

To use HandlerCtx, initialize it at the start of your handler:

```zig
const HandlerCtx = E12.HandlerCtx;

fn handleProtected(req: *E12.Request) E12.Response {
    var ctx = HandlerCtx.init(req, .{
        .require_auth = true,
        .require_orm = true,
        .get_orm = getORM, // Your app's ORM getter function
    }) catch |err| {
        return switch (err) {
            error.AuthenticationRequired => E12.Response.errorResponse("Authentication required", 401),
            error.DatabaseNotInitialized => E12.Response.serverError("Database not initialized"),
            else => E12.Response.serverError("Internal error"),
        };
    };
    
    // Now you can use ctx.user, ctx.orm(), etc.
    const user = ctx.user.?; // Safe because require_auth = true
    const orm = ctx.orm() catch unreachable; // Safe because require_orm = true
    
    return E12.Response.text("Hello, authenticated user!");
}
```

### 11.3 Authentication Handling

HandlerCtx automatically handles authentication boilerplate. Instead of manually calling `BasicAuthValve.requireAuth()` and managing memory:

**Before:**
```zig
fn handleSearchTodos(request: *Request) Response {
    const user = BasicAuthValve.requireAuth(request) catch {
        return Response.errorResponse("Authentication required", 401);
    };
    defer {
        allocator.free(user.username);
        allocator.free(user.email);
        allocator.free(user.password_hash);
    }
    
    // Use user.id, user.username, etc.
}
```

**After:**
```zig
fn handleSearchTodos(request: *Request) Response {
    var ctx = HandlerCtx.init(request, .{
        .require_auth = true,
        .get_orm = getORM,
    }) catch |err| {
        return switch (err) {
            error.AuthenticationRequired => Response.errorResponse("Authentication required", 401),
            else => Response.serverError("Internal error"),
        };
    };
    
    const user = ctx.user.?; // Already authenticated, strings are arena-allocated
    // Use user.id, user.username, etc. - no manual memory management needed!
}
```

### 11.4 Parameter Parsing

HandlerCtx provides convenient methods for parsing query parameters and route parameters:

**Query Parameters:**
```zig
var ctx = HandlerCtx.init(req, .{}) catch return Response.serverError("Failed to initialize");

// Required query parameter (returns error if missing)
const search_query = ctx.query([]const u8, "q") catch {
    return ctx.badRequest("Missing or invalid query parameter 'q'");
};

// Optional query parameter with default value
const limit = ctx.queryOrDefault(i32, "limit", 10); // Defaults to 10 if missing
const page = ctx.queryOrDefault(i32, "page", 1);     // Defaults to 1 if missing
```

**Route Parameters:**
```zig
// Route: GET /todos/:id
var ctx = HandlerCtx.init(req, .{}) catch return Response.serverError("Failed to initialize");

const todo_id = ctx.param(i64, "id") catch {
    return ctx.badRequest("Invalid todo ID");
};
```

**JSON Body:**
```zig
var ctx = HandlerCtx.init(req, .{}) catch return Response.serverError("Failed to initialize");

const todo_input = ctx.json(TodoInput) catch {
    return ctx.badRequest("Invalid JSON body");
};
```

### 11.5 Caching with HandlerCtx

HandlerCtx simplifies cache operations, especially when working with user-specific data:

```zig
fn handleGetStats(request: *Request) Response {
    var ctx = HandlerCtx.init(request, .{
        .require_auth = true,
        .require_orm = true,
        .get_orm = getORM,
    }) catch |err| {
        return switch (err) {
            error.AuthenticationRequired => Response.errorResponse("Authentication required", 401),
            error.DatabaseNotInitialized => Response.serverError("Database not initialized"),
            else => Response.serverError("Internal error"),
        };
    };

    const user = ctx.user.?;

    // Build cache key with user context (automatically includes user_id)
    const cache_key = ctx.cacheKey("todos:stats:{d}") catch {
        return ctx.serverError("Failed to create cache key");
    };
    // If user.id = 123, cache_key = "todos:stats:123"

    // Check cache
    if (ctx.cacheGet(cache_key) catch null) |entry| {
        return Response.text(entry.body)
            .withContentType(entry.content_type)
            .withHeader("X-Cache", "HIT");
    }

    // Fetch data from database
    const orm = ctx.orm() catch unreachable;
    const stats = getStats(orm, user.id) catch {
        return ctx.serverError("Failed to fetch stats");
    };

    // Serialize and cache
    const json = serializeStats(stats) catch {
        return ctx.serverError("Failed to serialize stats");
    };
    ctx.cacheSet(cache_key, json, 10000, "application/json");

    return Response.json(json)
        .withHeader("X-Cache", "MISS");
}
```

### 11.6 Before and After Comparison

Here's a complete example showing how HandlerCtx reduces boilerplate:

**Before (without HandlerCtx):**
```zig
fn handleSearchTodos(request: *Request) Response {
    // Require authentication
    const user = BasicAuthValve.requireAuth(request) catch {
        return Response.errorResponse("Authentication required", 401);
    };
    defer {
        allocator.free(user.username);
        allocator.free(user.email);
        allocator.free(user.password_hash);
    }

    // Parse query parameter
    const search_query = request.queryParamTyped([]const u8, "q") catch {
        return Response.errorResponse("Invalid query parameter", 400);
    } orelse {
        return Response.errorResponse("Missing query parameter", 400);
    };

    // Get ORM
    const orm = getORM() catch {
        return Response.serverError("Database not initialized");
    };

    // Build cache key
    const cache_key = std.fmt.allocPrint(request.arena.allocator(), "todos:search:{d}:{s}", .{user.id, search_query}) catch {
        return Response.serverError("Failed to create cache key");
    };

    // Check cache
    if (request.cacheGet(cache_key) catch null) |entry| {
        return Response.text(entry.body)
            .withContentType(entry.content_type)
            .withHeader("X-Cache", "HIT");
    }

    // ... rest of handler logic
}
```

**After (with HandlerCtx):**
```zig
fn handleSearchTodos(request: *Request) Response {
    var ctx = HandlerCtx.init(request, .{
        .require_auth = true,
        .require_orm = true,
        .get_orm = getORM,
    }) catch |err| {
        return switch (err) {
            error.AuthenticationRequired => Response.errorResponse("Authentication required", 401),
            error.DatabaseNotInitialized => Response.serverError("Database not initialized"),
            else => Response.serverError("Internal error"),
        };
    };

    const search_query = ctx.query([]const u8, "q") catch {
        return ctx.badRequest("Missing or invalid query parameter 'q'");
    };

    const user = ctx.user.?;
    
    // For cache keys with multiple values, use std.fmt.allocPrint directly
    const std = @import("std");
    const cache_key = std.fmt.allocPrint(request.arena.allocator(), "todos:search:{d}:{s}", .{ user.id, search_query }) catch {
        return ctx.serverError("Failed to create cache key");
    };

    if (ctx.cacheGet(cache_key) catch null) |entry| {
        return Response.text(entry.body)
            .withContentType(entry.content_type)
            .withHeader("X-Cache", "HIT");
    }

    const orm = ctx.orm() catch unreachable;
    
    // ... rest of handler logic - much cleaner!
}
```

**Code Reduction:**
- Authentication boilerplate: ~8 lines → 1 line (87% reduction)
- Query parsing: ~4 lines → 1 line (75% reduction)
- Cache key generation: ~3 lines → 1 line (67% reduction)
- Overall handler: ~15-20 lines of boilerplate → ~3-5 lines (70-80% reduction)

### 11.7 Error Handling

HandlerCtx provides convenient error response methods with automatic logging:

```zig
var ctx = HandlerCtx.init(req, .{}) catch return Response.serverError("Failed to initialize");

// Common error responses
return ctx.unauthorized("Authentication required");
return ctx.forbidden("You don't have permission");
return ctx.badRequest("Invalid input");
return ctx.notFound("Resource not found");
return ctx.serverError("Internal server error");

// Custom status code
return ctx.errorResponse("Custom error message", 418);
```

### 11.8 Integration with restApi

HandlerCtx works alongside `restApi` - it doesn't replace it. Use HandlerCtx for custom handlers that need more control:

```zig
// Use restApi for standard CRUD operations
try app.restApi("/api/todos", Todo, config);

// Use HandlerCtx for custom endpoints
try app.get("/api/todos/search", handleSearchTodos);
try app.get("/api/todos/stats", handleGetStats);
```

### 11.9 Best Practices

1. **Use HandlerCtx for Custom Handlers**: Use HandlerCtx for endpoints that need custom logic beyond standard CRUD
2. **Set Appropriate Requirements**: Use `require_auth` and `require_orm` flags to make requirements explicit
3. **Provide ORM Getter**: Pass your app's ORM getter function for flexible ORM access
4. **Use Convenience Methods**: Take advantage of `badRequest()`, `unauthorized()`, etc. for consistent error responses
5. **Leverage Caching**: Use `cacheKey()` to automatically include user context in cache keys
6. **Gradual Migration**: HandlerCtx is optional - migrate handlers incrementally

## Step 12: Using Auto-Discovery Features

Engine12 provides auto-discovery features that reduce boilerplate and follow conventions. These features are opt-in and gracefully handle missing directories.

### 12.1 Migration Auto-Discovery

Instead of manually importing migrations, use auto-discovery:

```zig
// In database.zig
const migration_discovery = @import("engine12").orm.migration_discovery;

pub fn initDatabase() !void {
    // ... database setup ...
    
    // Auto-discover migrations from directory
    var registry = try migration_discovery.discoverMigrations(allocator, "src/migrations");
    defer registry.deinit();
    
    // Run discovered migrations
    try orm.runMigrationsFromRegistry(&registry);
}
```

**Migration File Naming**: Use pattern `{number}_{name}.zig`:
- `1_create_users.zig`
- `2_add_email.zig`
- `3_add_indexes.zig`

Files are automatically sorted by version number.

### 12.2 Static File Auto-Discovery

Automatically register static file routes:

```zig
// In main.zig
try app.discoverStaticFiles("static");
// Automatically registers all subdirectories:
// - static/css/ -> /css/*
// - static/js/ -> /js/*
// - static/images/ -> /images/*
```

**Benefits**:
- No manual route registration
- Follows convention: directory name becomes route path
- Handles missing directories gracefully

### 12.3 Template Auto-Discovery

Automatically load templates from directory:

```zig
// In main.zig (development mode only)
const templates = try app.discoverTemplates("src/templates");
defer templates.deinit();

// Access templates by name (filename without .zt.html)
if (templates.get("index")) |template| {
    const html = try template.render(Context, context, allocator);
    return Response.html(html);
}
```

**Template Naming**: Filename becomes template name:
- `index.zt.html` → `templates.get("index")`
- `about.zt.html` → `templates.get("about")`
- `contact.zt.html` → `templates.get("contact")`

**Note**: Template discovery only works in development mode (requires hot reload).

### 12.4 Complete Example with Auto-Discovery

```zig
pub fn main() !void {
    // Initialize database with migration auto-discovery
    try database.initDatabase();
    const orm = try database.getORM();
    
    var app = try Engine12.initDevelopment();
    defer app.deinit();
    
    // Auto-discover static files
    app.discoverStaticFiles("static") catch |err| {
        std.debug.print("Warning: Static discovery failed: {}\n", .{err});
    };
    
    // Auto-discover templates
    const templates = app.discoverTemplates("src/templates") catch |err| {
        std.debug.print("Warning: Template discovery failed: {}\n", .{err});
    };
    defer templates.deinit();
    
    // Register routes
    try app.get("/", handleIndex);
    try app.restApi("/api/items", Item, config);
    
    try app.listen();  // Blocks until shutdown
}

fn handleIndex(req: *Request) Response {
    const template = templates.get("index") orelse {
        return Response.text("Template not found").withStatus(500);
    };
    
    const html = try template.render(Context, context, allocator);
    return Response.html(html);
}
```

## Step 13: HTMX Integration

Engine12 provides built-in HTMX support for server-driven interactivity. With HTMX, you can build dynamic web applications with all logic written in Zig - no JavaScript required. HTMX scripts are automatically injected into HTML responses.

### 13.1 Automatic Enablement

HTMX is automatically enabled when using `initDevelopment()`:

```zig
var app = try Engine12.initDevelopment();
// HTMX is now enabled - scripts are auto-injected into HTML responses
```

For production, enable HTMX explicitly:

```zig
var app = try Engine12.initProduction();
app.enableHtmx();
```

You can also configure HTMX with custom settings:

```zig
app.enableHtmxWithConfig(.{
    .version = "1.9.10",
    .extensions = &[_][]const u8{"ws", "sse"},  // Load HTMX extensions
    .debug = true,  // Enable debug mode in development
});
```

### 13.2 Detecting HTMX Requests

In your handlers, you can detect if a request came from HTMX:

```zig
fn handleAddTodo(req: *Request) Response {
    // Check if this is an HTMX request
    if (req.isHtmx()) {
        // This is an HTMX request - return fragment
        const todo = createTodo(req) catch return Response.badRequest("Invalid data");
        return Response.fragment(renderTodoHtml(todo))
            .htmxTrigger("todoAdded");
    }
    
    // Regular request - return full page
    return Response.html(renderFullPage());
}
```

**Request Detection Methods:**
- `req.isHtmx()` - Returns true if request was made by HTMX
- `req.isHtmxPartial()` - Returns true if request wants an HTML fragment (not full page)
- `req.isHtmxBoosted()` - Returns true if request is a boosted link/form (expects full page)
- `req.htmxTarget()` - Get the target element ID
- `req.htmxTrigger()` - Get the triggering element ID

### 13.3 Creating HTMX Responses

HTMX responses are created using special response methods:

**HTML Fragments:**
```zig
// Return just a fragment (partial HTML)
return Response.fragment("<li>New todo item</li>");
```

**Triggering Events:**
```zig
// Trigger a client-side event after response
return Response.fragment("<div>Done</div>")
    .htmxTrigger("todoCreated");
```

**Redirects:**
```zig
// Client-side redirect (no page reload)
return Response.htmxRedirect("/todos");
```

**URL Management:**
```zig
// Update browser URL without navigation
return Response.fragment("<div>Content</div>")
    .htmxPushUrl("/todos/123");  // Add to history
    
// Replace current URL in history
return Response.fragment("<div>Content</div>")
    .htmxReplaceUrl("/todos");
```

**Response Modifiers:**
```zig
// Change target element (using convenience alias)
return Response.fragment("<li>Item</li>")
    .withTarget("#todo-list");

// Change swap method (using convenience alias)
return Response.fragment("<li>Item</li>")
    .withSwap("beforeend");  // Append to target
```

### 13.4 Form Parsing

Engine12 provides a built-in form parser that makes handling form data easy:

```zig
fn handleCreateTodo(req: *Request) Response {
    var form = req.getFormParser();
    
    // Parse required field
    const title = form.getRequired("title") catch {
        return htmx.errors.validationErrorFragment("title", "Title is required");
    };
    defer req.allocator().free(title);
    
    // Parse optional fields
    const description = form.get("description") catch null;
    defer if (description) |d| req.allocator().free(d);
    
    const priority = (form.get("priority") catch null) orelse "medium";
    defer if (priority) |p| req.allocator().free(p);
    
    // Parse date
    const due_date = form.getDate("due_date") catch null;
    
    // Use parsed values...
}
```

**Form Parser Methods:**
- `get(key)` - Get optional form value (returns null if not found)
- `getRequired(key)` - Get required form value (returns error if missing)
- `getInt(key)` - Parse integer value
- `getBool(key)` - Parse boolean value (true for "true", "1", "yes")
- `getDate(key)` - Parse date (YYYY-MM-DD) and convert to timestamp

### 13.5 Error Handling

Standardized error responses make error handling consistent:

```zig
// Generic error
return htmx.errors.errorFragment("Something went wrong");

// Validation error
return htmx.errors.validationErrorFragment("title", "Title is required");

// Not found
return htmx.errors.notFoundFragment("Todo");

// Error with custom status
return htmx.errors.errorFragmentWithStatus("Database error", 500);
```

### 13.6 Complete Example

Here's a complete example of a todo list with HTMX using the new form parser and error helpers:

**Handler:**
```zig
const std = @import("std");
const E12 = @import("engine12");
const Request = E12.Request;
const Response = E12.Response;
const htmx = E12.htmx;

fn handleAddTodo(req: *Request) Response {
    // Use form parser for easy form data access
    var form = req.getFormParser();
    
    // Parse required field
    const title = form.getRequired("title") catch {
        return htmx.errors.validationErrorFragment("title", "Title is required");
    };
    defer req.allocator().free(title);
    
    if (title.len == 0) {
        return htmx.errors.validationErrorFragment("title", "Title cannot be empty");
    }
    
    // Parse optional fields
    const priority_raw = form.get("priority") catch null;
    defer if (priority_raw) |p| req.allocator().free(p);
    const priority = if (priority_raw) |p| p else "medium";
    
    const due_date = form.getDate("due_date") catch null;
    
    // Save to database
    const orm = getORM() catch {
        return htmx.errors.errorFragmentWithStatus("Database error", 500);
    };
    
    const todo = Todo{
        .id = 0,
        .title = title,
        .priority = priority,
        .completed = false,
        .due_date = due_date,
        .created_at = std.time.timestamp(),
    };
    
    orm.create(Todo, todo) catch {
        return htmx.errors.errorFragmentWithStatus("Failed to save", 500);
    };
    
    // Check if HTMX request
    if (req.isHtmxPartial()) {
        // Return just the new todo item HTML
        return Response.fragment(renderTodoItem(todo))
            .htmxTrigger("todoAdded");
    }
    
    // Non-HTMX: redirect to list
    return Response.redirect("/todos");
}

fn handleToggleTodo(req: *Request) Response {
    const id = req.paramTyped(i64, "id") catch {
        return htmx.errors.validationErrorFragment("id", "Invalid ID");
    };
    
    const orm = getORM() catch {
        return htmx.errors.errorFragmentWithStatus("Database error", 500);
    };
    
    var todo = orm.find(Todo, id) catch {
        return htmx.errors.notFoundFragment("Todo");
    } orelse {
        return htmx.errors.notFoundFragment("Todo");
    };
    
    todo.completed = !todo.completed;
    orm.update(Todo, todo) catch {
        return htmx.errors.errorFragmentWithStatus("Failed to update", 500);
    };
    
    if (req.isHtmxPartial()) {
        return Response.fragment(renderTodoItem(todo))
            .htmxTrigger("todoUpdated");
    }
    
    return Response.redirect("/todos");
}

fn handleDeleteTodo(req: *Request) Response {
    const id = req.paramTyped(i64, "id") catch {
        return htmx.errors.validationErrorFragment("id", "Invalid ID");
    };
    
    const orm = getORM() catch {
        return htmx.errors.errorFragmentWithStatus("Database error", 500);
    };
    
    orm.delete(Todo, id) catch {
        return htmx.errors.errorFragmentWithStatus("Failed to delete", 500);
    };
    
    if (req.isHtmxPartial()) {
        // Return empty response - HTMX will delete the element
        return Response.fragment("")
            .htmxTrigger("todoDeleted");
    }
    
    return Response.redirect("/todos");
}
```

**Template (HTML):**
```html
<!DOCTYPE html>
<html>
<head>
    <title>Todo List</title>
    <!-- HTMX script is automatically injected here by Engine12 -->
</head>
<body>
    <h1>Todos</h1>
    
    <!-- Add form - submits via HTMX, appends new todo to list -->
    <form hx-post="/todos" hx-target="#todo-list" hx-swap="beforeend">
        <input type="text" name="title" placeholder="New todo..." required>
        <button type="submit">Add</button>
    </form>
    
    <!-- Todo list -->
    <ul id="todo-list">
        {% for todo in todos %}
        <li id="todo-{{ todo.id }}">
            <input type="checkbox" 
                   hx-post="/todos/{{ todo.id }}/toggle"
                   hx-target="#todo-{{ todo.id }}"
                   hx-swap="outerHTML"
                   {% if todo.completed %}checked{% endif %}>
            <span>{{ todo.title }}</span>
            <button hx-delete="/todos/{{ todo.id }}" 
                    hx-target="#todo-{{ todo.id }}"
                    hx-swap="outerHTML"
                    hx-confirm="Delete this todo?">Delete</button>
        </li>
        {% endfor %}
    </ul>
    
    <!-- Count updates when todos change -->
    <div hx-trigger="todoAdded, todoDeleted from:body" hx-get="/todos/count">
        Total: <span id="count">{{ todos.len }}</span>
    </div>
</body>
</html>
```

**Key HTMX Attributes:**
- `hx-post`, `hx-get`, `hx-put`, `hx-delete` - HTTP method
- `hx-target` - Element to update with response
- `hx-swap` - How to swap content (`innerHTML`, `outerHTML`, `beforeend`, `afterbegin`, etc.)
- `hx-trigger` - When to trigger the request
- `hx-confirm` - Show confirmation dialog before request

**Benefits:**
- No JavaScript required - all logic in Zig
- Progressive enhancement - works without JavaScript
- Automatic script injection - no manual setup
- Type-safe handlers - compile-time guarantees
- Server-driven - all logic on the server

See the [API Reference](api-reference.md#htmx-integration) for complete HTMX API documentation.

## Step 14: Service Registry Pattern (New!)

Engine12 provides a built-in service registry for managing long-running services and daemons. This is useful for background workers, scheduled tasks, and microservice architectures.

### 14.1 Defining a Service

Services implement the `Service` interface with lifecycle methods:

```zig
const E12 = @import("engine12");
const Service = E12.services.Service;
const ManagedService = E12.services.ManagedService;
const ServiceRegistry = E12.services.ServiceRegistry;

const EmailService = struct {
    name: []const u8 = "email_service",
    allocator: std.mem.Allocator,
    running: bool = false,
    
    pub fn start(self: *EmailService) !void {
        self.running = true;
        // Initialize email client, connect to SMTP, etc.
    }
    
    pub fn stop(self: *EmailService) void {
        self.running = false;
        // Cleanup connections
    }
    
    pub fn healthCheck(self: *EmailService) E12.HealthStatus {
        return if (self.running) .healthy else .unhealthy;
    }
    
    // Implement Service interface
    pub fn asService(self: *EmailService) Service {
        return Service{
            .ptr = self,
            .startFn = @ptrCast(&EmailService.start),
            .stopFn = @ptrCast(&EmailService.stop),
            .healthCheckFn = @ptrCast(&EmailService.healthCheck),
        };
    }
};
```

### 14.2 Using the Service Registry

```zig
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // Create service registry
    var registry = ServiceRegistry.init(allocator);
    defer registry.deinit();
    
    // Create and register services
    var email_service = EmailService{ .allocator = allocator };
    try registry.register("email", email_service.asService(), .{
        .restart_policy = .on_failure,
        .max_restarts = 3,
        .health_check_interval_ms = 30000,
    });
    
    var notification_service = NotificationService{ .allocator = allocator };
    try registry.register("notifications", notification_service.asService(), .{
        .restart_policy = .always,
        .depends_on = &[_][]const u8{"email"},
    });
    
    // Start all services (respects dependencies)
    try registry.startAll();
    
    // Get service status
    if (registry.get("email")) |managed| {
        std.debug.print("Email service uptime: {}ms\n", .{managed.uptime()});
        std.debug.print("Health: {}\n", .{managed.healthCheck()});
    }
    
    // Stop all services (reverse order)
    registry.stopAll();
}
```

### 14.3 Restart Policies

Configure how services should be restarted on failure:

```zig
const RestartPolicy = E12.services.RestartPolicy;

// Never restart automatically
.restart_policy = .never,

// Restart only on failure (not on clean shutdown)
.restart_policy = .on_failure,

// Always restart (useful for daemons)
.restart_policy = .always,

// Restart on failure, but limit attempts
.restart_policy = .on_failure_limited,
.max_restarts = 5,
```

### 14.4 Health Monitoring

The registry can automatically monitor service health:

```zig
// Enable background health checks
try registry.startHealthMonitor(30000); // Check every 30 seconds

// Manual health check
const health = registry.checkHealth("email");
switch (health) {
    .healthy => std.debug.print("Service is healthy\n", .{}),
    .unhealthy => std.debug.print("Service needs attention\n", .{}),
    .degraded => std.debug.print("Service is degraded\n", .{}),
}

// Get all unhealthy services
const unhealthy = try registry.getUnhealthyServices(allocator);
defer allocator.free(unhealthy);
for (unhealthy) |name| {
    std.debug.print("Unhealthy: {s}\n", .{name});
}
```

## Next Steps

- Add validation for request data
- Implement authentication with sessions
- Add rate limiting
- Set up error handling
- Use auto-discovery features to reduce boilerplate
- Add HTMX interactivity to your templates
- Use the Service Registry for background workers
- Add more routes and features
- Deploy to production

See the [API Reference](api-reference.md) for more details on available APIs.

