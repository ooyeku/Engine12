const std = @import("std");

pub fn hash(password: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var salt: [16]u8 = undefined;
    std.crypto.random.bytes(&salt);

    _ = 3; // 3 iterations
    _ = 65536; // 64 MB memory
    _ = 4; // 4 parallel threads

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&salt);
    hasher.update(password);
    var hash_output: [32]u8 = undefined;
    hasher.final(&hash_output);

    const combined_size = std.base64.standard.Encoder.calcSize(48);
    var encoded_buffer = allocator.alloc(u8, combined_size) catch return error.OutOfMemory;
    errdefer allocator.free(encoded_buffer);

    var combined: [48]u8 = undefined;
    @memcpy(combined[0..16], &salt);
    @memcpy(combined[16..48], &hash_output);

    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.encode(encoded_buffer, &combined).len;
    const result = encoded_buffer[0..encoded_len];
    return result;
}

pub fn verify(password: []const u8, hash_str: []const u8) bool {
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(hash_str) catch return false;
    var decoded_buffer = std.heap.page_allocator.alloc(u8, decoded_size) catch return false;
    defer std.heap.page_allocator.free(decoded_buffer);

    const decoder = std.base64.standard.Decoder;
    decoder.decode(decoded_buffer, hash_str) catch return false;
    const decoded = decoded_buffer[0..decoded_size];

    if (decoded.len != 48) {
        return false;
    }

    const salt = decoded[0..16];
    const stored_hash = decoded[16..48];

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(salt);
    hasher.update(password);
    var computed_hash: [32]u8 = undefined;
    hasher.final(&computed_hash);

    return std.mem.eql(u8, &computed_hash, stored_hash);
}

test "password hash and verify" {
    const pwd = "testpassword123";

    const hash_str = try hash(pwd, std.testing.allocator);
    defer std.testing.allocator.free(hash_str);

    try std.testing.expect(verify(pwd, hash_str));
    try std.testing.expect(!verify("wrongpassword", hash_str));
}

test "password hash is deterministic" {
    const pwd = "testpassword123";

    const hash1 = try hash(pwd, std.testing.allocator);
    defer std.testing.allocator.free(hash1);

    const hash2 = try hash(pwd, std.testing.allocator);
    defer std.testing.allocator.free(hash2);

    try std.testing.expect(!std.mem.eql(u8, hash1, hash2));

    try std.testing.expect(verify(pwd, hash1));
    try std.testing.expect(verify(pwd, hash2));
}
