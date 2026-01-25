//! Runtime値 (Value)
//!
//! 評価器が返す実行時の値。
//! GC管理対象（将来）、永続データ構造。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md

const std = @import("std");

// === シンボル・キーワード ===

/// シンボル（インターン済み識別子）
pub const Symbol = struct {
    namespace: ?[]const u8,
    name: []const u8,

    pub fn init(name: []const u8) Symbol {
        return .{ .namespace = null, .name = name };
    }

    pub fn initNs(namespace: []const u8, name: []const u8) Symbol {
        return .{ .namespace = namespace, .name = name };
    }

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

    /// ハッシュ値を計算
    pub fn hash(self: Symbol) u64 {
        var h = std.hash.Wyhash.init(0);
        if (self.namespace) |ns| {
            h.update(ns);
            h.update("/");
        }
        h.update(self.name);
        return h.final();
    }
};

/// キーワード（インターン済み、ハッシュキャッシュ付き）
pub const Keyword = struct {
    namespace: ?[]const u8,
    name: []const u8,

    pub fn init(name: []const u8) Keyword {
        return .{ .namespace = null, .name = name };
    }

    pub fn initNs(namespace: []const u8, name: []const u8) Keyword {
        return .{ .namespace = namespace, .name = name };
    }

    pub fn eql(self: Keyword, other: Keyword) bool {
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

// === 文字列 ===

/// 不変文字列
pub const String = struct {
    data: []const u8,
    cached_hash: ?u64 = null,

    pub fn init(data: []const u8) String {
        return .{ .data = data };
    }

    pub fn eql(self: String, other: String) bool {
        return std.mem.eql(u8, self.data, other.data);
    }

    pub fn hash(self: *String) u64 {
        if (self.cached_hash) |h| return h;
        const h = std.hash.Wyhash.hash(0, self.data);
        self.cached_hash = h;
        return h;
    }
};

// === コレクション ===

/// 永続リスト（Cons cell ベース）
/// 初期実装: スライスベース、将来は真の永続リストに
pub const PersistentList = struct {
    items: []const Value,
    meta: ?*const Value = null,

    /// 空のリストを返す（値）
    pub fn emptyVal() PersistentList {
        return .{ .items = &[_]Value{} };
    }

    /// 空のリストを作成してポインタを返す
    pub fn empty(allocator: std.mem.Allocator) !*PersistentList {
        const list = try allocator.create(PersistentList);
        list.* = .{ .items = &[_]Value{} };
        return list;
    }

    /// スライスから作成
    pub fn fromSlice(allocator: std.mem.Allocator, items: []const Value) !*PersistentList {
        const list = try allocator.create(PersistentList);
        const new_items = try allocator.dupe(Value, items);
        list.* = .{ .items = new_items };
        return list;
    }

    pub fn count(self: PersistentList) usize {
        return self.items.len;
    }

    pub fn first(self: PersistentList) ?Value {
        if (self.items.len == 0) return null;
        return self.items[0];
    }

    pub fn rest(self: PersistentList, allocator: std.mem.Allocator) !PersistentList {
        if (self.items.len <= 1) return emptyVal();
        const new_items = try allocator.dupe(Value, self.items[1..]);
        return .{ .items = new_items };
    }
};

/// 永続ベクター
/// 初期実装: スライスベース、将来は32分木に
pub const PersistentVector = struct {
    items: []const Value,
    meta: ?*const Value = null,

    pub fn empty() PersistentVector {
        return .{ .items = &[_]Value{} };
    }

    pub fn count(self: PersistentVector) usize {
        return self.items.len;
    }

    pub fn nth(self: PersistentVector, index: usize) ?Value {
        if (index >= self.items.len) return null;
        return self.items[index];
    }

    pub fn conj(self: PersistentVector, allocator: std.mem.Allocator, val: Value) !PersistentVector {
        var new_items = try allocator.alloc(Value, self.items.len + 1);
        @memcpy(new_items[0..self.items.len], self.items);
        new_items[self.items.len] = val;
        return .{ .items = new_items };
    }
};

/// 永続マップ
/// 初期実装: 配列ベース（キー値ペア）、将来はHAMTに
pub const PersistentMap = struct {
    /// キー値ペアのフラットな配列 [k1, v1, k2, v2, ...]
    entries: []const Value,
    meta: ?*const Value = null,

    pub fn empty() PersistentMap {
        return .{ .entries = &[_]Value{} };
    }

    pub fn count(self: PersistentMap) usize {
        return self.entries.len / 2;
    }

    pub fn get(self: PersistentMap, key: Value) ?Value {
        var i: usize = 0;
        while (i < self.entries.len) : (i += 2) {
            if (key.eql(self.entries[i])) {
                return self.entries[i + 1];
            }
        }
        return null;
    }

    pub fn assoc(self: PersistentMap, allocator: std.mem.Allocator, key: Value, val: Value) !PersistentMap {
        // 既存キーを探す
        var i: usize = 0;
        while (i < self.entries.len) : (i += 2) {
            if (key.eql(self.entries[i])) {
                // 既存キーを更新
                var new_entries = try allocator.dupe(Value, self.entries);
                new_entries[i + 1] = val;
                return .{ .entries = new_entries };
            }
        }
        // 新規キーを追加
        var new_entries = try allocator.alloc(Value, self.entries.len + 2);
        @memcpy(new_entries[0..self.entries.len], self.entries);
        new_entries[self.entries.len] = key;
        new_entries[self.entries.len + 1] = val;
        return .{ .entries = new_entries };
    }
};

/// 永続セット
/// 初期実装: 配列ベース、将来はHAMTに
pub const PersistentSet = struct {
    items: []const Value,
    meta: ?*const Value = null,

    pub fn empty() PersistentSet {
        return .{ .items = &[_]Value{} };
    }

    pub fn count(self: PersistentSet) usize {
        return self.items.len;
    }

    pub fn contains(self: PersistentSet, val: Value) bool {
        for (self.items) |item| {
            if (val.eql(item)) return true;
        }
        return false;
    }

    pub fn conj(self: PersistentSet, allocator: std.mem.Allocator, val: Value) !PersistentSet {
        // 重複チェック
        if (self.contains(val)) return self;
        var new_items = try allocator.alloc(Value, self.items.len + 1);
        @memcpy(new_items[0..self.items.len], self.items);
        new_items[self.items.len] = val;
        return .{ .items = new_items };
    }
};

// === 関数 ===

/// 組み込み関数の型
pub const BuiltinFn = *const fn (allocator: std.mem.Allocator, args: []const Value) anyerror!Value;

/// ユーザー定義関数のアリティ
pub const FnArityRuntime = struct {
    params: []const []const u8,
    variadic: bool,
    body: *anyopaque, // *Node（循環依存を避けるため anyopaque）
};

/// 関数オブジェクト
pub const Fn = struct {
    name: ?Symbol = null,
    builtin: ?BuiltinFn = null,
    // ユーザー定義関数用
    arities: ?[]const FnArityRuntime = null,
    closure_bindings: ?[]const Value = null, // クロージャ環境
    meta: ?*const Value = null,

    pub fn initBuiltin(name: []const u8, f: BuiltinFn) Fn {
        return .{
            .name = Symbol.init(name),
            .builtin = f,
        };
    }

    /// ユーザー定義関数を作成
    pub fn initUser(
        name: ?[]const u8,
        arities: []const FnArityRuntime,
        closure_bindings: ?[]const Value,
    ) Fn {
        return .{
            .name = if (name) |n| Symbol.init(n) else null,
            .arities = arities,
            .closure_bindings = closure_bindings,
        };
    }

    /// 組み込み関数かどうか
    pub fn isBuiltin(self: *const Fn) bool {
        return self.builtin != null;
    }

    /// 引数の数に合ったアリティを検索
    pub fn findArity(self: *const Fn, arg_count: usize) ?*const FnArityRuntime {
        const arities = self.arities orelse return null;

        // 固定アリティを優先検索
        for (arities) |*arity| {
            if (!arity.variadic and arity.params.len == arg_count) {
                return arity;
            }
        }

        // 可変長アリティを検索
        for (arities) |*arity| {
            if (arity.variadic and arg_count >= arity.params.len - 1) {
                return arity;
            }
        }

        return null;
    }
};

// === Value 本体 ===

/// Runtime値
pub const Value = union(enum) {
    // === 基本型 ===
    nil,
    bool_val: bool,
    int: i64,
    float: f64,
    char_val: u21,

    // === 文字列・識別子 ===
    string: *String,
    keyword: *Keyword,
    symbol: *Symbol,

    // === コレクション ===
    list: *PersistentList,
    vector: *PersistentVector,
    map: *PersistentMap,
    set: *PersistentSet,

    // === 関数 ===
    fn_val: *Fn,

    // === 参照（将来）===
    // var_val: *Var,
    // atom: *Atom,

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
            .bool_val => |b| b,
            else => true,
        };
    }

    /// 等価性判定
    pub fn eql(self: Value, other: Value) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);
        if (self_tag != other_tag) return false;

        return switch (self) {
            .nil => true,
            .bool_val => |a| a == other.bool_val,
            .int => |a| a == other.int,
            .float => |a| a == other.float,
            .char_val => |a| a == other.char_val,
            .string => |a| a.eql(other.string.*),
            .keyword => |a| a.eql(other.keyword.*),
            .symbol => |a| a.eql(other.symbol.*),
            .list => |a| blk: {
                const b = other.list;
                if (a.items.len != b.items.len) break :blk false;
                for (a.items, b.items) |ai, bi| {
                    if (!ai.eql(bi)) break :blk false;
                }
                break :blk true;
            },
            .vector => |a| blk: {
                const b = other.vector;
                if (a.items.len != b.items.len) break :blk false;
                for (a.items, b.items) |ai, bi| {
                    if (!ai.eql(bi)) break :blk false;
                }
                break :blk true;
            },
            .map => |a| blk: {
                const b = other.map;
                if (a.count() != b.count()) break :blk false;
                var i: usize = 0;
                while (i < a.entries.len) : (i += 2) {
                    const key = a.entries[i];
                    const val = a.entries[i + 1];
                    if (b.get(key)) |bval| {
                        if (!val.eql(bval)) break :blk false;
                    } else {
                        break :blk false;
                    }
                }
                break :blk true;
            },
            .set => |a| blk: {
                const b = other.set;
                if (a.items.len != b.items.len) break :blk false;
                for (a.items) |item| {
                    if (!b.contains(item)) break :blk false;
                }
                break :blk true;
            },
            .fn_val => |a| a == other.fn_val, // 関数は参照等価
        };
    }

    /// 型名を返す（デバッグ用）
    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .nil => "nil",
            .bool_val => "boolean",
            .int => "integer",
            .float => "float",
            .char_val => "character",
            .string => "string",
            .keyword => "keyword",
            .symbol => "symbol",
            .list => "list",
            .vector => "vector",
            .map => "map",
            .set => "set",
            .fn_val => "function",
        };
    }

    /// デバッグ表示用（pr-str 相当）
    pub fn format(
        self: Value,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .nil => try writer.writeAll("nil"),
            .bool_val => |b| try writer.writeAll(if (b) "true" else "false"),
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
            .char_val => |c| {
                try writer.writeAll("\\");
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &buf) catch 0;
                try writer.writeAll(buf[0..len]);
            },
            .string => |s| try writer.print("\"{s}\"", .{s.data}),
            .keyword => |k| {
                if (k.namespace) |ns| {
                    try writer.print(":{s}/{s}", .{ ns, k.name });
                } else {
                    try writer.print(":{s}", .{k.name});
                }
            },
            .symbol => |sym| {
                if (sym.namespace) |ns| {
                    try writer.print("{s}/{s}", .{ ns, sym.name });
                } else {
                    try writer.writeAll(sym.name);
                }
            },
            .list => |lst| {
                try writer.writeByte('(');
                for (lst.items, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try item.format("", .{}, writer);
                }
                try writer.writeByte(')');
            },
            .vector => |vec| {
                try writer.writeByte('[');
                for (vec.items, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try item.format("", .{}, writer);
                }
                try writer.writeByte(']');
            },
            .map => |m| {
                try writer.writeByte('{');
                var i: usize = 0;
                var first = true;
                while (i < m.entries.len) : (i += 2) {
                    if (!first) try writer.writeAll(", ");
                    first = false;
                    try m.entries[i].format("", .{}, writer);
                    try writer.writeByte(' ');
                    try m.entries[i + 1].format("", .{}, writer);
                }
                try writer.writeByte('}');
            },
            .set => |s| {
                try writer.writeAll("#{");
                for (s.items, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try item.format("", .{}, writer);
                }
                try writer.writeByte('}');
            },
            .fn_val => |f| {
                if (f.name) |name| {
                    if (name.namespace) |ns| {
                        try writer.print("#<fn {s}/{s}>", .{ ns, name.name });
                    } else {
                        try writer.print("#<fn {s}>", .{name.name});
                    }
                } else {
                    try writer.writeAll("#<fn>");
                }
            },
        }
    }
};

// === ヘルパー関数 ===

/// nil 定数
pub const nil: Value = .nil;

/// true 定数
pub const true_val: Value = .{ .bool_val = true };

/// false 定数
pub const false_val: Value = .{ .bool_val = false };

/// 整数 Value を作成
pub fn intVal(n: i64) Value {
    return .{ .int = n };
}

/// 浮動小数点 Value を作成
pub fn floatVal(n: f64) Value {
    return .{ .float = n };
}

// === テスト ===

test "nil と boolean" {
    try std.testing.expect(nil.isNil());
    try std.testing.expect(!true_val.isNil());

    try std.testing.expect(!nil.isTruthy());
    try std.testing.expect(!false_val.isTruthy());
    try std.testing.expect(true_val.isTruthy());
    try std.testing.expect(intVal(0).isTruthy()); // 0 は truthy
}

test "数値" {
    const i = intVal(42);
    const f = floatVal(3.14);

    try std.testing.expectEqualStrings("integer", i.typeName());
    try std.testing.expectEqualStrings("float", f.typeName());

    try std.testing.expect(i.eql(intVal(42)));
    try std.testing.expect(!i.eql(intVal(43)));
}

test "等価性" {
    try std.testing.expect(nil.eql(nil));
    try std.testing.expect(true_val.eql(true_val));
    try std.testing.expect(!true_val.eql(false_val));
    try std.testing.expect(intVal(42).eql(intVal(42)));
    try std.testing.expect(!intVal(42).eql(intVal(43)));
}

test "Symbol" {
    const s1 = Symbol.init("foo");
    const s2 = Symbol.initNs("clojure.core", "map");

    try std.testing.expect(s1.eql(Symbol.init("foo")));
    try std.testing.expect(!s1.eql(s2));
    try std.testing.expectEqualStrings("foo", s1.name);
    try std.testing.expectEqualStrings("clojure.core", s2.namespace.?);
}

test "Keyword" {
    const k1 = Keyword.init("foo");
    const k2 = Keyword.initNs("ns", "bar");

    try std.testing.expect(k1.eql(Keyword.init("foo")));
    try std.testing.expect(!k1.eql(k2));
}

test "PersistentVector" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var vec = PersistentVector.empty();
    vec = try vec.conj(allocator, intVal(1));
    vec = try vec.conj(allocator, intVal(2));
    vec = try vec.conj(allocator, intVal(3));

    try std.testing.expectEqual(@as(usize, 3), vec.count());
    try std.testing.expect(vec.nth(0).?.eql(intVal(1)));
    try std.testing.expect(vec.nth(1).?.eql(intVal(2)));
    try std.testing.expect(vec.nth(2).?.eql(intVal(3)));
    try std.testing.expect(vec.nth(3) == null);
}

test "PersistentMap" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var m = PersistentMap.empty();

    // キーワードを作成
    var k1 = Keyword.init("a");
    var k2 = Keyword.init("b");
    const key1 = Value{ .keyword = &k1 };
    const key2 = Value{ .keyword = &k2 };

    m = try m.assoc(allocator, key1, intVal(1));
    m = try m.assoc(allocator, key2, intVal(2));

    try std.testing.expectEqual(@as(usize, 2), m.count());
    try std.testing.expect(m.get(key1).?.eql(intVal(1)));
    try std.testing.expect(m.get(key2).?.eql(intVal(2)));
}

test "format 出力" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try nil.format("", .{}, writer);
    try writer.writeByte(' ');
    try true_val.format("", .{}, writer);
    try writer.writeByte(' ');
    try intVal(42).format("", .{}, writer);

    try std.testing.expectEqualStrings("nil true 42", stream.getWritten());
}
