const std = @import("std");

// 10000回の upper-case + 結合
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        var buf: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "item-{d}", .{i}) catch unreachable;
        for (s) |c| {
            try result.append(allocator, std.ascii.toUpper(c));
        }
    }

    var out_buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&out_buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{result.items.len});
    try stdout.flush();
}
