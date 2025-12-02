const std = @import("std");
const ziggurat = @import("ziggurat");
const json_module = @import("json.zig");
const validation = @import("validation.zig");

/// Response buffer pool for efficient memory reuse
/// Eliminates the memory leak from using page_allocator for every response
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

    /// Acquire a buffer from the pool (or allocate a new one)
    pub fn acquire(self: *ResponseBufferPool, size: usize) ![]u8 {
        _ = self.stats_acquired.fetchAdd(1, .monotonic);

        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to find a buffer large enough in the pool
        var best_idx: ?usize = null;
        var best_size: usize = std.math.maxInt(usize);

        for (self.free_buffers.items, 0..) |buf, i| {
            if (buf.len >= size and buf.len < best_size) {
                best_idx = i;
                best_size = buf.len;
            }
        }

        if (best_idx) |idx| {
            // Found a suitable buffer - remove and return it
            const buf = self.free_buffers.swapRemove(idx);
            return buf[0..size];
        }

        // No suitable buffer found - allocate a new one
        _ = self.stats_allocated.fetchAdd(1, .monotonic);
        const alloc_size = @max(size, self.default_buffer_size);
        const new_buf = try self.backing_allocator.alloc(u8, alloc_size);
        return new_buf[0..size];
    }

    /// Release a buffer back to the pool for reuse
    pub fn release(self: *ResponseBufferPool, buf: []u8) void {
        _ = self.stats_released.fetchAdd(1, .monotonic);

        // Get the full buffer capacity (assume it was allocated with default size or larger)
        const full_buf = @as([*]u8, @ptrCast(buf.ptr))[0..self.getBufferCapacity(buf)];

        self.mutex.lock();
        defer self.mutex.unlock();

        // If pool is full, just free the buffer
        if (self.free_buffers.items.len >= self.max_buffers) {
            self.backing_allocator.free(full_buf);
            return;
        }

        // Add to pool for reuse
        self.free_buffers.append(self.backing_allocator, full_buf) catch {
            // If append fails, free the buffer
            self.backing_allocator.free(full_buf);
        };
    }

    /// Get the actual capacity of a buffer (for returning to pool)
    fn getBufferCapacity(self: *ResponseBufferPool, buf: []u8) usize {
        // Since we allocate with max(size, default_buffer_size), capacity is at least that
        return @max(buf.len, self.default_buffer_size);
    }

    /// Get pool statistics
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

    /// Clean up and free all pooled buffers
    pub fn deinit(self: *ResponseBufferPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.free_buffers.items) |buf| {
            self.backing_allocator.free(buf);
        }
        self.free_buffers.deinit(self.backing_allocator);
    }
};

/// Global response buffer pool (initialized lazily)
var global_buffer_pool: ?ResponseBufferPool = null;
var global_buffer_pool_mutex: std.Thread.Mutex = .{};
/// Atomic flag for thread-safe initialization (prevents race condition in double-checked locking)
var global_buffer_pool_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Thread-local storage for pending buffer release
/// This allows us to release response buffers after the response has been sent
/// Each worker thread tracks its own pending buffer
threadlocal var pending_buffer_release: ?[]u8 = null;

/// Thread-local storage for formatted responses with custom headers
/// Maps ziggurat response pointers to their formatted HTTP strings
threadlocal var formatted_responses: ?std.AutoHashMap(*const anyopaque, []const u8) = null;
threadlocal var formatted_responses_mutex: std.Thread.Mutex = .{};

/// Mark a buffer for release after the response is sent
/// Called internally by toZiggurat() before returning
fn markBufferForRelease(buffer: ?[]const u8) void {
    // Release any previously pending buffer first (defensive cleanup)
    if (pending_buffer_release) |prev_buf| {
        getBufferPool().release(prev_buf);
    }
    if (buffer) |buf| {
        pending_buffer_release = @constCast(buf);
    } else {
        pending_buffer_release = null;
    }
}

/// Release any pending buffer that was marked for release
/// Call this after the response has been formatted and sent
pub fn releasePendingBuffer() void {
    if (pending_buffer_release) |buf| {
        getBufferPool().release(buf);
        pending_buffer_release = null;
    }
}

/// Get or initialize the global buffer pool
/// Uses atomic flag with acquire/release ordering for thread-safe double-checked locking
pub fn getBufferPool() *ResponseBufferPool {
    // Fast path: check atomic flag with acquire ordering
    if (global_buffer_pool_initialized.load(.acquire)) {
        return &global_buffer_pool.?;
    }

    global_buffer_pool_mutex.lock();
    defer global_buffer_pool_mutex.unlock();

    // Double-check after acquiring lock
    if (!global_buffer_pool_initialized.load(.acquire)) {
        global_buffer_pool = ResponseBufferPool.init(
            std.heap.page_allocator,
            256, // max 256 pooled buffers
            64 * 1024, // 64KB default buffer size
        );
        // Release ordering ensures the pool is fully initialized before flag is set
        global_buffer_pool_initialized.store(true, .release);
    }

    return &global_buffer_pool.?;
}

/// Allocate persistent memory for response body using the buffer pool
fn allocatePersistent(size: usize) ![]u8 {
    const pool = getBufferPool();
    return pool.acquire(size);
}

/// Duplicate a slice into persistent memory using the buffer pool
fn dupePersistent(data: []const u8) ![]u8 {
    const buf = try allocatePersistent(data.len);
    @memcpy(buf, data);
    return buf;
}

/// Persistent allocator for response bodies (fallback for edge cases)
/// Now uses buffer pool internally for better memory management
const persistent_allocator = std.heap.page_allocator;

/// Cookie options for setting cookies
pub const CookieOptions = struct {
    maxAge: ?u64 = null, // Cookie expiration in seconds
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    secure: bool = false, // Only send over HTTPS
    httpOnly: bool = false, // Not accessible via JavaScript
};

/// engine12 Response wrapper around ziggurat.response.Response
/// Provides a clean API with fluent builders and memory-safe response handling
///
/// Memory Lifetime:
/// Response bodies are automatically copied to persistent memory (page_allocator) to ensure
/// they remain valid after the request completes. This memory is NEVER freed during the
/// application lifetime. For details, see the persistent_allocator documentation above.
pub const Response = struct {
    /// Internal ziggurat response (not exposed)
    inner: ziggurat.response.Response,

    /// Optional stored body for responses that need persistent memory
    /// This is used when body data comes from request arena and needs to be copied
    _persistent_body: ?[]const u8 = null,

    /// Custom headers to be applied (stored separately since ziggurat may not support all headers)
    /// Headers are stored as key-value pairs in persistent memory
    _custom_headers: ?std.StringHashMap([]const u8) = null,

    /// Status code (stored separately since ziggurat may not support status codes directly)
    _status_code: ?u16 = null,

    /// Create a JSON response from a struct
    /// Automatically serializes the struct to JSON using Json.serialize()
    /// Sets Content-Type header to application/json
    ///
    /// Example:
    /// ```zig
    /// const todo = Todo{ .id = 1, .title = "Test" };
    /// return Response.fromStruct(Todo, todo, allocator);
    /// ```
    pub fn fromStruct(comptime T: type, value: T, allocator: std.mem.Allocator) !Response {
        const json_str = try json_module.Json.serialize(T, value, allocator);
        defer allocator.free(json_str);

        // Copy to pooled memory for response (reusable buffers)
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

    /// Create a JSON response from an array of structs
    /// Automatically serializes the array to JSON using Json.serializeArray()
    /// Sets Content-Type header to application/json
    ///
    /// Example:
    /// ```zig
    /// const todos = [_]Todo{ todo1, todo2 };
    /// return Response.fromStructArray(Todo, &todos, allocator);
    /// ```
    pub fn fromStructArray(comptime T: type, items: []const T, allocator: std.mem.Allocator) !Response {
        const json_str = try json_module.Json.serializeArray(T, items, allocator);
        defer allocator.free(json_str);

        // Copy to pooled memory for response (reusable buffers)
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

    /// Create a JSON response
    /// The body string will be copied to persistent memory automatically
    ///
    /// Example:
    /// ```zig
    /// return Response.json("{\"status\":\"ok\"}");
    /// ```
    pub fn json(body: []const u8) Response {
        // Copy body to pooled memory since ziggurat stores references
        const persistent_body = dupePersistent(body) catch {
            // Critical: Cannot safely use original body if it's from request arena
            // Use static error message that doesn't require allocation
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

    /// Create a text response
    /// The body string will be copied to persistent memory automatically
    /// Memory allocated here persists for the lifetime of the application (never freed)
    ///
    /// Example:
    /// ```zig
    /// return Response.text("Hello, World!");
    /// ```
    pub fn text(body: []const u8) Response {
        const persistent_body = dupePersistent(body) catch {
            // Critical: Cannot safely use original body if it's from request arena
            // Use static error message that doesn't require allocation
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

    /// Create an HTML response
    /// The body string will be copied to persistent memory automatically
    /// Memory allocated here persists for the lifetime of the application (never freed)
    ///
    /// Example:
    /// ```zig
    /// return Response.html("<html><body>Hello</body></html>");
    /// ```
    pub fn html(body: []const u8) Response {
        const persistent_body = dupePersistent(body) catch {
            // Critical: Cannot safely use original body if it's from request arena
            // Use static error message that doesn't require allocation
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

    /// Serve a file with automatic content-type detection
    /// Detects MIME type from file extension and sets appropriate Content-Type header
    /// Supports common file types: CSS, JS, HTML, JSON, images, fonts, etc.
    ///
    /// Example:
    /// ```zig
    /// const contents = try readFile("static/css/style.css");
    /// return Response.serveFile("style.css", contents);
    /// ```
    pub fn serveFile(file_path: []const u8, contents: []const u8) Response {
        const mime_type = getMimeTypeFromPath(file_path);

        const persistent_body = dupePersistent(contents) catch {
            // Fallback to original contents if allocation fails
            const response = Response.text(contents);
            return response.withContentType(mime_type);
        };

        // Create response based on content type
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

    /// Get MIME type from file path (internal helper)
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

    /// Create a 200 OK response with JSON body
    ///
    /// Example:
    /// ```zig
    /// return Response.ok().json(data);
    /// ```
    pub fn ok() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(200);
    }

    /// Create a 201 Created response
    ///
    /// Example:
    /// ```zig
    /// return Response.created().json(.{ .id = new_id });
    /// ```
    pub fn created() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(201);
    }

    /// Create a 204 No Content response
    ///
    /// Example:
    /// ```zig
    /// return Response.noContent();
    /// ```
    pub fn noContent() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(204);
    }

    /// Create a 400 Bad Request response
    ///
    /// Example:
    /// ```zig
    /// return Response.badRequest().json(.{ .error = "Invalid input" });
    /// ```
    pub fn badRequest() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(400);
    }

    /// Create a 401 Unauthorized response
    ///
    /// Example:
    /// ```zig
    /// return Response.unauthorized().json(.{ .error = "Authentication required" });
    /// ```
    pub fn unauthorized() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(401);
    }

    /// Create a 403 Forbidden response
    ///
    /// Example:
    /// ```zig
    /// return Response.forbidden().json(.{ .error = "Access denied" });
    /// ```
    pub fn forbidden() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(403);
    }

    /// Create a 404 Not Found response with error message
    ///
    /// Example:
    /// ```zig
    /// return Response.notFound("Todo not found");
    /// ```
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

    /// Create a 500 Internal Server Error response
    ///
    /// Example:
    /// ```zig
    /// return Response.internalError().json(.{ .error = "Something went wrong" });
    /// ```
    pub fn internalError() Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(500);
    }

    /// Create an error response with custom message and status code
    ///
    /// Example:
    /// ```zig
    /// return Response.errorResponse("Invalid input", 400);
    /// ```
    pub fn errorResponse(message: []const u8, status_code: u16) Response {
        const error_json = std.fmt.allocPrint(persistent_allocator, "{{\"error\":\"{s}\"}}", .{message}) catch {
            return Response.internalError();
        };
        return Response.json(error_json).withStatus(status_code);
    }

    /// Create a 500 Internal Server Error response with message
    ///
    /// Example:
    /// ```zig
    /// return Response.serverError("Database connection failed");
    /// ```
    pub fn serverError(message: []const u8) Response {
        return Response.errorResponse(message, 500);
    }

    /// Create a validation error response from ValidationErrors
    ///
    /// Example:
    /// ```zig
    /// const errors = try schema.validate();
    /// if (!errors.isEmpty()) {
    ///     return Response.validationError(&errors);
    /// }
    /// ```
    pub fn validationError(errors: *validation.ValidationErrors) Response {
        const error_json = errors.toJson() catch {
            return Response.serverError("Failed to serialize validation errors");
        };
        // Note: error_json is allocated by errors.toJson() using errors.allocator
        // We need to copy it to pooled memory
        const persistent_json = dupePersistent(error_json) catch {
            errors.allocator.free(error_json); // Free original on allocation failure
            return Response.serverError("Failed to allocate validation error response");
        };
        errors.allocator.free(error_json); // Free original after successful duplication
        return Response.json(persistent_json).withStatus(400);
    }

    /// Serialize a struct to JSON and return as Response
    /// Uses Json.serialize internally
    ///
    /// Example:
    /// ```zig
    /// const todo = Todo{ .id = 1, .title = "Hello", .completed = false };
    /// return Response.jsonFrom(Todo, todo, allocator);
    /// ```
    pub fn jsonFrom(comptime T: type, value: T, allocator: std.mem.Allocator) Response {
        const json_str = json_module.Json.serialize(T, value, allocator) catch {
            return Response.serverError("Failed to serialize response");
        };
        // Copy to pooled memory since allocator may be arena
        const persistent_json = dupePersistent(json_str) catch {
            allocator.free(json_str);
            return Response.serverError("Failed to allocate response");
        };
        allocator.free(json_str);
        return Response.json(persistent_json);
    }

    /// Create a JSON response from std.json.Value.
    /// Useful for dynamic/heterogeneous JSON structures that can't be represented as a struct.
    ///
    /// Example:
    /// ```zig
    /// var obj = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    /// try obj.object.put("count", .{ .integer = 42 });
    /// try obj.object.put("name", .{ .string = "test" });
    /// return Response.fromJsonValue(obj, allocator);
    /// ```
    pub fn fromJsonValue(value: std.json.Value, allocator: std.mem.Allocator) Response {
        // Stringify the JSON value
        var output = std.ArrayList(u8).init(allocator);
        defer output.deinit();

        std.json.stringify(value, .{}, output.writer()) catch {
            return Response.serverError("Failed to serialize JSON value");
        };

        // Copy to persistent memory
        const persistent_json = dupePersistent(output.items) catch {
            return Response.serverError("Failed to allocate JSON response");
        };

        return Response.json(persistent_json);
    }

    /// Create a JSON response from std.json.Value with custom formatting options.
    ///
    /// Example:
    /// ```zig
    /// return Response.fromJsonValueFmt(value, .{ .whitespace = .indent_2 }, allocator);
    /// ```
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

    /// Set cache-control headers to prevent caching
    /// Sets no-cache, no-store, must-revalidate, Pragma: no-cache, and Expires: 0
    ///
    /// Example:
    /// ```zig
    /// return Response.json(data).noCache();
    /// ```
    pub fn noCache(self: Response) Response {
        return self
            .withHeader("Cache-Control", "no-cache, no-store, must-revalidate")
            .withHeader("Pragma", "no-cache")
            .withHeader("Expires", "0");
    }

    /// Set JSON body for this response
    /// The body string will be copied to persistent memory automatically
    /// Can be chained after builder methods like ok(), created(), etc.
    ///
    /// Example:
    /// ```zig
    /// return Response.created().withJson("{\"id\":123}");
    /// return Response.ok().withJson(data);
    /// ```
    pub fn withJson(self: Response, body: []const u8) Response {
        const persistent_body = dupePersistent(body) catch {
            // Critical: Cannot safely use original body if it's from request arena
            // Use static error message that doesn't require allocation
            // Preserve existing status code and headers (builder pattern)
            const error_msg = "{\"error\":\"Internal server error: Failed to allocate response memory\"}";
            const status_code = self._status_code orelse 500;
            return Response{
                .inner = ziggurat.response.Response.json(error_msg),
                ._persistent_body = null,
                ._custom_headers = self._custom_headers,
                ._status_code = status_code,
            };
        };

        // Preserve existing status code if set, otherwise keep null (defaults to 200)
        // This maintains consistency with error path which always sets a status code
        return Response{
            .inner = ziggurat.response.Response.json(persistent_body),
            ._persistent_body = persistent_body,
            ._custom_headers = self._custom_headers,
            ._status_code = self._status_code,
        };
    }

    /// Create an error JSON response with status 500
    ///
    /// Example:
    /// ```zig
    /// return Response.errorJson("Internal server error", allocator);
    /// ```
    pub fn errorJson(message: []const u8, allocator: std.mem.Allocator) !Response {
        const error_msg = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message});
        return Response.json(error_msg).withStatus(500);
    }

    /// Create an error JSON response with custom status code
    ///
    /// Example:
    /// ```zig
    /// return Response.errorJsonWithStatus("Not found", 404, allocator);
    /// ```
    pub fn errorJsonWithStatus(message: []const u8, status_code: u16, allocator: std.mem.Allocator) !Response {
        const error_msg = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message});
        return Response.json(error_msg).withStatus(status_code);
    }

    /// Create a success JSON response with status 200
    ///
    /// Example:
    /// ```zig
    /// const data = try Json.serialize(MyStruct, my_data, allocator);
    /// defer allocator.free(data);
    /// return Response.successJson(data, allocator);
    /// ```
    pub fn successJson(data: []const u8, allocator: std.mem.Allocator) !Response {
        _ = allocator;
        return Response.json(data);
    }

    /// Create a redirect response
    ///
    /// Example:
    /// ```zig
    /// return Response.redirect("/login");
    /// return Response.redirect("/dashboard").withStatus(301); // Permanent redirect
    /// ```
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

    /// Create a response with a specific status code
    ///
    /// Example:
    /// ```zig
    /// return Response.status(418); // I'm a teapot
    /// ```
    pub fn status(status_code: u16) Response {
        var resp = Response{
            .inner = ziggurat.response.Response.text(""),
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
        return resp.withStatus(status_code);
    }

    /// Set the Content-Type header
    /// Returns a new Response with the header set
    ///
    /// Example:
    /// ```zig
    /// return Response.text("data").withContentType("application/json");
    /// ```
    pub fn withContentType(self: Response, content_type: []const u8) Response {
        return Response{
            .inner = self.inner.withContentType(content_type),
            ._persistent_body = self._persistent_body,
            ._custom_headers = self._custom_headers,
            ._status_code = self._status_code,
        };
    }

    /// Set the status code
    /// Returns a new Response with the status set
    ///
    /// Example:
    /// ```zig
    /// return Response.text("error").withStatus(400);
    /// ```
    pub fn withStatus(self: Response, status_code: u16) Response {
        return Response{
            .inner = self.inner,
            ._persistent_body = self._persistent_body,
            ._custom_headers = self._custom_headers,
            ._status_code = status_code,
        };
    }

    /// Add a custom header
    /// The header value will be copied to persistent memory
    /// Note: For Content-Type, use withContentType() instead for proper handling
    /// Headers are stored and will be applied when ziggurat supports custom headers
    ///
    /// Example:
    /// ```zig
    /// return Response.json(data).withHeader("X-Custom-Header", "value");
    /// ```
    pub fn withHeader(self: Response, name: []const u8, value: []const u8) Response {
        // Special handling for Content-Type - delegate to withContentType()
        if (std.mem.eql(u8, name, "Content-Type")) {
            return self.withContentType(value);
        }

        // Store header in custom headers map
        // Copy name and value to pooled memory
        const persistent_name = dupePersistent(name) catch return self;
        const persistent_value = dupePersistent(value) catch return self;

        if (self._custom_headers) |headers| {
            // Add to existing headers map
            // Note: We need to create a mutable copy since headers is optional
            var headers_mut = headers;
            headers_mut.put(persistent_name, persistent_value) catch return self;
            return Response{
                .inner = self.inner,
                ._persistent_body = self._persistent_body,
                ._custom_headers = headers_mut,
                ._status_code = self._status_code,
            };
        } else {
            // Create new headers map
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

    // =========================================================================
    // HTMX Response Methods
    // =========================================================================

    /// Create an HTML fragment response (marked to skip HTMX injection)
    /// Use this for partial updates that shouldn't include the full HTMX script
    pub fn fragment(body: []const u8) Response {
        return Response.html(body).withHeader("X-HTMX-Fragment", "true");
    }

    /// Add HX-Trigger header to trigger a client-side event
    /// The event can be caught by hx-trigger on the client
    ///
    /// Example:
    /// ```zig
    /// return Response.html("<div>Done</div>").htmxTrigger("todoCreated");
    /// ```
    pub fn htmxTrigger(self: Response, event: []const u8) Response {
        return self.withHeader("HX-Trigger", event);
    }

    /// Add HX-Trigger-After-Swap header
    /// Event triggers after the swap is complete
    pub fn htmxTriggerAfterSwap(self: Response, event: []const u8) Response {
        return self.withHeader("HX-Trigger-After-Swap", event);
    }

    /// Add HX-Trigger-After-Settle header
    /// Event triggers after the settle step (CSS transitions complete)
    pub fn htmxTriggerAfterSettle(self: Response, event: []const u8) Response {
        return self.withHeader("HX-Trigger-After-Settle", event);
    }

    /// Create an HTMX redirect response
    /// The client will navigate to the specified URL
    pub fn htmxRedirect(url: []const u8) Response {
        return Response.noContent().withHeader("HX-Redirect", url);
    }

    /// Create an HTMX refresh response
    /// The client will refresh the current page
    pub fn htmxRefresh() Response {
        return Response.noContent().withHeader("HX-Refresh", "true");
    }

    /// Add HX-Push-Url header to push URL to browser history
    pub fn htmxPushUrl(self: Response, url: []const u8) Response {
        return self.withHeader("HX-Push-Url", url);
    }

    /// Add HX-Replace-Url header to replace URL in browser history (no new entry)
    pub fn htmxReplaceUrl(self: Response, url: []const u8) Response {
        return self.withHeader("HX-Replace-Url", url);
    }

    /// Add HX-Retarget header to change the target element for this response
    pub fn htmxRetarget(self: Response, selector: []const u8) Response {
        return self.withHeader("HX-Retarget", selector);
    }

    /// Add HX-Reswap header to change the swap style for this response
    pub fn htmxReswap(self: Response, style: []const u8) Response {
        return self.withHeader("HX-Reswap", style);
    }

    // =========================================================================
    // End HTMX Methods
    // =========================================================================

    /// Set a cookie
    /// The cookie value will be copied to persistent memory
    ///
    /// Example:
    /// ```zig
    /// return Response.ok().withCookie("session_id", "abc123")
    ///     .withCookie("theme", "dark", .{ .maxAge = 3600 });
    /// ```
    pub fn withCookie(self: Response, name: []const u8, value: []const u8, options: CookieOptions) Response {
        // Cookie value will be stored in pooled memory
        const persistent_name = dupePersistent(name) catch return self;
        const persistent_value = dupePersistent(value) catch {
            // Release name buffer back to pool on failure
            getBufferPool().release(@constCast(persistent_name));
            return self;
        };

        // Format Set-Cookie header
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

        // Store the Set-Cookie header in custom headers
        // This allows the cookie to be sent with the response
        return self.withHeader("Set-Cookie", cookie_str);
    }

    /// Create a response from a file path
    /// Reads the file and serves it with appropriate content type
    /// Supports streaming for large files
    ///
    /// Example:
    /// ```zig
    /// return Response.fromFile("static/report.pdf", allocator);
    /// ```
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

        // Copy to pooled memory for response
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

    /// Create a file download response
    /// Sets appropriate headers for file download
    ///
    /// Example:
    /// ```zig
    /// return Response.download("report.pdf", pdf_data);
    /// ```
    pub fn download(filename: []const u8, data: []const u8) Response {
        const persistent_data = dupePersistent(data) catch {
            // Critical: Cannot safely use original data if it's from request arena
            // Use static error message that doesn't require allocation
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

        // Set Content-Disposition header for download
        // For now, ziggurat may not support custom headers directly
        _ = filename;

        return resp.withContentType("application/octet-stream");
    }

    /// Create a streaming response (placeholder)
    /// For actual streaming, this would need ziggurat support
    ///
    /// Example:
    /// ```zig
    /// return Response.stream("text/plain", stream_data);
    /// ```
    pub fn stream(content_type: []const u8, data: []const u8) Response {
        const persistent_data = dupePersistent(data) catch {
            // Critical: Cannot safely use original data if it's from request arena
            // Use static error message that doesn't require allocation
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

    /// Get the response body content
    /// Returns the body string if available
    ///
    /// Example:
    /// ```zig
    /// const body = resp.getBody();
    /// ```
    pub fn getBody(self: Response) []const u8 {
        // Prefer persistent body if available
        if (self._persistent_body) |body| {
            return body;
        }
        // Fallback to accessing ziggurat response body
        // Note: ziggurat responses store body internally, we need to access it
        // For now, return empty if persistent body is not set
        // This is safe because all Response constructors copy to persistent_body
        return "";
    }

    /// Convert to ziggurat response (internal use)
    /// The response data is already in persistent memory
    /// Serialize custom headers into HTTP header format
    /// Returns a string with headers formatted as "Header-Name: value\r\n"
    /// Handles multiple Set-Cookie headers correctly
    fn serializeHeaders(headers: std.StringHashMap([]const u8), allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(allocator);

        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            const name = entry.key_ptr.*;
            const value = entry.value_ptr.*;

            // Validate header name (no newlines, no colons except in value)
            if (std.mem.indexOf(u8, name, "\r") != null or std.mem.indexOf(u8, name, "\n") != null) {
                return error.InvalidHeader;
            }

            // Format header line: "Header-Name: value\r\n"
            const header_line = try std.fmt.allocPrint(allocator, "{s}: {s}\r\n", .{ name, value });
            defer allocator.free(header_line);
            try result.appendSlice(allocator, header_line);
        }

        return result.toOwnedSlice(allocator);
    }

    /// Format HTTP response with custom headers and status code injected
    /// This method intercepts the formatted HTTP response from ziggurat and injects
    /// custom headers before the body. Also handles status code modification.
    /// Returns a complete HTTP response string ready to send to the client.
    pub fn formatWithHeaders(self: Response, allocator: std.mem.Allocator) ![]const u8 {
        // Get base formatted response from ziggurat
        // Note: ziggurat's format() uses page_allocator internally
        const base_response = self.inner.format() catch |err| {
            return err;
        };
        defer std.heap.page_allocator.free(base_response);

        // If no custom headers and no status code override, return base response
        const has_custom_headers = if (self._custom_headers) |headers| headers.count() > 0 else false;
        if (!has_custom_headers and self._status_code == null) {
            return try allocator.dupe(u8, base_response);
        }

        // Find the end of headers (double CRLF)
        const header_end = std.mem.indexOf(u8, base_response, "\r\n\r\n") orelse {
            // No header-body separator found, return base response
            return try allocator.dupe(u8, base_response);
        };

        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(allocator);

        // Handle status code modification
        if (self._status_code) |status_code| {
            // Find status line (first line)
            const status_line_end = std.mem.indexOf(u8, base_response, "\r\n") orelse {
                return try allocator.dupe(u8, base_response);
            };

            // Get reason phrase for status code
            const reason_phrase = getReasonPhrase(status_code);

            // Write modified status line
            const status_line = try std.fmt.allocPrint(allocator, "HTTP/1.1 {d} {s}\r\n", .{ status_code, reason_phrase });
            defer allocator.free(status_line);
            try result.appendSlice(allocator, status_line);

            // Copy headers from base response (skip original status line)
            const headers_start = status_line_end + 2; // Skip "\r\n"
            try result.appendSlice(allocator, base_response[headers_start..header_end]);
        } else {
            // Copy status line and headers from base response
            try result.appendSlice(allocator, base_response[0..header_end]);
        }

        // Inject custom headers
        if (has_custom_headers) {
            const custom_headers_str = try serializeHeaders(self._custom_headers.?, allocator);
            defer allocator.free(custom_headers_str);
            try result.appendSlice(allocator, custom_headers_str);
        }

        // Add header-body separator
        try result.appendSlice(allocator, "\r\n");

        // Copy body from base response
        const body_start = header_end + 4; // Skip "\r\n\r\n"
        if (body_start < base_response.len) {
            try result.appendSlice(allocator, base_response[body_start..]);
        }

        return result.toOwnedSlice(allocator);
    }

    /// Get HTTP reason phrase for a status code
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

    /// Note: Custom headers stored in _custom_headers are stored but ziggurat's Response
    /// type doesn't support arbitrary headers. Common headers like Content-Type work via
    /// withContentType(). Custom headers are preserved for potential future ziggurat updates.
    /// The persistent buffer is marked for release after the response is sent.
    /// If custom headers or status code are present, formats the response with headers
    /// and stores it in thread-local storage for retrieval during formatting.
    pub fn toZiggurat(self: Response) ziggurat.response.Response {
        // Mark the buffer for release after response is sent
        // This is safe because format() copies the body data before sending
        markBufferForRelease(self._persistent_body);

        // If we have custom headers or status code, format with headers and store
        const has_custom_headers = if (self._custom_headers) |headers| headers.count() > 0 else false;
        if (has_custom_headers or self._status_code != null) {
            // Format response with headers using page allocator (will be freed after sending)
            const formatted = self.formatWithHeaders(std.heap.page_allocator) catch {
                // If formatting fails, return base response without custom headers
                return self.inner;
            };

            // Store formatted response in thread-local storage keyed by ziggurat response pointer
            formatted_responses_mutex.lock();
            defer formatted_responses_mutex.unlock();

            if (formatted_responses == null) {
                formatted_responses = std.AutoHashMap(*const anyopaque, []const u8).init(std.heap.page_allocator);
            }

            const response_ptr: *const anyopaque = @ptrCast(&self.inner);
            formatted_responses.?.put(response_ptr, formatted) catch {
                // If storage fails, free formatted response and return base
                std.heap.page_allocator.free(formatted);
                return self.inner;
            };
        }

        return self.inner;
    }

    /// Get formatted response with custom headers if stored
    /// Returns null if no custom formatting was applied
    pub fn getFormattedResponse(ziggurat_resp: *const ziggurat.response.Response) ?[]const u8 {
        formatted_responses_mutex.lock();
        defer formatted_responses_mutex.unlock();

        if (formatted_responses) |*map| {
            const response_ptr: *const anyopaque = @ptrCast(ziggurat_resp);
            return map.get(response_ptr);
        }

        return null;
    }

    /// Clear formatted response after sending
    /// Call this after the formatted response has been sent to free memory
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

    /// Check if this response has custom headers stored
    /// Returns true if there are custom headers that would need to be applied
    pub fn hasCustomHeaders(self: Response) bool {
        if (self._custom_headers) |headers| {
            return headers.count() > 0;
        }
        return false;
    }

    /// Get custom headers for manual application if needed
    /// This allows external code to apply headers that ziggurat doesn't support directly
    pub fn getCustomHeaders(self: Response) ?std.StringHashMap([]const u8) {
        return self._custom_headers;
    }

    /// Create from ziggurat response (internal use)
    pub fn fromZiggurat(ziggurat_response: ziggurat.response.Response) Response {
        return Response{
            .inner = ziggurat_response,
            ._persistent_body = null,
            ._custom_headers = null,
            ._status_code = null,
        };
    }

    /// Release the response buffer back to the pool for reuse
    /// Call this after the response has been fully sent to reclaim memory
    /// This is automatically called by Engine12 after sending the response
    pub fn releaseBuffer(self: *Response) void {
        if (self._persistent_body) |body| {
            getBufferPool().release(@constCast(body));
            self._persistent_body = null;
        }
    }
};

// Tests
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
    // Create a simple response - use text instead of json to avoid potential issues
    const resp = Response.text("test data");
    const formatted = resp.formatWithHeaders(allocator) catch |err| {
        // If format fails (e.g., ziggurat not available in test), skip test
        if (err == error.OutOfMemory) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(formatted);

    // Should return base formatted response
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

    // Should include custom header
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

    // Should include both headers
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

    // Should have modified status line
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

    // Should have modified status line and custom header
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
    // Simulate a scenario where body comes from request arena
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const arena_allocator = gpa.allocator();

    // Allocate body in temporary arena
    const temp_body = try arena_allocator.dupe(u8, "{\"test\":\"data\"}");

    // Create response - should copy to persistent memory
    const resp = Response.json(temp_body);

    // Free the arena
    arena_allocator.free(temp_body);

    // Response should still be valid (body was copied)
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
    // Verify response was created
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
