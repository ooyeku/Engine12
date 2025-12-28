const std = @import("std");
const Env = @import("env.zig").Env;

/// Log levels for the application.
pub const LogLevel = enum {
    debug,
    info,
    warn,
    @"error",
};

/// Application environment.
pub const Environment = enum {
    development,
    staging,
    production,
};

/// Database driver type.
pub const DatabaseDriver = enum {
    sqlite,
    postgresql,
};

/// Server configuration.
pub const ServerConfig = struct {
    host: []const u8,
    port: u16,
    workers: u16,
    read_timeout_ms: u32,
    write_timeout_ms: u32,
    max_body_size: usize,
};

/// Database configuration.
pub const DatabaseConfig = struct {
    driver: DatabaseDriver,
    // SQLite
    sqlite_path: []const u8,
    // PostgreSQL
    pg_host: []const u8,
    pg_port: u16,
    pg_database: ?[]const u8,
    pg_user: ?[]const u8,
    pg_password: ?[]const u8,
};

/// Logging configuration.
pub const LogConfig = struct {
    level: LogLevel,
    enable_request_logging: bool,
};

/// Cache configuration.
pub const CacheConfig = struct {
    enabled: bool,
    ttl_ms: u32,
};

/// Engine limits configuration.
pub const LimitsConfig = struct {
    max_routes: usize = 5000,
    max_background_workers: usize = 32,
    max_health_checks: usize = 8,
    max_static_routes: usize = 500,
    max_ws_routes: usize = 1000,
    max_queue_size: usize = 4096,
    max_middleware: usize = 16,
    max_context_entries: usize = 16,
    max_route_params: usize = 8,
    max_valves: usize = 32,
};

/// Complete application configuration.
/// Note: String values are owned by this struct's arena allocator.
pub const Config = struct {
    environment: Environment,
    server: ServerConfig,
    database: DatabaseConfig,
    logging: LogConfig,
    cache: CacheConfig,
    limits: LimitsConfig,
    secret_key: ?[]const u8,

    /// Arena allocator that owns all string memory in this config.
    /// Caller must call deinit() to free memory.
    arena: ?std.heap.ArenaAllocator = null,

    /// Load configuration from environment variables and optional .env file.
    /// Looks for .env file in current directory by default.
    /// Caller must call deinit() on the returned Config.
    pub fn load(allocator: std.mem.Allocator) !Config {
        return loadFromFile(allocator, ".env");
    }

    /// Load configuration from a specific .env file path.
    /// Caller must call deinit() on the returned Config.
    pub fn loadFromFile(allocator: std.mem.Allocator, env_file_path: []const u8) !Config {
        var env = Env.init(allocator);
        defer env.deinit();

        // Load .env file (optional, won't error if missing)
        try env.loadFile(env_file_path);

        return loadFromEnvOwned(allocator, &env);
    }

    /// Load configuration from an Env instance, copying strings to owned memory.
    /// Caller must call deinit() on the returned Config.
    pub fn loadFromEnvOwned(allocator: std.mem.Allocator, env: *const Env) !Config {
        // Use arena allocator to own all string memory
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        const environment = env.getEnum(Environment, "E12_ENV", .development);

        // Determine defaults based on environment
        const is_prod = environment == .production;
        const default_workers: u16 = if (is_prod) 32 else 12;
        const default_log_level: LogLevel = if (is_prod) .info else .debug;

        // Server config - copy strings to arena
        const server = ServerConfig{
            .host = try aa.dupe(u8, env.getOrDefault("E12_HOST", "127.0.0.1")),
            .port = env.getInt(u16, "E12_PORT", 8080),
            .workers = env.getInt(u16, "E12_WORKERS", default_workers),
            .read_timeout_ms = env.getInt(u32, "E12_READ_TIMEOUT", 10000),
            .write_timeout_ms = env.getInt(u32, "E12_WRITE_TIMEOUT", 10000),
            .max_body_size = env.getInt(usize, "E12_MAX_BODY_SIZE", 10 * 1024 * 1024),
        };

        // Database config - copy strings to arena
        const db_driver = env.getEnum(DatabaseDriver, "E12_DB_DRIVER", .sqlite);
        const database = DatabaseConfig{
            .driver = db_driver,
            .sqlite_path = try aa.dupe(u8, env.getOrDefault("E12_DB_PATH", "app.db")),
            .pg_host = try aa.dupe(u8, env.getOrDefault("E12_DB_HOST", "127.0.0.1")),
            .pg_port = env.getInt(u16, "E12_DB_PORT", 5432),
            .pg_database = if (env.get("E12_DB_NAME")) |v| try aa.dupe(u8, v) else null,
            .pg_user = if (env.get("E12_DB_USER")) |v| try aa.dupe(u8, v) else null,
            .pg_password = if (env.get("E12_DB_PASSWORD")) |v| try aa.dupe(u8, v) else null,
        };

        // Validate PostgreSQL config in production
        if (is_prod and db_driver == .postgresql) {
            if (database.pg_database == null) {
                std.debug.print("[Config] Error: E12_DB_NAME is required for PostgreSQL in production\n", .{});
                return error.MissingRequiredConfig;
            }
            if (database.pg_user == null) {
                std.debug.print("[Config] Error: E12_DB_USER is required for PostgreSQL in production\n", .{});
                return error.MissingRequiredConfig;
            }
        }

        // Logging config
        const logging = LogConfig{
            .level = env.getEnum(LogLevel, "E12_LOG_LEVEL", default_log_level),
            .enable_request_logging = env.getBool("E12_LOG_REQUESTS", true),
        };

        // Cache config
        const cache = CacheConfig{
            .enabled = env.getBool("E12_CACHE_ENABLED", true),
            .ttl_ms = env.getInt(u32, "E12_CACHE_TTL", 60000),
        };

        // Limits config
        const limits = LimitsConfig{
            .max_routes = env.getInt(usize, "E12_MAX_ROUTES", 5000),
            .max_background_workers = env.getInt(usize, "E12_MAX_BACKGROUND_WORKERS", 32),
            .max_health_checks = env.getInt(usize, "E12_MAX_HEALTH_CHECKS", 8),
            .max_static_routes = env.getInt(usize, "E12_MAX_STATIC_ROUTES", 500),
            .max_ws_routes = env.getInt(usize, "E12_MAX_WS_ROUTES", 1000),
            .max_queue_size = env.getInt(usize, "E12_MAX_QUEUE_SIZE", 4096),
            .max_middleware = env.getInt(usize, "E12_MAX_MIDDLEWARE", 16),
            .max_context_entries = env.getInt(usize, "E12_MAX_CONTEXT_ENTRIES", 16),
            .max_route_params = env.getInt(usize, "E12_MAX_ROUTE_PARAMS", 8),
            .max_valves = env.getInt(usize, "E12_MAX_VALVES", 32),
        };

        // Secret key (required in production) - copy to arena
        const secret_key = if (env.get("E12_SECRET_KEY")) |v| try aa.dupe(u8, v) else null;
        if (is_prod and secret_key == null) {
            std.debug.print("[Config] Warning: E12_SECRET_KEY is not set in production\n", .{});
        }

        return Config{
            .environment = environment,
            .server = server,
            .database = database,
            .logging = logging,
            .cache = cache,
            .limits = limits,
            .secret_key = secret_key,
            .arena = arena,
        };
    }

    /// Load configuration from an Env instance without taking ownership.
    /// Strings in the returned Config point to memory owned by the Env.
    /// Use this only when the Env will outlive the Config.
    pub fn loadFromEnv(env: *const Env) !Config {
        const environment = env.getEnum(Environment, "E12_ENV", .development);

        // Determine defaults based on environment
        const is_prod = environment == .production;
        const default_workers: u16 = if (is_prod) 32 else 12;
        const default_log_level: LogLevel = if (is_prod) .info else .debug;

        // Server config
        const server = ServerConfig{
            .host = env.getOrDefault("E12_HOST", "127.0.0.1"),
            .port = env.getInt(u16, "E12_PORT", 8080),
            .workers = env.getInt(u16, "E12_WORKERS", default_workers),
            .read_timeout_ms = env.getInt(u32, "E12_READ_TIMEOUT", 10000),
            .write_timeout_ms = env.getInt(u32, "E12_WRITE_TIMEOUT", 10000),
            .max_body_size = env.getInt(usize, "E12_MAX_BODY_SIZE", 10 * 1024 * 1024),
        };

        // Database config
        const db_driver = env.getEnum(DatabaseDriver, "E12_DB_DRIVER", .sqlite);
        const database = DatabaseConfig{
            .driver = db_driver,
            .sqlite_path = env.getOrDefault("E12_DB_PATH", "app.db"),
            .pg_host = env.getOrDefault("E12_DB_HOST", "127.0.0.1"),
            .pg_port = env.getInt(u16, "E12_DB_PORT", 5432),
            .pg_database = env.get("E12_DB_NAME"),
            .pg_user = env.get("E12_DB_USER"),
            .pg_password = env.get("E12_DB_PASSWORD"),
        };

        // Validate PostgreSQL config in production
        if (is_prod and db_driver == .postgresql) {
            if (database.pg_database == null) {
                std.debug.print("[Config] Error: E12_DB_NAME is required for PostgreSQL in production\n", .{});
                return error.MissingRequiredConfig;
            }
            if (database.pg_user == null) {
                std.debug.print("[Config] Error: E12_DB_USER is required for PostgreSQL in production\n", .{});
                return error.MissingRequiredConfig;
            }
        }

        // Logging config
        const logging = LogConfig{
            .level = env.getEnum(LogLevel, "E12_LOG_LEVEL", default_log_level),
            .enable_request_logging = env.getBool("E12_LOG_REQUESTS", true),
        };

        // Cache config
        const cache = CacheConfig{
            .enabled = env.getBool("E12_CACHE_ENABLED", true),
            .ttl_ms = env.getInt(u32, "E12_CACHE_TTL", 60000),
        };

        // Limits config
        const limits = LimitsConfig{
            .max_routes = env.getInt(usize, "E12_MAX_ROUTES", 5000),
            .max_background_workers = env.getInt(usize, "E12_MAX_BACKGROUND_WORKERS", 32),
            .max_health_checks = env.getInt(usize, "E12_MAX_HEALTH_CHECKS", 8),
            .max_static_routes = env.getInt(usize, "E12_MAX_STATIC_ROUTES", 500),
            .max_ws_routes = env.getInt(usize, "E12_MAX_WS_ROUTES", 1000),
            .max_queue_size = env.getInt(usize, "E12_MAX_QUEUE_SIZE", 4096),
            .max_middleware = env.getInt(usize, "E12_MAX_MIDDLEWARE", 16),
            .max_context_entries = env.getInt(usize, "E12_MAX_CONTEXT_ENTRIES", 16),
            .max_route_params = env.getInt(usize, "E12_MAX_ROUTE_PARAMS", 8),
            .max_valves = env.getInt(usize, "E12_MAX_VALVES", 32),
        };

        // Secret key (required in production)
        const secret_key = env.get("E12_SECRET_KEY");
        if (is_prod and secret_key == null) {
            std.debug.print("[Config] Warning: E12_SECRET_KEY is not set in production\n", .{});
        }

        return Config{
            .environment = environment,
            .server = server,
            .database = database,
            .logging = logging,
            .cache = cache,
            .limits = limits,
            .secret_key = secret_key,
            .arena = null,
        };
    }

    /// Free all memory owned by this Config.
    pub fn deinit(self: *Config) void {
        if (self.arena) |*arena| {
            arena.deinit();
            self.arena = null;
        }
    }

    /// Check if running in production mode.
    pub fn isProduction(self: *const Config) bool {
        return self.environment == .production;
    }

    /// Check if running in development mode.
    pub fn isDevelopment(self: *const Config) bool {
        return self.environment == .development;
    }

    /// Print configuration summary (redacts sensitive values).
    pub fn printSummary(self: *const Config) void {
        std.debug.print("\n[Engine12 Configuration]\n", .{});
        std.debug.print("  Environment: {s}\n", .{@tagName(self.environment)});
        std.debug.print("  Server: {s}:{d} ({d} workers)\n", .{ self.server.host, self.server.port, self.server.workers });
        std.debug.print("  Database: {s}", .{@tagName(self.database.driver)});
        if (self.database.driver == .sqlite) {
            std.debug.print(" ({s})\n", .{self.database.sqlite_path});
        } else {
            std.debug.print(" ({s}:{d}/{s})\n", .{
                self.database.pg_host,
                self.database.pg_port,
                self.database.pg_database orelse "<not set>",
            });
        }
        std.debug.print("  Log Level: {s}\n", .{@tagName(self.logging.level)});
        std.debug.print("  Cache: {s} (TTL: {d}ms)\n", .{
            if (self.cache.enabled) "enabled" else "disabled",
            self.cache.ttl_ms,
        });
        std.debug.print("  Secret Key: {s}\n\n", .{
            if (self.secret_key != null) "[SET]" else "[NOT SET]",
        });
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Config.loadFromEnv defaults" {
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    const config = try Config.loadFromEnv(&env);

    try std.testing.expectEqual(Environment.development, config.environment);
    try std.testing.expectEqualStrings("127.0.0.1", config.server.host);
    try std.testing.expectEqual(@as(u16, 8080), config.server.port);
    try std.testing.expectEqual(DatabaseDriver.sqlite, config.database.driver);
    try std.testing.expectEqualStrings("app.db", config.database.sqlite_path);
}

test "Config.loadFromEnv with values" {
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    try env.parseLine("E12_ENV=production");
    try env.parseLine("E12_PORT=3000");
    try env.parseLine("E12_DB_DRIVER=postgresql");
    try env.parseLine("E12_DB_NAME=mydb");
    try env.parseLine("E12_DB_USER=admin");

    const config = try Config.loadFromEnv(&env);

    try std.testing.expectEqual(Environment.production, config.environment);
    try std.testing.expectEqual(@as(u16, 3000), config.server.port);
    try std.testing.expectEqual(DatabaseDriver.postgresql, config.database.driver);
    try std.testing.expectEqualStrings("mydb", config.database.pg_database.?);
}

test "Config.isProduction" {
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    try env.parseLine("E12_ENV=production");
    try env.parseLine("E12_DB_NAME=db");
    try env.parseLine("E12_DB_USER=user");

    const config = try Config.loadFromEnv(&env);

    try std.testing.expect(config.isProduction());
    try std.testing.expect(!config.isDevelopment());
}
