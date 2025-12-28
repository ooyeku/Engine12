const std = @import("std");

/// Built-in validators for form validation.
///
/// These validators can be used with FormValidator.validate() to perform
/// common validation checks on form fields.
///
/// Example usage:
/// ```zig
/// const validators = @import("htmx").validators;
/// validator.validate("email", validators.isEmail, "Invalid email address");
/// validator.validate("age", validators.isNumeric, "Must be a number");
/// ```

// ============================================================================
// String Validators
// ============================================================================

/// Validate that a string is not empty
pub fn isRequired(value: []const u8) bool {
    return value.len > 0;
}

/// Validate that a string is not empty after trimming whitespace
pub fn isRequiredTrimmed(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\n\r").len > 0;
}

/// Create a min length validator
pub fn minLength(comptime min: usize) fn ([]const u8) bool {
    return struct {
        pub fn validate(value: []const u8) bool {
            return value.len >= min;
        }
    }.validate;
}

/// Create a max length validator
pub fn maxLength(comptime max: usize) fn ([]const u8) bool {
    return struct {
        pub fn validate(value: []const u8) bool {
            return value.len <= max;
        }
    }.validate;
}

/// Create a length range validator
pub fn lengthBetween(comptime min: usize, comptime max: usize) fn ([]const u8) bool {
    return struct {
        pub fn validate(value: []const u8) bool {
            return value.len >= min and value.len <= max;
        }
    }.validate;
}

/// Create an exact length validator
pub fn exactLength(comptime length: usize) fn ([]const u8) bool {
    return struct {
        pub fn validate(value: []const u8) bool {
            return value.len == length;
        }
    }.validate;
}

// ============================================================================
// Email Validator
// ============================================================================

/// Validate email format (basic validation)
pub fn isEmail(value: []const u8) bool {
    if (value.len == 0) return false;

    // Find @ symbol
    const at_pos = std.mem.indexOf(u8, value, "@") orelse return false;

    // Must have something before @
    if (at_pos == 0) return false;

    // Must have something after @
    if (at_pos >= value.len - 1) return false;

    const domain = value[at_pos + 1 ..];

    // Domain must contain a dot
    const dot_pos = std.mem.indexOf(u8, domain, ".") orelse return false;

    // Must have something before and after the dot
    if (dot_pos == 0 or dot_pos >= domain.len - 1) return false;

    // Check for invalid characters in local part
    for (value[0..at_pos]) |c| {
        if (!isValidEmailLocalChar(c)) return false;
    }

    // Check for invalid characters in domain
    for (domain) |c| {
        if (!isValidEmailDomainChar(c)) return false;
    }

    return true;
}

fn isValidEmailLocalChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-' or c == '+';
}

fn isValidEmailDomainChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '-';
}

// ============================================================================
// URL Validator
// ============================================================================

/// Validate URL format
pub fn isUrl(value: []const u8) bool {
    if (value.len == 0) return false;

    // Check for common schemes
    const valid_schemes = [_][]const u8{ "http://", "https://", "ftp://" };
    var has_valid_scheme = false;

    for (valid_schemes) |scheme| {
        if (std.mem.startsWith(u8, value, scheme)) {
            has_valid_scheme = true;
            break;
        }
    }

    if (!has_valid_scheme) return false;

    // Find the domain part
    const scheme_end = std.mem.indexOf(u8, value, "://").? + 3;
    if (scheme_end >= value.len) return false;

    const rest = value[scheme_end..];
    if (rest.len == 0) return false;

    // Must have at least one valid domain character
    return rest[0] != '/' and rest[0] != ':';
}

/// Validate URL format (allows relative URLs)
pub fn isRelativeUrl(value: []const u8) bool {
    if (value.len == 0) return false;

    // Absolute URL
    if (isUrl(value)) return true;

    // Relative URL starting with /
    if (value[0] == '/') return true;

    return false;
}

// ============================================================================
// Numeric Validators
// ============================================================================

/// Validate that a string contains only digits
pub fn isNumeric(value: []const u8) bool {
    if (value.len == 0) return false;

    for (value) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }

    return true;
}

/// Validate that a string is a valid integer (including negative)
pub fn isInteger(value: []const u8) bool {
    if (value.len == 0) return false;

    var start: usize = 0;
    if (value[0] == '-' or value[0] == '+') {
        if (value.len == 1) return false;
        start = 1;
    }

    for (value[start..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }

    return true;
}

/// Validate that a string is a valid decimal number
pub fn isDecimal(value: []const u8) bool {
    if (value.len == 0) return false;

    var has_dot = false;
    var start: usize = 0;

    if (value[0] == '-' or value[0] == '+') {
        if (value.len == 1) return false;
        start = 1;
    }

    for (value[start..]) |c| {
        if (c == '.') {
            if (has_dot) return false; // Multiple dots
            has_dot = true;
        } else if (!std.ascii.isDigit(c)) {
            return false;
        }
    }

    return true;
}

/// Create a minimum value validator (for integer strings)
pub fn minValue(comptime min: i64) fn ([]const u8) bool {
    return struct {
        pub fn validate(value: []const u8) bool {
            const num = std.fmt.parseInt(i64, value, 10) catch return false;
            return num >= min;
        }
    }.validate;
}

/// Create a maximum value validator (for integer strings)
pub fn maxValue(comptime max: i64) fn ([]const u8) bool {
    return struct {
        pub fn validate(value: []const u8) bool {
            const num = std.fmt.parseInt(i64, value, 10) catch return false;
            return num <= max;
        }
    }.validate;
}

/// Create a value range validator (for integer strings)
pub fn valueBetween(comptime min: i64, comptime max: i64) fn ([]const u8) bool {
    return struct {
        pub fn validate(value: []const u8) bool {
            const num = std.fmt.parseInt(i64, value, 10) catch return false;
            return num >= min and num <= max;
        }
    }.validate;
}

// ============================================================================
// Alphanumeric Validators
// ============================================================================

/// Validate that a string contains only alphanumeric characters
pub fn isAlphanumeric(value: []const u8) bool {
    if (value.len == 0) return false;

    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c)) return false;
    }

    return true;
}

/// Validate that a string contains only alphabetic characters
pub fn isAlpha(value: []const u8) bool {
    if (value.len == 0) return false;

    for (value) |c| {
        if (!std.ascii.isAlphabetic(c)) return false;
    }

    return true;
}

/// Validate that a string contains only alphanumeric characters and underscores
pub fn isAlphanumericUnderscore(value: []const u8) bool {
    if (value.len == 0) return false;

    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }

    return true;
}

/// Validate a slug (lowercase alphanumeric with hyphens)
pub fn isSlug(value: []const u8) bool {
    if (value.len == 0) return false;

    // Cannot start or end with hyphen
    if (value[0] == '-' or value[value.len - 1] == '-') return false;

    for (value) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-') return false;
    }

    return true;
}

/// Validate a username (alphanumeric, underscore, hyphen, 3-20 chars)
pub fn isUsername(value: []const u8) bool {
    if (value.len < 3 or value.len > 20) return false;

    // First char must be alphanumeric
    if (!std.ascii.isAlphanumeric(value[0])) return false;

    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }

    return true;
}

// ============================================================================
// Pattern Matching
// ============================================================================

/// Create a pattern validator that checks if value contains a substring
pub fn contains(comptime pattern: []const u8) fn ([]const u8) bool {
    return struct {
        pub fn validate(value: []const u8) bool {
            return std.mem.indexOf(u8, value, pattern) != null;
        }
    }.validate;
}

/// Create a pattern validator that checks if value starts with a prefix
pub fn startsWith(comptime prefix: []const u8) fn ([]const u8) bool {
    return struct {
        pub fn validate(value: []const u8) bool {
            return std.mem.startsWith(u8, value, prefix);
        }
    }.validate;
}

/// Create a pattern validator that checks if value ends with a suffix
pub fn endsWith(comptime suffix: []const u8) fn ([]const u8) bool {
    return struct {
        pub fn validate(value: []const u8) bool {
            return std.mem.endsWith(u8, value, suffix);
        }
    }.validate;
}

// ============================================================================
// Choice Validators
// ============================================================================

/// Create a validator that checks if value is one of the allowed values
pub fn oneOf(comptime choices: []const []const u8) fn ([]const u8) bool {
    return struct {
        pub fn validate(value: []const u8) bool {
            for (choices) |choice| {
                if (std.mem.eql(u8, value, choice)) return true;
            }
            return false;
        }
    }.validate;
}

/// Create a validator that checks if value is NOT one of the disallowed values
pub fn notOneOf(comptime choices: []const []const u8) fn ([]const u8) bool {
    return struct {
        pub fn validate(value: []const u8) bool {
            for (choices) |choice| {
                if (std.mem.eql(u8, value, choice)) return false;
            }
            return true;
        }
    }.validate;
}

// ============================================================================
// Special Format Validators
// ============================================================================

/// Validate a phone number (basic: digits, spaces, dashes, parens, plus)
pub fn isPhone(value: []const u8) bool {
    if (value.len < 7) return false;

    var digit_count: usize = 0;

    for (value) |c| {
        if (std.ascii.isDigit(c)) {
            digit_count += 1;
        } else if (c != ' ' and c != '-' and c != '(' and c != ')' and c != '+') {
            return false;
        }
    }

    // Must have at least 7 digits
    return digit_count >= 7;
}

/// Validate a UUID format
pub fn isUuid(value: []const u8) bool {
    // UUID format: 8-4-4-4-12 = 36 chars total
    if (value.len != 36) return false;

    // Check dashes at correct positions
    if (value[8] != '-' or value[13] != '-' or value[18] != '-' or value[23] != '-') {
        return false;
    }

    // Check all other chars are hex
    for (value, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        if (!std.ascii.isHex(c)) return false;
    }

    return true;
}

/// Validate a hex color code (#RGB or #RRGGBB)
pub fn isHexColor(value: []const u8) bool {
    if (value.len != 4 and value.len != 7) return false;
    if (value[0] != '#') return false;

    for (value[1..]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }

    return true;
}

/// Validate a date in YYYY-MM-DD format
pub fn isDate(value: []const u8) bool {
    if (value.len != 10) return false;

    // Check format
    if (value[4] != '-' or value[7] != '-') return false;

    // Parse year
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    if (year < 1900 or year > 2100) return false;

    // Parse month
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    if (month < 1 or month > 12) return false;

    // Parse day
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
    if (day < 1 or day > 31) return false;

    return true;
}

/// Validate a time in HH:MM or HH:MM:SS format
pub fn isTime(value: []const u8) bool {
    if (value.len != 5 and value.len != 8) return false;

    // Check format
    if (value[2] != ':') return false;
    if (value.len == 8 and value[5] != ':') return false;

    // Parse hours
    const hours = std.fmt.parseInt(u8, value[0..2], 10) catch return false;
    if (hours > 23) return false;

    // Parse minutes
    const minutes = std.fmt.parseInt(u8, value[3..5], 10) catch return false;
    if (minutes > 59) return false;

    // Parse seconds if present
    if (value.len == 8) {
        const seconds = std.fmt.parseInt(u8, value[6..8], 10) catch return false;
        if (seconds > 59) return false;
    }

    return true;
}

// ============================================================================
// Password Validators
// ============================================================================

/// Validate password strength (min 8 chars, at least one letter and one digit)
pub fn isStrongPassword(value: []const u8) bool {
    if (value.len < 8) return false;

    var has_letter = false;
    var has_digit = false;

    for (value) |c| {
        if (std.ascii.isAlphabetic(c)) has_letter = true;
        if (std.ascii.isDigit(c)) has_digit = true;
    }

    return has_letter and has_digit;
}

/// Validate password strength (min 8 chars, upper, lower, digit, special)
pub fn isVeryStrongPassword(value: []const u8) bool {
    if (value.len < 8) return false;

    var has_upper = false;
    var has_lower = false;
    var has_digit = false;
    var has_special = false;

    for (value) |c| {
        if (std.ascii.isUpper(c)) has_upper = true;
        if (std.ascii.isLower(c)) has_lower = true;
        if (std.ascii.isDigit(c)) has_digit = true;
        if (!std.ascii.isAlphanumeric(c)) has_special = true;
    }

    return has_upper and has_lower and has_digit and has_special;
}

// ============================================================================
// Composite Validators
// ============================================================================

/// Combine multiple validators with AND logic
pub fn allOf(comptime validators: []const *const fn ([]const u8) bool) fn ([]const u8) bool {
    return struct {
        pub fn validate(value: []const u8) bool {
            inline for (validators) |v| {
                if (!v(value)) return false;
            }
            return true;
        }
    }.validate;
}

/// Combine multiple validators with OR logic
pub fn anyOf(comptime validators: []const *const fn ([]const u8) bool) fn ([]const u8) bool {
    return struct {
        pub fn validate(value: []const u8) bool {
            inline for (validators) |v| {
                if (v(value)) return true;
            }
            return false;
        }
    }.validate;
}

/// Negate a validator
pub fn not(comptime validator: *const fn ([]const u8) bool) fn ([]const u8) bool {
    return struct {
        pub fn validate(value: []const u8) bool {
            return !validator(value);
        }
    }.validate;
}

// ============================================================================
// Tests
// ============================================================================

test "isRequired" {
    try std.testing.expect(isRequired("hello"));
    try std.testing.expect(!isRequired(""));
}

test "isRequiredTrimmed" {
    try std.testing.expect(isRequiredTrimmed("hello"));
    try std.testing.expect(isRequiredTrimmed("  hello  "));
    try std.testing.expect(!isRequiredTrimmed(""));
    try std.testing.expect(!isRequiredTrimmed("   "));
}

test "minLength" {
    const validator = minLength(5);
    try std.testing.expect(validator("hello"));
    try std.testing.expect(validator("hello world"));
    try std.testing.expect(!validator("hi"));
}

test "maxLength" {
    const validator = maxLength(5);
    try std.testing.expect(validator("hello"));
    try std.testing.expect(validator("hi"));
    try std.testing.expect(!validator("hello world"));
}

test "lengthBetween" {
    const validator = lengthBetween(3, 10);
    try std.testing.expect(validator("hello"));
    try std.testing.expect(!validator("hi"));
    try std.testing.expect(!validator("hello world!"));
}

test "isEmail" {
    try std.testing.expect(isEmail("test@example.com"));
    try std.testing.expect(isEmail("user.name@domain.co.uk"));
    try std.testing.expect(isEmail("user+tag@example.com"));
    try std.testing.expect(!isEmail("invalid"));
    try std.testing.expect(!isEmail("@example.com"));
    try std.testing.expect(!isEmail("test@"));
    try std.testing.expect(!isEmail("test@domain"));
    try std.testing.expect(!isEmail(""));
}

test "isUrl" {
    try std.testing.expect(isUrl("http://example.com"));
    try std.testing.expect(isUrl("https://example.com/path"));
    try std.testing.expect(isUrl("https://example.com:8080/path?query=1"));
    try std.testing.expect(!isUrl("example.com"));
    try std.testing.expect(!isUrl("/path"));
    try std.testing.expect(!isUrl(""));
}

test "isRelativeUrl" {
    try std.testing.expect(isRelativeUrl("https://example.com"));
    try std.testing.expect(isRelativeUrl("/path"));
    try std.testing.expect(!isRelativeUrl(""));
}

test "isNumeric" {
    try std.testing.expect(isNumeric("12345"));
    try std.testing.expect(!isNumeric("-123"));
    try std.testing.expect(!isNumeric("12.34"));
    try std.testing.expect(!isNumeric("abc"));
    try std.testing.expect(!isNumeric(""));
}

test "isInteger" {
    try std.testing.expect(isInteger("12345"));
    try std.testing.expect(isInteger("-123"));
    try std.testing.expect(isInteger("+456"));
    try std.testing.expect(!isInteger("12.34"));
    try std.testing.expect(!isInteger("abc"));
}

test "isDecimal" {
    try std.testing.expect(isDecimal("12345"));
    try std.testing.expect(isDecimal("-123.45"));
    try std.testing.expect(isDecimal("3.14159"));
    try std.testing.expect(!isDecimal("12.34.56"));
    try std.testing.expect(!isDecimal("abc"));
}

test "minValue" {
    const validator = minValue(10);
    try std.testing.expect(validator("10"));
    try std.testing.expect(validator("100"));
    try std.testing.expect(!validator("5"));
    try std.testing.expect(!validator("abc"));
}

test "maxValue" {
    const validator = maxValue(100);
    try std.testing.expect(validator("100"));
    try std.testing.expect(validator("50"));
    try std.testing.expect(!validator("150"));
}

test "valueBetween" {
    const validator = valueBetween(1, 100);
    try std.testing.expect(validator("50"));
    try std.testing.expect(validator("1"));
    try std.testing.expect(validator("100"));
    try std.testing.expect(!validator("0"));
    try std.testing.expect(!validator("101"));
}

test "isAlphanumeric" {
    try std.testing.expect(isAlphanumeric("abc123"));
    try std.testing.expect(!isAlphanumeric("abc-123"));
    try std.testing.expect(!isAlphanumeric(""));
}

test "isSlug" {
    try std.testing.expect(isSlug("my-slug-123"));
    try std.testing.expect(!isSlug("-bad-slug"));
    try std.testing.expect(!isSlug("bad-slug-"));
    try std.testing.expect(!isSlug("Bad-Slug"));
    try std.testing.expect(!isSlug("bad slug"));
}

test "isUsername" {
    try std.testing.expect(isUsername("user123"));
    try std.testing.expect(isUsername("user_name-1"));
    try std.testing.expect(!isUsername("ab")); // too short
    try std.testing.expect(!isUsername("_user")); // starts with underscore
}

test "contains" {
    const validator = contains("test");
    try std.testing.expect(validator("this is a test"));
    try std.testing.expect(!validator("no match"));
}

test "startsWith" {
    const validator = startsWith("hello");
    try std.testing.expect(validator("hello world"));
    try std.testing.expect(!validator("world hello"));
}

test "endsWith" {
    const validator = endsWith(".com");
    try std.testing.expect(validator("example.com"));
    try std.testing.expect(!validator("example.org"));
}

test "oneOf" {
    const validator = oneOf(&.{ "red", "green", "blue" });
    try std.testing.expect(validator("red"));
    try std.testing.expect(validator("green"));
    try std.testing.expect(!validator("yellow"));
}

test "isPhone" {
    try std.testing.expect(isPhone("123-456-7890"));
    try std.testing.expect(isPhone("+1 (555) 123-4567"));
    try std.testing.expect(!isPhone("123")); // too few digits
    try std.testing.expect(!isPhone("abc-def-ghij"));
}

test "isUuid" {
    try std.testing.expect(isUuid("550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isUuid("not-a-uuid"));
    try std.testing.expect(!isUuid("550e8400e29b41d4a716446655440000")); // no dashes
}

test "isHexColor" {
    try std.testing.expect(isHexColor("#fff"));
    try std.testing.expect(isHexColor("#FF5733"));
    try std.testing.expect(!isHexColor("FF5733")); // no hash
    try std.testing.expect(!isHexColor("#GGGGGG")); // invalid hex
}

test "isDate" {
    try std.testing.expect(isDate("2024-01-15"));
    try std.testing.expect(!isDate("2024-13-01")); // invalid month
    try std.testing.expect(!isDate("01-15-2024")); // wrong format
}

test "isTime" {
    try std.testing.expect(isTime("14:30"));
    try std.testing.expect(isTime("14:30:45"));
    try std.testing.expect(!isTime("25:00")); // invalid hour
    try std.testing.expect(!isTime("14:60")); // invalid minute
}

test "isStrongPassword" {
    try std.testing.expect(isStrongPassword("Password1"));
    try std.testing.expect(!isStrongPassword("password")); // no digit
    try std.testing.expect(!isStrongPassword("12345678")); // no letter
    try std.testing.expect(!isStrongPassword("Pass1")); // too short
}

test "isVeryStrongPassword" {
    try std.testing.expect(isVeryStrongPassword("Password1!"));
    try std.testing.expect(!isVeryStrongPassword("password1!")); // no upper
    try std.testing.expect(!isVeryStrongPassword("PASSWORD1!")); // no lower
}

test "allOf" {
    const validator = allOf(&.{ &isRequired, &isAlphanumeric });
    try std.testing.expect(validator("hello123"));
    try std.testing.expect(!validator("hello-123")); // fails alphanumeric
    try std.testing.expect(!validator("")); // fails required
}

test "anyOf" {
    const validator = anyOf(&.{ &isEmail, &isUrl });
    try std.testing.expect(validator("test@example.com"));
    try std.testing.expect(validator("https://example.com"));
    try std.testing.expect(!validator("not-email-or-url"));
}

test "not" {
    const isEmpty = struct {
        pub fn check(v: []const u8) bool {
            return v.len == 0;
        }
    }.check;
    const notEmpty = not(&isEmpty);
    try std.testing.expect(notEmpty("hello"));
    try std.testing.expect(!notEmpty(""));
}
