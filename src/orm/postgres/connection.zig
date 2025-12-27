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

pub const Connection = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    reader: Reader,
    writer: Writer,
    in_transaction: bool = false,

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

    pub fn close(self: *Connection) void {
        self.writer.writeTerminate() catch {};
        self.stream.close();
        self.writer.deinit();
    }

    /// Execute a simple query (Q) and ignore rows. Returns rows affected if parsed.
    pub fn execute(self: *Connection, sql: []const u8) !void {
        try self.writer.writeQuery(sql);

        while (true) {
            const msg_type_byte = try self.reader.readByte();
            const msg_len = try self.reader.readInt32(); // Includes self
            const payload_len = @as(usize, @intCast(msg_len - 4));

            const msg_type = @as(types.Backend, @enumFromInt(msg_type_byte));

            switch (msg_type) {
                .CommandComplete => {
                    // Payload: Tag string (e.g., "INSERT 0 1")
                    try self.reader.skip(payload_len);
                },
                .ReadyForQuery => {
                    const status = try self.reader.readByte();
                    self.in_transaction = (status == @intFromEnum(types.TransactionStatus.InTransaction));
                    return;
                },
                .ErrorResponse => {
                    try self.reader.skip(payload_len);
                    return types.ProtocolError.QueryError; // TODO: Parse detailed error
                },
                .DataRow => {
                    // We are ignoring rows in simple execute
                    try self.reader.skip(payload_len);
                },
                .RowDescription => {
                    // Ignore description
                    try self.reader.skip(payload_len);
                },
                .EmptyQueryResponse => {
                    // No rows and no error
                },
                else => {
                    // Skip unknown/unhandled messages
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
            // Name
            const name = try self.reader.readString();
            names[i] = try self.allocator.dupe(u8, name);

            // Skip other fields: table_oid(4), col_attr(2), type_oid(4), type_len(2), type_mod(4), format(2)
            // Total skip: 18 bytes
            _ = try self.reader.readInt32(); // table oid
            _ = try self.reader.readInt16(); // attr
            _ = try self.reader.readInt32(); // type
            _ = try self.reader.readInt16(); // len
            _ = try self.reader.readInt32(); // mod
            _ = try self.reader.readInt16(); // format
        }

        return names;
    }

    /// Execute a simple query (Q) and return rows.
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
                    // We can't skip because we need names.
                    // But readRowDescription reads from stream, assumes current pos is at payload start.
                    // readByte/readInt32 advanced pos.
                    // So readRowDescription aligns perfectly.
                    col_names = try self.readRowDescription();
                },
                .DataRow => {
                    // Allocate buffer for this row's data
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
                .EmptyQueryResponse => {
                    // yield empty list
                },
                else => {
                    try self.reader.skip(payload_len);
                },
            }
        }
    }

    // --- Extended Protocol ---

    pub fn prepare(self: *Connection, name: []const u8, sql: []const u8) !void {
        // Send Parse
        // Param OIDs empty for now, let server infer
        try self.writer.writeParse(name, sql, &.{});
        try self.writer.writeSync();

        // Wait for ParseComplete
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
        // 1. Parse (Unnamed statement)
        try self.writer.writeParse("", sql, &.{});

        // 2. Bind
        // We need to convert params to string representation (Text format code 0)
        var encoded_params = std.ArrayListUnmanaged(?[]const u8){};
        defer encoded_params.deinit(self.allocator);

        // Arena for string allocations during encoding
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

        // All param formats 0 (Text) - assuming simple text encoding for now
        try self.writer.writeBind("", "", &[_]i16{}, encoded_params.items, &[_]i16{});

        // 3. Execute
        try self.writer.writeExecute("", 0); // 0 = all rows

        // 4. Sync
        try self.writer.writeSync();

        // 5. Consume results
        while (true) {
            const msg_type_byte = try self.reader.readByte();
            const msg_len = try self.reader.readInt32(); // Includes self
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
                .DataRow => try self.reader.skip(payload_len), // Ignore rows
                .RowDescription => try self.reader.skip(payload_len),
                else => try self.reader.skip(payload_len),
            }
        }
    }

    pub fn queryParams(self: *Connection, sql: []const u8, params: *const @import("../params.zig").ParamList) !ResultSet {
        // 1. Parse
        try self.writer.writeParse("", sql, &.{});

        // 2. Bind
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
                .blob => |b| try encoded_params.append(self.allocator, b), // Helper needed for bytea
            }
        }

        try self.writer.writeBind("", "", &[_]i16{}, encoded_params.items, &[_]i16{});

        // 3. Execute
        try self.writer.writeExecute("", 0);

        // 4. Sync
        try self.writer.writeSync();

        var rows = std.ArrayListUnmanaged(Row){};
        var col_names: [][]const u8 = &.{};
        errdefer {
            for (rows.items) |*r| r.deinit();
            rows.deinit(self.allocator);
            for (col_names) |n| self.allocator.free(n);
            self.allocator.free(col_names);
        }

        // 5. Consume
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
                else => try self.reader.skip(payload_len),
            }
        }
    }
};
