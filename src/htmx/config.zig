const std = @import("std");

/// HTMX configuration for Engine12
/// Controls script injection, versioning, and behavior
pub const HtmxConfig = struct {
    /// Enable HTMX script injection into HTML responses
    enabled: bool = true,

    /// HTMX version to use (from unpkg CDN)
    version: []const u8 = "1.9.10",

    /// Use CDN for HTMX script (recommended for production)
    /// If false, user must serve HTMX locally via static files
    use_cdn: bool = true,

    /// CDN base URL for HTMX (version is appended)
    cdn_url: []const u8 = "https://unpkg.com/htmx.org",

    /// HTMX extensions to load (e.g., "ws", "sse", "json-enc", "response-targets")
    /// Extensions are loaded from the same CDN
    extensions: []const []const u8 = &[_][]const u8{},

    /// Inject HTMX into fragment responses (partial HTML)
    /// Default: false - only inject into full HTML pages with <html> or <!DOCTYPE>
    inject_fragments: bool = false,

    /// Enable HTMX debug mode (logs to browser console)
    /// Automatically enabled in development mode
    debug: bool = false,

    /// Include integrity hash for CDN scripts (security feature)
    include_integrity: bool = false,

    /// Custom script attributes to add (e.g., for CSP nonce)
    script_attributes: []const u8 = "",

    /// Build the full CDN URL for HTMX script
    pub fn getScriptUrl(self: HtmxConfig) []const u8 {
        // Return static URL - caller handles version interpolation
        return self.cdn_url;
    }

    /// Build extension URL for a given extension name
    pub fn getExtensionUrl(self: HtmxConfig, allocator: std.mem.Allocator, ext_name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}@{s}/dist/ext/{s}.js", .{
            self.cdn_url,
            self.version,
            ext_name,
        });
    }
};

/// Default configuration - suitable for most use cases
pub const default_config = HtmxConfig{};

/// Development configuration - debug mode enabled
pub const development_config = HtmxConfig{
    .enabled = true,
    .debug = true,
};

/// Production configuration - optimized for performance
pub const production_config = HtmxConfig{
    .enabled = true,
    .debug = false,
    .include_integrity = true,
};

/// Disabled configuration - no HTMX injection
pub const disabled_config = HtmxConfig{
    .enabled = false,
};

// Tests
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
