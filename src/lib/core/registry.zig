//! comptime テーブル集約・登録
//!
//! 各ドメインファイルの builtins を結合し、registerCore で Env に登録する。

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const Fn = defs.Fn;
const Env = defs.Env;
const BuiltinDef = defs.BuiltinDef;

// ドメインモジュール
const arithmetic = @import("arithmetic.zig");
const predicates = @import("predicates.zig");
const collections = @import("collections.zig");
const sequences = @import("sequences.zig");
const strings = @import("strings.zig");
const io = @import("io.zig");
const meta = @import("meta.zig");
const concurrency = @import("concurrency.zig");
const interop = @import("interop.zig");
const transducers = @import("transducers.zig");
const namespaces = @import("namespaces.zig");
const eval_mod = @import("eval.zig");
const misc = @import("misc.zig");
const math_fns = @import("math_fns.zig");
const wasm = @import("wasm.zig");

// ============================================================
// comptime テーブル結合
// ============================================================

/// 全ドメインの builtins を comptime で結合
pub const all_builtins = arithmetic.builtins ++
    predicates.builtins ++
    collections.builtins ++
    sequences.builtins ++
    strings.builtins ++
    io.builtins ++
    meta.builtins ++
    concurrency.builtins ++
    interop.builtins ++
    transducers.builtins ++
    namespaces.builtins ++
    eval_mod.builtins ++
    misc.builtins ++
    math_fns.builtins;

/// wasm 名前空間の builtins
pub const wasm_builtins = wasm.builtins;

// comptime 検証: 名前の重複チェック
comptime {
    validateNoDuplicates(all_builtins, "clojure.core");
    validateNoDuplicates(wasm_builtins, "wasm");
}

fn validateNoDuplicates(comptime table: anytype, comptime ns_name: []const u8) void {
    @setEvalBranchQuota(table.len * table.len * 10);
    for (table, 0..) |a, i| {
        for (table[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) {
                @compileError(std.fmt.comptimePrint(
                    "{s}: builtin '{s}' が重複登録されています",
                    .{ ns_name, a.name },
                ));
            }
        }
    }
}

// ============================================================
// Env への登録
// ============================================================

/// clojure.core の組み込み関数を Env に登録
/// value_allocator: Value/Fn 等の Clojure オブジェクト用アロケータ
///   （GcAllocator 経由で GC 追跡される）
/// env.allocator: Namespace/Var/HashMap 等のインフラ用アロケータ
pub fn registerCore(env: *Env, value_allocator: std.mem.Allocator) !void {
    const core_ns = try env.findOrCreateNs("clojure.core");

    for (all_builtins) |b| {
        const v = try core_ns.intern(b.name);
        const fn_obj = try value_allocator.create(Fn);
        fn_obj.* = Fn.initBuiltin(b.name, b.func);
        v.bindRoot(Value{ .fn_val = fn_obj });
    }

    // wasm 名前空間の関数を登録
    try registerWasmNs(env, value_allocator);

    // 動的 Var（値として登録）
    try registerDynamicVars(value_allocator, core_ns);
}

/// wasm 名前空間の組み込み関数を登録
fn registerWasmNs(env: *Env, value_allocator: std.mem.Allocator) !void {
    const wasm_ns = try env.findOrCreateNs("wasm");

    for (wasm_builtins) |b| {
        const v = try wasm_ns.intern(b.name);
        const fn_obj = try value_allocator.create(Fn);
        fn_obj.* = Fn.initBuiltin(b.name, b.func);
        v.bindRoot(Value{ .fn_val = fn_obj });
    }
}

/// 動的 Var の初期値を登録
fn registerDynamicVars(allocator: std.mem.Allocator, core_ns: anytype) !void {
    // *clojure-version*
    {
        const v = try core_ns.intern("*clojure-version*");
        v.dynamic = true;
        const ver = try eval_mod.clojureVersionFn(allocator, &[_]Value{});
        v.bindRoot(ver);
    }
    // *assert* — デフォルト true
    {
        const v = try core_ns.intern("*assert*");
        v.dynamic = true;
        v.bindRoot(value_mod.true_val);
    }
    // *print-length* — デフォルト nil（無制限）
    {
        const v = try core_ns.intern("*print-length*");
        v.dynamic = true;
        v.bindRoot(value_mod.nil);
    }
    // *print-level* — デフォルト nil（無制限）
    {
        const v = try core_ns.intern("*print-level*");
        v.dynamic = true;
        v.bindRoot(value_mod.nil);
    }
    // *print-meta* — デフォルト false
    {
        const v = try core_ns.intern("*print-meta*");
        v.dynamic = true;
        v.bindRoot(value_mod.false_val);
    }
    // *print-readably* — デフォルト true
    {
        const v = try core_ns.intern("*print-readably*");
        v.dynamic = true;
        v.bindRoot(value_mod.true_val);
    }
    // *print-dup* — デフォルト false
    {
        const v = try core_ns.intern("*print-dup*");
        v.dynamic = true;
        v.bindRoot(value_mod.false_val);
    }
    // *print-namespace-maps* — デフォルト true
    {
        const v = try core_ns.intern("*print-namespace-maps*");
        v.dynamic = true;
        v.bindRoot(value_mod.true_val);
    }
    // *flush-on-newline* — デフォルト true
    {
        const v = try core_ns.intern("*flush-on-newline*");
        v.dynamic = true;
        v.bindRoot(value_mod.true_val);
    }
    // *read-eval* — デフォルト true
    {
        const v = try core_ns.intern("*read-eval*");
        v.dynamic = true;
        v.bindRoot(value_mod.true_val);
    }
    // *compile-path* — デフォルト "classes"
    {
        const v = try core_ns.intern("*compile-path*");
        v.dynamic = true;
        const str = try allocator.create(value_mod.String);
        str.* = value_mod.String.init("classes");
        v.bindRoot(Value{ .string = str });
    }
    // *1, *e — デフォルト nil
    {
        const v1 = try core_ns.intern("*1");
        v1.dynamic = true;
        v1.bindRoot(value_mod.nil);
        const ve = try core_ns.intern("*e");
        ve.dynamic = true;
        ve.bindRoot(value_mod.nil);
    }
    // Phase 20: 追加動的 Var
    {
        const v = try core_ns.intern("*ns*");
        v.dynamic = true;
        // *ns* はシンボル 'clojure.core を初期値として設定
        const sym = try allocator.create(value_mod.Symbol);
        sym.* = .{ .name = "clojure.core", .namespace = null };
        v.bindRoot(Value{ .symbol = sym });
    }
    {
        const v = try core_ns.intern("*in*");
        v.dynamic = true;
        v.bindRoot(value_mod.nil); // stdin リーダーは未実装
    }
    {
        const v = try core_ns.intern("*out*");
        v.dynamic = true;
        v.bindRoot(value_mod.nil); // stdout ライターは未実装
    }
    {
        const v = try core_ns.intern("*err*");
        v.dynamic = true;
        v.bindRoot(value_mod.nil); // stderr ライターは未実装
    }
    {
        const v = try core_ns.intern("*file*");
        v.dynamic = true;
        v.bindRoot(value_mod.nil);
    }
    {
        const v = try core_ns.intern("*agent*");
        v.dynamic = true;
        v.bindRoot(value_mod.nil);
    }
    {
        const v = try core_ns.intern("*repl*");
        v.dynamic = true;
        v.bindRoot(value_mod.false_val);
    }
    {
        const v = try core_ns.intern("*compile-files*");
        v.dynamic = true;
        v.bindRoot(value_mod.false_val);
    }
    {
        const v = try core_ns.intern("*compiler-options*");
        v.dynamic = true;
        const m = try allocator.create(value_mod.PersistentMap);
        m.* = .{ .entries = &[_]Value{} };
        v.bindRoot(Value{ .map = m });
    }
    {
        const v = try core_ns.intern("*reader-resolver*");
        v.dynamic = true;
        v.bindRoot(value_mod.nil);
    }
    {
        const v = try core_ns.intern("*suppress-read*");
        v.dynamic = true;
        v.bindRoot(value_mod.false_val);
    }
}

// ============================================================
// GC サポート
// ============================================================

const gc_mod = @import("../../gc/gc.zig");

/// GC ルート用グローバル参照を取得
pub fn getGcGlobals() gc_mod.GcGlobals {
    return .{
        .hierarchy = &defs.global_hierarchy,
        .taps = if (defs.global_taps) |t| t.items else null,
    };
}
