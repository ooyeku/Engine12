const std = @import("std");
const net = std.net;
const types = @import("types.zig");
const Reader = @import("reader.zig").MessageReader;
const Writer = @import("writer.zig").MessageWriter;
const auth = @import("auth.zig");
const Row = @import("row.zig").Row;

pub const ResultSet = struct {
    rows: std.ArrayListUnmanaged(Row),
    column_names: [][]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ResultSet) void {
        for (self.rows.items) |*r| r.deinit();
        self.rows.deinit(self.allocator);
        for (self.column_names) |n| self.allocator.free(n);
        self.allocator.free(self.column_names);
    }
};

/// A PostgreSQL database connection handling the frontend/backend protocol.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    reader: Reader,
    writer: Writer,
    in_transaction: bool = false,

    /// Establishes a new connection to a PostgreSQL server.
    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16, username: []const u8, database: []const u8, password: ?[]const u8) !Connection {
        const stream = try net.tcpConnectToHost(allocator, host, port);
        errdefer stream.close();

        var conn = Connection{
            .allocator = allocator,
            .stream = stream,
            .reader = Reader.init(stream),
            .writer = Writer.init(allocator, stream),
        };

        try auth.performHandshake(allocator, &conn.reader, &conn.writer, username, database, password);

        return conn;
    }

    /// Closes the connection gracefully.
    pub fn close(self: *Connection) void {
        self.writer.writeTerminate() catch {};
        self.stream.close();
        self.writer.deinit();
    }

    /// Executes a SQL command that does not return rows.
    pub fn execute(self: *Connection, sql: []const u8) !void {
        try self.writer.writeQuery(sql);

        while (true) {
            const msg_type_byte = try self.reader.readByte();
            const msg_len = try self.reader.readInt32();
            const payload_len = @as(usize, @intCast(msg_len - 4));

            const msg_type = @as(types.Backend, @enumFromInt(msg_type_byte));

            switch (msg_type) {
                .CommandComplete => {
                    try self.reader.skip(payload_len);
                },
                .ReadyForQuery => {
                    const status = try self.reader.readByte();
                    self.in_transaction = (status == @intFromEnum(types.TransactionStatus.InTransaction));
                    return;
                },
                .ErrorResponse => {
                    try self.reader.skip(payload_len);
                    return types.ProtocolError.QueryError;
                },
                .DataRow => {
                    try self.reader.skip(payload_len);
                },
                .RowDescription => {
                    try self.reader.skip(payload_len);
                },
                .EmptyQueryResponse => {},
                .NoticeResponse, .NotificationResponse, .ParameterStatus => {
                    try self.reader.skip(payload_len);
                },
                else => {
                    try self.reader.skip(payload_len);
                },
            }
        }
    }

    fn readRowDescription(self: *Connection) ![][]const u8 {
        const num_fields = try self.reader.readInt16();
        var names = try self.allocator.alloc([]const u8, @intCast(num_fields));
        errdefer self.allocator.free(names);

        for (0..@intCast(num_fields)) |i| {
            const name = try self.reader.readString();
            names[i] = try self.allocator.dupe(u8, name);

            _ = try self.reader.readInt32();
            _ = try self.reader.readInt16();
            _ = try self.reader.readInt32();
            _ = try self.reader.readInt16();
            _ = try self.reader.readInt32();
            _ = try self.reader.readInt16();
        }

        return names;
    }

    /// Executes a SQL query and returns the full result set.
    pub fn query(self: *Connection, sql: []const u8) !ResultSet {
        try self.writer.writeQuery(sql);

        var rows = std.ArrayListUnmanaged(Row){};
        var col_names: [][]const u8 = &.{};

        errdefer {
            for (rows.items) |*r| r.deinit();
            rows.deinit(self.allocator);
            for (col_names) |n| self.allocator.free(n);
            self.allocator.free(col_names);
        }

        while (true) {
            const msg_type_byte = try self.reader.readByte();
            const msg_len = try self.reader.readInt32();
            const payload_len = @as(usize, @intCast(msg_len - 4));

            const msg_type = @as(types.Backend, @enumFromInt(msg_type_byte));

            switch (msg_type) {
                .RowDescription => {
                    col_names = try self.readRowDescription();
                },
                .DataRow => {
                    const idx = try self.allocator.alloc(u8, payload_len);
                    errdefer self.allocator.free(idx);

                    try self.reader.readBytes(idx);

                    const row = try Row.init(self.allocator, idx);
                    try rows.append(self.allocator, row);
                },
                .CommandComplete => {
                    try self.reader.skip(payload_len);
                },
                .ReadyForQuery => {
                    const status = try self.reader.readByte();
                    self.in_transaction = (status == @intFromEnum(types.TransactionStatus.InTransaction));
                    return ResultSet{
                        .rows = rows,
                        .column_names = col_names,
                        .allocator = self.allocator,
                    };
                },
                .ErrorResponse => {
                    try self.reader.skip(payload_len);
                    return types.ProtocolError.QueryError;
                },
                .EmptyQueryResponse => {},
                .NoticeResponse, .NotificationResponse, .ParameterStatus => {
                    try self.reader.skip(payload_len);
                },
                else => {
                    try self.reader.skip(payload_len);
                },
            }
        }
    }

    pub fn prepare(self: *Connection, name: []const u8, sql: []const u8) !void {
        try self.writer.writeParse(name, sql, &.{});
        try self.writer.writeSync();

        while (true) {
            const msg_type_byte = try self.reader.readByte();
            const msg_len = try self.reader.readInt32();
            const payload_len = @as(usize, @intCast(msg_len - 4));
            const msg_type = @as(types.Backend, @enumFromInt(msg_type_byte));

            switch (msg_type) {
                .ParseComplete => {},
                .ReadyForQuery => {
                    const status = try self.reader.readByte();
                    self.in_transaction = (status == @intFromEnum(types.TransactionStatus.InTransaction));
                    return;
                },
                .ErrorResponse => {
                    try self.reader.skip(payload_len);
                    return types.ProtocolError.QueryError;
                },
                else => try self.reader.skip(payload_len),
            }
        }
    }

    pub fn executeParams(self: *Connection, sql: []const u8, params: *const @import("../params.zig").ParamList) !void {
        try self.writer.writeParse("", sql, &.{});

        var encoded_params = std.ArrayListUnmanaged(?[]const u8){};
        defer encoded_params.deinit(self.allocator);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        for (params.items.items) |param| {
            switch (param) {
                .null => try encoded_params.append(self.allocator, null),
                .int64 => |v| {
                    const s = try std.fmt.allocPrint(aa, "{d}", .{v});
                    try encoded_params.append(self.allocator, s);
                },
                .float64 => |v| {
                    const s = try std.fmt.allocPrint(aa, "{d}", .{v});
                    try encoded_params.append(self.allocator, s);
                },
                .text => |s| try encoded_params.append(self.allocator, s),
                .blob => |b| {
                    try encoded_params.append(self.allocator, b);
                },
            }
        }

        try self.writer.writeBind("", "", &[_]i16{}, encoded_params.items, &[_]i16{});

        try self.writer.writeDescribe(true, "");

        try self.writer.writeExecute("", 0);

        try self.writer.writeSync();

        while (true) {
            const msg_type_byte = try self.reader.readByte();
            const msg_len = try self.reader.readInt32();
            const payload_len = @as(usize, @intCast(msg_len - 4));

            const msg_type = @as(types.Backend, @enumFromInt(msg_type_byte));

            switch (msg_type) {
                .CommandComplete => try self.reader.skip(payload_len),
                .ReadyForQuery => {
                    const status = try self.reader.readByte();
                    self.in_transaction = (status == @intFromEnum(types.TransactionStatus.InTransaction));
                    return;
                },
                .ErrorResponse => {
                    try self.reader.skip(payload_len);
                    return types.ProtocolError.QueryError;
                },
                .ParseComplete, .BindComplete => {},
                .DataRow => try self.reader.skip(payload_len),
                .RowDescription => try self.reader.skip(payload_len),
                .PortalSuspended => try self.reader.skip(payload_len),
                .NoticeResponse, .NotificationResponse, .ParameterStatus => try self.reader.skip(payload_len),
                else => try self.reader.skip(payload_len),
            }
        }
    }

    pub fn queryParams(self: *Connection, sql: []const u8, params: *const @import("../params.zig").ParamList) !ResultSet {
        try self.writer.writeParse("", sql, &.{});

        var encoded_params = std.ArrayListUnmanaged(?[]const u8){};
        defer encoded_params.deinit(self.allocator);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        for (params.items.items) |param| {
            switch (param) {
                .null => try encoded_params.append(self.allocator, null),
                .int64 => |v| try encoded_params.append(self.allocator, try std.fmt.allocPrint(aa, "{d}", .{v})),
                .float64 => |v| try encoded_params.append(self.allocator, try std.fmt.allocPrint(aa, "{d}", .{v})),
                .text => |s| try encoded_params.append(self.allocator, s),
                .blob => |b| try encoded_params.append(self.allocator, b),
            }
        }

        try self.writer.writeBind("", "", &[_]i16{}, encoded_params.items, &[_]i16{});

        try self.writer.writeDescribe(true, "");

        try self.writer.writeExecute("", 0);

        try self.writer.writeSync();

        var rows = std.ArrayListUnmanaged(Row){};
        var col_names: [][]const u8 = &.{};
        errdefer {
            for (rows.items) |*r| r.deinit();
            rows.deinit(self.allocator);
            for (col_names) |n| self.allocator.free(n);
            self.allocator.free(col_names);
        }

        while (true) {
            const msg_type_byte = try self.reader.readByte();
            const msg_len = try self.reader.readInt32();
            const payload_len = @as(usize, @intCast(msg_len - 4));

            const msg_type = @as(types.Backend, @enumFromInt(msg_type_byte));

            switch (msg_type) {
                .RowDescription => {
                    col_names = try self.readRowDescription();
                },
                .DataRow => {
                    const idx = try self.allocator.alloc(u8, payload_len);
                    errdefer self.allocator.free(idx);
                    try self.reader.readBytes(idx);
                    const row = try Row.init(self.allocator, idx);
                    try rows.append(self.allocator, row);
                },
                .ReadyForQuery => {
                    const status = try self.reader.readByte();
                    self.in_transaction = (status == @intFromEnum(types.TransactionStatus.InTransaction));
                    return ResultSet{
                        .rows = rows,
                        .column_names = col_names,
                        .allocator = self.allocator,
                    };
                },
                .ErrorResponse => {
                    try self.reader.skip(payload_len);
                    return types.ProtocolError.QueryError;
                },
                .ParseComplete, .BindComplete => {},
                .CommandComplete => try self.reader.skip(payload_len),
                .PortalSuspended => try self.reader.skip(payload_len),
                .NoticeResponse, .NotificationResponse, .ParameterStatus => try self.reader.skip(payload_len),
                else => try self.reader.skip(payload_len),
            }
        }
    }
};
