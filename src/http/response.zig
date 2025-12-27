const std = @import("std");
const ziggurat = @import("ziggurat");
const json_module = @import("../data/json.zig");
const validation = @import("../data/validation.zig");

pub const ResponseBufferPool = struct {
    free_buffers: std.ArrayListUnmanaged([]u8),
    mutex: std.Thread.Mutex = .{},
    backing_allocator: std.mem.Allocator,
    max_buffers: usize,
    default_buffer_size: usize,
    stats_acquired: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stats_released: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stats_allocated: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(backing_allocator: std.mem.Allocator, max_buffers: usize, default_buffer_size: usize) ResponseBufferPool {
        return ResponseBufferPool{
            .free_buffers = std.ArrayListUnmanaged([]u8){},
            .mutex = .{},
            .backing_allocator = backing_allocator,
            .max_buffers = max_buffers,
            .default_buffer_size = default_buffer_size,
        };
    }

    pub fn acquire(self: *ResponseBufferPool, size: usize) ![]u8 {
        _ = self.stats_acquired.fetchAdd(1, .monotonic);

        self.mutex.lock();
        defer self.mutex.unlock();

        var best_idx: ?usize = null;
        var best_size: usize = std.math.maxInt(usize);

        for (self.free_buffers.items, 0..) |buf, i| {
            if (buf.len >= size and buf.len < best_size) {
                best_idx = i;
                best_size = buf.len;
            }
        }

        if (best_idx) |idx| {
            const buf = self.free_buffers.swapRemove(idx);
            return buf[0..size];
        }

        _ = self.stats_allocated.fetchAdd(1, .monotonic);
        const alloc_size = @max(size, self.default_buffer_size);
        const new_buf = try self.backing_allocator.alloc(u8, alloc_size);
        return new_buf[0..size];
    }

    pub fn release(self: *ResponseBufferPool, buf: []u8) void {
        _ = self.stats_released.fetchAdd(1, .monotonic);

        const full_buf = @as([*]u8, @ptrCast(buf.ptr))[0..self.getBufferCapacity(buf)];

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.free_buffers.items.len >= self.max_buffers) {
            self.backing_allocator.free(full_buf);
            return;
        }

        self.free_buffers.append(self.backing_allocator, full_buf) catch {
            self.backing_allocator.free(full_buf);
        };
    }

    fn getBufferCapacity(self: *ResponseBufferPool, buf: []u8) usize {
        return @max(buf.len, self.default_buffer_size);
    }

    pub fn getStats(self: *ResponseBufferPool) struct { acquired: u64, released: u64, allocated: u64, pooled: usize } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .acquired = self.stats_acquired.load(.monotonic),
            .released = self.stats_released.load(.monotonic),
            .allocated = self.stats_allocated.load(.monotonic),
            .pooled = self.free_buffers.items.len,
        };
    }

    pub fn deinit(self: *ResponseBufferPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.free_buffers.items) |buf| {
            self.backing_allocator.free(buf);
        }
        self.free_buffers.deinit(self.backing_allocator);
    }
};

var global_buffer_pool: ?ResponseBufferPool = null;
var global_buffer_pool_mutex: std.Thread.Mutex = .{};
var global_buffer_pool_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

threadlocal var pending_buffer_release: ?[]u8 = null;

threadlocal var formatted_responses: ?std.AutoHashMap(*const anyopaque, []const u8) = null;
threadlocal var formatted_responses_mutex: std.Thread.Mutex = .{};

fn markBufferForRelease(buffer: ?[]const u8) void {
    if (pending_buffer_release) |prev_buf| {
        getBufferPool().release(prev_buf);
    }
    if (buffer) |buf| {
        pending_buffer_release = @constCast(buf);
    } else {
        pending_buffer_release = null;
    }
}

pub fn releasePendingBuffer() void {
    if (pending_buffer_release) |buf| {
        getBufferPool().release(buf);
        pending_buffer_release = null;
    }
}

pub fn getBufferPool() *ResponseBufferPool {
    if (global_buffer_pool_initialized.load(.acquire)) {
        return &global_buffer_pool.?;
    }

    global_buffer_pool_mutex.lock();
    defer global_buffer_pool_mutex.unlock();

    if (!global_buffer_pool_initialized.load(.acquire)) {
        global_buffer_pool = ResponseBufferPool.init(
            std.heap.page_allocator,
            256, // max 256 pooled buffers
            64 * 1024, // 64KB default buffer size
        );
        global_buffer_pool_initialized.store(true, .release);
    }

    return &global_buffer_pool.?;
}

fn allocatePersistent(size: usize) ![]u8 {
    const pool = getBufferPool();
    return pool.acquire(size);
}

fn dupePersistent(data: []const u8) ![]u8 {
    const buf = try allocatePersistent(data.len);
    @memcpy(buf, data);
    return buf;
}

const persistent_allocator = std.heap.page_allocator;

pub const CookieOptions = struct {
    maxAge: ?u64 = null, // Cookie expiration in seconds
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    secure: bool = false, // Only send over HTTPS
    httpOnly: bool = false, // Not accessible via JavaScript
};

pub const Response = struct {
    inner: ziggurat.response.Response,

    _persistent_body: ?[]const u8 = null,

    _custom_headers: ?std.StringHashMap([]const u8) = null,

    _status_code: ?u16 = null,

    pub fn fromStruct(comptime T: type, value: T, allocator: std.mem.Allocator) !Response {
        const json_str = try json_module.Json.serialize(T, value, allocator);
        defer allocator.free(json_str);

        const persistent_body = dupePersistent(json_str) catch {
            return error.OutOfMemory;
        };

        var resp = Response{
            .inner = ziggurat.response.Response.json(persistent_body),
            ._persistent_body = persistent_body,
            ._custom_headers = null,
            ._status_code = null,
        };

        return resp.withContentType("application/json");
    }

    pub fn fromStructArray(comptime T: type, items: []const T, allocator: std.mem.Allocator) !Response {
        const json_str = try json_module.Json.serializeArray(T, items, allocator);
        defer allocator.free(json_str);

        const persistent_body = dupePersistent(json_str) catch {
            return error.OutOfMemory;
        };

        var resp = Response{
            .inner = ziggurat.response.Response.json(persistent_body),
            ._persistent_body = persistent_body,
            ._custom_headers = null,
            ._status_code = null,
        };

        return resp.withContentType("application/json");
    }

    pub fn json(body: []const u8) Response {
        const persistent_body = dupePersistent(body) catch {
            const error_msg = "{\"error\":\"Internal server error: Failed to allocate response memory\"}";
            return Response{
                .inner = ziggurat.response.Response.json(error_msg),
                ._persistent_body = null,
                ._custom_headers = null,
                ._status_code = 500,
            };
        };

        return Response{
            .inner = ziggurat.response.Response.json(persistent_body),
            ._persistent_body = persistent_body,
            ._custom_headers = null,
            ._status_code = null,
        };
    }

    pub fn text(body: []const u8) Response {
        const persistent_body = dupePersistent(body) catch {
            const error_msg = "Internal server error: Failed to allocate response memory";
            return Response{
                .inner = ziggurat.response.Response.text(error_msg),
                ._persistent_body = null,
                ._custom_headers = null,
                ._status_code = 500,
            };
        };

        return Response{
            .inner = ziggurat.response.Response.text(persistent_body),
            ._persistent_body = persistent_body,
            ._custom_headers = null,
            ._status_code = null,
        };
    }

    pub fn html(body: []const u8) Response {
        const persistent_body = dupePersistent(body) catch {
            const error_msg = "Internal server error: Failed to allocate response memory";
            return Response{
                .inner = ziggurat.response.Response.html(error_msg),
                ._persistent_body = null,
                ._custom_headers = null,
                ._status_code = 500,
            };
        };

        return Response{
            .inner = ziggurat.response.Response.html(persistent_body),
            ._persistent_body = persistent_body,
            ._custom_headers = null,
            ._status_code = null,
        };
    }

    pub fn serveFile(file_path: []const u8, contents: []const u8) Response {
        const mime_type = getMimeTypeFromPath(file_path);

        const persistent_body = dupePersistent(contents) catch {
            const response = Response.text(contents);
            return response.withContentType(mime_type);
        };

        var response = if (std.mem.eql(u8, mime_type, "text/html"))
            Response.html(persistent_body)
        else if (std.mem.eql(u8, mime_type, "text/css"))
            Response.text(persistent_body).withContentType("text/css")
        else if (std.mem.eql(u8, mime_type, "application/javascript"))
            Response.text(persistent_body).withContentType("application/javascript")
        else
            Response.text(persistent_body).withContentType(mime_type);

        response._persistent_body = persistent_body;
        return response;
    }

    fn getMimeTypeFromPath(file_path: []const u8) []const u8 {
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

    pub fn ok() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(200);
    }

    pub fn created() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(201);
    }

    pub fn noContent() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(204);
    }

    pub fn badRequest() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(400);
    }

    pub fn unauthorized() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(401);
    }

    pub fn forbidden() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(403);
    }

    pub fn notFound(message: []const u8) Response {
        const error_json = std.fmt.allocPrint(persistent_allocator, "{{\"error\":\"{s}\"}}", .{message}) catch {
            var resp = Response{
                .inner = ziggurat.response.Response.text(""),
                ._persistent_body = null,
                ._custom_headers = null,
                ._status_code = null,
            };
            return resp.withStatus(404);
        };
        var resp = Response.json(error_json);
        return resp.withStatus(404);
    }

    pub fn internalError() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(500);
    }

    pub fn errorResponse(message: []const u8, status_code: u16) Response {
        const error_json = std.fmt.allocPrint(persistent_allocator, "{{\"error\":\"{s}\"}}", .{message}) catch {
            return Response.internalError();
        };
        return Response.json(error_json).withStatus(status_code);
    }

    pub fn serverError(message: []const u8) Response {
        return Response.errorResponse(message, 500);
    }

    pub fn validationError(errors: *validation.ValidationErrors) Response {
        const error_json = errors.toJson() catch {
            return Response.serverError("Failed to serialize validation errors");
        };
        const persistent_json = dupePersistent(error_json) catch {
            errors.allocator.free(error_json); // Free original on allocation failure
            return Response.serverError("Failed to allocate validation error response");
        };
        errors.allocator.free(error_json); // Free original after successful duplication
        return Response.json(persistent_json).withStatus(400);
    }

    pub fn jsonFrom(comptime T: type, value: T, allocator: std.mem.Allocator) Response {
        const json_str = json_module.Json.serialize(T, value, allocator) catch {
            return Response.serverError("Failed to serialize response");
        };
        const persistent_json = dupePersistent(json_str) catch {
            allocator.free(json_str);
            return Response.serverError("Failed to allocate response");
        };
        allocator.free(json_str);
        return Response.json(persistent_json);
    }

    pub fn fromJsonValue(value: std.json.Value, allocator: std.mem.Allocator) Response {
        var output = std.ArrayList(u8).init(allocator);
        defer output.deinit();

        std.json.stringify(value, .{}, output.writer()) catch {
            return Response.serverError("Failed to serialize JSON value");
        };

        const persistent_json = dupePersistent(output.items) catch {
            return Response.serverError("Failed to allocate JSON response");
        };

        return Response.json(persistent_json);
    }

    pub fn fromJsonValueFmt(
        value: std.json.Value,
        options: std.json.StringifyOptions,
        allocator: std.mem.Allocator,
    ) Response {
        var output = std.ArrayList(u8).init(allocator);
        defer output.deinit();

        std.json.stringify(value, options, output.writer()) catch {
            return Response.serverError("Failed to serialize JSON value");
        };

        const persistent_json = dupePersistent(output.items) catch {
            return Response.serverError("Failed to allocate JSON response");
        };

        return Response.json(persistent_json);
    }

    pub fn noCache(self: Response) Response {
        return self
            .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
            .withHeader("Pragma", "no-cache")
            .withHeader("Expires", "0");
    }

    pub fn withJson(self: Response, body: []const u8) Response {
        const persistent_body = dupePersistent(body) catch {
            const error_msg = "{\"error\":\"Internal server error: Failed to allocate response memory\"}";
            const status_code = self._status_code orelse 500;
            return Response{
                .inner = ziggurat.response.Response.json(error_msg),
                ._persistent_body = null,
                ._custom_headers = self._custom_headers,
                ._status_code = status_code,
            };
        };

        return Response{
            .inner = ziggurat.response.Response.json(persistent_body),
            ._persistent_body = persistent_body,
            ._custom_headers = self._custom_headers,
            ._status_code = self._status_code,
        };
    }

    pub fn errorJson(message: []const u8, allocator: std.mem.Allocator) !Response {
        const error_msg = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message});
        return Response.json(error_msg).withStatus(500);
    }

    pub fn errorJsonWithStatus(message: []const u8, status_code: u16, allocator: std.mem.Allocator) !Response {
        const error_msg = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message});
        return Response.json(error_msg).withStatus(status_code);
    }

    pub fn successJson(data: []const u8, allocator: std.mem.Allocator) !Response {
        _ = allocator;
        return Response.json(data);
    }

    pub fn redirect(location: []const u8) Response {
        const persistent_location = dupePersistent(location) catch {
            var resp = Response{
                .inner = ziggurat.response.Response.text(""),
                ._persistent_body = null,
                ._custom_headers = null,
                ._status_code = null,
            };
            return resp.withStatus(302);
        };

        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = persistent_location,
            ._custom_headers = null,
            ._status_code = null,
        };
        resp = resp.withStatus(302);
        return resp.withHeader("Location", persistent_location);
    }

    pub fn status(status_code: u16) Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(status_code);
    }

    pub fn withContentType(self: Response, content_type: []const u8) Response {
        return Response{
            .inner = self.inner.withContentType(content_type),
            ._persistent_body = self._persistent_body,
            ._custom_headers = self._custom_headers,
            ._status_code = self._status_code,
        };
    }

    pub fn withStatus(self: Response, status_code: u16) Response {
        return Response{
            .inner = self.inner,
            ._persistent_body = self._persistent_body,
            ._custom_headers = self._custom_headers,
            ._status_code = status_code,
        };
    }

    pub fn withHeader(self: Response, name: []const u8, value: []const u8) Response {
        if (std.mem.eql(u8, name, "Content-Type")) {
            return self.withContentType(value);
        }

        const persistent_name = dupePersistent(name) catch return self;
        const persistent_value = dupePersistent(value) catch return self;

        if (self._custom_headers) |headers| {
            var headers_mut = headers;
            headers_mut.put(persistent_name, persistent_value) catch return self;
            return Response{
                .inner = self.inner,
                ._persistent_body = self._persistent_body,
                ._custom_headers = headers_mut,
                ._status_code = self._status_code,
            };
        } else {
            var new_headers = std.StringHashMap([]const u8).init(persistent_allocator);
            new_headers.put(persistent_name, persistent_value) catch return self;
            return Response{
                .inner = self.inner,
                ._persistent_body = self._persistent_body,
                ._custom_headers = new_headers,
                ._status_code = self._status_code,
            };
        }
    }

    pub fn fragment(body: []const u8) Response {
        return Response.html(body).withHeader("X-HTMX-Fragment", "true");
    }

    pub fn htmxTrigger(self: Response, event: []const u8) Response {
        return self.withHeader("HX-Trigger", event);
    }

    pub fn htmxTriggerAfterSwap(self: Response, event: []const u8) Response {
        return self.withHeader("HX-Trigger-After-Swap", event);
    }

    pub fn htmxTriggerAfterSettle(self: Response, event: []const u8) Response {
        return self.withHeader("HX-Trigger-After-Settle", event);
    }

    pub fn htmxRedirect(url: []const u8) Response {
        return Response.noContent().withHeader("HX-Redirect", url);
    }

    pub fn htmxRefresh() Response {
        return Response.noContent().withHeader("HX-Refresh", "true");
    }

    pub fn htmxPushUrl(self: Response, url: []const u8) Response {
        return self.withHeader("HX-Push-Url", url);
    }

    pub fn htmxReplaceUrl(self: Response, url: []const u8) Response {
        return self.withHeader("HX-Replace-Url", url);
    }

    pub fn htmxRetarget(self: Response, selector: []const u8) Response {
        return self.withHeader("HX-Retarget", selector);
    }

    pub fn htmxReswap(self: Response, style: []const u8) Response {
        return self.withHeader("HX-Reswap", style);
    }

    pub fn withCookie(self: Response, name: []const u8, value: []const u8, options: CookieOptions) Response {
        const persistent_name = dupePersistent(name) catch return self;
        const persistent_value = dupePersistent(value) catch {
            getBufferPool().release(@constCast(persistent_name));
            return self;
        };

        var cookie_header = std.ArrayListUnmanaged(u8){};
        cookie_header.writer(persistent_allocator).print("{s}={s}", .{ persistent_name, persistent_value }) catch {
            persistent_allocator.free(persistent_name);
            persistent_allocator.free(persistent_value);
            return self;
        };

        if (options.maxAge) |age| {
            cookie_header.writer(persistent_allocator).print("; Max-Age={d}", .{age}) catch {};
        }

        if (options.domain) |domain| {
            cookie_header.writer(persistent_allocator).print("; Domain={s}", .{domain}) catch {};
        }

        if (options.path) |path| {
            cookie_header.writer(persistent_allocator).print("; Path={s}", .{path}) catch {};
        }

        if (options.secure) {
            cookie_header.writer(persistent_allocator).print("; Secure", .{}) catch {};
        }

        if (options.httpOnly) {
            cookie_header.writer(persistent_allocator).print("; HttpOnly", .{}) catch {};
        }

        const cookie_str = cookie_header.toOwnedSlice(persistent_allocator) catch return self;

        return self.withHeader("Set-Cookie", cookie_str);
    }

    pub fn fromFile(file_path: []const u8, allocator: std.mem.Allocator) !Response {
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            return err;
        };
        defer file.close();

        const stat = file.stat() catch |err| {
            return err;
        };

        const file_size = @as(usize, @intCast(stat.size));
        const contents = allocator.alloc(u8, file_size) catch |err| {
            return err;
        };
        defer allocator.free(contents);

        const bytes_read = file.readAll(contents) catch |err| {
            return err;
        };
        if (bytes_read != contents.len) {
            return error.EndOfStream;
        }

        const persistent_body = dupePersistent(contents) catch {
            return error.OutOfMemory;
        };

        const mime_type = getMimeTypeFromPath(file_path);
        var resp = Response{
            .inner = ziggurat.response.Response.text(persistent_body),
            ._persistent_body = persistent_body,
            ._custom_headers = null,
            ._status_code = null,
        };

        return resp.withContentType(mime_type);
    }

    pub fn download(filename: []const u8, data: []const u8) Response {
        const persistent_data = dupePersistent(data) catch {
            const error_msg = "Internal server error: Failed to allocate response memory";
            return Response{
                .inner = ziggurat.response.Response.text(error_msg),
                ._persistent_body = null,
                ._custom_headers = null,
                ._status_code = 500,
            };
        };

        var resp = Response{
            .inner = ziggurat.response.Response.text(persistent_data),
            ._persistent_body = persistent_data,
        };

        _ = filename;

        return resp.withContentType("application/octet-stream");
    }

    pub fn stream(content_type: []const u8, data: []const u8) Response {
        const persistent_data = dupePersistent(data) catch {
            const error_msg = "Internal server error: Failed to allocate response memory";
            return Response{
                .inner = ziggurat.response.Response.text(error_msg),
                ._persistent_body = null,
                ._custom_headers = null,
                ._status_code = 500,
            };
        };

        var resp = Response{
            .inner = ziggurat.response.Response.text(persistent_data),
            ._persistent_body = persistent_data,
        };

        return resp.withContentType(content_type);
    }

    pub fn getBody(self: Response) []const u8 {
        if (self._persistent_body) |body| {
            return body;
        }
        return "";
    }

    fn serializeHeaders(headers: std.StringHashMap([]const u8), allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(allocator);

        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            const name = entry.key_ptr.*;
            const value = entry.value_ptr.*;

            if (std.mem.indexOf(u8, name, "\r") != null or std.mem.indexOf(u8, name, "\n") != null) {
                return error.InvalidHeader;
            }

            const header_line = try std.fmt.allocPrint(allocator, "{s}: {s}\r\n", .{ name, value });
            defer allocator.free(header_line);
            try result.appendSlice(allocator, header_line);
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn formatWithHeaders(self: Response, allocator: std.mem.Allocator) ![]const u8 {
        const base_response = self.inner.format() catch |err| {
            return err;
        };
        defer std.heap.page_allocator.free(base_response);

        const has_custom_headers = if (self._custom_headers) |headers| headers.count() > 0 else false;
        if (!has_custom_headers and self._status_code == null) {
            return try allocator.dupe(u8, base_response);
        }

        const header_end = std.mem.indexOf(u8, base_response, "\r\n\r\n") orelse {
            return try allocator.dupe(u8, base_response);
        };

        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(allocator);

        if (self._status_code) |status_code| {
            const status_line_end = std.mem.indexOf(u8, base_response, "\r\n") orelse {
                return try allocator.dupe(u8, base_response);
            };

            const reason_phrase = getReasonPhrase(status_code);

            const status_line = try std.fmt.allocPrint(allocator, "HTTP/1.1 {d} {s}\r\n", .{ status_code, reason_phrase });
            defer allocator.free(status_line);
            try result.appendSlice(allocator, status_line);

            const headers_start = status_line_end + 2; // Skip "\r\n"
            try result.appendSlice(allocator, base_response[headers_start..header_end]);
        } else {
            try result.appendSlice(allocator, base_response[0..header_end]);
        }

        if (has_custom_headers) {
            const custom_headers_str = try serializeHeaders(self._custom_headers.?, allocator);
            defer allocator.free(custom_headers_str);
            try result.appendSlice(allocator, custom_headers_str);
        }

        try result.appendSlice(allocator, "\r\n");

        const body_start = header_end + 4; // Skip "\r\n\r\n"
        if (body_start < base_response.len) {
            try result.appendSlice(allocator, base_response[body_start..]);
        }

        return result.toOwnedSlice(allocator);
    }

    fn getReasonPhrase(status_code: u16) []const u8 {
        return switch (status_code) {
            200 => "OK",
            201 => "Created",
            202 => "Accepted",
            204 => "No Content",
            301 => "Moved Permanently",
            302 => "Found",
            304 => "Not Modified",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            409 => "Conflict",
            422 => "Unprocessable Entity",
            429 => "Too Many Requests",
            500 => "Internal Server Error",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            504 => "Gateway Timeout",
            else => "Unknown",
        };
    }

    pub fn toZiggurat(self: Response) ziggurat.response.Response {
        markBufferForRelease(self._persistent_body);

        const has_custom_headers = if (self._custom_headers) |headers| headers.count() > 0 else false;
        if (has_custom_headers or self._status_code != null) {
            const formatted = self.formatWithHeaders(std.heap.page_allocator) catch {
                return self.inner;
            };

            formatted_responses_mutex.lock();
            defer formatted_responses_mutex.unlock();

            if (formatted_responses == null) {
                formatted_responses = std.AutoHashMap(*const anyopaque, []const u8).init(std.heap.page_allocator);
            }

            const response_ptr: *const anyopaque = @ptrCast(&self.inner);
            formatted_responses.?.put(response_ptr, formatted) catch {
                std.heap.page_allocator.free(formatted);
                return self.inner;
            };
        }

        return self.inner;
    }

    pub fn getFormattedResponse(ziggurat_resp: *const ziggurat.response.Response) ?[]const u8 {
        formatted_responses_mutex.lock();
        defer formatted_responses_mutex.unlock();

        if (formatted_responses) |*map| {
            const response_ptr: *const anyopaque = @ptrCast(ziggurat_resp);
            return map.get(response_ptr);
        }

        return null;
    }

    pub fn clearFormattedResponse(ziggurat_resp: *const ziggurat.response.Response) void {
        formatted_responses_mutex.lock();
        defer formatted_responses_mutex.unlock();

        if (formatted_responses) |*map| {
            const response_ptr: *const anyopaque = @ptrCast(ziggurat_resp);
            if (map.fetchRemove(response_ptr)) |entry| {
                std.heap.page_allocator.free(entry.value);
            }
        }
    }

    pub fn hasCustomHeaders(self: Response) bool {
        if (self._custom_headers) |headers| {
            return headers.count() > 0;
        }
        return false;
    }

    pub fn getCustomHeaders(self: Response) ?std.StringHashMap([]const u8) {
        return self._custom_headers;
    }

    pub fn fromZiggurat(ziggurat_response: ziggurat.response.Response) Response {
        return Response{
            .inner = ziggurat_response,
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
    }

    pub fn releaseBuffer(self: *Response) void {
        if (self._persistent_body) |body| {
            getBufferPool().release(@constCast(body));
            self._persistent_body = null;
        }
    }

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        if (self._persistent_body) |body| {
            std.heap.page_allocator.free(body);
            self._persistent_body = null;
        }

        if (self._custom_headers) |*headers| {
            var iter = headers.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            headers.deinit();
            self._custom_headers = null;
        }
    }
};

test "Response json" {
    const resp = Response.json("{\"test\":\"data\"}");
    _ = resp;
}

test "Response text" {
    const resp = Response.text("Hello, World!");
    _ = resp;
}

test "Response html" {
    const resp = Response.html("<html><body>Test</body></html>");
    _ = resp;
}

test "Response formatWithHeaders - no custom headers" {
    const allocator = std.testing.allocator;
    const resp = Response.text("test data");
    const formatted = resp.formatWithHeaders(allocator) catch |err| {
        if (err == error.OutOfMemory) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "HTTP/1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "test data") != null);
}

test "Response formatWithHeaders - single custom header" {
    const allocator = std.testing.allocator;
    var resp = Response.text("test data");
    resp = resp.withHeader("X-Custom-Header", "custom-value");
    const formatted = resp.formatWithHeaders(allocator) catch |err| {
        if (err == error.OutOfMemory) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "X-Custom-Header: custom-value") != null);
}

test "Response formatWithHeaders - multiple custom headers" {
    const allocator = std.testing.allocator;
    var resp = Response.text("test data");
    resp = resp.withHeader("X-Header-1", "value1");
    resp = resp.withHeader("X-Header-2", "value2");
    const formatted = resp.formatWithHeaders(allocator) catch |err| {
        if (err == error.OutOfMemory) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "X-Header-1: value1") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "X-Header-2: value2") != null);
}

test "Response formatWithHeaders - status code modification" {
    const allocator = std.testing.allocator;
    var resp = Response.text("not found");
    resp = resp.withStatus(404);
    const formatted = resp.formatWithHeaders(allocator) catch |err| {
        if (err == error.OutOfMemory) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "HTTP/1.1 404 Not Found") != null);
}

test "Response formatWithHeaders - status code and custom headers" {
    const allocator = std.testing.allocator;
    var resp = Response.text("unauthorized");
    resp = resp.withStatus(401);
    resp = resp.withHeader("WWW-Authenticate", "Basic realm=\"test\"");
    const formatted = resp.formatWithHeaders(allocator) catch |err| {
        if (err == error.OutOfMemory) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "HTTP/1.1 401 Unauthorized") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "WWW-Authenticate: Basic realm=\"test\"") != null);
}

test "Response serializeHeaders - multiple headers" {
    const allocator = std.testing.allocator;
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try headers.put("Header1", "value1");
    try headers.put("Header2", "value2");

    const serialized = try Response.serializeHeaders(headers, allocator);
    defer allocator.free(serialized);

    try std.testing.expect(std.mem.indexOf(u8, serialized, "Header1: value1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "Header2: value2\r\n") != null);
}

test "Response getReasonPhrase - various status codes" {
    try std.testing.expectEqualStrings("OK", Response.getReasonPhrase(200));
    try std.testing.expectEqualStrings("Created", Response.getReasonPhrase(201));
    try std.testing.expectEqualStrings("Not Found", Response.getReasonPhrase(404));
    try std.testing.expectEqualStrings("Internal Server Error", Response.getReasonPhrase(500));
    try std.testing.expectEqualStrings("Unknown", Response.getReasonPhrase(999));
}

test "Response withContentType" {
    const resp = Response.text("test").withContentType("application/json");
    _ = resp;
}

test "Response withStatus" {
    const resp = Response.text("test").withStatus(404);
    _ = resp;
}

test "Response ok" {
    const resp = Response.ok();
    _ = resp;
}

test "Response created" {
    const resp = Response.created();
    _ = resp;
}

test "Response noContent" {
    const resp = Response.noContent();
    _ = resp;
}

test "Response badRequest" {
    const resp = Response.badRequest();
    _ = resp;
}

test "Response unauthorized" {
    const resp = Response.unauthorized();
    _ = resp;
}

test "Response forbidden" {
    const resp = Response.forbidden();
    _ = resp;
}

test "Response notFound" {
    const resp = Response.notFound("Not found");
    _ = resp;
}

test "Response internalError" {
    const resp = Response.internalError();
    _ = resp;
}

test "Response redirect" {
    const resp = Response.redirect("/login");
    _ = resp;
}

test "Response status" {
    const resp = Response.status(418);
    _ = resp;
}

test "Response fluent builder chain" {
    const resp = Response.ok()
        .withContentType("application/json")
        .withStatus(200);
    _ = resp;
}

test "Response memory safety - body from arena" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const arena_allocator = gpa.allocator();

    const temp_body = try arena_allocator.dupe(u8, "{\"test\":\"data\"}");

    const resp = Response.json(temp_body);

    arena_allocator.free(temp_body);

    _ = resp;
}

test "Response empty string bodies" {
    const resp1 = Response.json("");
    _ = resp1;

    const resp2 = Response.text("");
    _ = resp2;

    const resp3 = Response.html("");
    _ = resp3;
}

test "Response download creates correct response" {
    const resp = Response.download("report.pdf", "PDF content");
    _ = resp;
}

test "Response stream creates correct response" {
    const resp = Response.stream("text/plain", "stream data");
    _ = resp;
}

test "Response withCookie with all options" {
    var resp = Response.ok();
    resp = resp.withCookie("session", "abc123", .{
        .maxAge = 3600,
        .domain = "example.com",
        .path = "/",
        .secure = true,
        .httpOnly = true,
    });
    const ziggurat_resp = resp.toZiggurat();
    _ = ziggurat_resp;
}

test "Response redirect with custom location" {
    const resp1 = Response.redirect("/login");
    _ = resp1;

    const resp2 = Response.redirect("/dashboard");
    _ = resp2;
}

test "Response all status code helpers" {
    const ok = Response.ok();
    _ = ok;

    const created = Response.created();
    _ = created;

    const noContent = Response.noContent();
    _ = noContent;

    const badRequest = Response.badRequest();
    _ = badRequest;

    const unauthorized = Response.unauthorized();
    _ = unauthorized;

    const forbidden = Response.forbidden();
    _ = forbidden;

    const notFound = Response.notFound("Not found");
    _ = notFound;

    const internalError = Response.internalError();
    _ = internalError;
}

test "Response status with custom code" {
    const resp = Response.status(418);
    _ = resp;
}

test "Response fluent chaining" {
    const resp = Response.text("Hello")
        .withContentType("text/plain")
        .withStatus(200)
        .withHeader("X-Custom", "value");
    _ = resp;
}

test "Response fromZiggurat creates wrapper" {
    const ziggurat_resp = ziggurat.response.Response.text("test");
    const resp = Response.fromZiggurat(ziggurat_resp);
    _ = resp;
}

test "Response toZiggurat converts back" {
    const resp = Response.text("test");
    const ziggurat_resp = resp.toZiggurat();
    _ = ziggurat_resp;
}
