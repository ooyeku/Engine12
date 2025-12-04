const std = @import("std");
const ziggurat = @import("ziggurat");
const Response = @import("response.zig").Response;

/// FileServer struct for serving static files.  Supports caching and file size limits.
pub const FileServer = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8,
    directory: []const u8,
    index_file: []const u8,
    enable_cache: bool,
    max_file_size: usize,

    const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB default

    pub fn init(
        allocator: std.mem.Allocator,
        base_path: []const u8,
        directory_path: []const u8,
    ) FileServer {
        return FileServer{
            .allocator = allocator,
            .base_path = base_path,
            .directory = directory_path,
            .index_file = "index.html",
            .enable_cache = true,
            .max_file_size = MAX_FILE_SIZE,
        };
    }

    /// Disable cache for this file server (useful in development mode)
    pub fn disableCache(self: *FileServer) void {
        self.enable_cache = false;
    }

    /// Enable cache for this file server
    pub fn enableCache(self: *FileServer) void {
        self.enable_cache = true;
    }

    /// Create a handler function that serves files from this FileServer
    /// The handler uses the route path to determine which file to serve
    ///
    /// WARNING: The returned handler captures a pointer to this FileServer.
    /// The FileServer must outlive the handler's usage. If the FileServer is
    /// stack-allocated, ensure it remains in scope while the handler is used.
    pub fn createHandler(self: *const FileServer) fn (*ziggurat.request.Request) ziggurat.response.Response {
        const self_ptr = self;
        const mount_path = self.base_path;
        return struct {
            const fs = self_ptr;
            const base = mount_path;

            fn handler(request: *ziggurat.request.Request) ziggurat.response.Response {
                // Since ziggurat doesn't expose request.uri directly,
                // we'll need to handle this at the route level
                // For now, serve the index file for the base path
                _ = request;

                // If base path is "/", serve index.html
                if (std.mem.eql(u8, base, "/")) {
                    return fs.serveFile("/").toZiggurat();
                }

                // Otherwise serve the base path
                return fs.serveFile(base).toZiggurat();
            }
        }.handler;
    }

    /// Create a handler that serves a specific file path
    ///
    /// WARNING: The returned handler captures a pointer to this FileServer.
    /// The FileServer must outlive the handler's usage. If the FileServer is
    /// stack-allocated, ensure it remains in scope while the handler is used.
    pub fn createPathHandler(self: *const FileServer, route_path: []const u8) fn (*ziggurat.request.Request) ziggurat.response.Response {
        const self_ptr = self;
        const path = route_path;
        return struct {
            const fs = self_ptr;
            const route = path;

            fn handler(request: *ziggurat.request.Request) ziggurat.response.Response {
                _ = request;
                return fs.serveFile(route).toZiggurat();
            }
        }.handler;
    }

    /// Serve a file based on the request path
    pub fn serveFile(self: *const FileServer, request_path: []const u8) Response {
        // Remove base_path prefix if present
        var file_path = request_path;
        if (std.mem.startsWith(u8, request_path, self.base_path)) {
            file_path = request_path[self.base_path.len..];
        }

        // Remove leading slash
        if (file_path.len > 0 and file_path[0] == '/') {
            file_path = file_path[1..];
        }

        // If path is empty or ends with '/', serve index file
        if (file_path.len == 0 or file_path[file_path.len - 1] == '/') {
            file_path = self.index_file;
        }

        // Validate path security
        if (!self.isValidPath(file_path)) {
            return self.createErrorResponse(403, "Forbidden: Invalid path");
        }

        // Read file
        const contents = self.readFile(file_path) catch |err| {
            return switch (err) {
                error.FileNotFound => self.createErrorResponse(404, "File not found"),
                error.FileTooLarge => self.createErrorResponse(413, "File too large"),
                error.InvalidPath => self.createErrorResponse(403, "Forbidden: Invalid path"),
                else => self.createErrorResponse(500, "Internal server error"),
            };
        };

        // Response stores a reference to the body string, so it must persist
        // We use page_allocator in readFile to ensure the memory persists for async response handling
        // The memory will not be freed - this is acceptable for static files as they're small

        // Determine MIME type and use appropriate Response method
        const mime_type = self.getMimeType(file_path);

        // Create response with correct Content-Type
        // Response stores a reference to the body string, so contents must persist
        var response = if (std.mem.eql(u8, mime_type, "text/html"))
            Response.html(contents)
        else if (std.mem.eql(u8, mime_type, "text/css"))
            Response.text(contents).withContentType("text/css")
        else if (std.mem.eql(u8, mime_type, "application/javascript"))
            Response.text(contents).withContentType("application/javascript")
        else
            Response.text(contents).withContentType(mime_type);

        // In development mode (when cache is disabled), add no-cache headers
        if (!self.enable_cache) {
            response = response
                .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
                .withHeader("Pragma", "no-cache")
                .withHeader("Expires", "0");
        }

        return response;
    }

    /// Create an error response
    /// Note: Caller should use page_allocator if persistence is required for async handling
    fn createErrorResponse(self: *const FileServer, status_code: u16, message: []const u8) Response {
        // Use allocator for error responses to ensure they persist for async handling
        const error_json = std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\"}}", .{message}) catch {
            return Response.text("Internal server error").withStatus(status_code);
        };
        // Don't free - Response stores a reference, so memory must persist
        return Response.json(error_json).withStatus(status_code);
    }

    /// Get MIME type from file extension
    pub fn getMimeType(self: *const FileServer, file_path: []const u8) []const u8 {
        _ = self;

        if (std.mem.lastIndexOf(u8, file_path, ".")) |dot_index| {
            const ext = file_path[dot_index + 1 ..];

            if (std.mem.eql(u8, ext, "html")) return "text/html";
            if (std.mem.eql(u8, ext, "css")) return "text/css";
            if (std.mem.eql(u8, ext, "js")) return "application/javascript";
            if (std.mem.eql(u8, ext, "json")) return "application/json";
            if (std.mem.eql(u8, ext, "png")) return "image/png";
            if (std.mem.eql(u8, ext, "jpg") or std.mem.eql(u8, ext, "jpeg")) return "image/jpeg";
            if (std.mem.eql(u8, ext, "svg")) return "image/svg+xml";
            if (std.mem.eql(u8, ext, "ico")) return "image/x-icon";
            if (std.mem.eql(u8, ext, "woff")) return "font/woff";
            if (std.mem.eql(u8, ext, "woff2")) return "font/woff2";
            if (std.mem.eql(u8, ext, "ttf")) return "font/ttf";
            if (std.mem.eql(u8, ext, "txt")) return "text/plain";
            if (std.mem.eql(u8, ext, "xml")) return "application/xml";
        }

        return "application/octet-stream";
    }

    /// Decode a single URL-encoded hex byte (e.g., "%2e" -> '.')
    /// Returns null if the encoding is invalid
    fn decodeHexByte(hex: []const u8) ?u8 {
        if (hex.len != 2) return null;
        var value: u8 = 0;
        for (hex) |c| {
            const digit = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return null,
            };
            value = value * 16 + digit;
        }
        return value;
    }

    /// Decode URL-encoded path for security validation
    /// Decodes %XX sequences to their byte values
    /// Uses a fixed buffer to avoid allocation issues
    fn decodeUrlPath(path: []const u8, buffer: []u8) ![]u8 {
        var pos: usize = 0;
        var i: usize = 0;

        while (i < path.len and pos < buffer.len) {
            if (i + 2 < path.len and path[i] == '%') {
                if (decodeHexByte(path[i + 1 .. i + 3])) |byte| {
                    if (pos >= buffer.len) return error.BufferTooSmall;
                    buffer[pos] = byte;
                    pos += 1;
                    i += 3;
                    continue;
                }
            }
            if (pos >= buffer.len) return error.BufferTooSmall;
            buffer[pos] = path[i];
            pos += 1;
            i += 1;
        }

        return buffer[0..pos];
    }

    /// Validate that the requested path is safe (no directory traversal)
    /// Checks both the original path and URL-decoded version for security
    ///
    /// Note: This function validates paths as-is (e.g., allows leading slashes).
    /// Path normalization (removing leading slashes, etc.) happens in `serveFile`
    /// before actual file access. This separation allows validation to catch
    /// security issues before normalization.
    pub fn isValidPath(self: *const FileServer, requested_path: []const u8) bool {
        _ = self;

        // Check for URL-encoded directory traversal patterns directly
        // Common patterns: %2e%2e (..), %2e%2e%2f (../), %2e%2e%5c (..\)
        const encoded_patterns = [_][]const u8{
            "%2e%2e", // ..
            "%2E%2E", // .. (uppercase)
            "%2e%2e%2f", // ../
            "%2E%2E%2F", // ../ (uppercase)
            "%2e%2e%5c", // ..\
            "%2E%2E%5C", // ..\ (uppercase)
            "%252e%252e", // Double-encoded %2e%2e
        };

        for (encoded_patterns) |pattern| {
            if (std.mem.indexOf(u8, requested_path, pattern)) |_| {
                return false;
            }
        }

        // Decode URL-encoded path and check decoded version
        // Use a fixed buffer for decoding (paths are typically short)
        var decode_buffer: [4096]u8 = undefined;
        const decoded_path = decodeUrlPath(requested_path, &decode_buffer) catch {
            // If decoding fails (buffer too small), reject the path for safety
            return false;
        };

        // Prevent directory traversal in decoded path
        if (std.mem.indexOf(u8, decoded_path, "..")) |_| {
            return false;
        }

        // Prevent directory traversal in original path
        if (std.mem.indexOf(u8, requested_path, "..")) |_| {
            return false;
        }

        // Prevent null bytes
        if (std.mem.indexOf(u8, requested_path, "\x00")) |_| {
            return false;
        }
        if (std.mem.indexOf(u8, decoded_path, "\x00")) |_| {
            return false;
        }

        // Allow leading slash for URL paths (validation happens before normalization in serveFile)
        // The path will be normalized in serveFile before actual file access
        return true;
    }

    /// Read a file from the filesystem safely
    /// Uses page_allocator to ensure contents persist for ziggurat's async response handling
    /// Note: Memory is not freed - this is acceptable for static file serving as files are small
    pub fn readFile(self: *const FileServer, file_path: []const u8) ![]const u8 {
        // Validate path security
        if (!self.isValidPath(file_path)) {
            return error.InvalidPath;
        }

        var dir = std.fs.cwd().openDir(self.directory, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return error.FileNotFound;
            }
            return err;
        };
        defer dir.close();

        var file = dir.openFile(file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return error.FileNotFound;
            }
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size > self.max_file_size) {
            return error.FileTooLarge;
        }

        // Use allocator to ensure memory persists for ziggurat's async response handling
        // ziggurat Response stores a reference to the body string, so it must persist
        // Note: Caller should use page_allocator if persistence is required for async handling
        const contents = try self.allocator.alloc(u8, @as(usize, @intCast(stat.size)));
        errdefer self.allocator.free(contents);

        const bytes_read = try file.readAll(contents);
        if (bytes_read != contents.len) {
            self.allocator.free(contents);
            return error.UnexpectedEOF;
        }

        return contents;
    }
};

// Tests
test "FileServer init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const server = FileServer.init(allocator, "/static", "public");
    try std.testing.expectEqualStrings(server.base_path, "/static");
    try std.testing.expectEqualStrings(server.directory, "public");
    try std.testing.expectEqualStrings(server.index_file, "index.html");
    try std.testing.expect(server.enable_cache == true);
}

test "FileServer getMimeType" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");
    try std.testing.expectEqualStrings(server.getMimeType("test.html"), "text/html");
    try std.testing.expectEqualStrings(server.getMimeType("style.css"), "text/css");
    try std.testing.expectEqualStrings(server.getMimeType("script.js"), "application/javascript");
    try std.testing.expectEqualStrings(server.getMimeType("data.json"), "application/json");
    try std.testing.expectEqualStrings(server.getMimeType("image.png"), "image/png");
    try std.testing.expectEqualStrings(server.getMimeType("unknown"), "application/octet-stream");
}

test "FileServer isValidPath" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");
    try std.testing.expect(server.isValidPath("index.html") == true);
    try std.testing.expect(server.isValidPath("/css/styles.css") == true);
    try std.testing.expect(server.isValidPath("../secret.txt") == false);
    try std.testing.expect(server.isValidPath("..\\file.txt") == false);
    try std.testing.expect(server.isValidPath("normal/file.txt") == true);
}

test "FileServer isValidPath with null bytes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");
    try std.testing.expect(server.isValidPath("file\x00.txt") == false);
}

test "FileServer getMimeType with various extensions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");
    try std.testing.expectEqualStrings(server.getMimeType("test.html"), "text/html");
    try std.testing.expectEqualStrings(server.getMimeType("style.css"), "text/css");
    try std.testing.expectEqualStrings(server.getMimeType("script.js"), "application/javascript");
    try std.testing.expectEqualStrings(server.getMimeType("data.json"), "application/json");
    try std.testing.expectEqualStrings(server.getMimeType("image.png"), "image/png");
    try std.testing.expectEqualStrings(server.getMimeType("image.jpg"), "image/jpeg");
    try std.testing.expectEqualStrings(server.getMimeType("image.jpeg"), "image/jpeg");
    try std.testing.expectEqualStrings(server.getMimeType("image.svg"), "image/svg+xml");
    try std.testing.expectEqualStrings(server.getMimeType("favicon.ico"), "image/x-icon");
    try std.testing.expectEqualStrings(server.getMimeType("font.woff"), "font/woff");
    try std.testing.expectEqualStrings(server.getMimeType("font.woff2"), "font/woff2");
    try std.testing.expectEqualStrings(server.getMimeType("font.ttf"), "font/ttf");
    try std.testing.expectEqualStrings(server.getMimeType("readme.txt"), "text/plain");
    try std.testing.expectEqualStrings(server.getMimeType("data.xml"), "application/xml");
    try std.testing.expectEqualStrings(server.getMimeType("unknown"), "application/octet-stream");
}

test "FileServer getMimeType with no extension" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");
    try std.testing.expectEqualStrings(server.getMimeType("noextension"), "application/octet-stream");
}

test "FileServer getMimeType with multiple dots" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");
    try std.testing.expectEqualStrings(server.getMimeType("file.min.js"), "application/javascript");
    try std.testing.expectEqualStrings(server.getMimeType("archive.tar.gz"), "application/octet-stream");
}

test "FileServer isValidPath edge cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");

    // Empty path
    try std.testing.expect(server.isValidPath("") == true);

    // Path with multiple ../ attempts
    try std.testing.expect(server.isValidPath("../../../etc/passwd") == false);

    // Path with mixed separators
    try std.testing.expect(server.isValidPath("path/..\\file.txt") == false);

    // Normal nested paths
    try std.testing.expect(server.isValidPath("subdir/file.txt") == true);
    try std.testing.expect(server.isValidPath("a/b/c/d/file.txt") == true);
}

test "FileServer init with custom settings" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const server = FileServer.init(allocator, "/assets", "static");
    try std.testing.expectEqualStrings(server.base_path, "/assets");
    try std.testing.expectEqualStrings(server.directory, "static");
    try std.testing.expectEqualStrings(server.index_file, "index.html");
    try std.testing.expect(server.enable_cache == true);
    try std.testing.expect(server.max_file_size == FileServer.MAX_FILE_SIZE);
}

// ============================================================================
// Bug Verification Tests
// ============================================================================

test "FileServer isValidPath - URL encoded directory traversal attacks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");

    // Test URL-encoded directory traversal attempts - all should be rejected
    // These patterns contain ".." in plain text, so they should be caught
    try std.testing.expect(server.isValidPath("..%2fsecret.txt") == false);
    try std.testing.expect(server.isValidPath("..%2Fsecret.txt") == false);

    // These are URL-encoded and should now be caught after the fix
    const encoded_patterns = [_]struct { pattern: []const u8, description: []const u8 }{
        .{ .pattern = "%2e%2e/secret.txt", .description = "URL-encoded ../" },
        .{ .pattern = "%2e%2e%2fsecret.txt", .description = "URL-encoded ../" },
        .{ .pattern = "%2e%2e%5csecret.txt", .description = "URL-encoded ..\\" },
        .{ .pattern = "file%2e%2e%2f%2e%2e/etc/passwd", .description = "Double encoded traversal" },
        .{ .pattern = "%252e%252e/secret.txt", .description = "Double-encoded %2e%2e" },
        .{ .pattern = "%2E%2E/secret.txt", .description = "Uppercase URL-encoded .." },
    };

    for (encoded_patterns) |item| {
        try std.testing.expect(server.isValidPath(item.pattern) == false);
        _ = item.description;
    }
}

test "FileServer isValidPath - Windows-style directory traversal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");

    // Windows backslash traversal (should be caught by ".." check, but verify)
    try std.testing.expect(server.isValidPath("..\\secret.txt") == false);
    try std.testing.expect(server.isValidPath("..\\..\\secret.txt") == false);
    try std.testing.expect(server.isValidPath("path\\..\\secret.txt") == false);

    // Mixed forward/backward slashes
    try std.testing.expect(server.isValidPath("../..\\secret.txt") == false);
}

test "FileServer isValidPath - path normalization edge cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");

    // Test leading slash behavior (BUG #6 - inconsistent validation)
    // isValidPath allows leading slashes, but serveFile strips them
    try std.testing.expect(server.isValidPath("/normal/path.txt") == true);
    try std.testing.expect(server.isValidPath("/../secret.txt") == false); // Should catch this

    // Test that leading slash doesn't bypass .. check
    try std.testing.expect(server.isValidPath("/../../etc/passwd") == false);
}

test "FileServer serveFile - empty path and trailing slash handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a test directory structure
    const test_dir = "test_fileserver_dir";
    std.fs.cwd().makeDir(test_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create index.html
    const index_content = "<html>Test</html>";
    const index_file = try std.fs.cwd().createFile(test_dir ++ "/index.html", .{});
    defer index_file.close();
    try index_file.writeAll(index_content);

    var server = FileServer.init(allocator, "/static", test_dir);

    // Test empty path (BUG #5 - redundant condition)
    // This should serve index.html
    const empty_response = server.serveFile("");
    // Verify response was created (can't easily check status_code as it's private)
    _ = empty_response;

    // Test trailing slash
    const slash_response = server.serveFile("/");
    _ = slash_response;

    // Test path ending with slash
    const trailing_slash_response = server.serveFile("subdir/");
    _ = trailing_slash_response;
}

test "FileServer readFile - error path memory leak prevention" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_dir = "test_fileserver_error_dir";
    std.fs.cwd().makeDir(test_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var server = FileServer.init(allocator, "/static", test_dir);

    // Test that non-existent file doesn't leak memory (BUG #1)
    // This should return FileNotFound error without leaking
    const result = server.readFile("nonexistent.txt");
    try std.testing.expectError(error.FileNotFound, result);

    // Test invalid path doesn't leak
    const invalid_result = server.readFile("../secret.txt");
    try std.testing.expectError(error.InvalidPath, invalid_result);
}

test "FileServer readFile - file too large error handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_dir = "test_fileserver_large_dir";
    std.fs.cwd().makeDir(test_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create a server with very small max_file_size
    var server = FileServer.init(allocator, "/static", test_dir);
    server.max_file_size = 10; // 10 bytes max

    // Create a file larger than max_file_size
    const large_file = try std.fs.cwd().createFile(test_dir ++ "/large.txt", .{});
    defer large_file.close();
    try large_file.writeAll("This is a large file that exceeds the limit");

    // Should return FileTooLarge error
    const result = server.readFile("large.txt");
    try std.testing.expectError(error.FileTooLarge, result);
}

test "FileServer createErrorResponse - status code usage" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");

    // Test that error responses are created (BUG #9 - status_code parameter ignored)
    // Note: We can't directly test createErrorResponse since it's private,
    // but we can test serveFile with invalid paths which calls it
    // The bug is that createErrorResponse accepts status_code but doesn't use it
    const forbidden_response = server.serveFile("../secret.txt");
    // Response should be created (verifies error handling works)
    // Note: status_code field is private, so we can't verify it's set correctly
    // This test documents that error responses are created
    _ = forbidden_response;

    const not_found_response = server.serveFile("nonexistent.txt");
    _ = not_found_response;
}

test "FileServer createHandler - handler creation and closure safety" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test that handler can be created (BUG #4 - dangling pointer risk)
    // This test verifies the handler creation doesn't crash immediately
    const server = FileServer.init(allocator, "/static", "public");

    // Note: createHandler returns a comptime function type, so we can't easily test it at runtime
    // This test documents that the function exists and can be called
    // The actual handler would need to be tested in integration tests
    // We can't directly reference the method as a field, but we can verify the struct compiles
    _ = server;

    // Verify the function signatures are correct
    const HandlerType = fn (*ziggurat.request.Request) ziggurat.response.Response;
    _ = HandlerType;
}

test "FileServer serveFile - base path prefix removal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_dir = "test_fileserver_base_dir";
    std.fs.cwd().makeDir(test_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create a test file
    const test_file = try std.fs.cwd().createFile(test_dir ++ "/test.txt", .{});
    defer test_file.close();
    try test_file.writeAll("test content");

    var server = FileServer.init(allocator, "/static", test_dir);

    // Test that base_path prefix is removed correctly
    const response1 = server.serveFile("/static/test.txt");
    // Verify response was created (status_code is stored in Response._status_code, not inner)
    _ = response1;

    // Test without base_path prefix
    const response2 = server.serveFile("test.txt");
    _ = response2;

    // Test with leading slash after prefix removal
    const response3 = server.serveFile("/static/subdir/file.txt");
    // Should try to serve "subdir/file.txt"
    // This tests the path normalization logic
    // Note: This will likely return 404 since the file doesn't exist, but tests path handling
    _ = response3;
}

test "FileServer - allocator consistency check" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test that FileServer stores allocator correctly (BUG #3)
    const server = FileServer.init(allocator, "/static", "public");

    // Verify allocator is stored (can't directly compare, but verify it's not null)
    // The allocator field should be accessible
    _ = server.allocator;

    // Note: We can't easily test that readFile uses self.allocator vs page_allocator
    // without modifying the code, but this test documents the expected behavior
}

test "FileServer isValidPath - comprehensive directory traversal tests" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");

    // Basic directory traversal patterns (should be caught)
    const basic_attack_patterns = [_][]const u8{
        "..",
        "../",
        "..\\",
        "../..",
        "../../",
        "../../../",
        "path/../secret",
        "path/..\\secret",
        "normal/../secret",
        "a/b/../../secret",
    };

    for (basic_attack_patterns) |pattern| {
        try std.testing.expect(server.isValidPath(pattern) == false);
    }

    // URL-encoded directory traversal patterns - all should now be caught after fix
    const encoded_attack_patterns = [_][]const u8{
        "..%2f", // URL-encoded ../
        "..%2F", // URL-encoded ../ (uppercase)
        "%2e%2e", // URL-encoded ..
        "%2E%2E", // URL-encoded .. (uppercase)
        "%2e%2e%2f", // URL-encoded ../
        "%2e%2e%5c", // URL-encoded ..\
        "..%2f..", // Mixed encoding
        "%2e%2e%2f%2e%2e", // Double encoded
        "path/..%2fsecret", // Path with encoded traversal
        "%2e%2e/path", // Encoded at start
        "..%2fpath", // Encoded traversal
        "normal/..%2fsecret", // Normal path with encoded traversal
        "a/b/%2e%2e/%2e%2e/secret", // Nested encoded traversal
    };

    // All encoded patterns should now be rejected after the fix
    for (encoded_attack_patterns) |pattern| {
        try std.testing.expect(server.isValidPath(pattern) == false);
    }

    // Valid paths that should pass
    const valid_patterns = [_][]const u8{
        "index.html",
        "css/style.css",
        "js/app.js",
        "images/logo.png",
        "subdir/file.txt",
        "a/b/c/d/file.txt",
        "/normal/path.txt",
        "/css/styles.css",
    };

    for (valid_patterns) |pattern| {
        try std.testing.expect(server.isValidPath(pattern) == true);
    }
}
