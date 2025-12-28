const std = @import("std");

/// Optimistic UI helpers for immediate feedback
pub const OptimisticUI = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OptimisticUI {
        return .{ .allocator = allocator };
    }

    /// Generate attributes for optimistic HTML update
    pub fn htmlAttributes(self: OptimisticUI, optimistic_html: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        try result.appendSlice(self.allocator, "hx-swap-oob=\"true\" ");
        try result.appendSlice(self.allocator, "hx-on::before-request=\"this.dataset.original = this.innerHTML; this.innerHTML = '");

        // Escape single quotes in HTML
        for (optimistic_html) |c| {
            if (c == '\'') {
                try result.appendSlice(self.allocator, "\\'");
            } else {
                try result.append(self.allocator, c);
            }
        }

        try result.appendSlice(self.allocator, "';\" ");
        try result.appendSlice(self.allocator, "hx-on::after-request=\"if(event.detail.failed) { this.innerHTML = this.dataset.original; }\"");

        return result.toOwnedSlice(self.allocator);
    }

    /// Generate attributes for optimistic class toggling
    pub fn classAttributes(self: OptimisticUI, add_class: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        try result.appendSlice(self.allocator, "hx-on::before-request=\"this.classList.add('");
        try result.appendSlice(self.allocator, add_class);
        try result.appendSlice(self.allocator, "');\" ");
        try result.appendSlice(self.allocator, "hx-on::after-request=\"if(event.detail.failed) { this.classList.remove('");
        try result.appendSlice(self.allocator, add_class);
        try result.appendSlice(self.allocator, "'); }\"");

        return result.toOwnedSlice(self.allocator);
    }

    /// Generate attributes for optimistic removal
    pub fn removeAttributes(self: OptimisticUI) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        try result.appendSlice(self.allocator,
            \\hx-on::before-request="this.style.opacity = '0.5'; this.dataset.removed = 'true';"
            \\hx-on::after-request="if(event.detail.failed) { this.style.opacity = '1'; delete this.dataset.removed; } else { this.remove(); }"
        );

        return result.toOwnedSlice(self.allocator);
    }

    /// Generate a button with optimistic disabled state
    pub fn button(self: OptimisticUI, text: []const u8, url: []const u8, loading_text: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        try result.appendSlice(self.allocator, "<button ");
        try result.appendSlice(self.allocator, "hx-post=\"");
        try result.appendSlice(self.allocator, url);
        try result.appendSlice(self.allocator, "\" ");
        try result.appendSlice(self.allocator, "hx-on::before-request=\"this.disabled = true; this.dataset.originalText = this.innerText; this.innerText = '");
        try result.appendSlice(self.allocator, loading_text);
        try result.appendSlice(self.allocator, "';\" ");
        try result.appendSlice(self.allocator, "hx-on::after-request=\"this.disabled = false; this.innerText = this.dataset.originalText;\">");
        try result.appendSlice(self.allocator, text);
        try result.appendSlice(self.allocator, "</button>");

        return result.toOwnedSlice(self.allocator);
    }

    /// Generate optimistic counter increment
    pub fn counterIncrement(self: OptimisticUI, selector: []const u8, delta: i32) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        const delta_str = try std.fmt.allocPrint(self.allocator, "{d}", .{delta});
        defer self.allocator.free(delta_str);

        try result.appendSlice(self.allocator, "hx-on::before-request=\"");
        try result.appendSlice(self.allocator, "const el = document.querySelector('");
        try result.appendSlice(self.allocator, selector);
        try result.appendSlice(self.allocator, "'); ");
        try result.appendSlice(self.allocator, "const current = parseInt(el.innerText) || 0; ");
        try result.appendSlice(self.allocator, "el.dataset.original = current; ");
        try result.appendSlice(self.allocator, "el.innerText = current + ");
        try result.appendSlice(self.allocator, delta_str);
        try result.appendSlice(self.allocator, ";\" ");
        try result.appendSlice(self.allocator, "hx-on::after-request=\"if(event.detail.failed) { ");
        try result.appendSlice(self.allocator, "const el = document.querySelector('");
        try result.appendSlice(self.allocator, selector);
        try result.appendSlice(self.allocator, "'); ");
        try result.appendSlice(self.allocator, "el.innerText = el.dataset.original; }\"");

        return result.toOwnedSlice(self.allocator);
    }

    /// Generate optimistic list item addition
    pub fn listItemAdd(self: OptimisticUI, list_selector: []const u8, item_html: []const u8) ![]const u8 {
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        try result.appendSlice(self.allocator, "hx-on::before-request=\"");
        try result.appendSlice(self.allocator, "const list = document.querySelector('");
        try result.appendSlice(self.allocator, list_selector);
        try result.appendSlice(self.allocator, "'); ");
        try result.appendSlice(self.allocator, "const temp = document.createElement('div'); ");
        try result.appendSlice(self.allocator, "temp.innerHTML = '");

        // Escape single quotes in HTML
        for (item_html) |c| {
            if (c == '\'') {
                try result.appendSlice(self.allocator, "\\'");
            } else {
                try result.append(self.allocator, c);
            }
        }

        try result.appendSlice(self.allocator, "'; ");
        try result.appendSlice(self.allocator, "const item = temp.firstElementChild; ");
        try result.appendSlice(self.allocator, "item.dataset.optimistic = 'true'; ");
        try result.appendSlice(self.allocator, "list.insertBefore(item, list.firstChild);\" ");
        try result.appendSlice(self.allocator, "hx-on::after-request=\"if(event.detail.failed) { ");
        try result.appendSlice(self.allocator, "const list = document.querySelector('");
        try result.appendSlice(self.allocator, list_selector);
        try result.appendSlice(self.allocator, "'); ");
        try result.appendSlice(self.allocator, "const item = list.querySelector('[data-optimistic]'); ");
        try result.appendSlice(self.allocator, "if(item) item.remove(); }\"");

        return result.toOwnedSlice(self.allocator);
    }
};

/// Convenience functions for optimistic UI
pub fn withOptimisticHtml(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    const ui = OptimisticUI.init(allocator);
    return ui.htmlAttributes(html);
}

pub fn withOptimisticClass(allocator: std.mem.Allocator, class: []const u8) ![]const u8 {
    const ui = OptimisticUI.init(allocator);
    return ui.classAttributes(class);
}

pub fn withOptimisticRemove(allocator: std.mem.Allocator) ![]const u8 {
    const ui = OptimisticUI.init(allocator);
    return ui.removeAttributes();
}

pub fn optimisticButton(allocator: std.mem.Allocator, text: []const u8, url: []const u8, loading_text: []const u8) ![]const u8 {
    const ui = OptimisticUI.init(allocator);
    return ui.button(text, url, loading_text);
}

pub fn withCounterIncrement(allocator: std.mem.Allocator, selector: []const u8, delta: i32) ![]const u8 {
    const ui = OptimisticUI.init(allocator);
    return ui.counterIncrement(selector, delta);
}

pub fn withListItemAdd(allocator: std.mem.Allocator, list_selector: []const u8, item_html: []const u8) ![]const u8 {
    const ui = OptimisticUI.init(allocator);
    return ui.listItemAdd(list_selector, item_html);
}

// Tests
test "optimistic class attributes" {
    const allocator = std.heap.page_allocator;
    const attrs = try withOptimisticClass(allocator, "loading");
    defer allocator.free(attrs);

    try std.testing.expect(std.mem.indexOf(u8, attrs, "classList.add('loading')") != null);
    try std.testing.expect(std.mem.indexOf(u8, attrs, "classList.remove('loading')") != null);
}

test "optimistic remove attributes" {
    const allocator = std.heap.page_allocator;
    const attrs = try withOptimisticRemove(allocator);
    defer allocator.free(attrs);

    try std.testing.expect(std.mem.indexOf(u8, attrs, "opacity = '0.5'") != null);
    try std.testing.expect(std.mem.indexOf(u8, attrs, "remove()") != null);
}

test "optimistic button" {
    const allocator = std.heap.page_allocator;
    const html = try optimisticButton(allocator, "Submit", "/api/submit", "Submitting...");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "Submit") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Submitting...") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "disabled = true") != null);
}

test "counter increment" {
    const allocator = std.heap.page_allocator;
    const attrs = try withCounterIncrement(allocator, "#counter", 1);
    defer allocator.free(attrs);

    try std.testing.expect(std.mem.indexOf(u8, attrs, "querySelector('#counter')") != null);
    try std.testing.expect(std.mem.indexOf(u8, attrs, "current + 1") != null);
}
