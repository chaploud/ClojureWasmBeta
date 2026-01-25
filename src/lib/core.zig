//! clojure.core 組み込み関数
//!
//! Clojure標準ライブラリの中核関数群。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md
//!
//! TODO: 評価器実装後に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const value = @import("../runtime/value.zig");
// const Value = value.Value;
// const context = @import("../runtime/context.zig");
// const Context = context.Context;

// === 算術演算 ===
// pub fn add(ctx: *Context, args: []Value) !Value { ... }
// pub fn sub(ctx: *Context, args: []Value) !Value { ... }
// pub fn mul(ctx: *Context, args: []Value) !Value { ... }
// pub fn div(ctx: *Context, args: []Value) !Value { ... }

// === コレクション操作 ===
// pub fn first(ctx: *Context, args: []Value) !Value { ... }
// pub fn rest(ctx: *Context, args: []Value) !Value { ... }
// pub fn cons(ctx: *Context, args: []Value) !Value { ... }
// pub fn conj(ctx: *Context, args: []Value) !Value { ... }

// === 述語 ===
// pub fn isNil(ctx: *Context, args: []Value) !Value { ... }
// pub fn isSeq(ctx: *Context, args: []Value) !Value { ... }

// === テスト ===

test "placeholder" {
    // 将来の実装用プレースホルダー
}
