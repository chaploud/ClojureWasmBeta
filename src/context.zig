//! Context: 評価コンテキスト
//!
//! 評価時のローカル環境を管理。
//! ローカルバインディング、recur ターゲット、コールスタック。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md
//!
//! TODO: 評価器実装時に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const form = @import("form.zig");
// const Symbol = form.Symbol;
// const value = @import("value.zig");
// const Value = value.Value;
// const env = @import("env.zig");
// const Env = env.Env;
// const namespace = @import("namespace.zig");
// const Namespace = namespace.Namespace;

/// Context: 評価コンテキスト
/// TODO: 実装時にコメント解除・拡張
pub const Context = struct {
    // === グローバル参照 ===
    // env: *Env,
    // current_ns: *Namespace,

    // === ローカルバインディング ===
    // bindings: []Value,           // ローカル変数の値
    // bindings_idx: SymbolIndexMap, // Symbol → bindings のインデックス

    // === 制御フロー ===
    // recur_target: ?*RecurTarget, // loop/fn の recur 先

    // === エラー追跡 ===
    // call_stack: CallStack,       // スタックトレース用

    // プレースホルダー
    placeholder: void,

    // === メソッド ===

    // /// ローカル変数を検索
    // pub fn lookupLocal(self: *Context, sym: Symbol) ?Value {
    //     if (self.bindings_idx.get(sym)) |idx| {
    //         return self.bindings[idx];
    //     }
    //     return null;
    // }

    // /// シンボルを解決（ローカル優先）
    // pub fn resolve(self: *Context, sym: Symbol) ?Value {
    //     // ローカル変数
    //     if (self.lookupLocal(sym)) |v| {
    //         return v;
    //     }
    //     // Var
    //     if (self.current_ns.resolve(sym)) |var_ref| {
    //         return var_ref.deref();
    //     }
    //     return null;
    // }

    // /// 新しいバインディングを追加したコンテキストを作成
    // pub fn pushBindings(
    //     self: *Context,
    //     syms: []Symbol,
    //     vals: []Value,
    // ) Context {
    //     var new_ctx = self.*;
    //     // bindings と bindings_idx を拡張
    //     // ...
    //     return new_ctx;
    // }

    // /// recur ターゲットを設定
    // pub fn withRecurTarget(self: *Context, target: *RecurTarget) Context {
    //     var new_ctx = self.*;
    //     new_ctx.recur_target = target;
    //     return new_ctx;
    // }
};

// === 補助型（将来）===
//
// /// recur のジャンプ先
// pub const RecurTarget = struct {
//     bindings: []Value,  // rebind 先
// };
//
// /// コールスタック（エラー追跡用）
// pub const CallStack = struct {
//     frames: []StackFrame,
// };
//
// pub const StackFrame = struct {
//     fn_name: ?Symbol,
//     ns_name: ?Symbol,
//     line: u32,
//     column: u32,
//     file: ?[]const u8,
// };
//
// const SymbolIndexMap = std.HashMap(Symbol, u32, ...);

// === テスト ===

test "placeholder" {
    const ctx: Context = .{ .placeholder = {} };
    _ = ctx;
}
