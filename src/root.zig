//! ClojureWasmBeta - Clojure処理系のZig実装
//!
//! Clojure互換（ブラックボックス）を目指す。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! ディレクトリ構成:
//!   src/core/     - 共通基盤（error等）
//!   src/reader/   - Phase 1: Reader（tokenizer, form）
//!   src/analyzer/ - Phase 2: Analyzer（node）
//!   src/runtime/  - Phase 3: Runtime（value, var, namespace, env, context）
//!   src/lib/      - 標準ライブラリ（将来）
//!
//! 詳細: docs/reference/type_design.md

const std = @import("std");

// === 共通基盤 ===
pub const err = @import("core/error.zig");

// === Phase 1: Reader ===
pub const form = @import("reader/form.zig");
pub const Form = form.Form;
pub const Symbol = form.Symbol;
pub const Metadata = form.Metadata;

pub const tokenizer = @import("reader/tokenizer.zig");
pub const Tokenizer = tokenizer.Tokenizer;
pub const Token = tokenizer.Token;
pub const TokenKind = tokenizer.TokenKind;

// === Phase 2: Analyzer ===
// TODO: 実装時にコメント解除
// pub const node = @import("analyzer/node.zig");
// pub const Node = node.Node;

// === Phase 3: Runtime ===
// TODO: 実装時にコメント解除
// pub const value = @import("runtime/value.zig");
// pub const Value = value.Value;
// pub const var_mod = @import("runtime/var.zig");
// pub const Var = var_mod.Var;
// pub const namespace = @import("runtime/namespace.zig");
// pub const Namespace = namespace.Namespace;
// pub const env = @import("runtime/env.zig");
// pub const Env = env.Env;
// pub const context = @import("runtime/context.zig");
// pub const Context = context.Context;

// テスト
test {
    std.testing.refAllDecls(@This());
}
