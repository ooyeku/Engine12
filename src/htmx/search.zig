const std = @import("std");

/// Search and autocomplete helpers with debouncing
pub const Search = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Search {
        return .{ .allocator = allocator };
    }

    /// Generate a search input with debouncing
    pub fn input(self: Search, url: []const u8, debounce_ms: u32) ![]const u8 {
        return self.inputWithOptions(url, debounce_ms, .{});
    }

    pub const InputOptions = struct {
        name: []const u8 = "q",
        placeholder: []const u8 = "Search...",
        target: []const u8 = "#search-results",
        min_length: usize = 2,
        trigger_on_load: bool = false,
    };

    /// Generate a search input with custom options
    pub fn inputWithOptions(self: Search, url: []const u8, debounce_ms: u32, opts: InputOptions) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        try result.appendSlice(self.allocator, "<input type=\"search\" ");
        try result.appendSlice(self.allocator, "name=\"");
        try result.appendSlice(self.allocator, opts.name);
        try result.appendSlice(self.allocator, "\" ");
        try result.appendSlice(self.allocator, "placeholder=\"");
        try result.appendSlice(self.allocator, opts.placeholder);
        try result.appendSlice(self.allocator, "\" ");
        try result.appendSlice(self.allocator, "hx-get=\"");
        try result.appendSlice(self.allocator, url);
        try result.appendSlice(self.allocator, "\" ");
        try result.appendSlice(self.allocator, "hx-trigger=\"keyup changed delay:");

        const debounce_str = try std.fmt.allocPrint(self.allocator, "{d}ms", .{debounce_ms});
        defer self.allocator.free(debounce_str);
        try result.appendSlice(self.allocator, debounce_str);

        if (opts.trigger_on_load) {
            try result.appendSlice(self.allocator, ", load");
        }

        try result.appendSlice(self.allocator, "\" ");
        try result.appendSlice(self.allocator, "hx-target=\"");
        try result.appendSlice(self.allocator, opts.target);
        try result.appendSlice(self.allocator, "\" ");
        try result.appendSlice(self.allocator, "hx-indicator=\".htmx-search-indicator\" ");

        // Add keyboard navigation support
        try result.appendSlice(self.allocator, "autocomplete=\"off\" ");
        try result.appendSlice(self.allocator, "aria-autocomplete=\"list\" ");
        try result.appendSlice(self.allocator, "role=\"combobox\" ");
        try result.appendSlice(self.allocator, "aria-expanded=\"false\" ");
        try result.appendSlice(self.allocator, "aria-controls=\"");
        try result.appendSlice(self.allocator, opts.target[1..]); // Remove # from target
        try result.appendSlice(self.allocator, "\">");

        return result.toOwnedSlice(self.allocator);
    }

    /// Generate search results container with keyboard navigation
    pub fn resultsContainer(self: Search, id: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        try result.appendSlice(self.allocator, "<div id=\"");
        try result.appendSlice(self.allocator, id);
        try result.appendSlice(self.allocator, "\" ");
        try result.appendSlice(self.allocator, "class=\"htmx-search-results\" ");
        try result.appendSlice(self.allocator, "role=\"listbox\">");
        try result.appendSlice(self.allocator, "</div>");

        return result.toOwnedSlice(self.allocator);
    }

    /// Generate a single search result item
    pub fn resultItem(self: Search, text: []const u8, value: []const u8, url: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        try result.appendSlice(self.allocator, "<div class=\"htmx-search-result\" ");
        try result.appendSlice(self.allocator, "role=\"option\" ");
        try result.appendSlice(self.allocator, "tabindex=\"-1\" ");
        try result.appendSlice(self.allocator, "data-value=\"");
        try result.appendSlice(self.allocator, value);
        try result.appendSlice(self.allocator, "\" ");
        try result.appendSlice(self.allocator, "hx-get=\"");
        try result.appendSlice(self.allocator, url);
        try result.appendSlice(self.allocator, "\" ");
        try result.appendSlice(self.allocator, "hx-trigger=\"click\">");
        try result.appendSlice(self.allocator, text);
        try result.appendSlice(self.allocator, "</div>");

        return result.toOwnedSlice(self.allocator);
    }

    /// Generate a search indicator/spinner
    pub fn indicator(self: Search) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        try result.appendSlice(self.allocator,
            \\<div class="htmx-search-indicator">
            \\  <svg class="htmx-search-spinner" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
            \\    <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
            \\    <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
            \\  </svg>
            \\</div>
        );

        return result.toOwnedSlice(self.allocator);
    }

    /// Generate empty state for no results
    pub fn noResults(self: Search, message: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        try result.appendSlice(self.allocator, "<div class=\"htmx-search-empty\">");
        try result.appendSlice(self.allocator, message);
        try result.appendSlice(self.allocator, "</div>");

        return result.toOwnedSlice(self.allocator);
    }
};

/// Convenience functions for search
pub fn input(allocator: std.mem.Allocator, url: []const u8, debounce_ms: u32) ![]const u8 {
    const search = Search.init(allocator);
    return search.input(url, debounce_ms);
}

pub fn inputWithOptions(allocator: std.mem.Allocator, url: []const u8, debounce_ms: u32, opts: Search.InputOptions) ![]const u8 {
    const search = Search.init(allocator);
    return search.inputWithOptions(url, debounce_ms, opts);
}

pub fn resultsContainer(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    const search = Search.init(allocator);
    return search.resultsContainer(id);
}

pub fn resultItem(allocator: std.mem.Allocator, text: []const u8, value: []const u8, url: []const u8) ![]const u8 {
    const search = Search.init(allocator);
    return search.resultItem(text, value, url);
}

pub fn indicator(allocator: std.mem.Allocator) ![]const u8 {
    const search = Search.init(allocator);
    return search.indicator();
}

pub fn noResults(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    const search = Search.init(allocator);
    return search.noResults(message);
}

// Tests
test "search input generates correct HTML" {
    const allocator = std.heap.page_allocator;
    const html = try input(allocator, "/api/search", 300);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "hx-get=\"/api/search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "delay:300ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "role=\"combobox\"") != null);
}

test "search input with custom options" {
    const allocator = std.heap.page_allocator;
    const html = try inputWithOptions(allocator, "/api/search", 500, .{
        .name = "search",
        .placeholder = "Find items...",
        .target = "#results",
        .min_length = 3,
    });
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "name=\"search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "placeholder=\"Find items...\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "delay:500ms") != null);
}

test "result item generates correct HTML" {
    const allocator = std.heap.page_allocator;
    const html = try resultItem(allocator, "Test Item", "test-id", "/items/test");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "Test Item") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-value=\"test-id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "hx-get=\"/items/test\"") != null);
}
