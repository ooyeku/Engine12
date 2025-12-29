const std = @import("std");
const Connection = @import("postgres/connection.zig").Connection;
const ResultSet = @import("postgres/connection.zig").ResultSet;
const Row = @import("postgres/row.zig").Row;
const row_mod = @import("row.zig");
const QueryResult = row_mod.QueryResult;
const PostgresStoredRow = row_mod.PostgresStoredRow;
const PostgresConfig = @import("driver.zig").PostgresConfig;
const ParamList = @import("params.zig").ParamList;


pub const PostgresDatabase = struct {
    conn: *Connection,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn open(config: PostgresConfig, allocator: std.mem.Allocator) !PostgresDatabase {
        const conn = try allocator.create(Connection);
        conn.* = try Connection.connect(allocator, config.host, config.port, config.username, config.database, config.password);
        return PostgresDatabase{
            .conn = conn,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn close(self: *PostgresDatabase) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.conn.close();
        self.allocator.destroy(self.conn);
    }

    pub fn execute(self: *PostgresDatabase, sql: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.conn.execute(sql);
    }

    pub fn executeParams(self: *PostgresDatabase, sql: []const u8, params: *const ParamList) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.conn.executeParams(sql, params);
    }

    pub fn query(self: *PostgresDatabase, sql: []const u8) !QueryResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        var rs = try self.conn.query(sql);
        defer rs.rows.deinit(self.allocator);







        return try convertToQueryResult(self.allocator, &rs);
    }

    pub fn queryParams(self: *PostgresDatabase, sql: []const u8, params: *const ParamList) !QueryResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        var rs = try self.conn.queryParams(sql, params);
        defer rs.rows.deinit(self.allocator);
        return try convertToQueryResult(self.allocator, &rs);
    }

    pub fn convertPlaceholders(allocator: std.mem.Allocator, sql: []const u8) ![]u8 {


        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(allocator);

        var param_idx: usize = 1;
        var i: usize = 0;
        while (i < sql.len) {
            if (sql[i] == '?') {
                try std.fmt.format(buf.writer(allocator), "${d}", .{param_idx});
                param_idx += 1;
            } else {
                try buf.append(allocator, sql[i]);
            }
            i += 1;
        }
        return buf.toOwnedSlice(allocator);
    }
};

test {
    _ = @import("postgres/tests.zig");
}

fn convertToQueryResult(allocator: std.mem.Allocator, rs: *ResultSet) !QueryResult {
    var stored_rows = std.ArrayListUnmanaged(PostgresStoredRow){};
    errdefer {
        for (stored_rows.items) |*r| r.deinit();
        stored_rows.deinit(allocator);
    }

    for (rs.rows.items) |row| {

        const values = try allocator.alloc(PostgresStoredRow.StoredValue, row.num_columns);
        errdefer allocator.free(values);

        for (0..row.num_columns) |i| {
            if (row.isNull(i)) {
                values[i] = .null_val;
            } else {


                if (row.getText(i)) |txt| {
                    const params_str = try allocator.dupe(u8, txt);
                    values[i] = .{ .text = params_str };
                } else {
                    values[i] = .null_val;
                }
            }
        }

        try stored_rows.append(allocator, PostgresStoredRow{
            .values = values,
            .allocator = allocator,
        });
    }








    var col_names = try allocator.alloc([]const u8, rs.column_names.len);
    errdefer allocator.free(col_names);

    for (rs.column_names, 0..) |src, i| {
        col_names[i] = try allocator.dupe(u8, src);
    }

    return QueryResult.initPostgres(stored_rows, col_names, allocator);
}
