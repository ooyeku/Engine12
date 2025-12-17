const std = @import("std");

pub const HtmxConfig = struct {
    enabled: bool = true,

    version: []const u8 = "1.9.10",

    use_cdn: bool = true,

    cdn_url: []const u8 = "https://unpkg.com/htmx.org",

    extensions: []const []const u8 = &[_][]const u8{},

    inject_fragments: bool = false,

    debug: bool = false,

    include_integrity: bool = false,

    script_attributes: []const u8 = "",

    pub fn getScriptUrl(self: HtmxConfig) []const u8 {
        return self.cdn_url;
    }

    pub fn getExtensionUrl(self: HtmxConfig, allocator: std.mem.Allocator, ext_name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}@{s}/dist/ext/{s}.js", .{
            self.cdn_url,
            self.version,
            ext_name,
        });
    }
};

pub const default_config = HtmxConfig{};

pub const development_config = HtmxConfig{
    .enabled = true,
    .debug = true,
};

pub const production_config = HtmxConfig{
    .enabled = true,
    .debug = false,
    .include_integrity = true,
};

pub const disabled_config = HtmxConfig{
    .enabled = false,
};

test "HtmxConfig defaults" {
    const config = HtmxConfig{};
    try std.testing.expect(config.enabled);
    try std.testing.expect(config.use_cdn);
    try std.testing.expect(!config.debug);
    try std.testing.expect(!config.inject_fragments);
    try std.testing.expectEqualStrings("1.9.10", config.version);
}

test "HtmxConfig extension URL" {
    const config = HtmxConfig{};
    const url = try config.getExtensionUrl(std.testing.allocator, "ws");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://unpkg.com/htmx.org@1.9.10/dist/ext/ws.js", url);
}
