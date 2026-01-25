//! Clojure値の表現
//!
//! tagged union で Clojure の各型を表現する。
//! 将来的に GC 対応時は ValueId (u32) でインデックス参照に変更予定。

const std = @import("std");

/// シンボル・キーワード用の名前空間付き識別子
pub const Symbol = struct {
    namespace: ?[]const u8,
    name: []const u8,

    pub fn init(name: []const u8) Symbol {
        return .{ .namespace = null, .name = name };
    }

    pub fn initNs(namespace: []const u8, name: []const u8) Symbol {
        return .{ .namespace = namespace, .name = name };
    }

    /// "ns/name" または "name" 形式で比較
    pub fn eql(self: Symbol, other: Symbol) bool {
        if (self.namespace) |ns1| {
            if (other.namespace) |ns2| {
                return std.mem.eql(u8, ns1, ns2) and std.mem.eql(u8, self.name, other.name);
            }
            return false;
        } else {
            return other.namespace == null and std.mem.eql(u8, self.name, other.name);
        }
    }
};

/// Clojure の値を表す tagged union
pub const Value = union(enum) {
    // 基本型
    nil,
    true_val,
    false_val,
    int: i64,
    float: f64,
    string: []const u8,
    symbol: Symbol,
    keyword: Symbol,

    // コレクション型（初期実装はスライスで表現）
    list: []const Value,
    vector: []const Value,
    // map, set は後で追加

    // === ヘルパー関数 ===

    /// nil かどうか
    pub fn isNil(self: Value) bool {
        return switch (self) {
            .nil => true,
            else => false,
        };
    }

    /// 真偽値として評価（nil と false のみ falsy）
    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .nil => false,
            .false_val => false,
            else => true,
        };
    }

    /// 型名を返す（デバッグ用）
    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .nil => "nil",
            .true_val, .false_val => "boolean",
            .int => "integer",
            .float => "float",
            .string => "string",
            .symbol => "symbol",
            .keyword => "keyword",
            .list => "list",
            .vector => "vector",
        };
    }

    /// デバッグ表示用
    pub fn format(
        self: Value,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .nil => try writer.writeAll("nil"),
            .true_val => try writer.writeAll("true"),
            .false_val => try writer.writeAll("false"),
            .int => |n| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "?";
                try writer.writeAll(s);
            },
            .float => |n| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "?";
                try writer.writeAll(s);
            },
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .symbol => |sym| {
                if (sym.namespace) |ns| {
                    try writer.print("{s}/{s}", .{ ns, sym.name });
                } else {
                    try writer.writeAll(sym.name);
                }
            },
            .keyword => |sym| {
                if (sym.namespace) |ns| {
                    try writer.print(":{s}/{s}", .{ ns, sym.name });
                } else {
                    try writer.print(":{s}", .{sym.name});
                }
            },
            .list => |items| {
                try writer.writeByte('(');
                for (items, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try item.format("", .{}, writer);
                }
                try writer.writeByte(')');
            },
            .vector => |items| {
                try writer.writeByte('[');
                for (items, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try item.format("", .{}, writer);
                }
                try writer.writeByte(']');
            },
        }
    }
};

// === テスト ===

test "nil と boolean" {
    const nil_val: Value = .nil;
    const t: Value = .true_val;
    const f: Value = .false_val;

    try std.testing.expect(nil_val.isNil());
    try std.testing.expect(!t.isNil());

    try std.testing.expect(!nil_val.isTruthy());
    try std.testing.expect(!f.isTruthy());
    try std.testing.expect(t.isTruthy());
}

test "数値" {
    const i = Value{ .int = 42 };
    const fl = Value{ .float = 3.14 };

    try std.testing.expect(i.isTruthy());
    try std.testing.expectEqualStrings("integer", i.typeName());
    try std.testing.expectEqualStrings("float", fl.typeName());
}

test "symbol と keyword" {
    const sym = Value{ .symbol = Symbol.init("foo") };
    const kw = Value{ .keyword = Symbol.initNs("user", "bar") };

    try std.testing.expectEqualStrings("symbol", sym.typeName());
    try std.testing.expectEqualStrings("keyword", kw.typeName());
}

test "format 出力" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    const val = Value{ .keyword = Symbol.initNs("user", "name") };
    try val.format("", .{}, writer);

    try std.testing.expectEqualStrings(":user/name", stream.getWritten());
}
