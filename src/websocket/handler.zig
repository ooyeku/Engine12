const std = @import("std");
const ws = @import("websocket");
const connection = @import("connection.zig");
const WebSocketConnection = connection.WebSocketConnection;
const websocket_mod = @import("module.zig");

pub const WebSocketHandler = *const fn (*WebSocketConnection) void;

pub fn createAppData(
    comptime HandlerFn: type,
) type {
    return struct {
        handler: HandlerFn,
        allocator: std.mem.Allocator,
        path: []const u8,
    };
}

pub fn createEngine12Handler(
    comptime HandlerFn: type,
) type {
    const AppData = createAppData(HandlerFn);

    return struct {
        const Self = @This();

        engine12_conn: ?*WebSocketConnection = null,
        conn_id: []const u8 = undefined,
        path: []const u8 = undefined,
        allocator: std.mem.Allocator = undefined,
        handler: HandlerFn = undefined,

        pub fn init(
            h: *ws.Handshake,
            conn: *ws.Conn,
            app: *AppData,
        ) !Self {
            const timestamp = std.time.milliTimestamp();
            const random = @as(u64, @intCast(std.time.nanoTimestamp())) % 1000000;
            const conn_id = try std.fmt.allocPrint(app.allocator, "ws_{d}_{d}", .{ timestamp, random });

            const path = app.path;

            const engine12_conn = try app.allocator.create(WebSocketConnection);
            errdefer app.allocator.destroy(engine12_conn);

            engine12_conn.* = WebSocketConnection{
                .conn = conn,
                .id = conn_id,
                .path = try app.allocator.dupe(u8, path),
                .headers = std.StringHashMap([]const u8).init(app.allocator),
                .is_open = std.atomic.Value(bool).init(true),
                .context = std.StringHashMap([]const u8).init(app.allocator),
                .allocator = app.allocator,
                .cleaned_up = std.atomic.Value(bool).init(false),
            };

            if (@hasField(@TypeOf(h.*), "headers")) {
                if (@TypeOf(h.headers) != @TypeOf(null)) {
                }
            }

            return Self{
                .engine12_conn = engine12_conn,
                .conn_id = conn_id,
                .path = try app.allocator.dupe(u8, path),
                .allocator = app.allocator,
                .handler = app.handler,
            };
        }

        pub fn afterInit(self: *Self) !void {
            if (self.engine12_conn) |conn| {
                self.handler(conn);
            }
        }

        pub fn clientMessage(self: *Self, data: []u8) !void {
            _ = self;
            _ = data;
        }

        pub fn close(self: *Self) void {
            if (self.engine12_conn) |conn| {
                conn.is_open.store(false, .monotonic);

                var room_ptr: ?*websocket_mod.room.WebSocketRoom = null;
                if (conn.get("hot_reload_room")) |room_ptr_str| {
                    const room_ptr_str_copy = self.allocator.dupe(u8, room_ptr_str) catch null;
                    defer if (room_ptr_str_copy) |str| self.allocator.free(str);

                    if (room_ptr_str_copy) |str| {
                        const room_ptr_int = std.fmt.parseInt(usize, str, 10) catch 0;
                        if (room_ptr_int != 0) {
                            room_ptr = @as(*websocket_mod.room.WebSocketRoom, @ptrFromInt(room_ptr_int));
                        }
                    }
                }

                conn.cleanup();

                if (room_ptr) |room| {
                    room.leave(conn);
                }

                self.allocator.destroy(conn);
            }

            self.allocator.free(self.path);
        }
    };
}
