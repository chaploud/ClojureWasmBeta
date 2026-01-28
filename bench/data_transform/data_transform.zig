const std = @import("std");

// 10000個の構造体を作成・変換
const Item = struct { id: i32, value: i32, doubled: i32 };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var items = std.ArrayList(Item).empty;
    defer items.deinit(allocator);

    var i: i32 = 0;
    while (i < 10000) : (i += 1) {
        try items.append(allocator, .{ .id = i, .value = i, .doubled = i * 2 });
    }

    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{items.items.len});
    try stdout.flush();
}
