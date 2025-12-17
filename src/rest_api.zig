const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const orm_mod = @import("orm/orm.zig");
const ORM = orm_mod.ORM;
const QueryBuilder = @import("orm/query_builder.zig").QueryBuilder;
const QueryResult = @import("orm/row.zig").QueryResult;
const validation = @import("validation.zig");
const ValidationErrors = validation.ValidationErrors;
const pagination_mod = @import("pagination.zig");
const Pagination = pagination_mod.Pagination;
const PaginationMeta = pagination_mod.PaginationMeta;
const json_mod = @import("json.zig");
const model_utils = @import("orm/model.zig");
const openapi = @import("openapi.zig");

const allocator = std.heap.page_allocator;

pub const AuthUser = struct {
    id: i64,
    username: []const u8,
    email: []const u8,
    password_hash: []const u8,
};

pub fn RestApiConfig(comptime Model: type) type {
    return struct {
        orm: *ORM,
        validator: *const fn (*Request, Model) anyerror!ValidationErrors,
        authenticator: ?*const fn (*Request) anyerror!AuthUser = null,
        authorization: ?*const fn (*Request, Model) anyerror!bool = null,
        cache_ttl_ms: ?u32 = null,
        enable_pagination: bool = true,
        default_limit: u32 = 20,
        max_limit: u32 = 100,
        enable_filtering: bool = true,
        enable_sorting: bool = true,
        _reserved_before_create: ?*const fn () void = null,
        _reserved_after_create: ?*const fn () void = null,
        _reserved_before_update: ?*const fn () void = null,
        _reserved_after_update: ?*const fn () void = null,
        _reserved_before_delete: ?*const fn () void = null,
    };
}

fn parseFilters(
    comptime T: type,
    builder: *QueryBuilder,
    request: *Request,
) !void {
    const filter_params = try request.queryParams();
    var filter_iter = filter_params.iterator();

    while (filter_iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, "filter")) continue;

        const filter_value = entry.value_ptr.*;
        const colon_pos = std.mem.indexOfScalar(u8, filter_value, ':') orelse continue;

        const field_name = filter_value[0..colon_pos];
        const field_value = filter_value[colon_pos + 1 ..];

        var field_valid = false;
        inline for (std.meta.fields(T)) |field| {
            if (std.mem.eql(u8, field.name, field_name)) {
                field_valid = true;
                break;
            }
        }

        if (!field_valid) {
            return error.InvalidFieldName;
        }

        _ = builder.whereEq(field_name, field_value);
    }
}

fn parseSort(
    comptime T: type,
    builder: *QueryBuilder,
    request: *Request,
) !void {
    const sort_param = try request.query("sort");
    const sort_value = sort_param orelse return;

    const colon_pos = std.mem.indexOfScalar(u8, sort_value, ':') orelse return;

    const field_name = sort_value[0..colon_pos];
    const direction = sort_value[colon_pos + 1 ..];

    var field_valid = false;
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            field_valid = true;
            break;
        }
    }

    if (!field_valid) {
        return error.InvalidFieldName;
    }

    const ascending = if (std.mem.eql(u8, direction, "asc"))
        true
    else if (std.mem.eql(u8, direction, "desc"))
        false
    else
        return error.InvalidSortDirection;

    _ = builder.orderBy(field_name, ascending);
}

fn buildListCacheKey(
    prefix: []const u8,
    request: *Request,
    user_id: ?i64,
    default_limit: u32,
) ![]const u8 {
    const arena = request.arena.allocator();

    var key_buf = std.ArrayListUnmanaged(u8){};
    defer key_buf.deinit(arena);
    const writer = key_buf.writer(arena);

    try writer.print("{s}:list", .{prefix});

    if (user_id) |uid| {
        try writer.print(":user:{d}", .{uid});
    }

    const filter_params = try request.queryParams();
    var filter_iter = filter_params.iterator();
    var has_filters = false;
    while (filter_iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "filter")) {
            if (!has_filters) {
                try writer.writeAll(":filter");
                has_filters = true;
            }
            try writer.print(":{s}", .{entry.value_ptr.*});
        }
    }

    if (try request.query("sort")) |sort| {
        try writer.print(":sort:{s}", .{sort});
    }

    const page = (request.queryParamTyped(u32, "page") catch null) orelse 1;
    const limit = (request.queryParamTyped(u32, "limit") catch null) orelse default_limit;
    try writer.print(":page:{d}:limit:{d}", .{ page, limit });

    return try key_buf.toOwnedSlice(arena);
}

fn buildShowCacheKey(prefix: []const u8, id: i64, user_id: ?i64) ![]const u8 {
    if (user_id) |uid| {
        return std.fmt.allocPrint(allocator, "{s}:{d}:user:{d}", .{ prefix, id, uid });
    } else {
        return std.fmt.allocPrint(allocator, "{s}:{d}", .{ prefix, id });
    }
}

fn PaginatedResponse(comptime T: type) type {
    return struct {
        data: []const T,
        meta: PaginationMeta,
    };
}

fn handleList(
    comptime T: type,
    prefix: []const u8,
    config: RestApiConfig(T),
    request: *Request,
) Response {
    var user: ?AuthUser = null;
    if (config.authenticator) |auth_fn| {
        user = auth_fn(request) catch {
            return Response.errorResponse("Authentication required", 401);
        };
    }

    if (config.cache_ttl_ms) |_| {
        const cache_key = buildListCacheKey(prefix, request, if (user) |u| u.id else null, config.default_limit) catch null;
        if (cache_key) |key| {
            if (request.cacheGet(key) catch null) |entry| {
                return Response.text(entry.body)
                    .withContentType(entry.content_type)
                    .withHeader("X-Cache", "HIT");
            }
        }
    }

    const pagination = if (config.enable_pagination)
        Pagination.fromRequestWithDefaults(request, config.default_limit, config.max_limit) catch {
            return Response.errorResponse("Invalid pagination parameters", 400);
        }
    else
        Pagination{ .page = 1, .limit = config.default_limit, .offset = 0 };

    const raw_table_name = model_utils.inferTableName(T);
    var table_name = model_utils.toLowercaseTableName(config.orm.allocator, raw_table_name) catch {
        return Response.serverError("Failed to get table name");
    };
    defer config.orm.allocator.free(table_name);

    if (std.mem.eql(u8, table_name, "todo")) {
        config.orm.allocator.free(table_name);
        table_name = config.orm.allocator.dupe(u8, "todos") catch {
            return Response.serverError("Failed to allocate table name");
        };
    }

    var builder = QueryBuilder.init(config.orm.allocator, table_name);
    defer builder.deinit();

    if (user) |authenticated_user| {
        var has_user_id_field = false;
        inline for (std.meta.fields(T)) |field| {
            if (std.mem.eql(u8, field.name, "user_id")) {
                has_user_id_field = true;
                break;
            }
        }
        if (has_user_id_field) {
            const user_id_str = std.fmt.allocPrint(request.arena.allocator(), "{d}", .{authenticated_user.id}) catch {
                return Response.serverError("Failed to format user_id filter");
            };
            _ = builder.whereEq("user_id", user_id_str);
        }
    }

    if (config.enable_filtering) {
        parseFilters(T, &builder, request) catch |err| {
            if (err == error.InvalidFieldName) {
                return Response.errorResponse("Invalid filter field name", 400);
            }
            return Response.serverError("Failed to parse filters");
        };
    }

    if (config.enable_sorting) {
        parseSort(T, &builder, request) catch |err| {
            if (err == error.InvalidFieldName) {
                return Response.errorResponse("Invalid sort field name", 400);
            }
            if (err == error.InvalidSortDirection) {
                return Response.errorResponse("Invalid sort direction (must be 'asc' or 'desc')", 400);
            }
        };
    }

    _ = builder.limit(pagination.limit).offset(pagination.offset);

    const sql = builder.build() catch {
        return Response.serverError("Failed to build query");
    };
    defer config.orm.allocator.free(sql);

    var query_result = config.orm.query(sql) catch {
        return Response.serverError("Failed to execute query");
    };
    defer query_result.deinit();

    var items = query_result.toArrayList(T) catch {
        return Response.serverError("Failed to deserialize results");
    };
    defer {
        for (items.items) |item| {
            inline for (std.meta.fields(T)) |field| {
                const field_type = @TypeOf(@field(item, field.name));
                if (@typeInfo(field_type) == .pointer) {
                    const ptr_info = @typeInfo(field_type).pointer;
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        config.orm.allocator.free(@field(item, field.name));
                    }
                } else if (@typeInfo(field_type) == .optional) {
                    const opt_info = @typeInfo(field_type).optional;
                    if (@typeInfo(opt_info.child) == .pointer) {
                        const ptr_info = @typeInfo(opt_info.child).pointer;
                        if (ptr_info.size == .slice and ptr_info.child == u8) {
                            if (@field(item, field.name)) |val| {
                                config.orm.allocator.free(val);
                            }
                        }
                    }
                }
            }
        }
        items.deinit(config.orm.allocator);
    }

    var count_builder = QueryBuilder.init(config.orm.allocator, table_name);
    defer count_builder.deinit();

    if (user) |authenticated_user| {
        var has_user_id_field = false;
        inline for (std.meta.fields(T)) |field| {
            if (std.mem.eql(u8, field.name, "user_id")) {
                has_user_id_field = true;
                break;
            }
        }
        if (has_user_id_field) {
            const user_id_str = std.fmt.allocPrint(request.arena.allocator(), "{d}", .{authenticated_user.id}) catch {
                return Response.serverError("Failed to format user_id filter for count");
            };
            _ = count_builder.whereEq("user_id", user_id_str);
        }
    }

    if (config.enable_filtering) {
        parseFilters(T, &count_builder, request) catch |err| {
            std.debug.print("[REST API] Warning: Failed to parse filters for count query: {}\n", .{err});
        };
    }

    var count_sql_buf = std.ArrayListUnmanaged(u8){};
    defer count_sql_buf.deinit(config.orm.allocator);

    count_sql_buf.writer(config.orm.allocator).print("SELECT COUNT(*) as count FROM {s}", .{table_name}) catch {
        return Response.serverError("Failed to build count query");
    };

    if (count_builder.where_clauses.items.len > 0) {
        count_sql_buf.writer(config.orm.allocator).print(" WHERE ", .{}) catch {
            return Response.serverError("Failed to build count query");
        };
        for (count_builder.where_clauses.items, 0..) |clause, i| {
            if (i > 0) count_sql_buf.writer(config.orm.allocator).print(" AND ", .{}) catch {
                return Response.serverError("Failed to build count query");
            };
            var escaped_value = std.ArrayListUnmanaged(u8){};
            defer escaped_value.deinit(config.orm.allocator);
            for (clause.value) |char| {
                if (char == '\'') {
                    escaped_value.append(config.orm.allocator, '\'') catch {
                        std.debug.print("[REST API] Warning: Failed to escape SQL value, skipping character\n", .{});
                        continue;
                    };
                    escaped_value.append(config.orm.allocator, '\'') catch {
                        std.debug.print("[REST API] Warning: Failed to escape SQL value, skipping character\n", .{});
                        continue;
                    };
                } else {
                    escaped_value.append(config.orm.allocator, char) catch {
                        std.debug.print("[REST API] Warning: Failed to escape SQL value, skipping character\n", .{});
                        continue;
                    };
                }
            }
            count_sql_buf.writer(config.orm.allocator).print("{s} {s} '{s}'", .{ clause.field, clause.operator, escaped_value.items }) catch {
                return Response.serverError("Failed to build count query");
            };
        }
    }

    const count_sql = count_sql_buf.toOwnedSlice(config.orm.allocator) catch {
        return Response.serverError("Failed to allocate count query");
    };
    defer config.orm.allocator.free(count_sql);

    var count_result = config.orm.query(count_sql) catch {
        return Response.serverError("Failed to execute count query");
    };
    defer count_result.deinit();

    const count_row = count_result.nextRow() orelse {
        return Response.serverError("Failed to get count");
    };
    const total = count_row.getInt64(0);

    const meta = pagination.toResponse(@intCast(total));
    const paginated = PaginatedResponse(T){
        .data = items.items,
        .meta = meta,
    };

    const response = Response.jsonFrom(PaginatedResponse(T), paginated, config.orm.allocator);

    if (config.cache_ttl_ms) |ttl| {
        const cache_key = buildListCacheKey(prefix, request, if (user) |u| u.id else null, config.default_limit) catch null;
        if (cache_key) |key| {
            const json = json_mod.Json.serialize(PaginatedResponse(T), paginated, config.orm.allocator) catch null;
            if (json) |j| {
                defer config.orm.allocator.free(j);
                const persistent_json = std.heap.page_allocator.dupe(u8, j) catch null;
                if (persistent_json) |pj| {
                    request.cacheSet(key, pj, ttl, "application/json") catch |err| {
                        std.debug.print("[REST API] Warning: Failed to cache response: {}\n", .{err});
                    };
                }
            }
        }
    }

    return response.withHeader("X-Cache", "MISS");
}

fn handleShow(
    comptime T: type,
    prefix: []const u8,
    config: RestApiConfig(T),
    request: *Request,
) Response {
    var user: ?AuthUser = null;
    if (config.authenticator) |auth_fn| {
        user = auth_fn(request) catch {
            return Response.errorResponse("Authentication required", 401);
        };
    }

    const id = request.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };

    if (config.cache_ttl_ms) |_| {
        const cache_key = buildShowCacheKey(prefix, id, if (user) |u| u.id else null) catch null;
        if (cache_key) |key| {
            defer allocator.free(key);
            if (request.cacheGet(key) catch null) |entry| {
                return Response.text(entry.body)
                    .withContentType(entry.content_type)
                    .withHeader("X-Cache", "HIT");
            }
        }
    }

    const found = config.orm.find(T, id) catch {
        return Response.serverError("Failed to fetch record");
    };

    const record = found orelse {
        return Response.notFound("Record not found");
    };
    defer {
        inline for (std.meta.fields(T)) |field| {
            const field_type = @TypeOf(@field(record, field.name));
            if (@typeInfo(field_type) == .pointer) {
                const ptr_info = @typeInfo(field_type).pointer;
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    config.orm.allocator.free(@field(record, field.name));
                }
            } else if (@typeInfo(field_type) == .optional) {
                const opt_info = @typeInfo(field_type).optional;
                if (@typeInfo(opt_info.child) == .pointer) {
                    const ptr_info = @typeInfo(opt_info.child).pointer;
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        if (@field(record, field.name)) |val| {
                            config.orm.allocator.free(val);
                        }
                    }
                }
            }
        }
    }

    if (config.authorization) |authz_fn| {
        const allowed = authz_fn(request, record) catch {
            return Response.errorResponse("Authorization failed", 403);
        };
        if (!allowed) {
            return Response.errorResponse("Access denied", 403);
        }
    }

    const response = Response.jsonFrom(T, record, config.orm.allocator);

    if (config.cache_ttl_ms) |ttl| {
        const cache_key = buildShowCacheKey(prefix, id, if (user) |u| u.id else null) catch null;
        if (cache_key) |key| {
            defer allocator.free(key);
            const json = json_mod.Json.serialize(T, record, config.orm.allocator) catch null;
            if (json) |j| {
                defer config.orm.allocator.free(j);
                const persistent_json = std.heap.page_allocator.dupe(u8, j) catch null;
                if (persistent_json) |pj| {
                    request.cacheSet(key, pj, ttl, "application/json") catch |err| {
                        std.debug.print("[REST API] Warning: Failed to cache response: {}\n", .{err});
                    };
                }
            }
        }
    }

    return response.withHeader("X-Cache", "MISS");
}

fn handleCreate(
    comptime T: type,
    prefix: []const u8,
    config: RestApiConfig(T),
    request: *Request,
) Response {
    var user: ?AuthUser = null;
    if (config.authenticator) |auth_fn| {
        user = auth_fn(request) catch {
            return Response.errorResponse("Authentication required", 401);
        };
    }

    const parsed = request.jsonBody(T) catch {
        return Response.errorResponse("Invalid JSON", 400);
    };

    var validation_errors = config.validator(request, parsed) catch {
        return Response.serverError("Validation error");
    };
    defer validation_errors.deinit();

    if (!validation_errors.isEmpty()) {
        return Response.validationError(&validation_errors);
    }

    var model_to_create = parsed;

    if (user) |authenticated_user| {
        inline for (std.meta.fields(T)) |field| {
            if (std.mem.eql(u8, field.name, "user_id")) {
                @field(model_to_create, "user_id") = authenticated_user.id;
                break;
            }
        }
    }

    const now = std.time.milliTimestamp();
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, "created_at")) {
            @field(model_to_create, "created_at") = now;
        }
        if (std.mem.eql(u8, field.name, "updated_at")) {
            @field(model_to_create, "updated_at") = now;
        }
    }

    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, "id")) {
            @field(model_to_create, "id") = 0;
            break;
        }
    }

    config.orm.create(T, model_to_create) catch {
        return Response.serverError("Failed to create record");
    };

    const created_id = config.orm.db.lastInsertRowId() catch |err| {
        std.debug.print("[REST API] Warning: Failed to get lastInsertRowId: {}\n", .{err});
        const response = Response.jsonFrom(T, model_to_create, config.orm.allocator);
        return response.withStatus(201);
    };

    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, "id")) {
            @field(model_to_create, "id") = created_id;
            break;
        }
    }

    if (config.cache_ttl_ms) |_| {
        const cache_key = buildListCacheKey(prefix, request, if (user) |u| u.id else null, config.default_limit) catch null;
        if (cache_key) |key| {
            request.cacheInvalidate(key);
        }
    }

    const response = Response.jsonFrom(T, model_to_create, config.orm.allocator);
    return response.withStatus(201);
}

fn handleUpdate(
    comptime T: type,
    prefix: []const u8,
    config: RestApiConfig(T),
    request: *Request,
) Response {
    var user: ?AuthUser = null;
    if (config.authenticator) |auth_fn| {
        user = auth_fn(request) catch {
            return Response.errorResponse("Authentication required", 401);
        };
    }

    const id = request.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };

    const existing = config.orm.find(T, id) catch {
        return Response.serverError("Failed to fetch record");
    };

    const existing_record = existing orelse {
        return Response.notFound("Record not found");
    };
    defer {
        inline for (std.meta.fields(T)) |field| {
            const field_type = @TypeOf(@field(existing_record, field.name));
            if (@typeInfo(field_type) == .pointer) {
                const ptr_info = @typeInfo(field_type).pointer;
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    config.orm.allocator.free(@field(existing_record, field.name));
                }
            } else if (@typeInfo(field_type) == .optional) {
                const opt_info = @typeInfo(field_type).optional;
                if (@typeInfo(opt_info.child) == .pointer) {
                    const ptr_info = @typeInfo(opt_info.child).pointer;
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        if (@field(existing_record, field.name)) |val| {
                            config.orm.allocator.free(val);
                        }
                    }
                }
            }
        }
    }

    if (config.authorization) |authz_fn| {
        const allowed = authz_fn(request, existing_record) catch {
            return Response.errorResponse("Authorization failed", 403);
        };
        if (!allowed) {
            return Response.errorResponse("Access denied", 403);
        }
    }

    const parsed = request.jsonBody(T) catch {
        return Response.errorResponse("Invalid JSON", 400);
    };

    var updated_record = existing_record;
    inline for (std.meta.fields(T)) |field| {
        const field_name = field.name;
        const is_managed_field = comptime blk: {
            break :blk std.mem.eql(u8, field_name, "id") or
                std.mem.eql(u8, field_name, "created_at") or
                std.mem.eql(u8, field_name, "updated_at") or
                std.mem.eql(u8, field_name, "user_id");
        };
        if (is_managed_field) {
            continue;
        }

        const parsed_value = @field(parsed, field.name);
        const field_type = @TypeOf(parsed_value);
        if (@typeInfo(field_type) == .optional) {
            if (parsed_value) |val| {
                @field(updated_record, field.name) = val;
            }
        } else {
            const type_info = @typeInfo(field_type);
            const should_copy = switch (type_info) {
                .bool => true, // Always copy bools (false is a valid value)
                .int => parsed_value != 0, // Skip zero integers
                .float => parsed_value != 0.0, // Skip zero floats
                .pointer => |ptr_info| blk: {
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        break :blk parsed_value.len > 0; // Skip empty strings
                    }
                    break :blk true; // Copy other pointer types
                },
                else => true, // Copy other types
            };
            if (should_copy) {
                @field(updated_record, field.name) = parsed_value;
            }
        }
    }

    @field(updated_record, "id") = id;

    var validation_errors = config.validator(request, updated_record) catch {
        return Response.serverError("Validation error");
    };
    defer validation_errors.deinit();

    if (!validation_errors.isEmpty()) {
        return Response.validationError(&validation_errors);
    }

    var model_to_update = updated_record;

    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, "updated_at")) {
            @field(model_to_update, "updated_at") = std.time.milliTimestamp();
            break;
        }
    }

    config.orm.update(T, model_to_update) catch {
        return Response.serverError("Failed to update record");
    };

    if (config.cache_ttl_ms) |_| {
        const cache_key = buildListCacheKey(prefix, request, if (user) |u| u.id else null, config.default_limit) catch null;
        if (cache_key) |key| {
            request.cacheInvalidate(key);
        }
        const show_cache_key = buildShowCacheKey(prefix, id, if (user) |u| u.id else null) catch null;
        if (show_cache_key) |key| {
            defer allocator.free(key); // buildShowCacheKey uses allocator (page_allocator)
            request.cacheInvalidate(key);
        }
    }

    const response = Response.jsonFrom(T, model_to_update, config.orm.allocator);
    return response;
}

fn handleDelete(
    comptime T: type,
    prefix: []const u8,
    config: RestApiConfig(T),
    request: *Request,
) Response {
    var user: ?AuthUser = null;
    if (config.authenticator) |auth_fn| {
        user = auth_fn(request) catch {
            return Response.errorResponse("Authentication required", 401);
        };
    }

    const id = request.paramTyped(i64, "id") catch {
        return Response.errorResponse("Invalid ID", 400);
    };

    const existing = config.orm.find(T, id) catch {
        return Response.serverError("Failed to fetch record");
    };

    const existing_record = existing orelse {
        return Response.notFound("Record not found");
    };
    defer {
        inline for (std.meta.fields(T)) |field| {
            const field_type = @TypeOf(@field(existing_record, field.name));
            if (@typeInfo(field_type) == .pointer) {
                const ptr_info = @typeInfo(field_type).pointer;
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    config.orm.allocator.free(@field(existing_record, field.name));
                }
            } else if (@typeInfo(field_type) == .optional) {
                const opt_info = @typeInfo(field_type).optional;
                if (@typeInfo(opt_info.child) == .pointer) {
                    const ptr_info = @typeInfo(opt_info.child).pointer;
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        if (@field(existing_record, field.name)) |val| {
                            config.orm.allocator.free(val);
                        }
                    }
                }
            }
        }
    }

    if (config.authorization) |authz_fn| {
        const allowed = authz_fn(request, existing_record) catch {
            return Response.errorResponse("Authorization failed", 403);
        };
        if (!allowed) {
            return Response.errorResponse("Access denied", 403);
        }
    }

    config.orm.delete(T, id) catch {
        return Response.serverError("Failed to delete record");
    };

    if (config.cache_ttl_ms) |_| {
        const cache_key = buildListCacheKey(prefix, request, if (user) |u| u.id else null, config.default_limit) catch null;
        if (cache_key) |key| {
            request.cacheInvalidate(key);
        }
        const show_cache_key = buildShowCacheKey(prefix, id, if (user) |u| u.id else null) catch null;
        if (show_cache_key) |key| {
            defer allocator.free(key); // buildShowCacheKey uses allocator (page_allocator)
            request.cacheInvalidate(key);
        }
    }

    return Response.noContent();
}

var rest_api_configs: std.StringHashMap(*const anyopaque) = undefined;
var rest_api_configs_mutex: std.Thread.Mutex = .{};
var rest_api_configs_initialized: bool = false;

fn initRestApiConfigs() void {
    if (!rest_api_configs_initialized) {
        rest_api_configs = std.StringHashMap(*const anyopaque).init(allocator);
        rest_api_configs_initialized = true;
    }
}

pub fn restApi(
    app: *@import("engine12.zig").Engine12,
    comptime prefix: []const u8,
    comptime Model: type,
    config: RestApiConfig(Model),
) !void {
    initRestApiConfigs();

    if (app.getOpenApiGenerator()) |generator| {
        generator.registerResource(prefix, Model) catch |err| {
            std.debug.print("Failed to register OpenAPI resource: {}\n", .{err});
        };
    } else |_| {
    }

    const config_ptr = try allocator.create(RestApiConfig(Model));
    config_ptr.* = config;

    rest_api_configs_mutex.lock();
    defer rest_api_configs_mutex.unlock();
    try rest_api_configs.put(prefix, config_ptr);

    try app.get(prefix, struct {
        const model_type = Model;
        const api_prefix = prefix;
        fn handler(req: *Request) Response {
            rest_api_configs_mutex.lock();
            defer rest_api_configs_mutex.unlock();
            const config_ptr_opt = rest_api_configs.get(api_prefix) orelse {
                return Response.serverError("REST API config not found");
            };
            const api_config = @as(*const RestApiConfig(model_type), @ptrCast(@alignCast(config_ptr_opt))).*;
            return handleList(model_type, api_prefix, api_config, req);
        }
    }.handler);

    const show_path = comptime prefix ++ "/:id";
    try app.get(show_path, struct {
        const model_type = Model;
        const api_prefix = prefix;
        fn handler(req: *Request) Response {
            rest_api_configs_mutex.lock();
            defer rest_api_configs_mutex.unlock();
            const config_ptr_opt = rest_api_configs.get(api_prefix) orelse {
                return Response.serverError("REST API config not found");
            };
            const api_config = @as(*const RestApiConfig(model_type), @ptrCast(@alignCast(config_ptr_opt))).*;
            return handleShow(model_type, api_prefix, api_config, req);
        }
    }.handler);

    try app.post(prefix, struct {
        const model_type = Model;
        const api_prefix = prefix;
        fn handler(req: *Request) Response {
            rest_api_configs_mutex.lock();
            defer rest_api_configs_mutex.unlock();
            const config_ptr_opt = rest_api_configs.get(api_prefix) orelse {
                return Response.serverError("REST API config not found");
            };
            const api_config = @as(*const RestApiConfig(model_type), @ptrCast(@alignCast(config_ptr_opt))).*;
            return handleCreate(model_type, api_prefix, api_config, req);
        }
    }.handler);

    const update_path = comptime prefix ++ "/:id";
    try app.put(update_path, struct {
        const model_type = Model;
        const api_prefix = prefix;
        fn handler(req: *Request) Response {
            rest_api_configs_mutex.lock();
            defer rest_api_configs_mutex.unlock();
            const config_ptr_opt = rest_api_configs.get(api_prefix) orelse {
                return Response.serverError("REST API config not found");
            };
            const api_config = @as(*const RestApiConfig(model_type), @ptrCast(@alignCast(config_ptr_opt))).*;
            return handleUpdate(model_type, api_prefix, api_config, req);
        }
    }.handler);

    const delete_path = comptime prefix ++ "/:id";
    try app.delete(delete_path, struct {
        const model_type = Model;
        const api_prefix = prefix;
        fn handler(req: *Request) Response {
            rest_api_configs_mutex.lock();
            defer rest_api_configs_mutex.unlock();
            const config_ptr_opt = rest_api_configs.get(api_prefix) orelse {
                return Response.serverError("REST API config not found");
            };
            const api_config = @as(*const RestApiConfig(model_type), @ptrCast(@alignCast(config_ptr_opt))).*;
            return handleDelete(model_type, api_prefix, api_config, req);
        }
    }.handler);
}
