const std = @import("std");
const types = @import("types.zig");
const Reader = @import("reader.zig").MessageReader;
const Writer = @import("writer.zig").MessageWriter;

/// Errors that can occur during the PostgreSQL authentication and handshake process.
pub const AuthError = error{
    /// The password was incorrect or the user does not exist.
    AuthenticationFailed,
    /// The server requested an authentication method that is not yet implemented (e.g., SCRAM-SHA-256).
    UnsupportedAuthMethod,
    /// The server sent a message that violates the expectations of the handshake protocol.
    ProtocolViolation,
    /// The server requires SSL/encryption which is not yet supported by this driver.
    EncryptionNotSupported,
} || types.ProtocolError;

/// Performs the initial handshake and authentication with the PostgreSQL server.
///
/// This function:
/// 1. Sends the 'StartupMessage' containing the username and database.
/// 2. Loops through backend responses until the server is ready for queries.
/// 3. Responds to authentication challenges (Cleartext or MD5).
/// 4. Handles 'ParameterStatus', 'BackendKeyData', and 'NoticeResponse' messages.
///
/// If successful, the connection is authenticated and ready to receive SQL queries.
pub fn performHandshake(allocator: std.mem.Allocator, reader: *Reader, writer: *Writer, username: []const u8, database: []const u8, password: ?[]const u8) !void {
    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();
    try params.put("user", username);
    try params.put("database", database);

    try params.put("application_name", "engine12_orm");

    try writer.writeStartupMessage(params);

    while (true) {
        const msg_type_byte = try reader.readByte();
        const msg_len = try reader.readInt32();
        _ = msg_len;

        const msg_type = @as(types.Backend, @enumFromInt(msg_type_byte));

        switch (msg_type) {
            .Authentication => {
                const auth_type_int = try reader.readInt32();
                const auth_type = @as(types.AuthType, @enumFromInt(auth_type_int));

                switch (auth_type) {
                    .Ok => {},
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
                return error.AuthenticationFailed;
            },
            .ParameterStatus => {
                const key = try reader.readString();
                const val = try reader.readString();
                _ = key;
                _ = val;
            },
            .BackendKeyData => {
                const pid = try reader.readInt32();
                const key = try reader.readInt32();
                _ = pid;
                _ = key;
            },
            .ReadyForQuery => {
                const status = try reader.readByte();
                _ = status;
                return;
            },
            .NoticeResponse => {
                while (true) {
                    const field_type = try reader.readByte();
                    if (field_type == 0) break;
                    _ = try reader.readString();
                }
            },
            else => {
                std.debug.print("[Postgres] Unexpected message during handshake: {c}\n", .{msg_type_byte});

                return error.ProtocolViolation;
            },
        }
    }
}

/// Calculates the MD5 hash for PostgreSQL MD5 authentication.
/// The algorithm is: concat('md5', hex(md5(hex(md5(password + username)) + salt)))
fn calculateMd5(allocator: std.mem.Allocator, password: []const u8, username: []const u8, salt: []const u8) ![]u8 {
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

    return std.fmt.allocPrint(allocator, "md5{s}", .{buf2});
}
