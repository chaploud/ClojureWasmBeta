//! Var: Clojure変数
//!
//! グローバル変数と動的バインディングを管理。
//! root バインディング + thread-local バインディング。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Symbol = value.Symbol;

/// Var: Clojure変数
/// グローバルに名前空間修飾されたシンボルに束縛される値
pub const Var = struct {
    /// 変数名
    sym: Symbol,

    /// 所属名前空間の名前
    ns_name: []const u8,

    /// root バインディング（グローバル値）
    root: Value = value.nil,

    /// ^:dynamic フラグ
    dynamic: bool = false,

    /// ^:macro フラグ
    macro: bool = false,

    /// ^:private フラグ
    private: bool = false,

    /// メタデータ（将来: *PersistentMap）
    meta: ?*const Value = null,

    /// ウォッチャー: [key1, fn1, key2, fn2, ...] の配列
    watches: ?[]const Value = null,

    /// docstring
    doc: ?[]const u8 = null,

    /// 引数リスト（表示用、例: "[x y]", "([x] [x y])"）
    arglists: ?[]const u8 = null,

    // === メソッド ===

    /// root 値を取得（thread-local を考慮しない）
    pub fn getRawRoot(self: *const Var) Value {
        return self.root;
    }

    /// 値を取得（動的バインディングを優先）
    pub fn deref(self: *const Var) Value {
        if (self.dynamic) {
            if (getThreadBinding(self)) |val| return val;
        }
        return self.root;
    }

    /// root 値を設定
    pub fn bindRoot(self: *Var, v: Value) void {
        self.root = v;
    }

    /// dynamic かどうか
    pub fn isDynamic(self: *const Var) bool {
        return self.dynamic;
    }

    /// macro かどうか
    pub fn isMacro(self: *const Var) bool {
        return self.macro;
    }

    /// macro フラグを設定
    pub fn setMacro(self: *Var, is_macro: bool) void {
        self.macro = is_macro;
    }

    /// private かどうか
    pub fn isPrivate(self: *const Var) bool {
        return self.private;
    }

    /// 完全修飾名を返す（例: "clojure.core/map"）
    pub fn qualifiedName(self: *const Var, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.ns_name, self.sym.name }) catch self.sym.name;
    }
};

// === バインディングフレーム（動的バインディング）===

/// バインディングエントリ（Var → Value）
pub const BindingEntry = struct {
    var_ptr: *Var,
    value: Value,
};

/// バインディングフレーム（push/pop 単位）
pub const BindingFrame = struct {
    entries: []BindingEntry,
    prev: ?*BindingFrame,
};

/// グローバルバインディングスタック（シングルスレッド前提 — Wasm ターゲット）
var current_frame: ?*BindingFrame = null;

/// push-thread-bindings: 新しいフレームを積む
pub fn pushBindings(frame: *BindingFrame) void {
    frame.prev = current_frame;
    current_frame = frame;
}

/// pop-thread-bindings: フレームを外す
pub fn popBindings() void {
    if (current_frame) |f| {
        current_frame = f.prev;
    }
}

/// フレームスタックから Var の動的値を検索
pub fn getThreadBinding(v: *const Var) ?Value {
    var frame = current_frame;
    while (frame) |f| {
        for (f.entries) |e| {
            if (e.var_ptr == @as(*Var, @constCast(v))) return e.value;
        }
        frame = f.prev;
    }
    return null;
}

/// set!: 現在のフレーム内の Var 値を変更
pub fn setThreadBinding(v: *Var, new_val: Value) !void {
    var frame = current_frame;
    while (frame) |f| {
        for (f.entries) |*e| {
            if (e.var_ptr == v) {
                e.value = new_val;
                return;
            }
        }
        frame = f.prev;
    }
    return error.IllegalState; // binding されていない Var に set! はエラー
}

/// Var がスレッドバインディングを持つか
pub fn hasThreadBinding(v: *const Var) bool {
    return getThreadBinding(v) != null;
}

/// 現在のフレームを取得（GC 用）
pub fn getCurrentFrame() ?*BindingFrame {
    return current_frame;
}

// === テスト ===

test "Var 基本操作" {
    var v = Var{
        .sym = Symbol.init("foo"),
        .ns_name = "user",
    };

    try std.testing.expect(v.deref().isNil());

    v.bindRoot(value.intVal(42));
    try std.testing.expect(v.deref().eql(value.intVal(42)));
}

test "Var フラグ" {
    const v = Var{
        .sym = Symbol.init("*debug*"),
        .ns_name = "user",
        .dynamic = true,
        .private = true,
    };

    try std.testing.expect(v.isDynamic());
    try std.testing.expect(v.isPrivate());
    try std.testing.expect(!v.isMacro());
}

test "動的バインディング push/pop" {
    var v = Var{
        .sym = Symbol.init("*x*"),
        .ns_name = "user",
        .dynamic = true,
    };
    v.bindRoot(value.intVal(1));

    // バインディングなし → root
    try std.testing.expect(v.deref().eql(value.intVal(1)));
    try std.testing.expect(!hasThreadBinding(&v));

    // push
    var entries = [_]BindingEntry{.{ .var_ptr = &v, .value = value.intVal(10) }};
    var frame = BindingFrame{ .entries = &entries, .prev = null };
    pushBindings(&frame);

    try std.testing.expect(v.deref().eql(value.intVal(10)));
    try std.testing.expect(hasThreadBinding(&v));

    // pop → root に戻る
    popBindings();
    try std.testing.expect(v.deref().eql(value.intVal(1)));
    try std.testing.expect(!hasThreadBinding(&v));
}

test "動的バインディング ネスト" {
    var x = Var{ .sym = Symbol.init("*x*"), .ns_name = "user", .dynamic = true };
    var y = Var{ .sym = Symbol.init("*y*"), .ns_name = "user", .dynamic = true };
    x.bindRoot(value.intVal(1));
    y.bindRoot(value.intVal(2));

    var entries1 = [_]BindingEntry{.{ .var_ptr = &x, .value = value.intVal(10) }};
    var frame1 = BindingFrame{ .entries = &entries1, .prev = null };
    pushBindings(&frame1);

    var entries2 = [_]BindingEntry{.{ .var_ptr = &y, .value = value.intVal(20) }};
    var frame2 = BindingFrame{ .entries = &entries2, .prev = null };
    pushBindings(&frame2);

    try std.testing.expect(x.deref().eql(value.intVal(10)));
    try std.testing.expect(y.deref().eql(value.intVal(20)));

    popBindings();
    try std.testing.expect(x.deref().eql(value.intVal(10)));
    try std.testing.expect(y.deref().eql(value.intVal(2)));

    popBindings();
    try std.testing.expect(x.deref().eql(value.intVal(1)));
    try std.testing.expect(y.deref().eql(value.intVal(2)));
}

test "set! バインディング内" {
    var v = Var{ .sym = Symbol.init("*x*"), .ns_name = "user", .dynamic = true };
    v.bindRoot(value.intVal(1));

    var entries = [_]BindingEntry{.{ .var_ptr = &v, .value = value.intVal(10) }};
    var frame = BindingFrame{ .entries = &entries, .prev = null };
    pushBindings(&frame);

    try setThreadBinding(&v, value.intVal(99));
    try std.testing.expect(v.deref().eql(value.intVal(99)));

    popBindings();
    // root は変わらない
    try std.testing.expect(v.deref().eql(value.intVal(1)));
}

test "set! バインディング外はエラー" {
    var v = Var{ .sym = Symbol.init("*x*"), .ns_name = "user", .dynamic = true };
    v.bindRoot(value.intVal(1));

    try std.testing.expectError(error.IllegalState, setThreadBinding(&v, value.intVal(99)));
}
