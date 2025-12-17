const std = @import("std");
const watcher = @import("watcher.zig");
const runtime_template = @import("runtime_template.zig");
const fileserver = @import("../fileserver.zig");
const websocket_room = @import("../websocket/room.zig");

pub const HotReloadManager = struct {
    allocator: std.mem.Allocator,
    file_watcher: watcher.FileWatcher,
    template_cache: std.StringHashMap(*runtime_template.RuntimeTemplate),
    static_file_servers: std.ArrayListUnmanaged(*fileserver.FileServer),
    reload_room: ?*websocket_room.WebSocketRoom = null,
    enabled: bool,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, enabled: bool) HotReloadManager {
        const reload_room = if (enabled) allocator.create(websocket_room.WebSocketRoom) catch null else null;
        if (reload_room) |room| {
            room.* = websocket_room.WebSocketRoom.init(allocator, "hot_reload") catch {
                allocator.destroy(room);
                return HotReloadManager{
                    .allocator = allocator,
                    .file_watcher = watcher.FileWatcher.init(allocator),
                    .template_cache = std.StringHashMap(*runtime_template.RuntimeTemplate).init(allocator),
                    .static_file_servers = .{},
                    .reload_room = null,
                    .enabled = enabled,
                };
            };
        }

        return HotReloadManager{
            .allocator = allocator,
            .file_watcher = watcher.FileWatcher.init(allocator),
            .template_cache = std.StringHashMap(*runtime_template.RuntimeTemplate).init(allocator),
            .static_file_servers = .{},
            .reload_room = reload_room,
            .enabled = enabled,
        };
    }

    pub fn getReloadRoom(self: *HotReloadManager) ?*websocket_room.WebSocketRoom {
        return self.reload_room;
    }

    pub fn watchTemplate(self: *HotReloadManager, template_path: []const u8) !*runtime_template.RuntimeTemplate {
        if (!self.enabled) {
            return error.HotReloadNotEnabled;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.template_cache.get(template_path)) |existing| {
            return existing;
        }

        const rt = try runtime_template.RuntimeTemplate.init(self.allocator, template_path);
        const rt_ptr = try self.allocator.create(runtime_template.RuntimeTemplate);
        rt_ptr.* = rt;

        const path_copy = try self.allocator.dupe(u8, template_path);
        try self.template_cache.put(path_copy, rt_ptr);

        try self.file_watcher.watch(template_path, templateReloadCallback, self);

        return rt_ptr;
    }

    pub fn watchZigFile(self: *HotReloadManager, zig_path: []const u8) !void {
        if (!self.enabled) {
            return error.HotReloadNotEnabled;
        }

        try self.file_watcher.watch(zig_path, zigReloadCallback, self);
    }

    fn templateReloadCallback(path: []const u8, context: ?*anyopaque) void {
        if (context) |ctx| {
            const manager = @as(*HotReloadManager, @ptrCast(@alignCast(ctx)));
            manager.notifyReload(path);
        }
    }

    fn zigReloadCallback(path: []const u8, context: ?*anyopaque) void {
        if (context) |ctx| {
            const manager = @as(*HotReloadManager, @ptrCast(@alignCast(ctx)));
            std.debug.print("[HotReload] Backend code changed: {s}\n", .{path});
            std.debug.print("[HotReload] Note: Backend code reloading requires application restart\n", .{});
            manager.notifyReload(path);
        }
    }

    fn notifyReload(self: *HotReloadManager, file_path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.reload_room) |room| {
            const json = std.fmt.allocPrint(self.allocator, "{{\"type\":\"reload\",\"file\":\"{s}\"}}", .{file_path}) catch return;
            defer self.allocator.free(json);

            room.broadcast(json) catch |err| {
                std.debug.print("[HotReload] Error broadcasting reload: {}\n", .{err});
            };
        }
    }

    pub fn watchStaticFiles(self: *HotReloadManager, file_server: *fileserver.FileServer) !void {
        if (!self.enabled) {
            return;
        }

        self.mutex.lock();
        try self.static_file_servers.append(self.allocator, file_server);
        const directory = file_server.directory;
        self.mutex.unlock();

        try self.watchDirectory(directory, staticFileReloadCallback, self);
    }

    fn watchDirectory(self: *HotReloadManager, directory_path: []const u8, callback: *const fn ([]const u8, ?*anyopaque) void, context: ?*anyopaque) !void {
        var dir = std.fs.cwd().openDir(directory_path, .{ .iterate = true }) catch {
            return;
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ directory_path, entry.name });
            defer self.allocator.free(full_path);

            if (entry.kind == .directory) {
                try self.watchDirectory(full_path, callback, context);
            } else {
                self.file_watcher.watch(full_path, callback, context) catch |err| {
                    std.debug.print("[HotReload] Warning: Failed to watch file {s}: {}\n", .{ full_path, err });
                };
            }
        }
    }

    fn staticFileReloadCallback(path: []const u8, context: ?*anyopaque) void {
        if (context) |ctx| {
            const manager = @as(*HotReloadManager, @ptrCast(@alignCast(ctx)));
            manager.notifyReload(path);
        }
    }

    pub fn start(self: *HotReloadManager) !void {
        if (!self.enabled) {
            return;
        }

        try self.file_watcher.start();
    }

    pub fn stop(self: *HotReloadManager) void {
        if (!self.enabled) {
            return;
        }

        self.file_watcher.stop();
    }

    pub fn deinit(self: *HotReloadManager) void {
        self.stop();

        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.template_cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.template_cache.deinit();

        self.static_file_servers.deinit(self.allocator);

        if (self.reload_room) |room| {
            room.deinit();
            self.allocator.destroy(room);
            self.reload_room = null;
        }

        self.file_watcher.deinit();
    }
};

test "HotReloadManager init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = HotReloadManager.init(allocator, true);
    manager.deinit();
}

test "HotReloadManager disabled" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = HotReloadManager.init(allocator, false);
    defer manager.deinit();

    const result = manager.watchTemplate("test.zt.html");
    try std.testing.expectError(error.HotReloadNotEnabled, result);
}
