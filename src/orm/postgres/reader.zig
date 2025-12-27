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

    /// Fill buffer if empty or insufficient data
    fn fillBuffer(self: *MessageReader) !void {
        // Move remaining data to start
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

    /// Ensure we have at least n bytes available
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

    /// Reads a null-terminated string. Returns a slice into the buffer.
    /// Note: The slice is valid only until the next read operation that might shift the buffer.
    pub fn readString(self: *MessageReader) ![]const u8 {
        var start = self.pos;
        while (true) {
            // Scan for null terminator in current buffer
            if (std.mem.indexOfScalar(u8, self.buffer[start..self.end], 0)) |idx| {
                const end_pos = start + idx;
                const result = self.buffer[self.pos..end_pos];
                self.pos = end_pos + 1; // Skip null
                return result;
            }

            // Not found, need more data.
            // If buffer is full and we haven't found null, message is too long or buffer too small.
            // For now, handle by shifting/filling.
            if (self.pos == 0 and self.end == self.buffer.len) {
                return error.MessageTooLong;
            }

            // Move partially read string to beginning
            const pending_len = self.end - self.pos;
            if (self.pos > 0) {
                std.mem.copyForwards(u8, &self.buffer, self.buffer[self.pos..self.end]);
                self.end = pending_len;
                self.pos = 0;
                start = pending_len; // Resume scan from where we left off
            } else {
                // Buffer full start at 0
                start = self.end;
            }

            const read = try self.stream.read(self.buffer[self.end..]);
            if (read == 0) return error.ConnectionClosed;
            self.end += read;
        }
    }

    /// Read raw bytes into a destination buffer
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

    /// Skip n bytes
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
