const std = @import("std");
const main = @import("main.zig");
const testing = std.testing;

test "today date string has correct format YYYY-MM-DD" {
    const date = main.todayDateStr();
    try testing.expect(date[4] == '-');
    try testing.expect(date[7] == '-');
    try testing.expect(date.len == 10);
    for (date[0..4]) |c| try testing.expect(c >= '0' and c <= '9');
    for (date[5..7]) |c| try testing.expect(c >= '0' and c <= '9');
    for (date[8..10]) |c| try testing.expect(c >= '0' and c <= '9');
}

test "current week dates returns 7 valid dates" {
    const dates = main.currentWeekDates();
    for (dates) |date| {
        try testing.expect(date[4] == '-');
        try testing.expect(date[7] == '-');
    }
}

test "html generation produces valid output" {
    var buf: [64 * 1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const entries = [_]main.Entry{};
    try main.writeHtml(fbs.writer(), &entries);
    const html = fbs.getWritten();
    try testing.expect(html.len > 0);
    try testing.expect(std.mem.indexOf(u8, html, "Work Log") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Monday") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Friday") != null);
}
