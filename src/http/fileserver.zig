const std = @import("std");
const ziggurat = @import("ziggurat");
const Response = @import("response.zig").Response;

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

    pub fn disableCache(self: *FileServer) void {
        self.enable_cache = false;
    }

    pub fn enableCache(self: *FileServer) void {
        self.enable_cache = true;
    }

    pub fn createHandler(self: *const FileServer) fn (*ziggurat.request.Request) ziggurat.response.Response {
        const self_ptr = self;
        const mount_path = self.base_path;
        return struct {
            const fs = self_ptr;
            const base = mount_path;

            fn handler(request: *ziggurat.request.Request) ziggurat.response.Response {
                _ = request;

                if (std.mem.eql(u8, base, "/")) {
                    return fs.serveFile("/").toZiggurat();
                }

                return fs.serveFile(base).toZiggurat();
            }
        }.handler;
    }

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

    pub fn serveFile(self: *const FileServer, request_path: []const u8) Response {
        var file_path = request_path;
        if (std.mem.startsWith(u8, request_path, self.base_path)) {
            file_path = request_path[self.base_path.len..];
        }

        if (file_path.len > 0 and file_path[0] == '/') {
            file_path = file_path[1..];
        }

        if (file_path.len == 0 or file_path[file_path.len - 1] == '/') {
            file_path = self.index_file;
        }

        if (!self.isValidPath(file_path)) {
            return self.createErrorResponse(403, "Forbidden: Invalid path");
        }

        const contents = self.readFile(file_path) catch |err| {
            return switch (err) {
                error.FileNotFound => self.createErrorResponse(404, "File not found"),
                error.FileTooLarge => self.createErrorResponse(413, "File too large"),
                error.InvalidPath => self.createErrorResponse(403, "Forbidden: Invalid path"),
                else => self.createErrorResponse(500, "Internal server error"),
            };
        };


        const mime_type = self.getMimeType(file_path);

        var response = if (std.mem.eql(u8, mime_type, "text/html"))
            Response.html(contents)
        else if (std.mem.eql(u8, mime_type, "text/css"))
            Response.text(contents).withContentType("text/css")
        else if (std.mem.eql(u8, mime_type, "application/javascript"))
            Response.text(contents).withContentType("application/javascript")
        else
            Response.text(contents).withContentType(mime_type);

        if (!self.enable_cache) {
            response = response
                .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
                .withHeader("Pragma", "no-cache")
                .withHeader("Expires", "0");
        }

        return response;
    }

    fn createErrorResponse(_: *const FileServer, status_code: u16, message: []const u8) Response {
        const error_json = std.fmt.allocPrint(std.heap.page_allocator, "{{\"error\":\"{s}\"}}", .{message}) catch {
            return Response.text("Internal server error").withStatus(status_code);
        };
        return Response.json(error_json).withStatus(status_code);
    }

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

    pub fn isValidPath(self: *const FileServer, requested_path: []const u8) bool {
        _ = self;

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

        var decode_buffer: [4096]u8 = undefined;
        const decoded_path = decodeUrlPath(requested_path, &decode_buffer) catch {
            return false;
        };

        if (std.mem.indexOf(u8, decoded_path, "..")) |_| {
            return false;
        }

        if (std.mem.indexOf(u8, requested_path, "..")) |_| {
            return false;
        }

        if (std.mem.indexOf(u8, requested_path, "\x00")) |_| {
            return false;
        }
        if (std.mem.indexOf(u8, decoded_path, "\x00")) |_| {
            return false;
        }

        return true;
    }

    pub fn readFile(self: *const FileServer, file_path: []const u8) ![]const u8 {
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

        const contents = try std.heap.page_allocator.alloc(u8, @as(usize, @intCast(stat.size)));
        errdefer std.heap.page_allocator.free(contents);

        const bytes_read = try file.readAll(contents);
        if (bytes_read != contents.len) {
            std.heap.page_allocator.free(contents);
            return error.UnexpectedEOF;
        }

        return contents;
    }
};

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

    try std.testing.expect(server.isValidPath("") == true);

    try std.testing.expect(server.isValidPath("../../../etc/passwd") == false);

    try std.testing.expect(server.isValidPath("path/..\\file.txt") == false);

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


test "FileServer isValidPath - URL encoded directory traversal attacks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");

    try std.testing.expect(server.isValidPath("..%2fsecret.txt") == false);
    try std.testing.expect(server.isValidPath("..%2Fsecret.txt") == false);

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

    try std.testing.expect(server.isValidPath("..\\secret.txt") == false);
    try std.testing.expect(server.isValidPath("..\\..\\secret.txt") == false);
    try std.testing.expect(server.isValidPath("path\\..\\secret.txt") == false);

    try std.testing.expect(server.isValidPath("../..\\secret.txt") == false);
}

test "FileServer isValidPath - path normalization edge cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");

    try std.testing.expect(server.isValidPath("/normal/path.txt") == true);
    try std.testing.expect(server.isValidPath("/../secret.txt") == false); // Should catch this

    try std.testing.expect(server.isValidPath("/../../etc/passwd") == false);
}

test "FileServer serveFile - empty path and trailing slash handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_dir = "test_fileserver_dir";
    std.fs.cwd().makeDir(test_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const index_content = "<html>Test</html>";
    const index_file = try std.fs.cwd().createFile(test_dir ++ "/index.html", .{});
    defer index_file.close();
    try index_file.writeAll(index_content);

    var server = FileServer.init(allocator, "/static", test_dir);

    var empty_response = server.serveFile("");
    defer empty_response.deinit(allocator);

    var slash_response = server.serveFile("/");
    defer slash_response.deinit(allocator);

    var trailing_slash_response = server.serveFile("subdir/");
    defer trailing_slash_response.deinit(allocator);
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

    const result = server.readFile("nonexistent.txt");
    try std.testing.expectError(error.FileNotFound, result);

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

    var server = FileServer.init(allocator, "/static", test_dir);
    server.max_file_size = 10; // 10 bytes max

    const large_file = try std.fs.cwd().createFile(test_dir ++ "/large.txt", .{});
    defer large_file.close();
    try large_file.writeAll("This is a large file that exceeds the limit");

    const result = server.readFile("large.txt");
    try std.testing.expectError(error.FileTooLarge, result);
}

test "FileServer createErrorResponse - status code usage" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");

    var forbidden_response = server.serveFile("../secret.txt");
    defer forbidden_response.deinit(allocator);

    var not_found_response = server.serveFile("nonexistent.txt");
    defer not_found_response.deinit(allocator);
}

test "FileServer createHandler - handler creation and closure safety" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const server = FileServer.init(allocator, "/static", "public");

    _ = server;

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

    const test_file = try std.fs.cwd().createFile(test_dir ++ "/test.txt", .{});
    defer test_file.close();
    try test_file.writeAll("test content");

    var server = FileServer.init(allocator, "/static", test_dir);

    var response1 = server.serveFile("/static/test.txt");
    defer response1.deinit(allocator);

    var response2 = server.serveFile("test.txt");
    defer response2.deinit(allocator);

    var response3 = server.serveFile("/static/subdir/file.txt");
    defer response3.deinit(allocator);
}

test "FileServer - allocator consistency check" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const server = FileServer.init(allocator, "/static", "public");

    _ = server.allocator;

}

test "FileServer isValidPath - comprehensive directory traversal tests" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = FileServer.init(allocator, "/static", "public");

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

    for (encoded_attack_patterns) |pattern| {
        try std.testing.expect(server.isValidPath(pattern) == false);
    }

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
