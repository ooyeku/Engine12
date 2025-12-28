const std = @import("std");

/// Pagination helpers for infinite scroll and load-more patterns
pub const Pagination = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Pagination {
        return .{ .allocator = allocator };
    }

    /// Generate a trigger element for infinite scroll (loads next page when revealed)
    pub fn nextPageTrigger(self: Pagination, url: []const u8, page: usize) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        try result.appendSlice(self.allocator, "<div class=\"htmx-pagination-trigger\" ");
        try result.appendSlice(self.allocator, "hx-get=\"");
        try result.appendSlice(self.allocator, url);

        // Add page parameter
        if (std.mem.indexOf(u8, url, "?")) |_| {
            try result.appendSlice(self.allocator, "&page=");
        } else {
            try result.appendSlice(self.allocator, "?page=");
        }

        const page_str = try std.fmt.allocPrint(self.allocator, "{d}", .{page});
        defer self.allocator.free(page_str);
        try result.appendSlice(self.allocator, page_str);

        try result.appendSlice(self.allocator, "\" ");
        try result.appendSlice(self.allocator, "hx-trigger=\"revealed\" ");
        try result.appendSlice(self.allocator, "hx-swap=\"afterend\" ");
        try result.appendSlice(self.allocator, "hx-indicator=\".htmx-loader\">");

        // Loading indicator
        try result.appendSlice(self.allocator, "<div class=\"htmx-loader\">Loading more...</div>");
        try result.appendSlice(self.allocator, "</div>");

        return result.toOwnedSlice(self.allocator);
    }

    /// Generate a "Load More" button for pagination
    pub fn loadMoreButton(self: Pagination, url: []const u8, page: usize) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        try result.appendSlice(self.allocator, "<button class=\"htmx-load-more\" ");
        try result.appendSlice(self.allocator, "hx-get=\"");
        try result.appendSlice(self.allocator, url);

        // Add page parameter
        if (std.mem.indexOf(u8, url, "?")) |_| {
            try result.appendSlice(self.allocator, "&page=");
        } else {
            try result.appendSlice(self.allocator, "?page=");
        }

        const page_str = try std.fmt.allocPrint(self.allocator, "{d}", .{page});
        defer self.allocator.free(page_str);
        try result.appendSlice(self.allocator, page_str);

        try result.appendSlice(self.allocator, "\" ");
        try result.appendSlice(self.allocator, "hx-swap=\"afterend\" ");
        try result.appendSlice(self.allocator, "hx-target=\"closest .htmx-load-more\">");
        try result.appendSlice(self.allocator, "Load More");
        try result.appendSlice(self.allocator, "</button>");

        return result.toOwnedSlice(self.allocator);
    }

    /// Generate a "Load More" button with custom text
    pub fn loadMoreButtonWithText(self: Pagination, url: []const u8, page: usize, text: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        try result.appendSlice(self.allocator, "<button class=\"htmx-load-more\" ");
        try result.appendSlice(self.allocator, "hx-get=\"");
        try result.appendSlice(self.allocator, url);

        // Add page parameter
        if (std.mem.indexOf(u8, url, "?")) |_| {
            try result.appendSlice(self.allocator, "&page=");
        } else {
            try result.appendSlice(self.allocator, "?page=");
        }

        const page_str = try std.fmt.allocPrint(self.allocator, "{d}", .{page});
        defer self.allocator.free(page_str);
        try result.appendSlice(self.allocator, page_str);

        try result.appendSlice(self.allocator, "\" ");
        try result.appendSlice(self.allocator, "hx-swap=\"afterend\" ");
        try result.appendSlice(self.allocator, "hx-target=\"closest .htmx-load-more\">");
        try result.appendSlice(self.allocator, text);
        try result.appendSlice(self.allocator, "</button>");

        return result.toOwnedSlice(self.allocator);
    }

    /// Generate numbered pagination controls
    pub fn numberedPages(self: Pagination, url: []const u8, current_page: usize, total_pages: usize) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        try result.appendSlice(self.allocator, "<nav class=\"htmx-pagination\">");

        // Previous button
        if (current_page > 1) {
            try result.appendSlice(self.allocator, "<button hx-get=\"");
            try result.appendSlice(self.allocator, url);
            if (std.mem.indexOf(u8, url, "?")) |_| {
                try result.appendSlice(self.allocator, "&page=");
            } else {
                try result.appendSlice(self.allocator, "?page=");
            }
            const prev_str = try std.fmt.allocPrint(self.allocator, "{d}", .{current_page - 1});
            defer self.allocator.free(prev_str);
            try result.appendSlice(self.allocator, prev_str);
            try result.appendSlice(self.allocator, "\" hx-target=\"#content\" hx-swap=\"innerHTML\">&laquo; Prev</button>");
        }

        // Page numbers (show current, prev, next, first, and last)
        const start_page = if (current_page > 2) current_page - 1 else 1;
        const end_page = if (current_page + 1 < total_pages) current_page + 1 else total_pages;

        if (start_page > 1) {
            try result.appendSlice(self.allocator, "<button hx-get=\"");
            try result.appendSlice(self.allocator, url);
            if (std.mem.indexOf(u8, url, "?")) |_| {
                try result.appendSlice(self.allocator, "&page=1");
            } else {
                try result.appendSlice(self.allocator, "?page=1");
            }
            try result.appendSlice(self.allocator, "\" hx-target=\"#content\" hx-swap=\"innerHTML\">1</button>");
            if (start_page > 2) {
                try result.appendSlice(self.allocator, "<span>...</span>");
            }
        }

        var page = start_page;
        while (page <= end_page) : (page += 1) {
            if (page == current_page) {
                try result.appendSlice(self.allocator, "<button class=\"active\" disabled>");
            } else {
                try result.appendSlice(self.allocator, "<button hx-get=\"");
                try result.appendSlice(self.allocator, url);
                if (std.mem.indexOf(u8, url, "?")) |_| {
                    try result.appendSlice(self.allocator, "&page=");
                } else {
                    try result.appendSlice(self.allocator, "?page=");
                }
                const page_str = try std.fmt.allocPrint(self.allocator, "{d}", .{page});
                defer self.allocator.free(page_str);
                try result.appendSlice(self.allocator, page_str);
                try result.appendSlice(self.allocator, "\" hx-target=\"#content\" hx-swap=\"innerHTML\">");
            }
            const page_str = try std.fmt.allocPrint(self.allocator, "{d}", .{page});
            defer self.allocator.free(page_str);
            try result.appendSlice(self.allocator, page_str);
            try result.appendSlice(self.allocator, "</button>");
        }

        if (end_page < total_pages) {
            if (end_page < total_pages - 1) {
                try result.appendSlice(self.allocator, "<span>...</span>");
            }
            try result.appendSlice(self.allocator, "<button hx-get=\"");
            try result.appendSlice(self.allocator, url);
            if (std.mem.indexOf(u8, url, "?")) |_| {
                try result.appendSlice(self.allocator, "&page=");
            } else {
                try result.appendSlice(self.allocator, "?page=");
            }
            const last_str = try std.fmt.allocPrint(self.allocator, "{d}", .{total_pages});
            defer self.allocator.free(last_str);
            try result.appendSlice(self.allocator, last_str);
            try result.appendSlice(self.allocator, "\" hx-target=\"#content\" hx-swap=\"innerHTML\">");
            try result.appendSlice(self.allocator, last_str);
            try result.appendSlice(self.allocator, "</button>");
        }

        // Next button
        if (current_page < total_pages) {
            try result.appendSlice(self.allocator, "<button hx-get=\"");
            try result.appendSlice(self.allocator, url);
            if (std.mem.indexOf(u8, url, "?")) |_| {
                try result.appendSlice(self.allocator, "&page=");
            } else {
                try result.appendSlice(self.allocator, "?page=");
            }
            const next_str = try std.fmt.allocPrint(self.allocator, "{d}", .{current_page + 1});
            defer self.allocator.free(next_str);
            try result.appendSlice(self.allocator, next_str);
            try result.appendSlice(self.allocator, "\" hx-target=\"#content\" hx-swap=\"innerHTML\">Next &raquo;</button>");
        }

        try result.appendSlice(self.allocator, "</nav>");

        return result.toOwnedSlice(self.allocator);
    }
};

/// Convenience functions for pagination
pub fn nextPageTrigger(allocator: std.mem.Allocator, url: []const u8, page: usize) ![]const u8 {
    const pagination = Pagination.init(allocator);
    return pagination.nextPageTrigger(url, page);
}

pub fn loadMoreButton(allocator: std.mem.Allocator, url: []const u8, page: usize) ![]const u8 {
    const pagination = Pagination.init(allocator);
    return pagination.loadMoreButton(url, page);
}

pub fn loadMoreButtonWithText(allocator: std.mem.Allocator, url: []const u8, page: usize, text: []const u8) ![]const u8 {
    const pagination = Pagination.init(allocator);
    return pagination.loadMoreButtonWithText(url, page, text);
}

pub fn numberedPages(allocator: std.mem.Allocator, url: []const u8, current_page: usize, total_pages: usize) ![]const u8 {
    const pagination = Pagination.init(allocator);
    return pagination.numberedPages(url, current_page, total_pages);
}

// Tests
test "nextPageTrigger generates correct HTML" {
    const allocator = std.heap.page_allocator;
    const html = try nextPageTrigger(allocator, "/api/items", 2);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "hx-get=\"/api/items?page=2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hx-trigger=\"revealed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hx-swap=\"afterend\"") != null);
}

test "loadMoreButton generates correct HTML" {
    const allocator = std.heap.page_allocator;
    const html = try loadMoreButton(allocator, "/api/items?filter=active", 3);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "hx-get=\"/api/items?filter=active&page=3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Load More") != null);
}

test "numberedPages generates pagination controls" {
    const allocator = std.heap.page_allocator;
    const html = try numberedPages(allocator, "/api/items", 5, 10);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"htmx-pagination\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Prev") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Next") != null);
}
