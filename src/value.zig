//! Runtime値 (Value)
//!
//! 評価器が返す実行時の値。
//! GC管理対象（将来）、永続データ構造。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md
//!
//! TODO: 評価器実装時に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const var_mod = @import("var.zig");
// const Var = var_mod.Var;
// const namespace = @import("namespace.zig");
// const Namespace = namespace.Namespace;

/// Runtime値
/// TODO: 実装時にコメント解除・拡張
pub const Value = union(enum) {
    // === 基本型 ===
    nil,
    bool_val: bool,
    int: i64,
    float: f64,
    // ratio: *Ratio,
    // bigint: *BigInt,
    // bigdec: *BigDecimal,

    // === 文字列・識別子 ===
    // string: *String,
    // char_val: u21,
    // keyword: *Keyword,
    // symbol: *Symbol,

    // === コレクション（永続データ構造）===
    // list: *PersistentList,
    // vector: *PersistentVector,
    // map: *PersistentMap,
    // set: *PersistentSet,

    // === 関数・参照 ===
    // fn_val: *Fn,
    // var_val: *Var,

    // === 参照型 ===
    // atom: *Atom,
    // ref: *Ref,        // STM用
    // agent: *Agent,

    // === その他 ===
    // namespace: *Namespace,
    // regex: *Regex,

    // プレースホルダー（コンパイル用）
    placeholder: void,

    // === ヘルパー関数 ===

    // pub fn isNil(self: Value) bool {
    //     return self == .nil;
    // }

    // pub fn isTruthy(self: Value) bool {
    //     return switch (self) {
    //         .nil => false,
    //         .bool_val => |b| b,
    //         else => true,
    //     };
    // }

    // pub fn typeName(self: Value) []const u8 {
    //     // TODO: 型名を返す
    // }
};

// === 将来追加予定の型 ===
//
// /// 永続リスト（Cons cell ベース）
// pub const PersistentList = struct {
//     first: Value,
//     rest: ?*PersistentList,
//     count: u32,
//     meta: ?*PersistentMap,
// };
//
// /// 永続ベクター（32分木）
// pub const PersistentVector = struct {
//     count: u32,
//     shift: u5,
//     root: *VectorNode,
//     tail: []Value,
//     meta: ?*PersistentMap,
// };
//
// /// 永続ハッシュマップ（HAMT）
// pub const PersistentMap = struct {
//     count: u32,
//     root: ?*MapNode,
//     has_null: bool,
//     null_value: Value,
//     meta: ?*PersistentMap,
// };
//
// /// 永続ハッシュセット
// pub const PersistentSet = struct {
//     impl: *PersistentMap,  // マップで実装
//     meta: ?*PersistentMap,
// };
//
// /// 関数オブジェクト
// pub const Fn = struct {
//     name: ?Symbol,
//     arities: []FnArity,
//     env: *Env,  // クロージャ環境
//     meta: ?*PersistentMap,
// };
//
// /// Atom（アトミック参照）
// pub const Atom = struct {
//     value: std.atomic.Value(Value),
//     meta: ?*PersistentMap,
//     validator: ?*Fn,
//     watches: *PersistentMap,
// };
//
// /// 有理数
// pub const Ratio = struct {
//     numerator: i64,    // TODO: BigInt対応
//     denominator: i64,
// };
//
// /// 文字列（不変、ハッシュキャッシュ付き）
// pub const String = struct {
//     data: []const u8,
//     hash: ?u32,
// };
//
// /// キーワード（インターン済み）
// pub const Keyword = struct {
//     namespace: ?*String,
//     name: *String,
//     hash: u32,
// };

// === テスト ===

test "placeholder" {
    const v: Value = .{ .placeholder = {} };
    _ = v;
}
