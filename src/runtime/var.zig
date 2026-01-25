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

    // === メソッド ===

    /// root 値を取得（thread-local を考慮しない）
    pub fn getRawRoot(self: *const Var) Value {
        return self.root;
    }

    /// 値を取得（thread-local を優先）
    /// TODO: スレッドローカルバインディング実装時に拡張
    pub fn deref(self: *const Var) Value {
        // 現時点では root のみ
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

// === Thread-local binding（将来実装）===
//
// スレッドローカルバインディングのフレーム
// pub const Frame = struct {
//     bindings: *PersistentMap,  // Var → Value
//     prev: ?*Frame,
// };
//
// threadlocal var current_frame: ?*Frame = null;
//
// pub fn pushThreadBindings(bindings: *PersistentMap) void { ... }
// pub fn popThreadBindings() void { ... }

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
