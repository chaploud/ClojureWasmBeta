//! Reader出力: 構文表現 (Form)
//!
//! Reader が返す構文的なデータ構造。評価前の表現。
//! マクロ展開の入力となり、Analyzer で Node に変換される。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md

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

// TODO: Keyword を Symbol と分離するか検討
// 本家Clojure では Keyword は Symbol とは別の型
// pub const Keyword = struct {
//     namespace: ?[]const u8,
//     name: []const u8,
// };

/// ソース位置情報を含むメタデータ
/// TODO: 本格実装時に拡張
pub const Metadata = struct {
    line: u32 = 0,
    column: u32 = 0,
    file: ?[]const u8 = null,
    // TODO: その他のメタデータ（:tag, :doc, etc.）
};

/// Reader出力: 構文表現
/// Clojure のフォームを tagged union で表現
pub const Form = union(enum) {
    // === リテラル ===
    nil,
    bool_true,
    bool_false,
    int: i64,
    float: f64,
    string: []const u8,

    // === 識別子 ===
    symbol: Symbol,
    keyword: Symbol, // TODO: 専用 Keyword 型に変更検討

    // === コレクション ===
    // TODO: メタデータ付き構造体に変更
    // 現状はスライスで簡易実装
    list: []const Form,
    vector: []const Form,
    // TODO: map, set 追加
    // map: *FormMap,
    // set: *FormSet,

    // === Reader専用構文 ===
    // TODO: 以下を追加
    // char_lit: u21,              // \a, \newline, etc.
    // ratio: Ratio,               // 22/7
    // regex: []const u8,          // #"pattern"
    // tagged_lit: *TaggedLiteral, // #uuid, #inst, etc.
    // reader_cond: *ReaderCond,   // #?, #?@

    // === ヘルパー関数 ===

    /// nil かどうか
    pub fn isNil(self: Form) bool {
        return switch (self) {
            .nil => true,
            else => false,
        };
    }

    /// 真偽値として評価（nil と false のみ falsy）
    pub fn isTruthy(self: Form) bool {
        return switch (self) {
            .nil => false,
            .bool_false => false,
            else => true,
        };
    }

    /// 型名を返す（デバッグ用）
    pub fn typeName(self: Form) []const u8 {
        return switch (self) {
            .nil => "nil",
            .bool_true, .bool_false => "boolean",
            .int => "integer",
            .float => "float",
            .string => "string",
            .symbol => "symbol",
            .keyword => "keyword",
            .list => "list",
            .vector => "vector",
        };
    }

    /// デバッグ表示用（pr-str 相当）
    pub fn format(
        self: Form,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .nil => try writer.writeAll("nil"),
            .bool_true => try writer.writeAll("true"),
            .bool_false => try writer.writeAll("false"),
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

// === 将来追加予定の型 ===
//
// pub const Ratio = struct {
//     numerator: i64,
//     denominator: i64,
// };
//
// pub const TaggedLiteral = struct {
//     tag: Symbol,
//     form: *Form,
//     meta: ?Metadata,
// };
//
// pub const ReaderCond = struct {
//     splicing: bool,  // #?@ なら true
//     list: []ReaderCondClause,
// };
//
// pub const ReaderCondClause = struct {
//     feature: Symbol,  // :clj, :cljs, :default
//     form: *Form,
// };

// === テスト ===

test "nil と boolean" {
    const nil_val: Form = .nil;
    const t: Form = .bool_true;
    const f: Form = .bool_false;

    try std.testing.expect(nil_val.isNil());
    try std.testing.expect(!t.isNil());

    try std.testing.expect(!nil_val.isTruthy());
    try std.testing.expect(!f.isTruthy());
    try std.testing.expect(t.isTruthy());
}

test "数値" {
    const i = Form{ .int = 42 };
    const fl = Form{ .float = 3.14 };

    try std.testing.expect(i.isTruthy());
    try std.testing.expectEqualStrings("integer", i.typeName());
    try std.testing.expectEqualStrings("float", fl.typeName());
}

test "symbol と keyword" {
    const sym = Form{ .symbol = Symbol.init("foo") };
    const kw = Form{ .keyword = Symbol.initNs("user", "bar") };

    try std.testing.expectEqualStrings("symbol", sym.typeName());
    try std.testing.expectEqualStrings("keyword", kw.typeName());
}

test "format 出力" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    const form = Form{ .keyword = Symbol.initNs("user", "name") };
    try form.format("", .{}, writer);

    try std.testing.expectEqualStrings(":user/name", stream.getWritten());
}
