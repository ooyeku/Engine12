const std = @import("std");
const templates = @import("../templates/template.zig");
const runtime_renderer = @import("runtime_renderer.zig");

pub const RuntimeTemplate = struct {
    file_path: []const u8,
    last_modified: i64,
    template_content: []const u8,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, file_path: []const u8) !RuntimeTemplate {
        const path_copy = try allocator.dupe(u8, file_path);

        const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024);

        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const stat = try file.stat();
        const last_modified = @as(i64, @intCast(stat.mtime));

        return RuntimeTemplate{
            .file_path = path_copy,
            .last_modified = last_modified,
            .template_content = content,
            .allocator = allocator,
        };
    }

    pub fn reload(self: *RuntimeTemplate) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const file = std.fs.cwd().openFile(self.file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return;
            }
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        const current_modified = @as(i64, @intCast(stat.mtime));

        if (current_modified > self.last_modified) {
            self.last_modified = current_modified;

            const new_content = try std.fs.cwd().readFileAlloc(self.allocator, self.file_path, 10 * 1024 * 1024);

            self.allocator.free(self.template_content);

            self.template_content = new_content;
        }
    }

    pub fn getContent(self: *RuntimeTemplate) ![]const u8 {
        try self.reload();
        return self.template_content;
    }

    pub fn render(
        self: *RuntimeTemplate,
        comptime Context: type,
        ctx: Context,
        render_allocator: std.mem.Allocator,
    ) ![]const u8 {
        try self.reload();

        return runtime_renderer.RuntimeRenderer.render(
            self.template_content,
            Context,
            ctx,
            render_allocator,
        );
    }

    pub fn getContentString(self: *RuntimeTemplate) ![]const u8 {
        try self.reload();
        return self.template_content;
    }

    pub fn deinit(self: *RuntimeTemplate) void {
        self.allocator.free(self.file_path);
        self.allocator.free(self.template_content);
    }
};

test "RuntimeTemplate init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_file = "test_template.zt.html";
    std.fs.cwd().writeFile(.{ .sub_path = test_file, .data = "<h1>{{ .title }}</h1>" }) catch {
        return;
    };
    defer std.fs.cwd().deleteFile(test_file) catch {};

    var rt = try RuntimeTemplate.init(allocator, test_file);
    defer rt.deinit();

    const content = try rt.getContentString();
    try std.testing.expect(std.mem.indexOf(u8, content, "<h1>") != null);
}

test "RuntimeTemplate reload on change" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_file = "test_reload.zt.html";
    std.fs.cwd().writeFile(.{ .sub_path = test_file, .data = "original" }) catch {
        return;
    };
    defer std.fs.cwd().deleteFile(test_file) catch {};

    var rt = try RuntimeTemplate.init(allocator, test_file);
    defer rt.deinit();

    var content = try rt.getContentString();
    try std.testing.expectEqualStrings(content, "original");

    std.fs.cwd().writeFile(.{ .sub_path = test_file, .data = "modified" }) catch {
        return;
    };

    try rt.reload();
    content = try rt.getContentString();
    try std.testing.expectEqualStrings(content, "modified");
}
