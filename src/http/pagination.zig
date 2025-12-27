const std = @import("std");
const Request = @import("request.zig").Request;

pub const PaginationMeta = struct {
    page: u32,
    limit: u32,
    total: u32,
    total_pages: u32,
};

pub const Pagination = struct {
    page: u32,
    limit: u32,
    offset: u32,
    
    pub fn fromRequest(req: *Request) !Pagination {
        return fromRequestWithDefaults(req, 20, 100);
    }

    pub fn fromRequestWithDefaults(req: *Request, default_limit: u32, max_limit: u32) !Pagination {
        const page = (req.queryParamTyped(u32, "page") catch null) orelse 1;
        var limit = (req.queryParamTyped(u32, "limit") catch null) orelse default_limit;
        
        if (page < 1) {
            return error.InvalidArgument;
        }
        
        if (limit < 1) {
            return error.InvalidArgument;
        }
        
        if (limit > max_limit) {
            limit = max_limit;
        }
        
        const offset = (page - 1) * limit;
        
        return Pagination{
            .page = page,
            .limit = limit,
            .offset = offset,
        };
    }
    
    pub fn toResponse(self: Pagination, total: u32) PaginationMeta {
        const total_pages = if (total == 0) 0 else ((total - 1) / self.limit) + 1;
        
        return PaginationMeta{
            .page = self.page,
            .limit = self.limit,
            .total = total,
            .total_pages = total_pages,
        };
    }
};

test "Pagination fromRequest with defaults" {
    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const pagination = try Pagination.fromRequest(&req);
    try std.testing.expectEqual(pagination.page, 1);
    try std.testing.expectEqual(pagination.limit, 20);
    try std.testing.expectEqual(pagination.offset, 0);
}

test "Pagination fromRequest with query params" {
    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos?page=3&limit=10",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    const pagination = try Pagination.fromRequest(&req);
    try std.testing.expectEqual(pagination.page, 3);
    try std.testing.expectEqual(pagination.limit, 10);
    try std.testing.expectEqual(pagination.offset, 20);
}

test "Pagination fromRequest invalid page" {
    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos?page=0",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    try std.testing.expectError(error.InvalidArgument, Pagination.fromRequest(&req));
}

test "Pagination fromRequest invalid limit" {
    const ziggurat = @import("ziggurat");
    const headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    const user_data = std.StringHashMap([]const u8).init(std.testing.allocator);
    var ziggurat_req = ziggurat.request.Request{
        .path = "/api/todos?limit=0",
        .method = .GET,
        .body = "",
        .headers = headers,
        .allocator = std.testing.allocator,
        .user_data = user_data,
    };
    var req = Request.fromZiggurat(&ziggurat_req, std.testing.allocator);
    defer req.deinit();
    
    try std.testing.expectError(error.InvalidArgument, Pagination.fromRequest(&req));
}

test "Pagination toResponse" {
    const pagination = Pagination{
        .page = 2,
        .limit = 10,
        .offset = 10,
    };
    
    const meta = pagination.toResponse(25);
    try std.testing.expectEqual(meta.page, 2);
    try std.testing.expectEqual(meta.limit, 10);
    try std.testing.expectEqual(meta.total, 25);
    try std.testing.expectEqual(meta.total_pages, 3);
}

test "Pagination toResponse with zero total" {
    const pagination = Pagination{
        .page = 1,
        .limit = 10,
        .offset = 0,
    };
    
    const meta = pagination.toResponse(0);
    try std.testing.expectEqual(meta.total, 0);
    try std.testing.expectEqual(meta.total_pages, 0);
}

