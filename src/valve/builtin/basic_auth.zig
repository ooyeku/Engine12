const std = @import("std");
const valve = @import("../valve.zig");
const Valve = valve.Valve;
const ValveCapability = valve.ValveCapability;
const context = @import("../context.zig");
const ValveContext = context.ValveContext;
const Request = @import("../../http/request.zig").Request;
const Response = @import("../../http/response.zig").Response;
const middleware = @import("../../middleware/middleware.zig");
const orm = @import("../../orm/orm.zig");
const ORM = orm.ORM;
const Model = orm.Model;
const ModelWithORM = orm.ModelWithORM;
const Migration = @import("../../orm/migration.zig").Migration;
const SqlEscape = orm.SqlEscape;
const jwt = @import("jwt.zig");
const Claims = jwt.Claims;
const password = @import("password.zig");
const json_module = @import("../../data/json.zig");

pub const User = struct {
    id: i64,
    username: []const u8,
    email: []const u8,
    password_hash: []const u8,
    created_at: i64,
    updated_at: i64,
};

const UserInput = struct {
    username: ?[]const u8,
    email: ?[]const u8,
    password: ?[]const u8,
};

const LoginResponse = struct {
    token: []const u8,
    expires_in: i64,
    user: struct {
        id: i64,
        username: []const u8,
        email: []const u8,
    },
};

pub const BasicAuthConfig = struct {
    secret_key: []const u8,
    token_expiry_seconds: i64 = 3600,
    user_table_name: []const u8 = "users",
    orm: *ORM,
};

pub const BasicAuthValve = struct {
    valve: Valve,
    config: BasicAuthConfig,
    user_model: ModelWithORM(User),

    const Self = @This();

    var global_registry: ?*Self = null;
    var registry_mutex: std.Thread.Mutex = .{};

    pub fn init(config: BasicAuthConfig) Self {
        return Self{
            .valve = Valve{
                .metadata = valve.ValveMetadata{
                    .name = "basic_auth",
                    .version = "1.0.0",
                    .description = "JWT-based authentication valve with user management",
                    .author = "Engine12 Team",
                    .required_capabilities = &[_]ValveCapability{ .routes, .middleware, .database_access },
                },
                .init = &Self.initValve,
                .deinit = &Self.deinitValve,
                .onAppStart = &Self.onAppStart,
                .onAppStop = null,
            },
            .config = config,
            .user_model = ModelWithORM(User).init(config.orm),
        };
    }

    pub fn initValve(v: *Valve, ctx: *ValveContext) !void {
        const offset = @offsetOf(BasicAuthValve, "valve");
        const addr = @intFromPtr(v) - offset;
        const self = @as(*BasicAuthValve, @ptrFromInt(addr));

        registry_mutex.lock();
        defer registry_mutex.unlock();
        global_registry = self;

        try ctx.registerMiddleware(&Self.authMiddleware);
    }

    pub fn deinitValve(v: *Valve) void {
        registry_mutex.lock();
        defer registry_mutex.unlock();
        global_registry = null;
        _ = v;
    }

    pub fn onAppStart(v: *Valve, ctx: *ValveContext) !void {
        const offset = @offsetOf(BasicAuthValve, "valve");
        const addr = @intFromPtr(v) - offset;
        const self = @as(*BasicAuthValve, @ptrFromInt(addr));

        try self.runMigration(ctx.allocator);
    }

    fn runMigration(self: *Self, allocator: std.mem.Allocator) !void {
        const driver = self.config.orm.db.getDriver();

        switch (driver) {
            .sqlite => {
                const create_table_sql = try std.fmt.allocPrint(allocator,
                    \\CREATE TABLE IF NOT EXISTS {s} (
                    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
                    \\  username TEXT UNIQUE NOT NULL,
                    \\  email TEXT UNIQUE NOT NULL,
                    \\  password_hash TEXT NOT NULL,
                    \\  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                    \\  updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
                    \\);
                    \\CREATE INDEX IF NOT EXISTS idx_users_username ON {s}(username);
                    \\CREATE INDEX IF NOT EXISTS idx_users_email ON {s}(email);
                , .{ self.config.user_table_name, self.config.user_table_name, self.config.user_table_name });
                defer allocator.free(create_table_sql);

                self.config.orm.db.execute(create_table_sql) catch |err| {
                    return err;
                };
            },
            .postgresql => {
                const create_table_sql = try std.fmt.allocPrint(allocator,
                    \\CREATE TABLE IF NOT EXISTS {s} (
                    \\  id SERIAL PRIMARY KEY,
                    \\  username VARCHAR(255) UNIQUE NOT NULL,
                    \\  email VARCHAR(255) UNIQUE NOT NULL,
                    \\  password_hash TEXT NOT NULL,
                    \\  created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM NOW())::BIGINT,
                    \\  updated_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM NOW())::BIGINT
                    \\)
                , .{self.config.user_table_name});
                defer allocator.free(create_table_sql);

                self.config.orm.db.execute(create_table_sql) catch |err| {
                    return err;
                };

                const idx1 = try std.fmt.allocPrint(allocator, "CREATE INDEX IF NOT EXISTS idx_users_username ON {s}(username)", .{self.config.user_table_name});
                defer allocator.free(idx1);
                self.config.orm.db.execute(idx1) catch {};

                const idx2 = try std.fmt.allocPrint(allocator, "CREATE INDEX IF NOT EXISTS idx_users_email ON {s}(email)", .{self.config.user_table_name});
                defer allocator.free(idx2);
                self.config.orm.db.execute(idx2) catch {};
            },
        }
    }

    fn authMiddleware(req: *Request) middleware.MiddlewareResult {
        const auth_header = req.header("Authorization") orelse {
            return .proceed;
        };

        if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
            return .proceed; // Invalid format, but allow through
        }

        const token_slice = auth_header["Bearer ".len..];
        if (token_slice.len == 0) {
            return .proceed;
        }

        const token = req.arena.allocator().dupe(u8, token_slice) catch {
            return .proceed;
        };

        req.context.put("auth_token", token) catch {
            return .proceed;
        };

        return .proceed;
    }

    pub fn handleRegister(req: *Request) Response {
        const self = Self.getInstance(req) orelse {
            return Response.errorResponse("Authentication valve not initialized", 500);
        };

        const allocator = req.arena.allocator();

        const body = req.body();
        const input = json_module.Json.deserialize(UserInput, body, allocator) catch {
            return Response.errorResponse("Invalid request body", 400);
        };

        const username = input.username orelse {
            return Response.errorResponse("Username is required", 400);
        };
        const email = input.email orelse {
            return Response.errorResponse("Email is required", 400);
        };
        const pwd = input.password orelse {
            return Response.errorResponse("Password is required", 400);
        };

        if (username.len < 3 or username.len > 50) {
            return Response.errorResponse("Username must be between 3 and 50 characters", 400);
        }

        if (pwd.len < 6) {
            return Response.errorResponse("Password must be at least 6 characters", 400);
        }

        const password_hash = password.hash(pwd, self.config.orm.allocator) catch {
            return Response.serverError("Failed to hash password");
        };
        defer self.config.orm.allocator.free(password_hash);

        const check_sql = std.fmt.allocPrint(
            allocator,
            "SELECT * FROM {s}",
            .{self.config.user_table_name},
        ) catch {
            return Response.serverError("Failed to allocate memory");
        };
        defer allocator.free(check_sql);

        var check_result = self.config.orm.db.query(check_sql) catch {
            return Response.serverError("Failed to query users");
        };
        defer check_result.deinit();

        var all_users = check_result.toArrayList(User) catch {
            return Response.serverError("Failed to parse user data");
        };
        defer {
            for (all_users.items) |user| {
                self.config.orm.allocator.free(user.username);
                self.config.orm.allocator.free(user.email);
                self.config.orm.allocator.free(user.password_hash);
            }
            all_users.deinit(self.config.orm.allocator);
        }

        for (all_users.items) |user| {
            if (std.mem.eql(u8, user.username, username)) {
                return Response.errorResponse("Username already exists", 409);
            }
            if (std.mem.eql(u8, user.email, email)) {
                return Response.errorResponse("Email already exists", 409);
            }
        }

        const username_copy = self.config.orm.allocator.dupe(u8, username) catch {
            return Response.serverError("Failed to allocate username");
        };
        errdefer self.config.orm.allocator.free(username_copy);

        const email_copy = self.config.orm.allocator.dupe(u8, email) catch {
            self.config.orm.allocator.free(username_copy);
            return Response.serverError("Failed to allocate email");
        };
        errdefer self.config.orm.allocator.free(email_copy);

        const now = std.time.timestamp();

        const escaped_username = SqlEscape.escapeString(allocator, username_copy) catch {
            self.config.orm.allocator.free(username_copy);
            self.config.orm.allocator.free(email_copy);
            return Response.serverError("Failed to escape username");
        };
        defer allocator.free(escaped_username);
        const escaped_email = SqlEscape.escapeString(allocator, email_copy) catch {
            self.config.orm.allocator.free(username_copy);
            self.config.orm.allocator.free(email_copy);
            return Response.serverError("Failed to escape email");
        };
        defer allocator.free(escaped_email);
        const escaped_password_hash = SqlEscape.escapeString(allocator, password_hash) catch {
            self.config.orm.allocator.free(username_copy);
            self.config.orm.allocator.free(email_copy);
            return Response.serverError("Failed to escape password hash");
        };
        defer allocator.free(escaped_password_hash);

        const insert_sql = std.fmt.allocPrint(
            allocator,
            "INSERT INTO {s} (username, email, password_hash, created_at, updated_at) VALUES ('{s}', '{s}', '{s}', {d}, {d})",
            .{ self.config.user_table_name, escaped_username, escaped_email, escaped_password_hash, now, now },
        ) catch {
            self.config.orm.allocator.free(username_copy);
            self.config.orm.allocator.free(email_copy);
            return Response.serverError("Failed to allocate memory");
        };
        defer allocator.free(insert_sql);

        self.config.orm.db.execute(insert_sql) catch {
            self.config.orm.allocator.free(username_copy);
            self.config.orm.allocator.free(email_copy);
            return Response.errorResponse("Failed to create user", 500);
        };

        _ = self.config.orm.db.lastInsertRowId() catch {
            self.config.orm.allocator.free(username_copy);
            self.config.orm.allocator.free(email_copy);
            return Response.errorResponse("Failed to get created user ID", 500);
        };

        return Response.created();
    }

    pub fn handleLogin(req: *Request) Response {
        const self = Self.getInstance(req) orelse {
            return Response.errorResponse("Authentication valve not initialized", 500);
        };

        const allocator = req.arena.allocator();

        const body = req.body();
        const input = json_module.Json.deserialize(UserInput, body, allocator) catch {
            return Response.errorResponse("Invalid request body", 400);
        };

        const username_or_email = input.username orelse input.email orelse {
            return Response.errorResponse("Username or email is required", 400);
        };
        const pwd = input.password orelse {
            return Response.errorResponse("Password is required", 400);
        };

        const find_sql = std.fmt.allocPrint(
            allocator,
            "SELECT * FROM {s}",
            .{self.config.user_table_name},
        ) catch {
            return Response.serverError("Failed to allocate memory");
        };
        defer allocator.free(find_sql);

        var find_result = self.config.orm.db.query(find_sql) catch {
            return Response.serverError("Failed to query users");
        };
        defer find_result.deinit();

        var all_users = find_result.toArrayList(User) catch {
            return Response.serverError("Failed to parse user data");
        };
        defer {
            for (all_users.items) |user| {
                self.config.orm.allocator.free(user.username);
                self.config.orm.allocator.free(user.email);
                self.config.orm.allocator.free(user.password_hash);
            }
            all_users.deinit(self.config.orm.allocator);
        }

        var found_user: ?User = null;
        var found_user_index: ?usize = null;
        for (all_users.items, 0..) |user, i| {
            if (std.mem.eql(u8, user.username, username_or_email) or std.mem.eql(u8, user.email, username_or_email)) {
                found_user = user;
                found_user_index = i;
                break;
            }
        }

        const user = found_user orelse {
            return Response.errorResponse("Invalid username or password", 401);
        };

        const user_id = user.id;
        const user_username = allocator.dupe(u8, user.username) catch {
            return Response.serverError("Failed to allocate username");
        };
        defer allocator.free(user_username);
        const user_email = allocator.dupe(u8, user.email) catch {
            return Response.serverError("Failed to allocate email");
        };
        defer allocator.free(user_email);
        const user_password_hash = allocator.dupe(u8, user.password_hash) catch {
            return Response.serverError("Failed to allocate password hash");
        };
        defer allocator.free(user_password_hash);

        const password_valid = password.verify(pwd, user_password_hash);
        if (!password_valid) {
            return Response.errorResponse("Invalid username or password", 401);
        }

        const now = std.time.timestamp();
        const claims = Claims{
            .user_id = user_id,
            .username = user_username,
            .exp = now + self.config.token_expiry_seconds,
        };

        const token = jwt.encode(claims, self.config.secret_key, allocator) catch {
            return Response.serverError("Failed to generate token");
        };
        defer allocator.free(token);

        const persistent_token = std.heap.page_allocator.dupe(u8, token) catch {
            return Response.serverError("Failed to allocate token");
        };

        const persistent_username = std.heap.page_allocator.dupe(u8, user_username) catch {
            std.heap.page_allocator.free(persistent_token);
            return Response.serverError("Failed to allocate username");
        };
        const persistent_email = std.heap.page_allocator.dupe(u8, user_email) catch {
            std.heap.page_allocator.free(persistent_token);
            std.heap.page_allocator.free(persistent_username);
            return Response.serverError("Failed to allocate email");
        };

        const login_response = LoginResponse{
            .token = persistent_token,
            .expires_in = self.config.token_expiry_seconds,
            .user = .{
                .id = user_id,
                .username = persistent_username,
                .email = persistent_email,
            },
        };

        const json_str = json_module.Json.serialize(LoginResponse, login_response, allocator) catch {
            std.heap.page_allocator.free(persistent_token);
            std.heap.page_allocator.free(persistent_username);
            std.heap.page_allocator.free(persistent_email);
            return Response.serverError("Failed to serialize response");
        };
        defer allocator.free(json_str);

        const persistent_json = std.heap.page_allocator.dupe(u8, json_str) catch {
            std.heap.page_allocator.free(persistent_token);
            std.heap.page_allocator.free(persistent_username);
            std.heap.page_allocator.free(persistent_email);
            return Response.serverError("Failed to allocate response");
        };

        return Response.json(persistent_json);
    }

    pub fn handleLogout(req: *Request) Response {
        _ = req;
        return Response.ok();
    }

    pub fn handleGetMe(req: *Request) Response {
        const self = Self.getInstance(req) orelse {
            return Response.errorResponse("Authentication valve not initialized", 500);
        };

        const allocator = req.arena.allocator();

        const token = req.context.get("auth_token") orelse {
            return Response.errorResponse("Unauthorized", 401);
        };

        const claims = jwt.decode(token, self.config.secret_key, allocator) catch {
            return Response.errorResponse("Invalid or expired token", 401);
        };
        defer allocator.free(claims.username);

        const sql = std.fmt.allocPrint(
            allocator,
            "SELECT * FROM {s} WHERE id = {d}",
            .{ self.config.user_table_name, claims.user_id },
        ) catch {
            return Response.serverError("Failed to allocate SQL");
        };
        defer allocator.free(sql);

        var result = self.config.orm.db.query(sql) catch {
            return Response.serverError("Failed to query user");
        };
        defer result.deinit();

        var users = result.toArrayList(User) catch {
            return Response.serverError("Failed to parse user data");
        };
        defer {
            for (users.items) |u| {
                self.config.orm.allocator.free(u.username);
                self.config.orm.allocator.free(u.email);
                self.config.orm.allocator.free(u.password_hash);
            }
            users.deinit(self.config.orm.allocator);
        }

        const user = if (users.items.len > 0) users.items[0] else {
            return Response.errorResponse("User not found", 404);
        };

        const user_username = std.heap.page_allocator.dupe(u8, user.username) catch {
            return Response.serverError("Failed to allocate username");
        };
        const user_email = std.heap.page_allocator.dupe(u8, user.email) catch {
            std.heap.page_allocator.free(user_username);
            return Response.serverError("Failed to allocate email");
        };

        const user_response = struct {
            id: i64,
            username: []const u8,
            email: []const u8,
            created_at: i64,
        }{
            .id = user.id,
            .username = user_username,
            .email = user_email,
            .created_at = user.created_at,
        };

        return Response.jsonFrom(@TypeOf(user_response), user_response, std.heap.page_allocator);
    }

    pub fn getCurrentUser(req: *Request) !?User {
        const self = Self.getInstance(req) orelse {
            return null;
        };

        const token = req.context.get("auth_token") orelse {
            return null;
        };

        const allocator = req.arena.allocator();

        const claims = jwt.decode(token, self.config.secret_key, allocator) catch {
            return null;
        };
        defer allocator.free(claims.username);

        const sql = try std.fmt.allocPrint(
            allocator,
            "SELECT * FROM {s} WHERE id = {d}",
            .{ self.config.user_table_name, claims.user_id },
        );
        defer allocator.free(sql);

        var result = self.config.orm.db.query(sql) catch {
            return null;
        };
        defer result.deinit();

        var users = result.toArrayList(User) catch {
            return null;
        };
        defer {
            for (users.items) |user| {
                self.config.orm.allocator.free(user.username);
                self.config.orm.allocator.free(user.email);
                self.config.orm.allocator.free(user.password_hash);
            }
            users.deinit(self.config.orm.allocator);
        }

        if (users.items.len > 0) {
            const user = users.items[0];
            return User{
                .id = user.id,
                .username = try self.config.orm.allocator.dupe(u8, user.username),
                .email = try self.config.orm.allocator.dupe(u8, user.email),
                .password_hash = try self.config.orm.allocator.dupe(u8, user.password_hash),
                .created_at = user.created_at,
                .updated_at = user.updated_at,
            };
        }

        return null;
    }

    pub fn requireAuth(req: *Request) !User {
        const user_opt = try getCurrentUser(req);
        const user = user_opt orelse {
            return error.Unauthorized;
        };
        return user;
    }

    fn getInstance(_: *Request) ?*Self {
        registry_mutex.lock();
        defer registry_mutex.unlock();
        return global_registry;
    }
};
