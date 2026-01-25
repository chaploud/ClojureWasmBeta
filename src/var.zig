//! Var: Clojure変数
//!
//! グローバル変数と動的バインディングを管理。
//! root バインディング + thread-local バインディング。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md
//!
//! TODO: 評価器実装時に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const value = @import("value.zig");
// const Value = value.Value;
// const namespace = @import("namespace.zig");
// const Namespace = namespace.Namespace;
// const form = @import("form.zig");
// const Symbol = form.Symbol;

/// Var: Clojure変数
/// TODO: 実装時にコメント解除・拡張
pub const Var = struct {
    // === 基本フィールド ===
    // root: Value,              // グローバルバインディング
    // sym: Symbol,              // 変数名
    // ns: *Namespace,           // 所属名前空間

    // === メタデータ ===
    // meta: ?*PersistentMap,    // :doc, :arglists, :private, etc.
    // dynamic: bool,            // ^:dynamic フラグ
    // macro: bool,              // ^:macro フラグ

    // === Thread-local binding ===
    // TODO: スレッドローカルバインディング実装
    // thread_bindings: ThreadLocal(Frame),

    // === Watches ===
    // watches: ?*PersistentMap, // add-watch 用

    // プレースホルダー
    placeholder: void,

    // === メソッド ===

    // /// root 値を取得（thread-local を考慮しない）
    // pub fn getRawRoot(self: *Var) Value {
    //     return self.root;
    // }

    // /// 値を取得（thread-local を優先）
    // pub fn deref(self: *Var) Value {
    //     if (self.dynamic) {
    //         if (getThreadBinding(self)) |binding| {
    //             return binding.val;
    //         }
    //     }
    //     return self.root;
    // }

    // /// root 値を設定
    // pub fn bindRoot(self: *Var, v: Value) void {
    //     self.root = v;
    // }

    // /// dynamic かどうか
    // pub fn isDynamic(self: *Var) bool {
    //     return self.dynamic;
    // }

    // /// macro かどうか
    // pub fn isMacro(self: *Var) bool {
    //     return self.macro;
    // }
};

// === Thread-local binding ===
//
// /// スレッドローカルバインディングのフレーム
// pub const Frame = struct {
//     bindings: *PersistentMap,  // Var → Value
//     prev: ?*Frame,
// };
//
// /// スレッドローカルストレージ
// threadlocal var current_frame: ?*Frame = null;
//
// /// push-thread-bindings 相当
// pub fn pushThreadBindings(bindings: *PersistentMap) void {
//     const new_frame = allocator.create(Frame);
//     new_frame.bindings = bindings;
//     new_frame.prev = current_frame;
//     current_frame = new_frame;
// }
//
// /// pop-thread-bindings 相当
// pub fn popThreadBindings() void {
//     if (current_frame) |frame| {
//         current_frame = frame.prev;
//         allocator.destroy(frame);
//     }
// }
//
// /// 特定 Var のスレッドローカルバインディングを取得
// fn getThreadBinding(v: *Var) ?Value {
//     var frame = current_frame;
//     while (frame) |f| {
//         if (f.bindings.get(v)) |val| {
//             return val;
//         }
//         frame = f.prev;
//     }
//     return null;
// }

// === テスト ===

test "placeholder" {
    const v: Var = .{ .placeholder = {} };
    _ = v;
}
