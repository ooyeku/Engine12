const std = @import("std");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;

pub const HtmxResourceConfig = struct {
    list: ?*const fn (*Request) Response = null,
    show: ?*const fn (*Request) Response = null,
    create: ?*const fn (*Request) Response = null,
    update: ?*const fn (*Request) Response = null,
    delete: ?*const fn (*Request) Response = null,
    edit_form: ?*const fn (*Request) Response = null,
    new_form: ?*const fn (*Request) Response = null,
};

pub const RouteBinding = struct {
    method: []const u8,
    path: []const u8,
    handler: *const fn (*Request) Response,
};

pub const HtmxRouter = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayListUnmanaged(RouteBinding),

    pub fn init(allocator: std.mem.Allocator) HtmxRouter {
        return .{
            .allocator = allocator,
            .routes = .{},
        };
    }

    pub fn deinit(self: *HtmxRouter) void {
        for (self.routes.items) |route| {
            self.allocator.free(route.path);
        }
        self.routes.deinit(self.allocator);
    }

    pub fn resource(self: *HtmxRouter, base_path: []const u8, config: HtmxResourceConfig) !void {
        if (config.list) |handler| {
            const path = try self.allocator.dupe(u8, base_path);
            try self.routes.append(self.allocator, .{
                .method = "GET",
                .path = path,
                .handler = handler,
            });
        }

        if (config.create) |handler| {
            const path = try self.allocator.dupe(u8, base_path);
            try self.routes.append(self.allocator, .{
                .method = "POST",
                .path = path,
                .handler = handler,
            });
        }

        if (config.show) |handler| {
            const path = try std.fmt.allocPrint(self.allocator, "{s}/:id", .{base_path});
            try self.routes.append(self.allocator, .{
                .method = "GET",
                .path = path,
                .handler = handler,
            });
        }

        if (config.update) |handler| {
            const path = try std.fmt.allocPrint(self.allocator, "{s}/:id", .{base_path});
            try self.routes.append(self.allocator, .{
                .method = "PUT",
                .path = path,
                .handler = handler,
            });
        }

        if (config.delete) |handler| {
            const path = try std.fmt.allocPrint(self.allocator, "{s}/:id", .{base_path});
            try self.routes.append(self.allocator, .{
                .method = "DELETE",
                .path = path,
                .handler = handler,
            });
        }

        if (config.edit_form) |handler| {
            const path = try std.fmt.allocPrint(self.allocator, "{s}/:id/edit", .{base_path});
            try self.routes.append(self.allocator, .{
                .method = "GET",
                .path = path,
                .handler = handler,
            });
        }

        if (config.new_form) |handler| {
            const path = try std.fmt.allocPrint(self.allocator, "{s}/new", .{base_path});
            try self.routes.append(self.allocator, .{
                .method = "GET",
                .path = path,
                .handler = handler,
            });
        }
    }

    pub fn getRoutes(self: *HtmxRouter) []const RouteBinding {
        return self.routes.items;
    }
};

pub fn createRouter(allocator: std.mem.Allocator) HtmxRouter {
    return HtmxRouter.init(allocator);
}

test "htmx router resource registration" {
    const allocator = std.testing.allocator;
    var router = createRouter(allocator);
    defer router.deinit();

    const testHandler = struct {
        fn handler(_: *Request) Response {
            return Response.fragment("<div>test</div>");
        }
    }.handler;

    try router.resource("/todos", .{
        .list = testHandler,
        .create = testHandler,
        .update = testHandler,
        .delete = testHandler,
    });

    try std.testing.expectEqual(@as(usize, 4), router.routes.items.len);
}

test "htmx router with show and forms" {
    const allocator = std.testing.allocator;
    var router = createRouter(allocator);
    defer router.deinit();

    const testHandler = struct {
        fn handler(_: *Request) Response {
            return Response.fragment("<div>test</div>");
        }
    }.handler;

    try router.resource("/users", .{
        .list = testHandler,
        .show = testHandler,
        .new_form = testHandler,
        .edit_form = testHandler,
    });

    try std.testing.expectEqual(@as(usize, 4), router.routes.items.len);
}
