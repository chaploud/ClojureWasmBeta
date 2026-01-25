//! ClojureWasmBeta CLI エントリポイント

const std = @import("std");
const clj = @import("ClojureWasmBeta");

pub fn main() !void {
    // 簡単なトークナイザーのデモ
    const source = "(+ 1 2)";
    var tokenizer = clj.Tokenizer.init(source);

    // Zig 0.15.2: バッファ付き writer
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("Tokenizing: {s}\n", .{source});

    while (true) {
        const tok = tokenizer.next();
        try stdout.print("  {s}: \"{s}\"\n", .{ @tagName(tok.kind), tok.text(source) });
        if (tok.kind == .eof) break;
    }

    try stdout.flush();
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
