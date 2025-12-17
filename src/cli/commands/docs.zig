const std = @import("std");

pub fn generateDocs(allocator: std.mem.Allocator) !void {
    _ = allocator; // Not used, but kept for consistency with other commands

    const docs_content = readDocsFile() catch |err| {
        std.debug.print("Error: Failed to read docs/api-reference.md: {}\n", .{err});
        std.debug.print("Please ensure you're running from the Engine12 root directory,\n", .{});
        std.debug.print("or that docs/api-reference.md exists relative to the executable.\n", .{});
        return err;
    };
    defer std.heap.page_allocator.free(docs_content);

    const cwd = std.fs.cwd();

    cwd.writeFile(.{ .sub_path = "engine12-docs.md", .data = docs_content }) catch |err| {
        std.debug.print("Error: Failed to write engine12-docs.md: {}\n", .{err});
        return err;
    };

    std.debug.print("Successfully generated engine12-docs.md\n", .{});
}

fn readDocsFile() ![]const u8 {
    if (readDocsFromPath("docs/api-reference.md")) |content| {
        return content;
    } else |_| {}

    const exe_path = try std.fs.selfExePathAlloc(std.heap.page_allocator);
    defer std.heap.page_allocator.free(exe_path);

    const last_slash = std.mem.lastIndexOfScalar(u8, exe_path, '/') orelse {
        return error.DocsNotFound;
    };
    const exe_dir = exe_path[0..last_slash];

    var path_buf: [1024]u8 = undefined;
    const relative_path = try std.fmt.bufPrint(&path_buf, "{s}/../docs/api-reference.md", .{exe_dir});

    if (readDocsFromPath(relative_path)) |content| {
        return content;
    } else |_| {}

    return error.DocsNotFound;
}

fn readDocsFromPath(path: []const u8) ![]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    const max_size = 10 * 1024 * 1024; // 10MB max
    if (stat.size > max_size) {
        return error.FileTooLarge;
    }

    const content = try std.heap.page_allocator.alloc(u8, @as(usize, @intCast(stat.size)));
    const bytes_read = try file.readAll(content);
    if (bytes_read != content.len) {
        std.heap.page_allocator.free(content);
        return error.UnexpectedEOF;
    }

    return content;
}
