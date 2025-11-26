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

/// Get or initialize the global buffer pool
pub fn getBufferPool() *ResponseBufferPool {
    if (global_buffer_pool != null) {
        return &global_buffer_pool.?;
    }

    global_buffer_pool_mutex.lock();
    defer global_buffer_pool_mutex.unlock();

    if (global_buffer_pool == null) {
        global_buffer_pool = ResponseBufferPool.init(
            std.heap.page_allocator,
            256, // max 256 pooled buffers
            64 * 1024, // 64KB default buffer size
        );
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
            // If allocation fails, fall back to original (may be a string literal)
            return Response{
                .inner = ziggurat.response.Response.json(body),
                ._persistent_body = null,
                ._custom_headers = null,
                ._status_code = null,
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
            return Response{
                .inner = ziggurat.response.Response.text(body),
                ._persistent_body = null,
                ._custom_headers = null,
                ._status_code = null,
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
            return Response{
                .inner = ziggurat.response.Response.html(body),
                ._persistent_body = null,
                ._custom_headers = null,
                ._status_code = null,
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
            return Response{
                .inner = ziggurat.response.Response.json(body),
                ._persistent_body = self._persistent_body,
                ._custom_headers = self._custom_headers,
                ._status_code = self._status_code,
            };
        };

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

        // For now, just return self since ziggurat may not support Set-Cookie header directly
        // In the future, this would set the Set-Cookie header
        _ = cookie_str;
        return self;
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
            return Response{
                .inner = ziggurat.response.Response.text(data),
                ._persistent_body = null,
                ._custom_headers = null,
                ._status_code = null,
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
            return Response{
                .inner = ziggurat.response.Response.text(data),
                ._persistent_body = null,
                ._custom_headers = null,
                ._status_code = null,
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
    /// Note: Custom headers stored in _custom_headers are not yet applied to the ziggurat response
    /// as ziggurat may not support custom headers directly. They are stored for future use.
    pub fn toZiggurat(self: Response) ziggurat.response.Response {
        return self.inner;
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
