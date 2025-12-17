const std = @import("std");

pub const Time = struct {
    pub fn nowMillis() i64 {
        return std.time.milliTimestamp();
    }

    pub fn nowSeconds() i64 {
        return std.time.timestamp();
    }

    pub fn formatTimestamp(timestamp: i64, allocator: std.mem.Allocator) ![]const u8 {
        const seconds = if (timestamp > 1000000000000) @divTrunc(timestamp, 1000) else timestamp;
        
        const epoch = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(seconds)) };
        const epoch_day = epoch.getEpochDay();
        const day_seconds = epoch.getDaySeconds();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        
        const year = year_day.year;
        const month = month_day.month.numeric();
        const day = month_day.day_index + 1;
        const hour = day_seconds.getHoursIntoDay();
        const minute = day_seconds.getMinutesIntoHour();
        const second = day_seconds.getSecondsIntoMinute();
        
        return std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
            .{ year, month, day, hour, minute, second },
        );
    }

    pub fn parseTimestamp(iso_string: []const u8) !i64 {
        if (iso_string.len < 19) {
            return error.InvalidTimestamp;
        }

        const year = try std.fmt.parseInt(i32, iso_string[0..4], 10);
        
        const month = try std.fmt.parseInt(u8, iso_string[5..7], 10);
        if (month < 1 or month > 12) {
            return error.InvalidTimestamp;
        }
        
        const day = try std.fmt.parseInt(u8, iso_string[8..10], 10);
        if (day < 1 or day > 31) {
            return error.InvalidTimestamp;
        }
        
        const hour = try std.fmt.parseInt(u8, iso_string[11..13], 10);
        if (hour > 23) {
            return error.InvalidTimestamp;
        }
        
        const minute = try std.fmt.parseInt(u8, iso_string[14..16], 10);
        if (minute > 59) {
            return error.InvalidTimestamp;
        }
        
        const second = try std.fmt.parseInt(u8, iso_string[17..19], 10);
        if (second > 59) {
            return error.InvalidTimestamp;
        }

        const days_since_epoch = calculateDaysSinceEpoch(year, month, day);
        const seconds_since_epoch = days_since_epoch * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
        
        return seconds_since_epoch * 1000; // Return in milliseconds
    }

    pub fn formatDate(timestamp: i64, allocator: std.mem.Allocator) ![]const u8 {
        const seconds = if (timestamp > 1000000000000) @divTrunc(timestamp, 1000) else timestamp;
        
        const epoch = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(seconds)) };
        const epoch_day = epoch.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        
        const year = year_day.year;
        const month = month_day.month;
        const day = month_day.day_index + 1;
        
        const month_names = [_][]const u8{
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December",
        };
        
        const month_name = month_names[@as(usize, @intFromEnum(month)) - 1];
        
        return std.fmt.allocPrint(
            allocator,
            "{s} {d}, {d}",
            .{ month_name, day, year },
        );
    }

    fn calculateDaysSinceEpoch(year: i32, month: u8, day: u8) i64 {
        const year_diff = year - 1970;
        var days: i64 = @as(i64, @intCast(year_diff)) * 365;
        
        const leap_years = (year - 1969) / 4;
        days += @as(i64, @intCast(leap_years));
        
        days += @as(i64, @intCast(month - 1)) * 30;
        
        days += @as(i64, @intCast(day - 1));
        
        return days;
    }
};

test "Time.nowMillis" {
    const now = Time.nowMillis();
    try std.testing.expect(now > 0);
}

test "Time.nowSeconds" {
    const now = Time.nowSeconds();
    try std.testing.expect(now > 0);
}

test "Time.formatTimestamp" {
    const allocator = std.testing.allocator;
    const timestamp: i64 = 1704067200000; // Approximate
    const formatted = try Time.formatTimestamp(timestamp, allocator);
    defer allocator.free(formatted);
    
    try std.testing.expect(std.mem.indexOf(u8, formatted, "2024") != null);
}

test "Time.formatDate" {
    const allocator = std.testing.allocator;
    const timestamp = Time.nowMillis();
    const formatted = try Time.formatDate(timestamp, allocator);
    defer allocator.free(formatted);
    
    const months = [_][]const u8{ "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December" };
    var found = false;
    for (months) |month| {
        if (std.mem.indexOf(u8, formatted, month) != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

