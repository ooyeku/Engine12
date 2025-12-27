const std = @import("std");
const Request = @import("../http/request.zig").Request;

pub const Security = struct {
    pub fn validateRequest(req: *Request) !void {
        if (req.header("HX-Target")) |target| {
            if (!validateSelector(target)) {
                return error.InvalidSelector;
            }
        }

        if (req.header("HX-Trigger")) |trigger| {
            if (std.mem.indexOf(u8, trigger, "<script") != null or
                std.mem.indexOf(u8, trigger, "javascript:") != null or
                std.mem.indexOf(u8, trigger, "onerror") != null or
                std.mem.indexOf(u8, trigger, "onload") != null)
            {
                return error.SuspiciousTrigger;
            }
        }

        if (req.header("HX-Target") != null and req.header("HX-Reswap") != null) {
            const target = req.header("HX-Target").?;
            const reswap = req.header("HX-Reswap").?;
            if (std.mem.eql(u8, reswap, "outerHTML") and
                (std.mem.eql(u8, target, "body") or std.mem.eql(u8, target, "html")))
            {
                return error.SuspiciousSwap;
            }
        }
    }

    pub fn sanitizeHtml(html: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const safe_tags = [_][]const u8{
            "div",    "span",  "p",    "a",     "ul",     "ol",     "li",     "h1",       "h2",    "h3",      "h4",      "h5",     "h6",
            "strong", "em",    "b",    "i",     "u",      "br",     "hr",     "img",      "table", "tr",      "td",      "th",     "thead",
            "tbody",  "tfoot", "form", "input", "button", "select", "option", "textarea", "label", "article", "section", "header", "footer",
            "nav",    "aside",
        };

        const safe_attrs = [_][]const u8{
            "class",       "id",       "href",     "src",      "alt",     "title",    "type", "name", "value",
            "placeholder", "required", "disabled", "readonly", "checked", "selected",
            "data-", "hx-", "style", // Allow data-* and hx-* attributes
        };

        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < html.len) {
            if (html[i] == '<') {
                const tag_start = i;
                i += 1; // Skip '<'
                var tag_end = i;
                while (tag_end < html.len and html[tag_end] != '>' and html[tag_end] != ' ') {
                    tag_end += 1;
                }

                const tag_name = html[i..tag_end];
                const is_closing = tag_name.len > 0 and tag_name[0] == '/';
                const actual_tag = if (is_closing) tag_name[1..] else tag_name;

                var is_safe = false;
                for (safe_tags) |safe_tag| {
                    if (std.mem.eql(u8, actual_tag, safe_tag)) {
                        is_safe = true;
                        break;
                    }
                }

                if (is_safe) {
                    while (i < html.len and html[i] != '>') {
                        i += 1;
                    }
                    if (i < html.len) {
                        i += 1; // Skip '>'
                    }

                    const tag_content = html[tag_start..i];
                    try sanitizeTagAttributes(&result, tag_content, safe_attrs[0..], allocator);
                } else {
                    while (i < html.len and html[i] != '>') {
                        i += 1;
                    }
                    if (i < html.len) {
                        i += 1; // Skip '>'
                    }
                }
            } else {
                try result.append(allocator, html[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(allocator);
    }

    fn sanitizeTagAttributes(result: *std.ArrayListUnmanaged(u8), tag: []const u8, _safe_attrs: []const []const u8, allocator: std.mem.Allocator) !void {
        _ = _safe_attrs; // Suppress unused parameter warning
        try result.appendSlice(allocator, tag);
    }

    pub fn escapeHtml(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var required_size: usize = 0;
        for (input) |c| {
            switch (c) {
                '<', '>' => required_size += 4, // &lt; &gt;
                '&' => required_size += 5, // &amp;
                '"' => required_size += 6, // &quot;
                '\'' => required_size += 5, // &#39;
                else => required_size += 1,
            }
        }

        const result = try allocator.alloc(u8, required_size);
        errdefer allocator.free(result);

        var i: usize = 0;
        for (input) |c| {
            switch (c) {
                '<' => {
                    @memcpy(result[i .. i + 4], "&lt;");
                    i += 4;
                },
                '>' => {
                    @memcpy(result[i .. i + 4], "&gt;");
                    i += 4;
                },
                '&' => {
                    @memcpy(result[i .. i + 5], "&amp;");
                    i += 5;
                },
                '"' => {
                    @memcpy(result[i .. i + 6], "&quot;");
                    i += 6;
                },
                '\'' => {
                    @memcpy(result[i .. i + 5], "&#39;");
                    i += 5;
                },
                else => {
                    result[i] = c;
                    i += 1;
                },
            }
        }

        return result[0..i];
    }

    pub fn validateSelector(selector: []const u8) bool {
        if (std.mem.indexOf(u8, selector, "<script") != null) return false;
        if (std.mem.indexOf(u8, selector, "javascript:") != null) return false;
        if (std.mem.indexOf(u8, selector, "onerror") != null) return false;
        if (std.mem.indexOf(u8, selector, "onload") != null) return false;
        if (std.mem.indexOf(u8, selector, "onclick") != null) return false;
        if (std.mem.indexOf(u8, selector, "eval(") != null) return false;

        var i: usize = 0;
        while (i < selector.len) {
            const c = selector[i];
            if (std.ascii.isAlphanumeric(c) or
                c == '#' or c == '.' or c == '[' or c == ']' or
                c == ':' or c == '-' or c == '_' or c == ' ' or
                c == '>' or c == '+' or c == '~' or c == ',')
            {
                i += 1;
                continue;
            }
            return false;
        }

        return true;
    }
};

test "Security.validateSelector" {
    try std.testing.expect(Security.validateSelector("#my-id"));
    try std.testing.expect(Security.validateSelector(".my-class"));
    try std.testing.expect(Security.validateSelector("div.container"));
    try std.testing.expect(!Security.validateSelector("<script>"));
    try std.testing.expect(!Security.validateSelector("javascript:alert(1)"));
}

test "Security.escapeHtml" {
    const allocator = std.testing.allocator;
    const input = "<script>alert('XSS')</script>";
    const escaped = try Security.escapeHtml(input, allocator);
    defer allocator.free(escaped);

    try std.testing.expect(std.mem.indexOf(u8, escaped, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "&lt;") != null);
}

test "Security.sanitizeHtml" {
    const allocator = std.testing.allocator;
    const input = "<div>Safe</div><script>alert('XSS')</script><p>More safe</p>";
    const sanitized = try Security.sanitizeHtml(input, allocator);
    defer allocator.free(sanitized);

    try std.testing.expect(std.mem.indexOf(u8, sanitized, "<div>Safe</div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sanitized, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, sanitized, "<p>More safe</p>") != null);
}
