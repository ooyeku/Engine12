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

    /// Begin a new message. Clears buffer and reserves space for Type (optional) and Length.
    /// If type_byte is null, it's a StartupMessage (no type byte).
    /// If type_byte is set, it writes the type byte immediately to the stream or buffer?
    /// Actually specific message methods are better.

    // --- Primitives ---

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

    // --- Commands ---

    pub fn writeStartupMessage(self: *MessageWriter, params: std.StringHashMap([]const u8)) !void {
        self.buffer.clearRetainingCapacity();

        // Reserve 4 bytes for length
        try self.buffer.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });

        // Protocol Version 3.0 (196608)
        try self.writeInt32(196608);

        var it = params.iterator();
        while (it.next()) |entry| {
            try self.writeString(entry.key_ptr.*);
            try self.writeString(entry.value_ptr.*);
        }
        try self.buffer.append(self.allocator, 0); // Null terminator for params list

        // Update length
        const len = @as(i32, @intCast(self.buffer.items.len));
        std.mem.writeInt(i32, self.buffer.items[0..4], len, .big);

        try self.stream.writeAll(self.buffer.items);
    }

    pub fn writePassword(self: *MessageWriter, password: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.append(self.allocator, @intFromEnum(types.Frontend.PasswordMessage));

        // Reserve length
        try self.buffer.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });

        try self.writeString(password);

        // Update length
        const len = @as(i32, @intCast(self.buffer.items.len - 1)); // -1 for type byte
        std.mem.writeInt(i32, self.buffer.items[1..5], len, .big);

        try self.stream.writeAll(self.buffer.items);
    }

    pub fn writeQuery(self: *MessageWriter, sql: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.append(self.allocator, @intFromEnum(types.Frontend.Query));

        // Reserve length
        try self.buffer.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });

        try self.writeString(sql);

        // Update length
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
            4, // Length 4 (only length field itself)
        };
        try self.stream.writeAll(&msg);
    }

    // --- Extended Query Protocol ---

    pub fn writeParse(self: *MessageWriter, name: []const u8, sql: []const u8, param_oids: []const i32) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.append(self.allocator, @intFromEnum(types.Frontend.Parse));
        try self.buffer.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 }); // Len placeholder

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
        params: anytype, // Expecting a slice of param values (bytes)
        result_formats: []const i16,
    ) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.append(self.allocator, @intFromEnum(types.Frontend.Bind));
        try self.buffer.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });

        try self.writeString(portal);
        try self.writeString(statement);

        // Param formats
        try self.writeInt16(@intCast(param_formats.len));
        for (param_formats) |fmt| {
            try self.writeInt16(fmt);
        }

        // Params
        try self.writeInt16(@intCast(params.len));
        for (params) |info| {
            // info is expected to be ?[]const u8
            if (info) |p| {
                try self.writeInt32(@intCast(p.len));
                try self.buffer.appendSlice(self.allocator, p);
            } else {
                try self.writeInt32(-1); // NULL
            }
        }

        // Result formats
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
