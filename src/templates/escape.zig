const std = @import("std");

pub const Escape = struct {
    pub fn escapeHtml(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var escaped_count: usize = 0;
        for (input) |char| {
            escaped_count += switch (char) {
                '&' => 5,
                '<' => 4,
                '>' => 4,
                '"' => 6,
                '\'' => 5,
                else => 1,
            };
        }

        if (escaped_count == input.len) {
            return try allocator.dupe(u8, input);
        }

        const output = try allocator.alloc(u8, escaped_count);
        var out_index: usize = 0;

        for (input) |char| {
            switch (char) {
                '&' => {
                    @memcpy(output[out_index .. out_index + 5], "&amp;");
                    out_index += 5;
                },
                '<' => {
                    @memcpy(output[out_index .. out_index + 4], "&lt;");
                    out_index += 4;
                },
                '>' => {
                    @memcpy(output[out_index .. out_index + 4], "&gt;");
                    out_index += 4;
                },
                '"' => {
                    @memcpy(output[out_index .. out_index + 6], "&quot;");
                    out_index += 6;
                },
                '\'' => {
                    @memcpy(output[out_index .. out_index + 5], "&#39;");
                    out_index += 5;
                },
                else => {
                    output[out_index] = char;
                    out_index += 1;
                },
            }
        }

        return output;
    }

    pub fn escapeHtmlComptime(comptime input: []const u8) []const u8 {
        var result: []const u8 = "";
        var i: usize = 0;
        while (i < input.len) {
            const char = input[i];
            result = result ++ switch (char) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\'' => "&#39;",
                else => input[i .. i + 1],
            };
            i += 1;
        }
        return result;
    }
};

test "escapeHtml basic" {
    const allocator = std.testing.allocator;
    const input = "<script>alert('xss')</script>";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings(escaped, "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;");
}

test "escapeHtml ampersand" {
    const allocator = std.testing.allocator;
    const input = "A & B";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings(escaped, "A &amp; B");
}

test "escapeHtml quotes" {
    const allocator = std.testing.allocator;
    const input = "\"hello\" 'world'";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings(escaped, "&quot;hello&quot; &#39;world&#39;");
}

test "escapeHtml no escaping needed" {
    const allocator = std.testing.allocator;
    const input = "Hello World";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings(escaped, "Hello World");
}

test "escapeHtml empty string" {
    const allocator = std.testing.allocator;
    const input = "";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings(escaped, "");
}

test "escapeHtml less than only" {
    const allocator = std.testing.allocator;
    const input = "<";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&lt;", escaped);
}

test "escapeHtml greater than only" {
    const allocator = std.testing.allocator;
    const input = ">";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&gt;", escaped);
}

test "escapeHtml ampersand only" {
    const allocator = std.testing.allocator;
    const input = "&";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&amp;", escaped);
}

test "escapeHtml double quote only" {
    const allocator = std.testing.allocator;
    const input = "\"";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&quot;", escaped);
}

test "escapeHtml single quote only" {
    const allocator = std.testing.allocator;
    const input = "'";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&#39;", escaped);
}

test "escapeHtml all five special characters" {
    const allocator = std.testing.allocator;
    const input = "<>&\"'";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&lt;&gt;&amp;&quot;&#39;", escaped);
}

test "escapeHtml multiple ampersands" {
    const allocator = std.testing.allocator;
    const input = "A && B && C";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("A &amp;&amp; B &amp;&amp; C", escaped);
}

test "escapeHtml multiple less than" {
    const allocator = std.testing.allocator;
    const input = "<<<";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&lt;&lt;&lt;", escaped);
}

test "escapeHtml multiple greater than" {
    const allocator = std.testing.allocator;
    const input = ">>>";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&gt;&gt;&gt;", escaped);
}

test "escapeHtml consecutive special characters" {
    const allocator = std.testing.allocator;
    const input = "<>&";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&lt;&gt;&amp;", escaped);
}

test "escapeHtml special char at start" {
    const allocator = std.testing.allocator;
    const input = "<div>content</div>";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&lt;div&gt;content&lt;/div&gt;", escaped);
}

test "escapeHtml special char at end" {
    const allocator = std.testing.allocator;
    const input = "content>";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("content&gt;", escaped);
}

test "escapeHtml mixed text and special chars" {
    const allocator = std.testing.allocator;
    const input = "Hello <world> & 'goodbye'";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("Hello &lt;world&gt; &amp; &#39;goodbye&#39;", escaped);
}

test "escapeHtml html tag with attributes" {
    const allocator = std.testing.allocator;
    const input = "<a href=\"url\">link</a>";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&lt;a href=&quot;url&quot;&gt;link&lt;/a&gt;", escaped);
}

test "escapeHtml img tag" {
    const allocator = std.testing.allocator;
    const input = "<img src='image.jpg' alt=\"Photo\">";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&lt;img src=&#39;image.jpg&#39; alt=&quot;Photo&quot;&gt;", escaped);
}

test "escapeHtml javascript code" {
    const allocator = std.testing.allocator;
    const input = "if (x > 5 && y < 10) { alert(\"hello\"); }";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("if (x &gt; 5 &amp;&amp; y &lt; 10) { alert(&quot;hello&quot;); }", escaped);
}

test "escapeHtml url with query params" {
    const allocator = std.testing.allocator;
    const input = "http://example.com?a=1&b=2";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("http://example.com?a=1&amp;b=2", escaped);
}

test "escapeHtml json string" {
    const allocator = std.testing.allocator;
    const input = "{\"name\": \"value\"}";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("{&quot;name&quot;: &quot;value&quot;}", escaped);
}

test "escapeHtml unicode characters pass through" {
    const allocator = std.testing.allocator;
    const input = "Hello 世界 🌍";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("Hello 世界 🌍", escaped);
}

test "escapeHtml unicode with special chars" {
    const allocator = std.testing.allocator;
    const input = "こんにちは<world>";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("こんにちは&lt;world&gt;", escaped);
}

test "escapeHtml newlines preserved" {
    const allocator = std.testing.allocator;
    const input = "Line1\nLine2\nLine3";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("Line1\nLine2\nLine3", escaped);
}

test "escapeHtml tabs preserved" {
    const allocator = std.testing.allocator;
    const input = "Col1\tCol2\tCol3";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("Col1\tCol2\tCol3", escaped);
}

test "escapeHtml carriage return preserved" {
    const allocator = std.testing.allocator;
    const input = "Windows\r\nline";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("Windows\r\nline", escaped);
}

test "escapeHtml numbers preserved" {
    const allocator = std.testing.allocator;
    const input = "1234567890";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("1234567890", escaped);
}

test "escapeHtml alphanumeric preserved" {
    const allocator = std.testing.allocator;
    const input = "abcXYZ123";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("abcXYZ123", escaped);
}

test "escapeHtml special punctuation preserved" {
    const allocator = std.testing.allocator;
    const input = "!@#$%^*()_+-=[]{}|;:,.<>?/";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("!@#$%^*()_+-=[]{}|;:,.&lt;&gt;?/", escaped);
}

test "escapeHtml only special chars no text" {
    const allocator = std.testing.allocator;
    const input = "<>'\"&";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&lt;&gt;&#39;&quot;&amp;", escaped);
}

test "escapeHtml already escaped entity" {
    const allocator = std.testing.allocator;
    const input = "&amp;";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&amp;amp;", escaped);
}

test "escapeHtml double escaping prevention not applied" {
    const allocator = std.testing.allocator;
    const input = "&lt;div&gt;";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&amp;lt;div&amp;gt;", escaped);
}

test "escapeHtml long string" {
    const allocator = std.testing.allocator;
    const input = "x" ** 1000;
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings(input, escaped);
}

test "escapeHtml long string with special chars" {
    const allocator = std.testing.allocator;
    const input = "<" ** 100;
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    const expected = "&lt;" ** 100;
    try std.testing.expectEqualStrings(expected, escaped);
}

test "escapeHtml single character normal" {
    const allocator = std.testing.allocator;
    const input = "a";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("a", escaped);
}

test "escapeHtml whitespace only" {
    const allocator = std.testing.allocator;
    const input = "   ";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("   ", escaped);
}

test "escapeHtml mixed whitespace" {
    const allocator = std.testing.allocator;
    const input = " \t\n\r ";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings(" \t\n\r ", escaped);
}

test "escapeHtml sql injection attempt" {
    const allocator = std.testing.allocator;
    const input = "'; DROP TABLE users; --";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&#39;; DROP TABLE users; --", escaped);
}

test "escapeHtml xss script tag" {
    const allocator = std.testing.allocator;
    const input = "<script>alert('XSS')</script>";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&lt;script&gt;alert(&#39;XSS&#39;)&lt;/script&gt;", escaped);
}

test "escapeHtml xss img onerror" {
    const allocator = std.testing.allocator;
    const input = "<img src=x onerror=\"alert('XSS')\">";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&lt;img src=x onerror=&quot;alert(&#39;XSS&#39;)&quot;&gt;", escaped);
}

test "escapeHtml xss javascript protocol" {
    const allocator = std.testing.allocator;
    const input = "<a href=\"javascript:alert('XSS')\">click</a>";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&lt;a href=&quot;javascript:alert(&#39;XSS&#39;)&quot;&gt;click&lt;/a&gt;", escaped);
}

test "escapeHtml html comment" {
    const allocator = std.testing.allocator;
    const input = "<!-- comment -->";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&lt;!-- comment --&gt;", escaped);
}

test "escapeHtml cdata section" {
    const allocator = std.testing.allocator;
    const input = "<![CDATA[content]]>";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&lt;![CDATA[content]]&gt;", escaped);
}

test "escapeHtml doctype declaration" {
    const allocator = std.testing.allocator;
    const input = "<!DOCTYPE html>";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&lt;!DOCTYPE html&gt;", escaped);
}

test "escapeHtml xml declaration" {
    const allocator = std.testing.allocator;
    const input = "<?xml version=\"1.0\"?>";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("&lt;?xml version=&quot;1.0&quot;?&gt;", escaped);
}

test "escapeHtml backslash preserved" {
    const allocator = std.testing.allocator;
    const input = "C:\\path\\to\\file";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("C:\\path\\to\\file", escaped);
}

test "escapeHtml forward slash preserved" {
    const allocator = std.testing.allocator;
    const input = "/path/to/file";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("/path/to/file", escaped);
}

test "escapeHtml null byte should be preserved" {
    const allocator = std.testing.allocator;
    const input = "before\x00after";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("before\x00after", escaped);
}

test "escapeHtml control characters preserved" {
    const allocator = std.testing.allocator;
    const input = "\x01\x02\x03";
    const escaped = try Escape.escapeHtml(allocator, input);
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("\x01\x02\x03", escaped);
}

test "escapeHtml very long mixed content" {
    const allocator = std.testing.allocator;
    var input_buf: [5000]u8 = undefined;
    for (&input_buf, 0..) |*byte, i| {
        byte.* = switch (i % 6) {
            0 => '<',
            1 => '>',
            2 => '&',
            3 => '"',
            4 => '\'',
            else => 'x',
        };
    }
    const escaped = try Escape.escapeHtml(allocator, &input_buf);
    defer allocator.free(escaped);
    try std.testing.expect(escaped.len > input_buf.len);
}

test "escapeHtmlComptime basic" {
    const result = comptime Escape.escapeHtmlComptime("<script>alert('xss')</script>");
    try std.testing.expectEqualStrings("&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;", result);
}

test "escapeHtmlComptime all special chars" {
    const result = comptime Escape.escapeHtmlComptime("<>&\"'");
    try std.testing.expectEqualStrings("&lt;&gt;&amp;&quot;&#39;", result);
}

test "escapeHtmlComptime no escaping needed" {
    const result = comptime Escape.escapeHtmlComptime("Hello World");
    try std.testing.expectEqualStrings("Hello World", result);
}

test "escapeHtmlComptime empty string" {
    const result = comptime Escape.escapeHtmlComptime("");
    try std.testing.expectEqualStrings("", result);
}

test "escapeHtmlComptime ampersand" {
    const result = comptime Escape.escapeHtmlComptime("A & B");
    try std.testing.expectEqualStrings("A &amp; B", result);
}

test "escapeHtmlComptime less than" {
    const result = comptime Escape.escapeHtmlComptime("<div>");
    try std.testing.expectEqualStrings("&lt;div&gt;", result);
}

test "escapeHtmlComptime quotes" {
    const result = comptime Escape.escapeHtmlComptime("\"hello\" 'world'");
    try std.testing.expectEqualStrings("&quot;hello&quot; &#39;world&#39;", result);
}

test "escapeHtmlComptime single character" {
    const result = comptime Escape.escapeHtmlComptime("<");
    try std.testing.expectEqualStrings("&lt;", result);
}

test "escapeHtmlComptime mixed content" {
    const result = comptime Escape.escapeHtmlComptime("Hello <world> & 'goodbye'");
    try std.testing.expectEqualStrings("Hello &lt;world&gt; &amp; &#39;goodbye&#39;", result);
}

test "escapeHtmlComptime url" {
    const result = comptime Escape.escapeHtmlComptime("http://example.com?a=1&b=2");
    try std.testing.expectEqualStrings("http://example.com?a=1&amp;b=2", result);
}

test "escapeHtmlComptime html tag" {
    const result = comptime Escape.escapeHtmlComptime("<a href=\"link\">text</a>");
    try std.testing.expectEqualStrings("&lt;a href=&quot;link&quot;&gt;text&lt;/a&gt;", result);
}

test "escapeHtmlComptime newlines" {
    const result = comptime Escape.escapeHtmlComptime("Line1\nLine2");
    try std.testing.expectEqualStrings("Line1\nLine2", result);
}

test "escapeHtmlComptime unicode" {
    const result = comptime Escape.escapeHtmlComptime("Hello 世界");
    try std.testing.expectEqualStrings("Hello 世界", result);
}

test "escapeHtmlComptime consecutive special chars" {
    const result = comptime Escape.escapeHtmlComptime("<<<>>>");
    try std.testing.expectEqualStrings("&lt;&lt;&lt;&gt;&gt;&gt;", result);
}

test "escapeHtmlComptime numbers preserved" {
    const result = comptime Escape.escapeHtmlComptime("123456");
    try std.testing.expectEqualStrings("123456", result);
}

test "escapeHtmlComptime whitespace" {
    const result = comptime Escape.escapeHtmlComptime("  spaces  ");
    try std.testing.expectEqualStrings("  spaces  ", result);
}

test "escapeHtmlComptime xss attempt" {
    const result = comptime Escape.escapeHtmlComptime("<img src=x onerror='alert(1)'>");
    try std.testing.expectEqualStrings("&lt;img src=x onerror=&#39;alert(1)&#39;&gt;", result);
}

test "escapeHtmlComptime json" {
    const result = comptime Escape.escapeHtmlComptime("{\"key\": \"value\"}");
    try std.testing.expectEqualStrings("{&quot;key&quot;: &quot;value&quot;}", result);
}

test "escapeHtmlComptime already escaped" {
    const result = comptime Escape.escapeHtmlComptime("&amp;");
    try std.testing.expectEqualStrings("&amp;amp;", result);
}

test "escapeHtmlComptime tabs" {
    const result = comptime Escape.escapeHtmlComptime("A\tB\tC");
    try std.testing.expectEqualStrings("A\tB\tC", result);
}
