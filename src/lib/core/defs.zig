//! core 型定義・threadlocal 変数・モジュール状態
//!
//! 全サブモジュールが依存する基盤定義。

const std = @import("std");
pub const value_mod = @import("../../runtime/value.zig");
pub const Value = value_mod.Value;
pub const Fn = value_mod.Fn;
pub const env_mod = @import("../../runtime/env.zig");
pub const Env = env_mod.Env;
pub const var_mod = @import("../../runtime/var.zig");
pub const Var = var_mod.Var;
pub const namespace_mod = @import("../../runtime/namespace.zig");
pub const Namespace = namespace_mod.Namespace;
pub const Reader = @import("../../reader/reader.zig").Reader;
pub const Analyzer = @import("../../analyzer/analyze.zig").Analyzer;
pub const tree_walk = @import("../../runtime/evaluator.zig");
pub const Context = @import("../../runtime/context.zig").Context;
pub const regex_mod = @import("../../regex/regex.zig");
pub const regex_matcher = @import("../../regex/matcher.zig");
pub const wasm_loader = @import("../../wasm/loader.zig");
pub const wasm_runtime = @import("../../wasm/runtime.zig");
pub const wasm_interop = @import("../../wasm/interop.zig");
pub const wasm_wasi = @import("../../wasm/wasi.zig");
pub const engine_mod = @import("../../runtime/engine.zig");
pub const EvalEngine = engine_mod.EvalEngine;
pub const Backend = engine_mod.Backend;

// ============================================================
// 型定義
// ============================================================

/// 組み込み関数の型（value.zig との循環依存を避けるためここで定義）
pub const BuiltinFn = *const fn (allocator: std.mem.Allocator, args: []const Value) anyerror!Value;

/// LazySeq force コールバック型
/// 引数なし fn を呼び出して結果を返す。evaluator/VM がそれぞれ設定する。
pub const ForceFn = *const fn (fn_val: Value, allocator: std.mem.Allocator) anyerror!Value;
pub const CallFn = *const fn (fn_val: Value, args: []const Value, allocator: std.mem.Allocator) anyerror!Value;

/// 組み込み関数の定義
pub const BuiltinDef = struct {
    name: []const u8,
    func: BuiltinFn,
};

/// 組み込み関数エラー
pub const CoreError = error{
    TypeError,
    ArityError,
    DivisionByZero,
    OutOfMemory,
};

// ============================================================
// threadlocal 変数
// ============================================================

/// 現在の force コールバック（threadlocal）
/// evaluator/VM が builtin 呼び出し前に設定する
pub threadlocal var force_lazy_seq_fn: ?ForceFn = null;
/// 関数呼び出しコールバック（lazy map/filter 用）
pub threadlocal var call_fn: ?CallFn = null;
/// 現在の Env（find-var, intern 等で使用）
pub threadlocal var current_env: ?*Env = null;

/// 現在の評価バックエンド（load-file 等で使用）
/// main.zig で --backend オプションに応じて設定される
pub threadlocal var current_backend: Backend = .tree_walk;

/// with-out-str 用: stdout キャプチャバッファ
/// non-null のとき、print/println/pr/prn/printf/newline の出力をここに蓄積する
pub threadlocal var output_capture: ?*std.ArrayListUnmanaged(u8) = null;
/// output_capture 用アロケータ
pub threadlocal var output_capture_allocator: ?std.mem.Allocator = null;

// ============================================================
// モジュール状態
// ============================================================

/// ロード済みライブラリ管理
pub const LoadedLibsSet = std.StringHashMapUnmanaged(void);
pub var loaded_libs: LoadedLibsSet = .empty;
/// ロード済みライブラリ用アロケータ（persistent メモリ）
pub var loaded_libs_allocator: ?std.mem.Allocator = null;

/// ロード済みライブラリの初期化
pub fn initLoadedLibs(allocator: std.mem.Allocator) void {
    loaded_libs_allocator = allocator;
}

/// クラスパスルート（ファイルロード時の基準ディレクトリ）
pub var classpath_roots: [16]?[]const u8 = .{null} ** 16;
pub var classpath_count: usize = 0;

/// クラスパスルートを追加
pub fn addClasspathRoot(path: []const u8) void {
    if (classpath_count < classpath_roots.len) {
        classpath_roots[classpath_count] = path;
        classpath_count += 1;
    }
}

/// 階層グローバル状態
pub var global_hierarchy: ?Value = null;

/// tap グローバル状態
pub var global_taps: ?std.ArrayList(Value) = null;

/// gensym カウンタ
pub var gensym_counter: u64 = 0;
