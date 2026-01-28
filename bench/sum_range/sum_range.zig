const std = @import("std");

pub fn main() !void {
    var sum: i64 = 0;
    var i: i64 = 0;
    while (i < 1000000) : (i += 1) {
        sum += i;
    }
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{sum});
    try stdout.flush();
}
