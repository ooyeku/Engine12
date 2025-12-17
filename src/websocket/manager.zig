const std = @import("std");
const ws = @import("websocket");
const vigil = @import("vigil");
const handler = @import("handler.zig");
const connection = @import("connection.zig");

pub const WebSocketServerEntry = struct {
    path: []const u8,
    port: u16,
    handler: handler.WebSocketHandler,
};

pub const WebSocketManager = struct {
    servers: std.ArrayListUnmanaged(WebSocketServerEntry),

    connections: std.StringHashMap(*connection.WebSocketConnection),
    connections_mutex: std.Thread.Mutex = .{},

    allocator: std.mem.Allocator,

    base_port: u16 = 9000,

    next_port: u16 = 9000,

    built_supervisor: ?vigil.Supervisor = null,

    pub fn init(allocator: std.mem.Allocator) !WebSocketManager {
        return WebSocketManager{
            .servers = .{},
            .connections = std.StringHashMap(*connection.WebSocketConnection).init(allocator),
            .allocator = allocator,
            .base_port = 9000,
            .next_port = 9000,
            .built_supervisor = null,
        };
    }

    pub fn registerServer(
        self: *WebSocketManager,
        path: []const u8,
        handler_fn: handler.WebSocketHandler,
    ) !void {
        const port = self.next_port;
        self.next_port += 1;

        try self.servers.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .port = port,
            .handler = handler_fn,
        });
    }

    pub fn start(self: *WebSocketManager) !void {
        var supervisor = vigil.supervisor(self.allocator);

        for (self.servers.items) |entry| {
            const HandlerType = handler.createEngine12Handler(@TypeOf(entry.handler));

            const AppData = handler.createAppData(@TypeOf(entry.handler));
            const app_data = AppData{
                .handler = entry.handler,
                .allocator = self.allocator,
                .path = entry.path,
            };

            const server = try ws.Server(HandlerType).init(self.allocator, .{
                .port = entry.port,
                .address = "127.0.0.1",
                .handshake = .{
                    .timeout = 3,
                    .max_size = 1024,
                    .max_headers = 32,
                },
            });

            const ServerThread = struct {
                server_ptr: *ws.Server(HandlerType),
                app_data: AppData,

                fn run(ctx: @This()) void {
                    var mutable_app_data = ctx.app_data;
                    ctx.server_ptr.listen(&mutable_app_data) catch |err| {
                        std.debug.print("[WebSocket] Server error: {}\n", .{err});
                    };
                }
            };

            const server_ptr = try self.allocator.create(ws.Server(HandlerType));
            server_ptr.* = server;

            const server_thread = ServerThread{
                .server_ptr = server_ptr,
                .app_data = app_data,
            };

            var thread = try std.Thread.spawn(.{}, ServerThread.run, .{server_thread});
            thread.detach();

            const server_name = try std.fmt.allocPrint(self.allocator, "ws_server_{s}", .{entry.path});
            defer self.allocator.free(server_name);

            const noop_task = struct {
                fn task() void {
                }
            }.task;

            _ = supervisor.child(server_name, noop_task) catch |err| {
                std.debug.print("[ERROR] Failed to register WebSocket server '{s}': {any}\n", .{ server_name, err });
            };
        }

        self.built_supervisor = supervisor.build();
        try self.built_supervisor.?.start();
    }

    pub fn stop(self: *WebSocketManager) void {
        if (self.built_supervisor) |*sup| {
            sup.stop();
            sup.deinit();
            self.built_supervisor = null;
        }

        for (self.servers.items) |entry| {
            self.allocator.free(entry.path);
        }
        self.servers.deinit(self.allocator);

        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        var it = self.connections.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.cleanup();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit();
    }

    pub fn registerConnection(
        self: *WebSocketManager,
        conn_id: []const u8,
        conn: *connection.WebSocketConnection,
    ) !void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        try self.connections.put(conn_id, conn);
    }

    pub fn removeConnection(self: *WebSocketManager, conn_id: []const u8) void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        _ = self.connections.remove(conn_id);
    }

    pub fn getConnection(
        self: *WebSocketManager,
        conn_id: []const u8,
    ) ?*connection.WebSocketConnection {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();

        return self.connections.get(conn_id);
    }
};
