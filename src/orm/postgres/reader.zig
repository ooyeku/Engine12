const std = @import("std");
const types = @import("types.zig");

pub const MessageReader = struct {
    stream: std.net.Stream,
    buffer: [8192]u8 = undefined,
    pos: usize = 0,
    end: usize = 0,

    pub fn init(stream: std.net.Stream) MessageReader {
        return MessageReader{
            .stream = stream,
        };
    }


    fn fillBuffer(self: *MessageReader) !void {

        if (self.pos < self.end) {
            const remaining = self.end - self.pos;
            std.mem.copyForwards(u8, &self.buffer, self.buffer[self.pos..self.end]);
            self.end = remaining;
            self.pos = 0;
        } else {
            self.pos = 0;
            self.end = 0;
        }

        const read = try self.stream.read(self.buffer[self.end..]);
        if (read == 0) return error.ConnectionClosed;
        self.end += read;
    }


    fn ensure(self: *MessageReader, n: usize) !void {
        while (self.end - self.pos < n) {
            try self.fillBuffer();
        }
    }

    pub fn readByte(self: *MessageReader) !u8 {
        if (self.pos >= self.end) try self.fillBuffer();
        const b = self.buffer[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn readInt16(self: *MessageReader) !i16 {
        try self.ensure(2);
        const val = std.mem.readInt(i16, self.buffer[self.pos..][0..2], .big);
        self.pos += 2;
        return val;
    }

    pub fn readInt32(self: *MessageReader) !i32 {
        try self.ensure(4);
        const val = std.mem.readInt(i32, self.buffer[self.pos..][0..4], .big);
        self.pos += 4;
        return val;
    }



    pub fn readString(self: *MessageReader) ![]const u8 {
        var start = self.pos;
        while (true) {

            if (std.mem.indexOfScalar(u8, self.buffer[start..self.end], 0)) |idx| {
                const end_pos = start + idx;
                const result = self.buffer[self.pos..end_pos];
                self.pos = end_pos + 1;
                return result;
            }




            if (self.pos == 0 and self.end == self.buffer.len) {
                return error.MessageTooLong;
            }


            const pending_len = self.end - self.pos;
            if (self.pos > 0) {
                std.mem.copyForwards(u8, &self.buffer, self.buffer[self.pos..self.end]);
                self.end = pending_len;
                self.pos = 0;
                start = pending_len;
            } else {

                start = self.end;
            }

            const read = try self.stream.read(self.buffer[self.end..]);
            if (read == 0) return error.ConnectionClosed;
            self.end += read;
        }
    }


    pub fn readBytes(self: *MessageReader, dest: []u8) !void {
        var dest_pos: usize = 0;
        while (dest_pos < dest.len) {
            const available = self.end - self.pos;
            if (available == 0) {
                try self.fillBuffer();
                continue;
            }

            const needed = dest.len - dest_pos;
            const to_copy = @min(available, needed);

            @memcpy(dest[dest_pos .. dest_pos + to_copy], self.buffer[self.pos .. self.pos + to_copy]);
            self.pos += to_copy;
            dest_pos += to_copy;
        }
    }


    pub fn skip(self: *MessageReader, n: usize) !void {
        var remaining = n;
        while (remaining > 0) {
            const available = self.end - self.pos;
            if (available >= remaining) {
                self.pos += remaining;
                return;
            }
            remaining -= available;
            self.pos = self.end;
            try self.fillBuffer();
        }
    }
};
