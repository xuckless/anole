//! Next-time vectors adapted from dying-will-bullet/cron (MIT, Copyright (c)
//! 2023 Hanaasagi), commit 91ab895b5a910449e20a6e873cc01a8b27001ad6,
//! src/cron.zig "test normal", "test last day", "test day of week", "test
//! alias" and "test real example". Only the 5-field expressions are kept
//! (that library reads 6 and 7 fields as minute..year; Anole's sixth field is
//! seconds), and those with its `L<weekday>` form (Anole writes `5L`). The
//! expression "0 0 1,15 * 3" is left out: that library requires both day
//! fields to match, Anole follows Vixie cron (either). All are evaluated in
//! UTC from 2023-06-08 09:25:30.
const std = @import("std");
const cron = @import("root.zig");
const Time = @import("../db/time.zig").Time;

const vectors = [_][2][]const u8{
    .{ "* * * * *", "2023-06-08 09:26:00" },
    .{ "0 * * * *", "2023-06-08 10:00:00" },
    .{ "0 0 * * *", "2023-06-09 00:00:00" },
    .{ "0 0 1 * *", "2023-07-01 00:00:00" },
    .{ "5/15 * * * *", "2023-06-08 09:35:00" },
    .{ "5-51/15 * * * *", "2023-06-08 09:35:00" },
    .{ "1,8,40 * * * *", "2023-06-08 09:40:00" },
    .{ "0 0 1 1 *", "2024-01-01 00:00:00" },
    .{ "0 0 ? * 0-6", "2023-06-09 00:00:00" },
    .{ "0 0 31 * *", "2023-07-31 00:00:00" },
    .{ "0,1/2 * * * *", "2023-06-08 09:27:00" },
    .{ "0-6,50-59/2 * * * *", "2023-06-08 09:50:00" },
    .{ "0-6,50/2 * * * *", "2023-06-08 09:50:00" },
    .{ "10,20 15 * * *", "2023-06-08 15:10:00" },
    .{ "* 2-5 * * *", "2023-06-09 02:00:00" },
    .{ "0 0 1 jan-dec *", "2023-07-01 00:00:00" },
    .{ "0 0 ? * sun-sat", "2023-06-09 00:00:00" },
    .{ "0 0 L 6 ?", "2023-06-30 00:00:00" },
    .{ "0 0 1,L 2 ?", "2024-02-01 00:00:00" },
    .{ "0 0 2,L 2 ?", "2024-02-02 00:00:00" },
    .{ "0 0 L 2 ?", "2024-02-29 00:00:00" },
    .{ "59 23 L 12 *", "2023-12-31 23:59:00" },
    .{ "0 0 ? 7 mon", "2023-07-03 00:00:00" },
    .{ "0 0 ? 8 mon-fri", "2023-08-01 00:00:00" },
    .{ "0 12 * * sat-sun", "2023-06-10 12:00:00" },
    .{ "@weekly", "2023-06-11 00:00:00" },
    .{ "@monthly", "2023-07-01 00:00:00" },
    .{ "@daily", "2023-06-09 00:00:00" },
    .{ "@hourly", "2023-06-08 10:00:00" },
    .{ "@annually", "2024-01-01 00:00:00" },
    .{ "@yearly", "2024-01-01 00:00:00" },
    .{ "0 0 * 8 *", "2023-08-01 00:00:00" },
    .{ "0 1 * * SUN", "2023-06-11 01:00:00" },
    .{ "0 1/3 * * SUN", "2023-06-11 01:00:00" },
    .{ "0 */6 * * SUN", "2023-06-11 00:00:00" },
    .{ "0 */6 */4 * SUN", "2023-06-25 00:00:00" },
    .{ "* */6 */4 */3 SUN", "2023-07-09 00:00:00" },
    .{ "* 3,2 * * MON", "2023-06-12 02:00:00" },
    .{ "* 3-10 * * THU", "2023-06-08 09:26:00" },
    .{ "* * 1 2 ?", "2024-02-01 00:00:00" },
    .{ "0 4 8-14 * *", "2023-06-09 04:00:00" },
    .{ "5 0 * 8 *", "2023-08-01 00:05:00" },
    .{ "15 14 1 * *", "2023-07-01 14:15:00" },
    .{ "0 22 * * 1-5", "2023-06-08 22:00:00" },
    .{ "23 0-20/2 * * *", "2023-06-08 10:23:00" },
    .{ "0 0,12 1 */2 *", "2023-07-01 00:00:00" },
    .{ "0 0 1 * ?", "2023-07-01 00:00:00" },
    .{ "30 8 * * 1-5", "2023-06-09 08:30:00" },
    .{ "0 12 * 1 1,3,5", "2024-01-01 12:00:00" },
    .{ "0 0 1,15 * ?", "2023-06-15 00:00:00" },
    .{ "0 0 */2 * ?", "2023-06-09 00:00:00" },
    .{ "0 0 1 1 ?", "2024-01-01 00:00:00" },
    .{ "0 0 9-12/2 * ?", "2023-06-09 00:00:00" },
};

test "cron vectors: next fire times from dying-will-bullet/cron" {
    const z = cron.Zone.utc;
    const start = Time.fromMillis(1686216330000);
    for (vectors) |v| {
        const s = cron.Schedule.parse(v[0], null) catch |err| {
            std.debug.print("cannot parse \"{s}\"\n", .{v[0]});
            return err;
        };
        const next = s.next(start, &z) orelse {
            std.debug.print("no next time for \"{s}\"\n", .{v[0]});
            return error.NoNext;
        };
        var buf: [32]u8 = undefined;
        const got = try std.fmt.bufPrint(&buf, "{f}", .{next});
        // `Time` prints RFC 3339 ("2023-06-09T00:00:00Z"): compare as date and time.
        var want: [20]u8 = undefined;
        @memcpy(want[0..10], v[1][0..10]);
        want[10] = 'T';
        @memcpy(want[11..19], v[1][11..19]);
        want[19] = 'Z';
        std.testing.expectEqualStrings(&want, got[0..20]) catch |err| {
            std.debug.print("\"{s}\"\n", .{v[0]});
            return err;
        };
    }
}
