//! ClojureWasmBeta - Clojure処理系のZig実装
//!
//! Clojure互換（ブラックボックス）を目指す。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! ディレクトリ構成:
//!   src/base/     - 共通基盤（error, allocator, intern等）
//!   src/reader/   - Phase 1: Reader（tokenizer, form）
//!   src/analyzer/ - Phase 2: Analyzer（node）
//!   src/runtime/  - Phase 3: Runtime（value, var, namespace, env, context）
//!   src/lib/      - 標準ライブラリ（clojure.core等）
//!
//! 詳細: docs/reference/type_design.md

const std = @import("std");

// === 共通基盤 ===
pub const err = @import("base/error.zig");

// === Phase 1: Reader ===
pub const form = @import("reader/form.zig");
pub const Form = form.Form;
pub const Symbol = form.Symbol;
pub const Metadata = form.Metadata;

pub const tokenizer = @import("reader/tokenizer.zig");
pub const Tokenizer = tokenizer.Tokenizer;
pub const Token = tokenizer.Token;
pub const TokenKind = tokenizer.TokenKind;

pub const reader = @import("reader/reader.zig");
pub const Reader = reader.Reader;

// === Phase 2: Analyzer ===
pub const node = @import("analyzer/node.zig");
pub const Node = node.Node;
pub const SourceInfo = node.SourceInfo;

pub const analyze = @import("analyzer/analyze.zig");
pub const Analyzer = analyze.Analyzer;

// === Phase 3: Runtime ===
pub const value = @import("runtime/value.zig");
pub const Value = value.Value;
pub const RuntimeSymbol = value.Symbol;
pub const Keyword = value.Keyword;
pub const PersistentList = value.PersistentList;
pub const PersistentVector = value.PersistentVector;
pub const PersistentMap = value.PersistentMap;
pub const PersistentSet = value.PersistentSet;
pub const Fn = value.Fn;

pub const var_mod = @import("runtime/var.zig");
pub const Var = var_mod.Var;

pub const namespace = @import("runtime/namespace.zig");
pub const Namespace = namespace.Namespace;

pub const env_mod = @import("runtime/env.zig");
pub const Env = env_mod.Env;

pub const allocators_mod = @import("runtime/allocators.zig");
pub const Allocators = allocators_mod.Allocators;

pub const context = @import("runtime/context.zig");
pub const Context = context.Context;

pub const evaluator = @import("runtime/evaluator.zig");

pub const engine = @import("runtime/engine.zig");
pub const EvalEngine = engine.EvalEngine;
pub const Backend = engine.Backend;

// === GC ===
pub const gc = @import("gc/gc.zig");
pub const gc_allocator = @import("gc/gc_allocator.zig");
pub const gc_tracing = @import("gc/tracing.zig");

// === 正規表現 ===
pub const regex = @import("regex/regex.zig");
pub const regex_matcher = @import("regex/matcher.zig");

// === Wasm ===
pub const wasm_loader = @import("wasm/loader.zig");
pub const wasm_runtime = @import("wasm/runtime.zig");
pub const wasm_types = @import("wasm/types.zig");
pub const wasm_interop = @import("wasm/interop.zig");
pub const wasm_host_functions = @import("wasm/host_functions.zig");
pub const wasm_wasi = @import("wasm/wasi.zig");

// === コンパイラ ===
pub const bytecode = @import("compiler/bytecode.zig");
pub const compiler = @import("compiler/emit.zig");

// === 標準ライブラリ ===
pub const core = @import("lib/core.zig");

// === テスト ===
pub const test_e2e = @import("test_e2e.zig");

test {
    std.testing.refAllDecls(@This());
}
