//! ClojureWasmBeta - Clojure処理系のZig実装
//!
//! Clojure互換（ブラックボックス）を目指す。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md

const std = @import("std");

// === Phase 1: Reader ===
pub const form = @import("form.zig");
pub const Form = form.Form;
pub const Symbol = form.Symbol;
pub const Metadata = form.Metadata;

pub const tokenizer = @import("reader/tokenizer.zig");
pub const Tokenizer = tokenizer.Tokenizer;
pub const Token = tokenizer.Token;
pub const TokenKind = tokenizer.TokenKind;

// === Phase 2: Analyzer ===
// TODO: 実装時にコメント解除
// pub const node = @import("node.zig");
// pub const Node = node.Node;

// === Phase 3: Runtime ===
// TODO: 実装時にコメント解除
// pub const value = @import("value.zig");
// pub const Value = value.Value;
// pub const var_mod = @import("var.zig");
// pub const Var = var_mod.Var;
// pub const namespace = @import("namespace.zig");
// pub const Namespace = namespace.Namespace;
// pub const env = @import("env.zig");
// pub const Env = env.Env;
// pub const context = @import("context.zig");
// pub const Context = context.Context;

// === エラー ===
pub const err = @import("error.zig");

// テスト
test {
    std.testing.refAllDecls(@This());
}
