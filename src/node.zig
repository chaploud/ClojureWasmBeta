//! Analyzer出力: 実行可能ノード (Node)
//!
//! Form を解析して生成される実行可能な中間表現。
//! 各 Node は run() メソッドで Value を返す。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md
//!
//! TODO: Analyzer 実装時に有効化

const std = @import("std");
const err = @import("error.zig");

// TODO: 実装時にコメント解除
// const value = @import("value.zig");
// const Value = value.Value;
// const context = @import("context.zig");
// const Context = context.Context;

/// ソース位置情報（エラー追跡用）
pub const SourceInfo = struct {
    line: u32,
    column: u32,
    file: ?[]const u8,
};

/// 実行可能ノード
/// TODO: 実装時にコメント解除・拡張
pub const Node = union(enum) {
    // === リテラル（即値）===
    // constant: Value,

    // === 参照 ===
    // var_ref: VarRefNode,      // Var参照
    // local_ref: LocalRefNode,  // ローカル変数参照

    // === 制御構造 ===
    // if_node: *IfNode,
    // do_node: *DoNode,
    // let_node: *LetNode,
    // loop_node: *LoopNode,
    // recur_node: *RecurNode,

    // === 関数 ===
    // fn_node: *FnNode,
    // call_node: *CallNode,

    // === 定義 ===
    // def_node: *DefNode,

    // === 例外 ===
    // try_node: *TryNode,
    // throw_node: *ThrowNode,

    // プレースホルダー（コンパイル用）
    placeholder: void,

    // /// スタック情報を取得
    // pub fn stack(self: Node) ?SourceInfo {
    //     // TODO: 各ノードタイプに応じてスタック情報を返す
    // }

    // /// 評価実行
    // pub fn run(self: Node, ctx: *Context) RunError!Value {
    //     // TODO: 各ノードタイプに応じて評価
    // }
};

// === 将来追加予定のノード型 ===
//
// pub const VarRefNode = struct {
//     var_ref: *Var,
//     stack: SourceInfo,
// };
//
// pub const LocalRefNode = struct {
//     idx: u32,  // bindings 配列のインデックス
//     stack: SourceInfo,
// };
//
// pub const IfNode = struct {
//     test_node: *Node,
//     then_node: *Node,
//     else_node: ?*Node,
//     stack: SourceInfo,
// };
//
// pub const DoNode = struct {
//     statements: []*Node,
//     stack: SourceInfo,
// };
//
// pub const LetNode = struct {
//     bindings: []LetBinding,
//     body: *Node,
//     stack: SourceInfo,
// };
//
// pub const LetBinding = struct {
//     sym: Symbol,
//     init: *Node,
// };
//
// pub const FnNode = struct {
//     name: ?Symbol,
//     arities: []FnArity,
//     stack: SourceInfo,
// };
//
// pub const FnArity = struct {
//     params: []Symbol,
//     variadic: bool,
//     body: *Node,
// };
//
// pub const CallNode = struct {
//     fn_node: *Node,
//     args: []*Node,
//     stack: SourceInfo,
// };
//
// pub const DefNode = struct {
//     sym: Symbol,
//     init: ?*Node,
//     meta: ?*Node,
//     stack: SourceInfo,
// };
//
// pub const LoopNode = struct {
//     bindings: []LetBinding,
//     body: *Node,
//     stack: SourceInfo,
// };
//
// pub const RecurNode = struct {
//     args: []*Node,
//     stack: SourceInfo,
// };

// === テスト ===

test "placeholder" {
    const node: Node = .{ .placeholder = {} };
    _ = node;
}
