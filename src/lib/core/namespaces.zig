//! 名前空間操作
//!
//! NS操作, require, use, alias, binding, thread-bindings

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const var_mod = defs.var_mod;
const Env = defs.Env;
const Namespace = defs.Namespace;
const namespace_mod = defs.namespace_mod;
const BuiltinDef = defs.BuiltinDef;

const helpers = @import("helpers.zig");
const collections = @import("collections.zig");

const eval_mod = @import("eval.zig");

// ============================================================
// 名前空間ヘルパー
// ============================================================

/// 引数から名前空間名を取得（シンボルまたは文字列）
fn nsArgName(arg: Value) ?[]const u8 {
    return switch (arg) {
        .symbol => |s| s.name,
        .string => |s| s.data,
        else => null,
    };
}

/// 引数から Namespace オブジェクトを取得
/// シンボル/文字列 → findNs
fn resolveNsArg(arg: Value) ?*Namespace {
    const env = defs.current_env orelse return null;
    const name = nsArgName(arg) orelse return null;
    return env.findNs(name);
}

// ============================================================
// 名前空間操作（簡易実装）
// ============================================================

/// find-ns : 名前空間を検索
pub fn findNsFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const env = defs.current_env orelse return error.TypeError;
    const name = nsArgName(args[0]) orelse return error.TypeError;
    if (env.findNs(name)) |_| {
        // シンボルとして返す（Clojure は NS オブジェクトを返すが、ここではシンボルで代用）
        return args[0];
    }
    return value_mod.nil;
}

/// create-ns : 名前空間を作成
pub fn createNsFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const env = defs.current_env orelse return error.TypeError;
    const name = nsArgName(args[0]) orelse return error.TypeError;
    _ = env.findOrCreateNs(name) catch return error.EvalError;
    return args[0];
}

/// all-ns : すべての名前空間をリストで返す
pub fn allNsFn(allocator: std.mem.Allocator, _: []const Value) anyerror!Value {
    const env = defs.current_env orelse return error.TypeError;
    // 名前空間数をカウント
    var ns_count: usize = 0;
    {
        var counting_iter = env.getAllNamespaces();
        while (counting_iter.next()) |_| {
            ns_count += 1;
        }
    }
    const items = try allocator.alloc(Value, ns_count);
    var build_iter = env.getAllNamespaces();
    var i: usize = 0;
    while (build_iter.next()) |entry| {
        const sym = try allocator.create(value_mod.Symbol);
        sym.* = .{ .name = entry.key_ptr.*, .namespace = null };
        items[i] = Value{ .symbol = sym };
        i += 1;
    }
    const lst = try allocator.create(value_mod.PersistentList);
    lst.* = .{ .items = items };
    return Value{ .list = lst };
}

/// ns-name : 名前空間の名前をシンボルで返す
pub fn nsNameFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const ns = resolveNsArg(args[0]);
    if (ns) |n| {
        const sym = try allocator.create(value_mod.Symbol);
        sym.* = .{ .name = n.name, .namespace = null };
        return Value{ .symbol = sym };
    }
    // 引数がシンボルならそのまま返す（Clojure互換: NS自体をシンボルで代用）
    return args[0];
}

/// ns-publics : NS 内で定義された全 Var のマップ {sym var} を返す
pub fn nsPublicsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const ns = resolveNsArg(args[0]) orelse return emptyMap(allocator);
    return buildVarMap(allocator, ns.getAllVars(), ns.name);
}

/// ns-interns : NS 内で intern された全 Var のマップ（ns-publics と同じ）
pub fn nsInternsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const ns = resolveNsArg(args[0]) orelse return emptyMap(allocator);
    return buildVarMap(allocator, ns.getAllVars(), ns.name);
}

/// ns-map : NS 内の全マッピング（interns + refers）を返す
pub fn nsMapFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const ns = resolveNsArg(args[0]) orelse return emptyMap(allocator);
    // interns + refers の合計数をカウント
    var total_count: usize = 0;
    {
        var var_iter = ns.getAllVars();
        while (var_iter.next()) |_| total_count += 1;
    }
    {
        var ref_iter = ns.getAllRefers();
        while (ref_iter.next()) |_| total_count += 1;
    }
    const entries = try allocator.alloc(Value, total_count * 2);
    var idx: usize = 0;
    // interns
    {
        var var_iter = ns.getAllVars();
        while (var_iter.next()) |entry| {
            const sym = try allocator.create(value_mod.Symbol);
            sym.* = .{ .name = entry.key_ptr.*, .namespace = null };
            entries[idx] = Value{ .symbol = sym };
            entries[idx + 1] = entry.value_ptr.*.deref();
            idx += 2;
        }
    }
    // refers
    {
        var ref_iter = ns.getAllRefers();
        while (ref_iter.next()) |entry| {
            const sym = try allocator.create(value_mod.Symbol);
            sym.* = .{ .name = entry.key_ptr.*, .namespace = null };
            entries[idx] = Value{ .symbol = sym };
            entries[idx + 1] = entry.value_ptr.*.deref();
            idx += 2;
        }
    }
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries[0..idx] };
    return Value{ .map = m };
}

/// ns-refers : NS の refer された Var のマップ
pub fn nsRefersFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const ns = resolveNsArg(args[0]) orelse return emptyMap(allocator);
    return buildVarMap(allocator, ns.getAllRefers(), null);
}

/// ns-imports : インポートされた型のマップ（Zig実装では空マップ）
pub fn nsImportsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return emptyMap(allocator);
}

/// ns-aliases : NS のエイリアスマップ {alias-sym ns-sym}
pub fn nsAliasesFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const ns = resolveNsArg(args[0]) orelse return emptyMap(allocator);
    var alias_count: usize = 0;
    {
        var counting_iter = ns.getAllAliases();
        while (counting_iter.next()) |_| alias_count += 1;
    }
    const entries = try allocator.alloc(Value, alias_count * 2);
    var build_iter = ns.getAllAliases();
    var idx: usize = 0;
    while (build_iter.next()) |entry| {
        const alias_sym = try allocator.create(value_mod.Symbol);
        alias_sym.* = .{ .name = entry.key_ptr.*, .namespace = null };
        entries[idx] = Value{ .symbol = alias_sym };
        const ns_sym = try allocator.create(value_mod.Symbol);
        ns_sym.* = .{ .name = entry.value_ptr.*.name, .namespace = null };
        entries[idx + 1] = Value{ .symbol = ns_sym };
        idx += 2;
    }
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries[0..idx] };
    return Value{ .map = m };
}

/// ns-resolve : 名前空間内でシンボルを解決
pub fn nsResolveFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    // 第1引数で NS を解決し、その NS 内でシンボルを検索
    const ns = resolveNsArg(args[0]);
    if (ns) |n| {
        if (args[1] == .symbol) {
            if (n.resolve(args[1].symbol.name)) |v| {
                // Var の値を返す
                return v.deref();
            }
            // clojure.core のフォールバック
            const env = defs.current_env orelse return value_mod.nil;
            if (env.findNs("clojure.core")) |core| {
                if (core.resolve(args[1].symbol.name)) |v| {
                    return v.deref();
                }
            }
        }
    }
    // フォールバック: resolveFn に委譲
    return eval_mod.resolveFn(allocator, args[1..2]);
}

/// ns-unmap : NS からシンボルを除去
pub fn nsUnmapFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const ns = resolveNsArg(args[0]) orelse return value_mod.nil;
    const sym_name = nsArgName(args[1]) orelse return error.TypeError;
    ns.unmap(sym_name);
    return value_mod.nil;
}

/// ns-unalias : NS からエイリアスを除去
pub fn nsUnaliasFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const ns = resolveNsArg(args[0]) orelse return value_mod.nil;
    const alias_name = nsArgName(args[1]) orelse return error.TypeError;
    ns.removeAlias(alias_name);
    return value_mod.nil;
}

/// remove-ns : 名前空間を環境から削除
pub fn removeNsFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const env = defs.current_env orelse return value_mod.nil;
    const name = nsArgName(args[0]) orelse return error.TypeError;
    // clojure.core は削除不可
    if (std.mem.eql(u8, name, "clojure.core")) return value_mod.nil;
    _ = env.removeNs(name);
    return value_mod.nil;
}

// === NS ヘルパー関数 ===

/// 空マップを返す
fn emptyMap(allocator: std.mem.Allocator) anyerror!Value {
    const entries = try allocator.alloc(Value, 0);
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

/// VarMap イテレータから {sym var-value} マップを構築
fn buildVarMap(allocator: std.mem.Allocator, iter_init: namespace_mod.VarMap.Iterator, _: ?[]const u8) anyerror!Value {
    // カウント（イテレータはコピーで受け取るのでリセット不要）
    var ns_count: usize = 0;
    {
        var counting_iter = iter_init;
        while (counting_iter.next()) |_| ns_count += 1;
    }
    const entries = try allocator.alloc(Value, ns_count * 2);
    var build_iter = iter_init;
    var idx: usize = 0;
    while (build_iter.next()) |entry| {
        const sym = try allocator.create(value_mod.Symbol);
        sym.* = .{ .name = entry.key_ptr.*, .namespace = null };
        entries[idx] = Value{ .symbol = sym };
        entries[idx + 1] = entry.value_ptr.*.deref();
        idx += 2;
    }
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries[0..idx] };
    return Value{ .map = m };
}

// ============================================================
// Reader / その他ユーティリティ
// ============================================================

/// read : 入力から読み取り（read-string に委譲）
pub fn readFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // 簡易実装: 引数がstring なら read-string と同じ
    if (args.len >= 1 and args[0] == .string) {
        return eval_mod.readStringFn(allocator, args[0..1]);
    }
    return value_mod.nil;
}

/// read+string : 読み取り結果と元文字列のベクターを返す
pub fn readPlusStringFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const form_val = try eval_mod.readStringFn(allocator, args[0..1]);
    // [form source-string] を返す
    const items = try allocator.alloc(Value, 2);
    items[0] = form_val;
    items[1] = args[0];
    const vec = try allocator.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };
    return Value{ .vector = vec };
}

/// reader-conditional : リーダーコンディショナル（データをそのまま返す）
pub fn readerConditionalFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    return args[0];
}

/// loaded-libs : ロード済みライブラリのセットを返す
pub fn loadedLibsFn(allocator: std.mem.Allocator, _: []const Value) anyerror!Value {
    var lib_count: usize = 0;
    {
        var lib_iter = defs.loaded_libs.iterator();
        while (lib_iter.next()) |_| lib_count += 1;
    }
    const items = try allocator.alloc(Value, lib_count);
    var lib_iter = defs.loaded_libs.iterator();
    var i: usize = 0;
    while (lib_iter.next()) |entry| {
        const sym = try allocator.create(value_mod.Symbol);
        sym.* = .{ .name = entry.key_ptr.*, .namespace = null };
        items[i] = Value{ .symbol = sym };
        i += 1;
    }
    const s = try allocator.create(value_mod.PersistentSet);
    s.* = .{ .items = items[0..i] };
    return Value{ .set = s };
}

/// default-data-readers : デフォルトデータリーダー（空マップを返す）
pub fn defaultDataReadersFn(allocator: std.mem.Allocator, _: []const Value) anyerror!Value {
    const entries = try allocator.alloc(Value, 0);
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

/// print-ctor : コンストラクタ出力（スタブ）
pub fn printCtorFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    return value_mod.nil;
}

/// PrintWriter-on : ライター作成（スタブ、nil を返す）
pub fn printWriterOnFn(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    return value_mod.nil;
}

/// compile : AOT コンパイル（スタブ、nil を返す）
pub fn compileFn(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    return value_mod.nil;
}

/// load-reader : リーダーからロード（スタブ）
pub fn loadReaderFn(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    return value_mod.nil;
}

/// load-file : ファイルを読み込んで評価
pub fn loadFileFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    const path = switch (args[0]) {
        .string => |s| s.data,
        .symbol => |s| s.name,
        else => return error.TypeError,
    };
    // ファイルを読み込む
    const file = std.fs.cwd().openFile(path, .{}) catch return value_mod.nil;
    defer file.close();
    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return value_mod.nil;
    return helpers.loadFileContentWithPath(allocator, content, path);
}

// ============================================================
// Phase 20: 残り59 — binding/chunk/regex/IO/NS/type stubs
// ============================================================

// --- Binding / threading stubs ---

/// binding: マクロ展開で処理するため関数としては不要（互換性のためスタブ残し）
pub fn bindingStubFn(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    return value_mod.nil;
}

/// set! — 動的 Var への代入（binding スコープ内でのみ有効）
pub fn setBangFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    // args[0] は var_val（Var ポインタ）
    const v: *var_mod.Var = switch (args[0]) {
        .var_val => |ptr| @ptrCast(@alignCast(ptr)),
        else => return error.TypeError,
    };
    try var_mod.setThreadBinding(v, args[1]);
    return args[1];
}

/// get-thread-bindings — 現在のフレームの全バインディングをマップとして返す
pub fn getThreadBindingsFn(allocator: std.mem.Allocator, _: []const Value) anyerror!Value {
    const frame = var_mod.getCurrentFrame();
    if (frame == null) {
        const m = try allocator.create(value_mod.PersistentMap);
        m.* = .{ .entries = &[_]Value{} };
        return Value{ .map = m };
    }
    // フレームスタックを走査して全エントリを収集
    var all_entries: std.ArrayListUnmanaged(Value) = .empty;
    var f = frame;
    while (f) |fr| {
        for (fr.entries) |e| {
            try all_entries.append(allocator, Value{ .var_val = @ptrCast(e.var_ptr) });
            try all_entries.append(allocator, e.value);
        }
        f = fr.prev;
    }
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = try all_entries.toOwnedSlice(allocator) };
    return Value{ .map = m };
}

/// push-thread-bindings — マップから BindingFrame を構築して push
pub fn pushThreadBindingsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    // args[0] は map (Var → Value のペア)
    const m = switch (args[0]) {
        .map => |mp| mp,
        else => return error.TypeError,
    };
    const n_pairs = m.entries.len / 2;
    if (n_pairs == 0) return value_mod.nil;

    // BindingEntry[] を構築
    const entries = try allocator.alloc(var_mod.BindingEntry, n_pairs);
    var idx: usize = 0;
    var i: usize = 0;
    while (i < m.entries.len) : (i += 2) {
        const key = m.entries[i];
        const val = m.entries[i + 1];
        // key は var_val であるべき
        const v: *var_mod.Var = switch (key) {
            .var_val => |ptr| @ptrCast(@alignCast(ptr)),
            else => return error.TypeError,
        };
        // dynamic フラグを確認
        if (!v.isDynamic()) return error.IllegalState;
        entries[idx] = .{ .var_ptr = v, .value = val };
        idx += 1;
    }

    // BindingFrame を allocate
    const frame = try allocator.create(var_mod.BindingFrame);
    frame.* = .{ .entries = entries, .prev = null };
    var_mod.pushBindings(frame);
    return value_mod.nil;
}

/// pop-thread-bindings — フレームを外す
pub fn popThreadBindingsFn(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    var_mod.popBindings();
    return value_mod.nil;
}

/// thread-bound? — Var がバインディングフレーム内か
pub fn threadBoundPred(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const v: *const var_mod.Var = switch (args[0]) {
        .var_val => |ptr| @ptrCast(@alignCast(ptr)),
        else => return error.TypeError,
    };
    return if (var_mod.hasThreadBinding(v)) value_mod.true_val else value_mod.false_val;
}

/// with-redefs-fn — Var の root を一時退避 → 差替 → fn 呼び出し → 復元
pub fn withRedefsFnFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const call_fn_opt = defs.call_fn orelse return error.TypeError;
    // args[0] = map (Var → new-value), args[1] = fn
    const m = switch (args[0]) {
        .map => |mp| mp,
        else => return error.TypeError,
    };
    const n_pairs = m.entries.len / 2;

    // 元の root を退避
    const old_roots = try allocator.alloc(Value, n_pairs);
    const vars = try allocator.alloc(*var_mod.Var, n_pairs);
    var idx: usize = 0;
    var i: usize = 0;
    while (i < m.entries.len) : (i += 2) {
        const v: *var_mod.Var = switch (m.entries[i]) {
            .var_val => |ptr| @ptrCast(@alignCast(ptr)),
            else => return error.TypeError,
        };
        old_roots[idx] = v.getRawRoot();
        vars[idx] = v;
        v.bindRoot(m.entries[i + 1]);
        idx += 1;
    }

    // fn を呼び出し（エラーでも必ず復元する）
    const result = call_fn_opt(args[1], &[_]Value{}, allocator);

    // 復元
    for (vars, old_roots) |v, old| {
        v.bindRoot(old);
    }

    return result;
}

/// requiring-resolve — resolve のエイリアス（require はスタブ）
pub fn requiringResolveFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .symbol) return error.TypeError;
    const env = defs.current_env orelse return error.TypeError;
    const sym = value_mod.Symbol{
        .namespace = args[0].symbol.namespace,
        .name = args[0].symbol.name,
    };
    if (env.resolve(sym)) |v| {
        return v.root;
    }
    return value_mod.nil;
}

// --- NS 関数 stubs ---

/// refer — 他の名前空間の Var を現在の NS に参照追加
/// (refer 'ns-name) — 全 Var を refer
/// (refer 'ns-name :only '[sym1 sym2]) — 指定 Var のみ refer
/// (refer 'ns-name :exclude '[sym1 sym2]) — 指定 Var を除外して refer
/// (refer 'ns-name :rename '{old-name new-name}) — リネームして refer
pub fn referFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    const env = defs.current_env orelse return error.TypeError;
    const source_name = nsArgName(args[0]) orelse return error.TypeError;
    const source_ns = env.findNs(source_name) orelse return value_mod.nil;
    const current_ns = env.getCurrentNs() orelse return error.TypeError;

    // オプション解析: :only, :exclude, :rename
    var only_list: ?[]const Value = null;
    var exclude_list: ?[]const Value = null;
    var rename_map: ?[]const Value = null;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        if (args[i] == .keyword) {
            if (std.mem.eql(u8, args[i].keyword.name, "only")) {
                if (args[i + 1] == .vector) {
                    only_list = args[i + 1].vector.items;
                }
            } else if (std.mem.eql(u8, args[i].keyword.name, "exclude")) {
                if (args[i + 1] == .vector) {
                    exclude_list = args[i + 1].vector.items;
                }
            } else if (std.mem.eql(u8, args[i].keyword.name, "rename")) {
                if (args[i + 1] == .map) {
                    rename_map = args[i + 1].map.entries;
                }
            }
        }
    }

    // source_ns の全 Var をイテレートして refer
    var var_iter = source_ns.getAllVars();
    while (var_iter.next()) |entry| {
        const sym_name = entry.key_ptr.*;
        // :only フィルタ
        if (only_list) |only| {
            if (!containsSymName(only, sym_name)) continue;
        }
        // :exclude フィルタ
        if (exclude_list) |exclude| {
            if (containsSymName(exclude, sym_name)) continue;
        }
        // :rename 処理
        const refer_name = if (rename_map) |rmap| blk: {
            break :blk findRename(rmap, sym_name) orelse sym_name;
        } else sym_name;
        current_ns.refer(refer_name, entry.value_ptr.*) catch {};
    }
    return value_mod.nil;
}

/// require — 名前空間をロードして設定
/// (require 'ns-name)
/// (require '[ns-name :as alias])
/// (require '[ns-name :refer [sym1 sym2]])
/// (require '[ns-name :refer :all])
pub fn requireFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    const env = defs.current_env orelse return error.TypeError;
    const current_ns = env.getCurrentNs() orelse return error.TypeError;

    // :reload フラグチェック
    var force_reload = false;
    for (args) |arg| {
        if (arg == .keyword) {
            if (std.mem.eql(u8, arg.keyword.name, "reload") or
                std.mem.eql(u8, arg.keyword.name, "reload-all"))
            {
                force_reload = true;
            }
        }
    }

    // 各引数を処理
    for (args) |arg| {
        switch (arg) {
            .symbol => |s| {
                // (require 'ns-name)
                requireNsLoad(allocator, s.name, force_reload) catch {};
            },
            .vector => |v| {
                // (require '[ns-name :as alias :refer [...]])
                if (v.items.len < 1) continue;
                const ns_sym_name = nsArgName(v.items[0]) orelse continue;
                requireNsLoad(allocator, ns_sym_name, force_reload) catch {};
                const target_ns = env.findOrCreateNs(ns_sym_name) catch continue;

                // オプション解析
                var vi: usize = 1;
                while (vi + 1 < v.items.len) : (vi += 2) {
                    if (v.items[vi] == .keyword) {
                        const kw_name = v.items[vi].keyword.name;
                        if (std.mem.eql(u8, kw_name, "as")) {
                            // :as alias
                            const alias_name = nsArgName(v.items[vi + 1]) orelse continue;
                            current_ns.setAlias(alias_name, target_ns) catch {};
                        } else if (std.mem.eql(u8, kw_name, "refer")) {
                            // :refer [sym1 sym2] or :refer :all
                            if (v.items[vi + 1] == .vector) {
                                for (v.items[vi + 1].vector.items) |ref_sym| {
                                    const ref_name = nsArgName(ref_sym) orelse continue;
                                    if (target_ns.resolve(ref_name)) |var_ref| {
                                        current_ns.refer(ref_name, var_ref) catch {};
                                    }
                                }
                            } else if (v.items[vi + 1] == .keyword) {
                                if (std.mem.eql(u8, v.items[vi + 1].keyword.name, "all")) {
                                    var all_iter = target_ns.getAllVars();
                                    while (all_iter.next()) |entry| {
                                        current_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
                                    }
                                }
                            }
                        }
                    }
                }
            },
            .keyword => {}, // :reload 等は上で処理済み
            else => {},
        }
    }
    return value_mod.nil;
}

/// NS名のファイルをロードする（ロード済みならスキップ）
fn requireNsLoad(allocator: std.mem.Allocator, ns_name: []const u8, force_reload: bool) !void {
    // clojure.core は常にロード済み
    if (std.mem.eql(u8, ns_name, "clojure.core")) return;

    // ロード済みチェック
    if (!force_reload and defs.loaded_libs.contains(ns_name)) return;

    // NS名 → ファイルパス変換 (.clj と .cljc の両方)
    const rel_path_clj = try helpers.nsNameToPath(allocator, ns_name, ".clj");
    const rel_path_cljc = try helpers.nsNameToPath(allocator, ns_name, ".cljc");

    // クラスパスルートからファイルを探索 (.clj → .cljc フォールバック)
    var loaded = false;
    var ri: usize = 0;
    while (ri < defs.classpath_count) : (ri += 1) {
        if (defs.classpath_roots[ri]) |root| {
            const full_path_clj = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, rel_path_clj });
            if (tryLoadFile(allocator, full_path_clj)) {
                loaded = true;
                break;
            }
            const full_path_cljc = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, rel_path_cljc });
            if (tryLoadFile(allocator, full_path_cljc)) {
                loaded = true;
                break;
            }
        }
    }

    // ルートなしで相対パスを試す (.clj → .cljc)
    if (!loaded) {
        if (!tryLoadFile(allocator, rel_path_clj)) {
            _ = tryLoadFile(allocator, rel_path_cljc);
        }
    }

    // ロード済みとして登録（ファイルが見つからなくても NS は作成済みなので登録）
    const alloc = defs.loaded_libs_allocator orelse allocator;
    const key = try alloc.dupe(u8, ns_name);
    defs.loaded_libs.put(alloc, key, {}) catch {};
}

/// ファイルを読み込んで評価（失敗時は false）
fn tryLoadFile(allocator: std.mem.Allocator, path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();
    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return false;
    // 現在の NS を退避（ファイル内で ns が変更される可能性がある）
    const env = defs.current_env orelse return false;
    const saved_ns = env.getCurrentNs();
    _ = helpers.loadFileContentWithPath(allocator, content, path) catch |e| {
        // エラー時は NS を復元
        if (saved_ns) |ns| env.setCurrentNs(ns);
        // デバッグ: エラーを stderr に出力
        var buf: [256]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&buf);
        const stderr = &stderr_writer.interface;
        stderr.print("[load-error] {s}: {any}\n", .{ path, e }) catch {};
        stderr.flush() catch {};
        return false;
    };
    // NS を復元（require 元の NS に戻す）
    if (saved_ns) |ns| env.setCurrentNs(ns);
    return true;
}

/// use — require + refer :all 相当
/// (use 'ns-name)
/// (use '[ns-name :only [sym1 sym2]])
pub fn useFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    const env = defs.current_env orelse return error.TypeError;
    const current_ns = env.getCurrentNs() orelse return error.TypeError;

    for (args) |arg| {
        switch (arg) {
            .symbol => |s| {
                // (use 'ns-name) — NS をロード + 全 Var を refer
                requireNsLoad(allocator, s.name, false) catch {};
                const target_ns = env.findOrCreateNs(s.name) catch continue;
                var all_iter = target_ns.getAllVars();
                while (all_iter.next()) |entry| {
                    current_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
                }
            },
            .vector => |v| {
                // (use '[ns-name :only [...]])
                if (v.items.len < 1) continue;
                const ns_sym_name = nsArgName(v.items[0]) orelse continue;
                requireNsLoad(allocator, ns_sym_name, false) catch {};
                const target_ns = env.findOrCreateNs(ns_sym_name) catch continue;

                // :only フィルタ解析
                var only_list: ?[]const Value = null;
                var vi: usize = 1;
                while (vi + 1 < v.items.len) : (vi += 2) {
                    if (v.items[vi] == .keyword) {
                        if (std.mem.eql(u8, v.items[vi].keyword.name, "only")) {
                            if (v.items[vi + 1] == .vector) {
                                only_list = v.items[vi + 1].vector.items;
                            }
                        }
                    }
                }

                var all_iter = target_ns.getAllVars();
                while (all_iter.next()) |entry| {
                    if (only_list) |only| {
                        if (!containsSymName(only, entry.key_ptr.*)) continue;
                    }
                    current_ns.refer(entry.key_ptr.*, entry.value_ptr.*) catch {};
                }
            },
            else => {},
        }
    }
    return value_mod.nil;
}

/// alias — 名前空間エイリアスを設定
/// (alias alias-sym ns-sym)
pub fn aliasFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const env = defs.current_env orelse return error.TypeError;
    const current_ns = env.getCurrentNs() orelse return error.TypeError;
    const alias_name = nsArgName(args[0]) orelse return error.TypeError;
    const target_name = nsArgName(args[1]) orelse return error.TypeError;
    const target_ns = env.findNs(target_name) orelse return error.TypeError;
    current_ns.setAlias(alias_name, target_ns) catch return error.EvalError;
    return value_mod.nil;
}

/// in-ns — 名前空間を切り替え
/// (in-ns 'ns-name) — NS を作成/取得して current_ns を設定
pub fn inNsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const ns_name = nsArgName(args[0]) orelse return error.TypeError;
    const env = defs.current_env orelse return error.TypeError;
    const ns = env.findOrCreateNs(ns_name) catch return error.EvalError;
    // 現在の NS を切り替え
    env.setCurrentNs(ns);
    // シンボルとして返す
    const sym = try allocator.create(value_mod.Symbol);
    sym.* = .{ .name = ns_name, .namespace = null };
    return Value{ .symbol = sym };
}

// === refer/use ヘルパー ===

/// シンボル名がリストに含まれるか
fn containsSymName(items: []const Value, name: []const u8) bool {
    for (items) |item| {
        if (nsArgName(item)) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
    }
    return false;
}

/// rename マップから対応する新名前を取得
fn findRename(entries: []const Value, name: []const u8) ?[]const u8 {
    var ri: usize = 0;
    while (ri + 1 < entries.len) : (ri += 2) {
        if (nsArgName(entries[ri])) |key| {
            if (std.mem.eql(u8, key, name)) {
                return nsArgName(entries[ri + 1]);
            }
        }
    }
    return null;
}

// --- Chunk stubs ---

/// chunk-buffer — スタブ: 空ベクターを返す
pub fn chunkBufferFn(allocator: std.mem.Allocator, _: []const Value) anyerror!Value {
    const vec = try allocator.create(value_mod.PersistentVector);
    vec.* = .{ .items = &[_]Value{} };
    return Value{ .vector = vec };
}

/// chunk-append — スタブ: nil
pub fn chunkAppendFn(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    return value_mod.nil;
}

/// chunk — スタブ: 引数をそのまま返す
pub fn chunkFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    return args[0];
}

/// chunk-cons — cons のエイリアス
pub fn chunkConsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    return collections.cons(allocator, args);
}

/// chunk-first — first のエイリアス
pub fn chunkFirstFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    return collections.first(allocator, args);
}

/// chunk-next — next のエイリアス
pub fn chunkNextFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    return collections.next(allocator, args);
}

/// chunk-rest — rest のエイリアス
pub fn chunkRestFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    return collections.rest(allocator, args);
}

/// chunked-seq? — スタブ: false
pub fn chunkedSeqPred(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    return value_mod.false_val;
}

// ============================================================
// builtins 配列
// ============================================================

pub const builtins = [_]BuiltinDef{
    // NS 操作
    .{ .name = "find-ns", .func = findNsFn },
    .{ .name = "create-ns", .func = createNsFn },
    .{ .name = "all-ns", .func = allNsFn },
    .{ .name = "ns-name", .func = nsNameFn },
    .{ .name = "ns-publics", .func = nsPublicsFn },
    .{ .name = "ns-interns", .func = nsInternsFn },
    .{ .name = "ns-map", .func = nsMapFn },
    .{ .name = "ns-refers", .func = nsRefersFn },
    .{ .name = "ns-imports", .func = nsImportsFn },
    .{ .name = "ns-aliases", .func = nsAliasesFn },
    .{ .name = "ns-resolve", .func = nsResolveFn },
    .{ .name = "ns-unmap", .func = nsUnmapFn },
    .{ .name = "ns-unalias", .func = nsUnaliasFn },
    .{ .name = "remove-ns", .func = removeNsFn },
    // Reader / ユーティリティ
    .{ .name = "read", .func = readFn },
    .{ .name = "read+string", .func = readPlusStringFn },
    .{ .name = "reader-conditional", .func = readerConditionalFn },
    .{ .name = "loaded-libs", .func = loadedLibsFn },
    .{ .name = "default-data-readers", .func = defaultDataReadersFn },
    .{ .name = "print-ctor", .func = printCtorFn },
    .{ .name = "PrintWriter-on", .func = printWriterOnFn },
    .{ .name = "compile", .func = compileFn },
    .{ .name = "load-reader", .func = loadReaderFn },
    .{ .name = "load-file", .func = loadFileFn },
    .{ .name = "load", .func = loadFileFn },
    // Phase 20: binding/threading stubs
    .{ .name = "set!", .func = setBangFn },
    .{ .name = "get-thread-bindings", .func = getThreadBindingsFn },
    .{ .name = "push-thread-bindings", .func = pushThreadBindingsFn },
    .{ .name = "pop-thread-bindings", .func = popThreadBindingsFn },
    .{ .name = "thread-bound?", .func = threadBoundPred },
    .{ .name = "with-redefs-fn", .func = withRedefsFnFn },
    .{ .name = "requiring-resolve", .func = requiringResolveFn },
    // Phase 20: NS
    .{ .name = "refer", .func = referFn },
    .{ .name = "require", .func = requireFn },
    .{ .name = "use", .func = useFn },
    .{ .name = "alias", .func = aliasFn },
    .{ .name = "in-ns", .func = inNsFn },
    // Phase 20: chunk stubs
    .{ .name = "chunk-buffer", .func = chunkBufferFn },
    .{ .name = "chunk-append", .func = chunkAppendFn },
    .{ .name = "chunk", .func = chunkFn },
    .{ .name = "chunk-cons", .func = chunkConsFn },
    .{ .name = "chunk-first", .func = chunkFirstFn },
    .{ .name = "chunk-next", .func = chunkNextFn },
    .{ .name = "chunk-rest", .func = chunkRestFn },
    .{ .name = "chunked-seq?", .func = chunkedSeqPred },
};
