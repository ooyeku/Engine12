const std = @import("std");
const types = @import("types.zig");
const MessageReader = @import("reader.zig").MessageReader;
const MessageWriter = @import("writer.zig").MessageWriter;

test "Postgres Protocol Handshake" {
    const allocator = std.testing.allocator;

    const address = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 0);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    const port = server.listen_address.in.getPort();

    const ServerThread = struct {
        pub fn run(server_ptr: *std.net.Server) !void {
            const alloc = std.testing.allocator;
            const conn = try server_ptr.accept();
            defer conn.stream.close();

            var reader = MessageReader.init(conn.stream);
            var writer = MessageWriter.init(alloc, conn.stream);
            defer writer.deinit();


            const len = try reader.readInt32();
            const proto = try reader.readInt32();
            try std.testing.expectEqual(@as(i32, 196608), proto);


            const param_len = len - 8;
            try reader.skip(@intCast(param_len));



            var buf = std.ArrayListUnmanaged(u8){};
            defer buf.deinit(alloc);

            try buf.append(alloc, 'R');
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(i32, &len_buf, 12, .big);
            try buf.appendSlice(alloc, &len_buf);

            std.mem.writeInt(i32, &len_buf, 5, .big);
            try buf.appendSlice(alloc, &len_buf);

            const salt = "SALT";
            try buf.appendSlice(alloc, salt);

            try conn.stream.writeAll(buf.items);


            const msg_type = try reader.readByte();
            try std.testing.expectEqual(@as(u8, 'p'), msg_type);
            const p_len = try reader.readInt32();
            const pass = try reader.readString();
            try std.testing.expect(std.mem.startsWith(u8, pass, "md5"));
            _ = p_len;


            buf.clearRetainingCapacity();
            try buf.append(alloc, 'R');
            std.mem.writeInt(i32, &len_buf, 8, .big);
            try buf.appendSlice(alloc, &len_buf);
            std.mem.writeInt(i32, &len_buf, 0, .big);
            try buf.appendSlice(alloc, &len_buf);
            try conn.stream.writeAll(buf.items);


            buf.clearRetainingCapacity();
            try buf.append(alloc, 'Z');
            std.mem.writeInt(i32, &len_buf, 5, .big);
            try buf.appendSlice(alloc, &len_buf);
            try buf.append(alloc, 'I');
            try conn.stream.writeAll(buf.items);
        }
    };

    const thread = try std.Thread.spawn(.{}, ServerThread.run, .{&server});
    defer thread.join();

    const client_conn = try std.net.tcpConnectToAddress(std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, port));
    defer client_conn.close();

    var reader = MessageReader.init(client_conn);
    var writer = MessageWriter.init(allocator, client_conn);
    defer writer.deinit();

    const auth = @import("auth.zig");
    try auth.performHandshake(allocator, &reader, &writer, "user", "db", "password");
}
