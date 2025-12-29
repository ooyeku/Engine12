const std = @import("std");
const types = @import("types.zig");

pub const MessageWriter = struct {
    stream: std.net.Stream,
    buffer: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream) MessageWriter {
        return MessageWriter{
            .stream = stream,
            .buffer = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MessageWriter) void {
        self.buffer.deinit(self.allocator);
    }








    fn writeInt32(self: *MessageWriter, val: i32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(i32, &buf, val, .big);
        try self.buffer.appendSlice(self.allocator, &buf);
    }

    fn writeInt16(self: *MessageWriter, val: i16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(i16, &buf, val, .big);
        try self.buffer.appendSlice(self.allocator, &buf);
    }

    fn writeString(self: *MessageWriter, str: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, str);
        try self.buffer.append(self.allocator, 0);
    }



    pub fn writeStartupMessage(self: *MessageWriter, params: std.StringHashMap([]const u8)) !void {
        self.buffer.clearRetainingCapacity();


        try self.buffer.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });


        try self.writeInt32(196608);

        var it = params.iterator();
        while (it.next()) |entry| {
            try self.writeString(entry.key_ptr.*);
            try self.writeString(entry.value_ptr.*);
        }
        try self.buffer.append(self.allocator, 0);


        const len = @as(i32, @intCast(self.buffer.items.len));
        std.mem.writeInt(i32, self.buffer.items[0..4], len, .big);

        try self.stream.writeAll(self.buffer.items);
    }

    pub fn writePassword(self: *MessageWriter, password: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.append(self.allocator, @intFromEnum(types.Frontend.PasswordMessage));


        try self.buffer.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });

        try self.writeString(password);


        const len = @as(i32, @intCast(self.buffer.items.len - 1));
        std.mem.writeInt(i32, self.buffer.items[1..5], len, .big);

        try self.stream.writeAll(self.buffer.items);
    }

    pub fn writeQuery(self: *MessageWriter, sql: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.append(self.allocator, @intFromEnum(types.Frontend.Query));


        try self.buffer.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });

        try self.writeString(sql);


        const len = @as(i32, @intCast(self.buffer.items.len - 1));
        std.mem.writeInt(i32, self.buffer.items[1..5], len, .big);

        try self.stream.writeAll(self.buffer.items);
    }

    pub fn writeTerminate(self: *MessageWriter) !void {
        const msg = [_]u8{
            @intFromEnum(types.Frontend.Terminate),
            0,
            0,
            0,
            4,
        };
        try self.stream.writeAll(&msg);
    }



    pub fn writeParse(self: *MessageWriter, name: []const u8, sql: []const u8, param_oids: []const i32) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.append(self.allocator, @intFromEnum(types.Frontend.Parse));
        try self.buffer.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });

        try self.writeString(name);
        try self.writeString(sql);

        try self.writeInt16(@intCast(param_oids.len));
        for (param_oids) |oid| {
            try self.writeInt32(oid);
        }

        const len = @as(i32, @intCast(self.buffer.items.len - 1));
        std.mem.writeInt(i32, self.buffer.items[1..5], len, .big);
        try self.stream.writeAll(self.buffer.items);
    }

    pub fn writeBind(
        self: *MessageWriter,
        portal: []const u8,
        statement: []const u8,
        param_formats: []const i16,
        params: anytype,
        result_formats: []const i16,
    ) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.append(self.allocator, @intFromEnum(types.Frontend.Bind));
        try self.buffer.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });

        try self.writeString(portal);
        try self.writeString(statement);


        try self.writeInt16(@intCast(param_formats.len));
        for (param_formats) |fmt| {
            try self.writeInt16(fmt);
        }


        try self.writeInt16(@intCast(params.len));
        for (params) |info| {

            if (info) |p| {
                try self.writeInt32(@intCast(p.len));
                try self.buffer.appendSlice(self.allocator, p);
            } else {
                try self.writeInt32(-1);
            }
        }


        try self.writeInt16(@intCast(result_formats.len));
        for (result_formats) |fmt| {
            try self.writeInt16(fmt);
        }

        const len = @as(i32, @intCast(self.buffer.items.len - 1));
        std.mem.writeInt(i32, self.buffer.items[1..5], len, .big);
        try self.stream.writeAll(self.buffer.items);
    }

    pub fn writeDescribe(self: *MessageWriter, is_portal: bool, name: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.append(self.allocator, @intFromEnum(types.Frontend.Describe));
        try self.buffer.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });

        try self.buffer.append(self.allocator, if (is_portal) 'P' else 'S');
        try self.writeString(name);

        const len = @as(i32, @intCast(self.buffer.items.len - 1));
        std.mem.writeInt(i32, self.buffer.items[1..5], len, .big);
        try self.stream.writeAll(self.buffer.items);
    }

    pub fn writeExecute(self: *MessageWriter, portal: []const u8, max_rows: i32) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.append(self.allocator, @intFromEnum(types.Frontend.Execute));
        try self.buffer.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });

        try self.writeString(portal);
        try self.writeInt32(max_rows);

        const len = @as(i32, @intCast(self.buffer.items.len - 1));
        std.mem.writeInt(i32, self.buffer.items[1..5], len, .big);
        try self.stream.writeAll(self.buffer.items);
    }

    pub fn writeSync(self: *MessageWriter) !void {
        const msg = [_]u8{ @intFromEnum(types.Frontend.Sync), 0, 0, 0, 4 };
        try self.stream.writeAll(&msg);
    }
};
