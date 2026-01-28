const std = @import("std");

// filter odd, map square, take 10000, sum
pub fn main() !void {
    var sum: i64 = 0;
    var count: usize = 0;
    var i: i64 = 0;
    while (i < 100000 and count < 10000) : (i += 1) {
        if (@mod(i, 2) == 1) {
            sum += i * i;
            count += 1;
        }
    }
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{sum});
    try stdout.flush();
}
