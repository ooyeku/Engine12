const std = @import("std");
const types = @import("types.zig");
const Reader = @import("reader.zig").MessageReader;
const Writer = @import("writer.zig").MessageWriter;

pub const AuthError = error{
    AuthenticationFailed,
    UnsupportedAuthMethod,
    ProtocolViolation,
    EncryptionNotSupported,
} || types.ProtocolError;

pub fn performHandshake(allocator: std.mem.Allocator, reader: *Reader, writer: *Writer, username: []const u8, database: []const u8, password: ?[]const u8) !void {
    // 1. Send Startup Message
    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();
    try params.put("user", username);
    try params.put("database", database);
    // Add application_name for debugging visibility
    try params.put("application_name", "engine12_orm");

    try writer.writeStartupMessage(params);

    // 2. Handle Auth Response
    while (true) {
        const msg_type_byte = try reader.readByte();
        const msg_len = try reader.readInt32(); // Includes self
        _ = msg_len; // We might need this for payload reading

        const msg_type = @as(types.Backend, @enumFromInt(msg_type_byte));

        switch (msg_type) {
            .Authentication => {
                const auth_type_int = try reader.readInt32();
                const auth_type = @as(types.AuthType, @enumFromInt(auth_type_int));

                switch (auth_type) {
                    .Ok => {
                        // Auth successful, proceed to wait for ReadyForQuery
                    },
                    .CleartextPassword => {
                        if (password) |pass| {
                            try writer.writePassword(pass);
                        } else {
                            return error.AuthenticationFailed;
                        }
                    },
                    .Md5Password => {
                        if (password) |pass| {
                            var salt: [4]u8 = undefined;
                            try reader.readBytes(&salt);

                            const hash = try calculateMd5(allocator, pass, username, &salt);
                            defer allocator.free(hash);
                            try writer.writePassword(hash);
                        } else {
                            return error.AuthenticationFailed;
                        }
                    },
                    else => {
                        std.debug.print("[Postgres] Unsupported auth type: {}\n", .{auth_type});
                        return error.UnsupportedAuthMethod;
                    },
                }
            },
            .ErrorResponse => {
                // TODO: Parse error fields for better debug
                return error.AuthenticationFailed;
            },
            .ParameterStatus => {
                // Key/Value pair, null terminated
                const key = try reader.readString();
                const val = try reader.readString();
                _ = key;
                _ = val;
                // We can store these if needed (server_version, timezone, etc)
            },
            .BackendKeyData => {
                // PID (i32) + Key (i32)
                const pid = try reader.readInt32();
                const key = try reader.readInt32();
                _ = pid;
                _ = key;
                // Store if cancellation support is needed
            },
            .ReadyForQuery => {
                // Transaction status
                const status = try reader.readByte();
                _ = status;
                return; // Handshake complete
            },
            .NoticeResponse => {
                // Ignore notices during handshake for now
                // Needs to consume the fields
                while (true) {
                    const field_type = try reader.readByte();
                    if (field_type == 0) break;
                    _ = try reader.readString();
                }
            },
            else => {
                std.debug.print("[Postgres] Unexpected message during handshake: {c}\n", .{msg_type_byte});
                // return error.ProtocolViolation;
                // Be lenient, maybe skip message? But we define Reader to be sequential.
                // For now, if we don't know the message, we can't reliably skip it unless we track msg_len
                // correctly across all branches.
                // Since `msg_len` was read at top, we technically know how *long* the message is.
                // We should implement skip.
                // But reader.skip needs to account for bytes already read (auth_type_int for Auth).
                return error.ProtocolViolation;
            },
        }
    }
}

fn calculateMd5(allocator: std.mem.Allocator, password: []const u8, username: []const u8, salt: []const u8) ![]u8 {
    // 1. md5("password" + "username")
    var buf1: [32]u8 = undefined;
    {
        var hasher = std.crypto.hash.Md5.init(.{});
        hasher.update(password);
        hasher.update(username);
        var digest: [16]u8 = undefined;
        hasher.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        @memcpy(&buf1, &hex);
    }

    // 2. md5(digest1 + salt)
    var buf2: [32]u8 = undefined;
    {
        var hasher = std.crypto.hash.Md5.init(.{});
        hasher.update(&buf1);
        hasher.update(salt);
        var digest: [16]u8 = undefined;
        hasher.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        @memcpy(&buf2, &hex);
    }

    // 3. Prepend "md5"
    return std.fmt.allocPrint(allocator, "md5{s}", .{buf2});
}
