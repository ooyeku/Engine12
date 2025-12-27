const std = @import("std");
const types = @import("types.zig");

pub const Row = struct {
    data: []u8, // Owns the DataRow payload (excluding msg type/len)
    num_columns: u16,
    allocator: std.mem.Allocator,

    // We can index the column offsets lazily or eagerly.
    // For performance, let's index eagerly since ORM usually reads all columns anyway.
    col_offsets: []usize,
    col_lens: []i32,

    pub fn init(allocator: std.mem.Allocator, data: []u8) !Row {
        // Data format:
        // Int16: num columns
        // For each col:
        //   Int32: length of val
        //   [length] bytes: val

        if (data.len < 2) return error.ProtocolViolation;

        const num_cols = std.mem.readInt(u16, data[0..2], .big);
        var pos: usize = 2;

        var offsets = try allocator.alloc(usize, num_cols);
        var lens = try allocator.alloc(i32, num_cols);
        errdefer {
            allocator.free(offsets);
            allocator.free(lens);
        }

        for (0..num_cols) |i| {
            if (pos + 4 > data.len) return error.ProtocolViolation;

            const col_len = std.mem.readInt(i32, data[pos..][0..4], .big);
            pos += 4;

            lens[i] = col_len;

            if (col_len >= 0) {
                const u_len: usize = @intCast(col_len);
                if (pos + u_len > data.len) return error.ProtocolViolation;

                offsets[i] = pos;
                pos += u_len;
            } else {
                offsets[i] = 0; // Invalid offset for NULL
            }
        }

        return Row{
            .data = data,
            .num_columns = num_cols,
            .allocator = allocator,
            .col_offsets = offsets,
            .col_lens = lens,
        };
    }

    pub fn deinit(self: *Row) void {
        self.allocator.free(self.col_offsets);
        self.allocator.free(self.col_lens);
        self.allocator.free(self.data);
    }

    pub fn isNull(self: Row, col_idx: usize) bool {
        if (col_idx >= self.num_columns) return true;
        return self.col_lens[col_idx] == -1;
    }

    pub fn getBytes(self: Row, col_idx: usize) ?[]const u8 {
        if (self.isNull(col_idx)) return null;

        const offset = self.col_offsets[col_idx];
        const len = @as(usize, @intCast(self.col_lens[col_idx]));

        return self.data[offset .. offset + len];
    }

    // --- Type conversions ---
    // Assuming Text format protocol for now (simple query 'Q' returns text)

    pub fn getText(self: Row, col_idx: usize) ?[]const u8 {
        return self.getBytes(col_idx);
    }

    pub fn getInt64(self: Row, col_idx: usize) i64 {
        const bytes = self.getBytes(col_idx) orelse return 0;
        return std.fmt.parseInt(i64, bytes, 10) catch 0;
    }

    pub fn getInt32(self: Row, col_idx: usize) i32 {
        const bytes = self.getBytes(col_idx) orelse return 0;
        return std.fmt.parseInt(i32, bytes, 10) catch 0;
    }

    pub fn getFloat(self: Row, col_idx: usize) f64 {
        const bytes = self.getBytes(col_idx) orelse return 0.0;
        return std.fmt.parseFloat(f64, bytes) catch 0.0;
    }

    pub fn getBool(self: Row, col_idx: usize) bool {
        const bytes = self.getBytes(col_idx) orelse return false;
        if (bytes.len == 0) return false;
        return bytes[0] == 't';
    }

    // Helpers for allocation
    pub fn getTextAlloc(self: Row, allocator: std.mem.Allocator, col_idx: usize) !?[]u8 {
        const text = self.getText(col_idx) orelse return null;
        return try allocator.dupe(u8, text);
    }
};
