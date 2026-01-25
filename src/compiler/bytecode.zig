//! Bytecode: バイトコード定義
//!
//! Node から生成される中間表現。VM で実行される。
//!
//! 処理フロー:
//!   Form (Reader) → Node (Analyzer) → Bytecode (Compiler) → Value (VM)
//!
//! 詳細: docs/reference/architecture.md
//!
//! TODO: VM実装時に有効化

const std = @import("std");

/// オペコード
/// TODO: 実装時に拡張
pub const Opcode = enum(u8) {
    // === スタック操作 ===
    // push_nil,
    // push_true,
    // push_false,
    // push_int,       // 即値整数
    // push_const,     // 定数プールから
    // pop,
    // dup,

    // === ローカル変数 ===
    // load_local,     // ローカル変数をプッシュ
    // store_local,    // スタックトップをローカルに格納

    // === グローバル変数 ===
    // load_var,       // Var を deref
    // store_var,      // Var に bind

    // === 関数呼び出し ===
    // call,           // 関数呼び出し (arity 指定)
    // tail_call,      // 末尾呼び出し最適化
    // return_val,     // 関数から戻る

    // === 制御フロー ===
    // jump,           // 無条件ジャンプ
    // jump_if_false,  // 条件ジャンプ
    // jump_if_nil,

    // === クロージャ ===
    // make_closure,   // クロージャ生成
    // close_upvalue,  // upvalue をクローズ

    // プレースホルダー
    placeholder,
};

/// バイトコードチャンク
/// TODO: 実装時にコメント解除
pub const Chunk = struct {
    // code: std.ArrayList(u8),       // バイトコード列
    // constants: std.ArrayList(Value), // 定数プール
    // lines: std.ArrayList(u32),     // 行番号情報（デバッグ用）

    placeholder: void,
};

// === テスト ===

test "placeholder" {
    const op: Opcode = .placeholder;
    _ = op;
}
