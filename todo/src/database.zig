const std = @import("std");
const E12 = @import("engine12");
const Database = E12.orm.Database;
const DatabaseConfig = E12.orm.DatabaseConfig;
const Driver = E12.orm.Driver;
const ORM = E12.orm.ORM;
const MigrationRegistry = E12.orm.MigrationRegistryType;
const migration_discovery = E12.migration_discovery;
const Logger = E12.Logger;
const RuntimeTemplate = E12.RuntimeTemplate;
const ResponseCache = E12.cache.ResponseCache;

const allocator = std.heap.page_allocator;

// Database configuration - set via environment or defaults
// Default to SQLite for ease of use (no server required)
// Set DB_DRIVER=postgresql to use PostgreSQL
pub const DbConfig = struct {
    driver: Driver = .sqlite,
    // PostgreSQL settings
    pg_host: []const u8 = "127.0.0.1",
    pg_port: u16 = 5432,
    pg_database: []const u8 = "todo_app",
    pg_username: []const u8 = "postgres",
    pg_password: ?[]const u8 = null,
    pg_pool_size: u16 = 5,
    // SQLite settings (fallback)
    sqlite_path: []const u8 = "todo.db",
};

// Global state
var global_db: ?Database = null;
var global_orm: ?ORM = null;
var global_index_template: ?*RuntimeTemplate = null;
var global_template_registry_storage: ?E12.TemplateRegistry = null;
var global_config: DbConfig = .{};

/// Database mutex for thread-safe access
/// Background tasks should lock this before any database operations
pub var db_mutex: std.Thread.Mutex = .{};
var global_app: ?*E12.Engine12 = null;
var global_cache: ?*ResponseCache = null;
var cache_mutex: std.Thread.Mutex = .{};

/// Get the logger from the global app instance
pub fn getLogger() ?*Logger {
    if (global_app) |app| {
        return app.getLogger();
    }
    return null;
}

/// Get the current database driver
pub fn getDriver() Driver {
    return global_config.driver;
}

/// Get the ORM instance
/// NOTE: This does NOT lock the database mutex. Callers that need thread-safe
/// access (background tasks, etc.) should lock db_mutex before calling this
/// and keep it locked during all database operations.
pub fn getORM() !*ORM {
    if (global_orm) |*orm| {
        return orm;
    }

    return error.DatabaseNotInitialized;
}

/// Execute a function with thread-safe ORM access
/// The mutex is held for the entire duration of the callback
/// Use this for background tasks that run in separate threads
pub fn withORM(comptime callback: fn (*ORM) void) void {
    db_mutex.lock();
    defer db_mutex.unlock();

    if (global_orm) |*orm| {
        callback(orm);
    }
}

/// Execute a function with thread-safe database access that can return a value
pub fn withORMResult(comptime T: type, comptime callback: fn (*ORM) T) T {
    db_mutex.lock();
    defer db_mutex.unlock();

    if (global_orm) |*orm| {
        return callback(orm);
    }
    return undefined;
}

/// Load database configuration from environment variables
fn loadConfigFromEnv() DbConfig {
    var config = DbConfig{};

    // Check for driver selection
    if (std.posix.getenv("DB_DRIVER")) |driver_env| {
        if (std.mem.eql(u8, driver_env, "sqlite")) {
            config.driver = .sqlite;
        } else if (std.mem.eql(u8, driver_env, "postgresql") or std.mem.eql(u8, driver_env, "postgres")) {
            config.driver = .postgresql;
        }
    }

    // PostgreSQL settings
    if (std.posix.getenv("PGHOST")) |host| {
        config.pg_host = host;
    }
    if (std.posix.getenv("PGPORT")) |port_str| {
        config.pg_port = std.fmt.parseInt(u16, port_str, 10) catch 5432;
    }
    if (std.posix.getenv("PGDATABASE")) |db| {
        config.pg_database = db;
    }
    if (std.posix.getenv("PGUSER")) |user| {
        config.pg_username = user;
    }
    if (std.posix.getenv("PGPASSWORD")) |pass| {
        config.pg_password = pass;
    }

    // SQLite settings
    if (std.posix.getenv("SQLITE_PATH")) |path| {
        config.sqlite_path = path;
    }

    return config;
}

/// Initialize the database and run migrations
pub fn initDatabase() !void {
    db_mutex.lock();
    defer db_mutex.unlock();

    if (global_db != null) {
        return; // Already initialized
    }

    // Load configuration from environment
    global_config = loadConfigFromEnv();

    // Open database based on driver configuration
    const db_config = switch (global_config.driver) {
        .sqlite => DatabaseConfig.sqlite(global_config.sqlite_path),
        .postgresql => DatabaseConfig.postgresql(.{
            .host = global_config.pg_host,
            .port = global_config.pg_port,
            .database = global_config.pg_database,
            .username = global_config.pg_username,
            .password = global_config.pg_password,
            .pool_size = global_config.pg_pool_size,
        }),
    };

    std.debug.print("[Todo] Initializing database with driver: {s}\n", .{@tagName(global_config.driver)});

    global_db = try Database.openWithConfig(db_config, allocator);

    // Initialize ORM
    global_orm = ORM.init(global_db.?, allocator);

    // Run migrations based on driver type
    try runMigrations();
}

/// Initialize the database with a specific configuration (for testing)
pub fn initDatabaseWithConfig(config: DbConfig) !void {
    db_mutex.lock();
    defer db_mutex.unlock();

    if (global_db != null) {
        return;
    }

    global_config = config;

    const db_config = switch (config.driver) {
        .sqlite => DatabaseConfig.sqlite(config.sqlite_path),
        .postgresql => DatabaseConfig.postgresql(.{
            .host = config.pg_host,
            .port = config.pg_port,
            .database = config.pg_database,
            .username = config.pg_username,
            .password = config.pg_password,
            .pool_size = config.pg_pool_size,
        }),
    };

    global_db = try Database.openWithConfig(db_config, allocator);
    global_orm = ORM.init(global_db.?, allocator);

    try runMigrations();
}

/// Run migrations for the current driver
fn runMigrations() !void {
    // For PostgreSQL, run PostgreSQL-specific migrations
    // For SQLite, use discovery-based migrations
    switch (global_config.driver) {
        .postgresql => {
            // Run PostgreSQL-specific schema creation
            try runPostgresMigrations();
        },
        .sqlite => {
            // Use migration auto-discovery for SQLite
            var registry = migration_discovery.discoverMigrations(allocator, "todo/src/migrations") catch |err| {
                std.debug.print("[Todo] Warning: Migration discovery failed: {}\n", .{err});
                return;
            };
            defer registry.deinit();
            try global_orm.?.runMigrationsFromRegistry(&registry);
        },
    }
}

/// Run PostgreSQL-specific migrations
fn runPostgresMigrations() !void {
    const db = &global_db.?;

    // Create migrations table if not exists
    db.execute(
        \\CREATE TABLE IF NOT EXISTS _migrations (
        \\  id SERIAL PRIMARY KEY,
        \\  name VARCHAR(255) NOT NULL UNIQUE,
        \\  applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\)
    ) catch |err| {
        std.debug.print("[Todo] Warning: Failed to create migrations table: {}\n", .{err});
    };

    // Create users table
    db.execute(
        \\CREATE TABLE IF NOT EXISTS users (
        \\  id SERIAL PRIMARY KEY,
        \\  username VARCHAR(255) NOT NULL UNIQUE,
        \\  email VARCHAR(255) NOT NULL UNIQUE,
        \\  password_hash TEXT NOT NULL,
        \\  created_at BIGINT NOT NULL,
        \\  updated_at BIGINT NOT NULL
        \\)
    ) catch |err| {
        std.debug.print("[Todo] Warning: Users table may already exist: {}\n", .{err});
    };

    // Create indexes for users
    db.execute("CREATE INDEX IF NOT EXISTS idx_users_username ON users(username)") catch {};
    db.execute("CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)") catch {};

    // Create todos table
    db.execute(
        \\CREATE TABLE IF NOT EXISTS todos (
        \\  id SERIAL PRIMARY KEY,
        \\  title VARCHAR(255) NOT NULL,
        \\  description TEXT NOT NULL DEFAULT '',
        \\  completed BOOLEAN NOT NULL DEFAULT FALSE,
        \\  priority TEXT NOT NULL DEFAULT 'medium',
        \\  due_date BIGINT,
        \\  tags TEXT,
        \\  user_id INTEGER REFERENCES users(id),
        \\  created_at BIGINT NOT NULL,
        \\  updated_at BIGINT NOT NULL
        \\)
    ) catch |err| {
        std.debug.print("[Todo] Warning: Todos table may already exist: {}\n", .{err});
    };

    // Create indexes for todos
    db.execute("CREATE INDEX IF NOT EXISTS idx_todos_user_id ON todos(user_id)") catch {};
    db.execute("CREATE INDEX IF NOT EXISTS idx_todos_completed ON todos(completed)") catch {};
    db.execute("CREATE INDEX IF NOT EXISTS idx_todos_priority ON todos(priority)") catch {};

    std.debug.print("[Todo] PostgreSQL migrations completed\n", .{});
}

/// Set the global app instance (for logger access)
pub fn setGlobalApp(app: *E12.Engine12) void {
    global_app = app;
}

/// Set the global template instance (deprecated - use template registry instead)
pub fn setGlobalTemplate(template: *RuntimeTemplate) void {
    global_index_template = template;
}

/// Get the global template instance (deprecated - use template registry instead)
pub fn getGlobalTemplate() ?*RuntimeTemplate {
    return global_index_template;
}

/// Set the global template registry instance
pub fn setGlobalTemplateRegistry(registry: E12.TemplateRegistry) void {
    global_template_registry_storage = registry;
}

/// Get the global template registry instance
pub fn getGlobalTemplateRegistry() ?*E12.TemplateRegistry {
    if (global_template_registry_storage) |*registry| {
        return registry;
    }
    return null;
}

/// Set the global cache instance
pub fn setGlobalCache(cache: *ResponseCache) void {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    global_cache = cache;
}

/// Close the database connection
pub fn closeDatabase() void {
    db_mutex.lock();
    defer db_mutex.unlock();

    if (global_db) |*db| {
        db.close();
        global_db = null;
    }
    global_orm = null;
}
