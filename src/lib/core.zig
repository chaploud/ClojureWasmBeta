//! clojure.core 組み込み関数 — Facade
//!
//! 各ドメインファイル (core/*.zig) への re-export を提供。
//! 外部モジュール (evaluator, vm, engine 等) はこのファイルを import する。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md

// ============================================================
// 基盤: 型定義・threadlocal・モジュール状態 (defs.zig)
// ============================================================

const defs = @import("core/defs.zig");

// 型 re-export
pub const value_mod = defs.value_mod;
pub const Value = defs.Value;
pub const Fn = defs.Fn;
pub const env_mod = defs.env_mod;
pub const Env = defs.Env;
pub const var_mod = defs.var_mod;
pub const Var = defs.Var;
pub const namespace_mod = defs.namespace_mod;
pub const Namespace = defs.Namespace;
pub const Reader = defs.Reader;
pub const Analyzer = defs.Analyzer;
pub const tree_walk = defs.tree_walk;
pub const Context = defs.Context;
pub const regex_mod = defs.regex_mod;
pub const regex_matcher = defs.regex_matcher;
pub const wasm_loader = defs.wasm_loader;
pub const wasm_runtime = defs.wasm_runtime;
pub const wasm_interop = defs.wasm_interop;
pub const wasm_wasi = defs.wasm_wasi;

// 型定義
pub const BuiltinFn = defs.BuiltinFn;
pub const ForceFn = defs.ForceFn;
pub const CallFn = defs.CallFn;
pub const BuiltinDef = defs.BuiltinDef;
pub const CoreError = defs.CoreError;

// ============================================================
// threadlocal 変数アクセサ
// ============================================================
//
// Zig 0.15 では threadlocal var のポインタを comptime で取得できないため、
// インラインアクセサ関数で提供する。
//
// 使用例:
//   core.setForceCallback(&treeWalkForce);  // 書き込み
//   const f = core.getForceCallback();      // 読み込み

pub inline fn getForceCallback() ?ForceFn {
    return defs.force_lazy_seq_fn;
}
pub inline fn setForceCallback(f: ?ForceFn) void {
    defs.force_lazy_seq_fn = f;
}

pub inline fn getCallFn() ?CallFn {
    return defs.call_fn;
}
pub inline fn setCallFn(f: ?CallFn) void {
    defs.call_fn = f;
}

pub inline fn getCurrentEnv() ?*Env {
    return defs.current_env;
}
pub inline fn setCurrentEnv(env: ?*Env) void {
    defs.current_env = env;
}

pub inline fn getOutputCapture() ?*@import("std").ArrayListUnmanaged(u8) {
    return defs.output_capture;
}
pub inline fn setOutputCapture(cap: ?*@import("std").ArrayListUnmanaged(u8)) void {
    defs.output_capture = cap;
}

pub inline fn getOutputCaptureAllocator() ?@import("std").mem.Allocator {
    return defs.output_capture_allocator;
}
pub inline fn setOutputCaptureAllocator(alloc: ?@import("std").mem.Allocator) void {
    defs.output_capture_allocator = alloc;
}

// ============================================================
// モジュール状態
// ============================================================

pub const LoadedLibsSet = defs.LoadedLibsSet;
pub const loaded_libs = &defs.loaded_libs;
pub const loaded_libs_allocator = &defs.loaded_libs_allocator;
pub const initLoadedLibs = defs.initLoadedLibs;
pub const classpath_roots = &defs.classpath_roots;
pub const classpath_count = &defs.classpath_count;
pub const addClasspathRoot = defs.addClasspathRoot;
pub const global_hierarchy = &defs.global_hierarchy;
pub const global_taps = &defs.global_taps;
pub const gensym_counter = &defs.gensym_counter;

// ============================================================
// サブモジュール re-export
// ============================================================

// --- helpers ---
const helpers_ = @import("core/helpers.zig");
pub const ensureRealized = helpers_.ensureRealized;
pub const collectToSlice = helpers_.collectToSlice;
pub const getItems = helpers_.getItems;
pub const getItemsRealized = helpers_.getItemsRealized;
pub const writeToOutput = helpers_.writeToOutput;
pub const writeByteToOutput = helpers_.writeByteToOutput;
pub const outputValueForPrint = helpers_.outputValueForPrint;
pub const outputValueForPr = helpers_.outputValueForPr;
pub const printValue = helpers_.printValue;
pub const printValueToBuf = helpers_.printValueToBuf;
pub const printValueForPrint = helpers_.printValueForPrint;
pub const valueToString = helpers_.valueToString;
pub const compareNumbers = helpers_.compareNumbers;
pub const numToFloat = helpers_.numToFloat;
pub const compareValues = helpers_.compareValues;
pub const isFnValue = helpers_.isFnValue;
pub const debugLog = helpers_.debugLog;
pub const nsNameToPath = helpers_.nsNameToPath;
pub const loadFileContent = helpers_.loadFileContent;
pub const lookupKeywordInMap = helpers_.lookupKeywordInMap;

// --- lazy ---
const lazy_ = @import("core/lazy.zig");
pub const forceLazySeqOneStep = lazy_.forceLazySeqOneStep;
pub const forceTransformOneStep = lazy_.forceTransformOneStep;
pub const forceConcatOneStep = lazy_.forceConcatOneStep;
pub const forceGeneratorOneStep = lazy_.forceGeneratorOneStep;
pub const seqFirst = lazy_.seqFirst;
pub const seqRest = lazy_.seqRest;
pub const isSeqEmpty = lazy_.isSeqEmpty;
pub const isSourceExhausted = lazy_.isSourceExhausted;
pub const lazyFirst = lazy_.lazyFirst;
pub const lazyRest = lazy_.lazyRest;
pub const forceLazySeq = lazy_.forceLazySeq;

// --- interop ---
const interop_ = @import("core/interop.zig");
pub const findIsaMethodFromMultiFn = interop_.findIsaMethodFromMultiFn;

// --- registry ---
const registry_ = @import("core/registry.zig");
pub const registerCore = registry_.registerCore;
pub const getGcGlobals = registry_.getGcGlobals;
pub const all_builtins = registry_.all_builtins;
pub const wasm_builtins = registry_.wasm_builtins;

// ============================================================
// テスト: 全サブモジュールの test を取り込み
// ============================================================

test {
    _ = @import("core/defs.zig");
    _ = @import("core/helpers.zig");
    _ = @import("core/lazy.zig");
    _ = @import("core/arithmetic.zig");
    _ = @import("core/predicates.zig");
    _ = @import("core/collections.zig");
    _ = @import("core/sequences.zig");
    _ = @import("core/strings.zig");
    _ = @import("core/io.zig");
    _ = @import("core/meta.zig");
    _ = @import("core/concurrency.zig");
    _ = @import("core/interop.zig");
    _ = @import("core/transducers.zig");
    _ = @import("core/namespaces.zig");
    _ = @import("core/eval.zig");
    _ = @import("core/misc.zig");
    _ = @import("core/wasm.zig");
    _ = @import("core/registry.zig");
}
