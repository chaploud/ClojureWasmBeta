//! eval・read-string・sorted コレクション
//!
//! eval, read-string, load-string, macroexpand, sorted-map, sorted-set, resolve

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const Reader = defs.Reader;
const Analyzer = defs.Analyzer;
const tree_walk = defs.tree_walk;
const Context = defs.Context;
const Env = defs.Env;
const BuiltinDef = defs.BuiltinDef;

const helpers = @import("helpers.zig");
const collections = @import("collections.zig");
const strings = @import("strings.zig");

// ============================================================
// struct 操作
// ============================================================

/// destructure : 分配束縛マクロのヘルパー（簡易: そのまま返す）
pub fn destructureFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return args[0]; // 簡易実装
}

/// seq-to-map-for-destructuring : シーケンスをマップに変換（分配束縛用）
pub fn seqToMapFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] == .map) return args[0];
    // シーケンスをキー・値ペアとして解釈
    const items = try helpers.collectToSlice(allocator, args[0]);
    if (items.len % 2 != 0) return error.TypeError;
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = items };
    return Value{ .map = m };
}

/// xml-seq : XML ノード（マップ）をシーケンスとして走査（簡易版）
/// ツリーのフラット化: ノード自身 + 子ノードを再帰的に列挙
pub fn xmlSeqFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    // 入力がマップでなければそのままリストで返す
    if (args[0] != .map) {
        const items = try allocator.alloc(Value, 1);
        items[0] = args[0];
        const l = try allocator.create(value_mod.PersistentList);
        l.* = .{ .items = items };
        return Value{ .list = l };
    }
    // マップの :content を再帰的に展開
    var result = std.ArrayList(Value).empty;
    defer result.deinit(allocator);
    try result.append(allocator, args[0]);
    // :content キーの子要素をフラット化
    const content_kw = value_mod.Keyword.init("content");
    var i: usize = 0;
    while (i + 1 < args[0].map.entries.len) : (i += 2) {
        if (args[0].map.entries[i] == .keyword) {
            if (args[0].map.entries[i].keyword.eql(content_kw)) {
                const content = args[0].map.entries[i + 1];
                if (content == .vector) {
                    for (content.vector.items) |child| {
                        if (child == .map) {
                            const child_seq = try xmlSeqFn(allocator, &[_]Value{child});
                            if (child_seq == .list) {
                                try result.appendSlice(allocator, child_seq.list.items);
                            }
                        } else {
                            try result.append(allocator, child);
                        }
                    }
                }
            }
        }
    }
    const items = try allocator.alloc(Value, result.items.len);
    @memcpy(items, result.items);
    const l = try allocator.create(value_mod.PersistentList);
    l.* = .{ .items = items };
    return Value{ .list = l };
}

/// the-ns : 名前空間オブジェクトを返す（簡易: シンボル名を返す）
pub fn theNsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return args[0]; // 簡易実装: 名前空間オブジェクトの代わりにシンボルを返す
}

/// accessor : struct のフィールドアクセス関数を返す
pub fn accessorFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    // (accessor s key) → キーワードを返す（キーワードは関数として使える）
    // Clojure: (accessor s :name) → (fn [m] (:name m))
    // 簡易実装: キーワードはすでに関数として呼べるのでそのまま返す
    return args[1];
}

/// create-struct : 構造体定義を作成（簡易: キーのベクターを返す）
pub fn createStructFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // (create-struct & keys) → struct 定義（簡易版: キーのベクターを返す）
    if (args.len < 1) return error.ArityError;
    const key_items = try allocator.alloc(Value, args.len);
    @memcpy(key_items, args);
    const vec = try allocator.create(value_mod.PersistentVector);
    vec.* = .{ .items = key_items };
    return Value{ .vector = vec };
}

/// struct : struct 定義からインスタンスを作成（簡易: マップを返す）
pub fn structFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // (struct s & vals) → {:key1 val1 :key2 val2 ...}
    if (args.len < 1) return error.ArityError;
    if (args[0] != .vector) return error.TypeError;
    const struct_keys = args[0].vector.items;
    const struct_vals = args[1..];
    if (struct_keys.len != struct_vals.len) return error.ArityError;
    const entries = try allocator.alloc(Value, struct_keys.len * 2);
    for (struct_keys, 0..) |key, idx| {
        entries[idx * 2] = key;
        entries[idx * 2 + 1] = if (idx < struct_vals.len) struct_vals[idx] else value_mod.nil;
    }
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

/// struct-map : struct 定義からキーワード引数でインスタンスを作成
pub fn structMapFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // (struct-map s & keyvals)
    if (args.len < 1) return error.ArityError;
    if (args[0] != .vector) return error.TypeError;
    // キーワード引数をそのままマップにする
    const kvs = args[1..];
    if (kvs.len % 2 != 0) return error.ArityError;
    const entries = try allocator.alloc(Value, kvs.len);
    @memcpy(entries, kvs);
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

// ============================================================
// eval / read-string / macroexpand / load-string
// ============================================================

/// read-string : 文字列をパースしてデータ構造を返す
pub fn readStringFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const source = args[0].string.data;

    // Reader でパース
    var reader = Reader.init(allocator, source);
    const form = reader.read() catch return error.EvalError;
    if (form) |f| {
        // Analyzer の formToValue でデータ構造に変換
        const env = defs.current_env orelse return error.TypeError;
        var analyzer = Analyzer.init(allocator, env);
        return analyzer.formToValue(f) catch return error.EvalError;
    }
    return value_mod.nil;
}

/// eval : Value（データ構造）を評価する
pub fn evalFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const env = defs.current_env orelse return error.TypeError;

    // Value → Form に変換
    var analyzer = Analyzer.init(allocator, env);
    const form = analyzer.valueToForm(args[0]) catch return error.EvalError;

    // Form → Node に変換
    const node = analyzer.analyze(form) catch return error.EvalError;

    // Node を TreeWalk で評価
    var ctx = Context.init(allocator, env);
    return tree_walk.run(node, &ctx) catch return error.EvalError;
}

/// load-string : 文字列を複数式として読み込み・評価
pub fn loadStringFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const source = args[0].string.data;
    const env = defs.current_env orelse return error.TypeError;

    // 全式を読み込み
    var reader = Reader.init(allocator, source);
    const forms = reader.readAll() catch return error.EvalError;

    var result: Value = value_mod.nil;
    for (forms) |form| {
        var analyzer = Analyzer.init(allocator, env);
        const node = analyzer.analyze(form) catch return error.EvalError;
        var ctx = Context.init(allocator, env);
        result = tree_walk.run(node, &ctx) catch return error.EvalError;
    }
    return result;
}

/// macroexpand-1 : マクロを1段展開（簡易実装: データをそのまま返す）
pub fn macroexpand1Fn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    // マクロ展開は Analyzer 内部で行われるため、
    // ビルトイン関数からは直接アクセスが困難。
    // 簡易実装: フォームをそのまま返す
    return args[0];
}

/// macroexpand : マクロを完全展開（簡易実装: データをそのまま返す）
pub fn macroexpandFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return args[0];
}

/// resolve : シンボルを環境から解決
pub fn resolveFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
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

// ============================================================
// sorted-map / sorted-set（簡易実装: ソートされた通常コレクション）
// ============================================================

/// sorted-map : ソートされたマップ（簡易: 通常マップを返す）
pub fn sortedMapFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len % 2 != 0) return error.ArityError;
    const entries = try allocator.alloc(Value, args.len);
    @memcpy(entries, args);
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

/// sorted-map-by : コンパレータ付きソートマップ（簡易: 通常マップ、コンパレータ無視）
pub fn sortedMapByFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    // 最初の引数はコンパレータ（無視）、残りがキーバリューペア
    const kvs = args[1..];
    if (kvs.len % 2 != 0) return error.ArityError;
    const entries = try allocator.alloc(Value, kvs.len);
    @memcpy(entries, kvs);
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

/// sorted-set : ソートされたセット（簡易: 通常セットを返す）
pub fn sortedSetFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    const items = try allocator.alloc(Value, args.len);
    @memcpy(items, args);
    const s = try allocator.create(value_mod.PersistentSet);
    s.* = .{ .items = items };
    return Value{ .set = s };
}

/// sorted-set-by : コンパレータ付きソートセット（簡易: 通常セット、コンパレータ無視）
pub fn sortedSetByFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    const set_vals = args[1..];
    const items = try allocator.alloc(Value, set_vals.len);
    @memcpy(items, set_vals);
    const s = try allocator.create(value_mod.PersistentSet);
    s.* = .{ .items = items };
    return Value{ .set = s };
}

/// subseq : ソートコレクションの部分列（簡易: filter相当）
pub fn subseqFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // (subseq sc test key) or (subseq sc start-test start-key end-test end-key)
    if (args.len < 3) return error.ArityError;
    // 簡易実装: コレクションをseqとしてそのまま返す
    return collections.seq(allocator, args[0..1]);
}

/// rsubseq : 逆順部分列（簡易: reverse + subseq相当）
pub fn rsubseqFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 3) return error.ArityError;
    // 簡易実装: コレクションをseqとしてreverse
    const seq_val = try collections.seq(allocator, args[0..1]);
    return collections.reverseFn(allocator, &[_]Value{seq_val});
}

// ============================================================
// 動的 Var スタブ
// ============================================================

/// *clojure-version* の値を返す
pub fn clojureVersionFn(allocator: std.mem.Allocator, _: []const Value) anyerror!Value {
    // {:major 1 :minor 12 :incremental 0 :qualifier nil}
    const entries = try allocator.alloc(Value, 8);
    const mkKw = struct {
        fn f(alloc: std.mem.Allocator, name: []const u8) !Value {
            const kw = try alloc.create(value_mod.Keyword);
            kw.* = value_mod.Keyword.init(name);
            return Value{ .keyword = kw };
        }
    }.f;
    entries[0] = try mkKw(allocator, "major");
    entries[1] = value_mod.intVal(1);
    entries[2] = try mkKw(allocator, "minor");
    entries[3] = value_mod.intVal(12);
    entries[4] = try mkKw(allocator, "incremental");
    entries[5] = value_mod.intVal(0);
    entries[6] = try mkKw(allocator, "qualifier");
    entries[7] = value_mod.nil;
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

// ============================================================
// builtins
// ============================================================

pub const builtins = [_]BuiltinDef{
    // struct 操作
    .{ .name = "destructure", .func = destructureFn },
    .{ .name = "seq-to-map-for-destructuring", .func = seqToMapFn },
    .{ .name = "xml-seq", .func = xmlSeqFn },
    .{ .name = "the-ns", .func = theNsFn },
    .{ .name = "accessor", .func = accessorFn },
    .{ .name = "create-struct", .func = createStructFn },
    .{ .name = "struct", .func = structFn },
    .{ .name = "struct-map", .func = structMapFn },
    // eval / read-string / macroexpand
    .{ .name = "read-string", .func = readStringFn },
    .{ .name = "eval", .func = evalFn },
    .{ .name = "load-string", .func = loadStringFn },
    .{ .name = "macroexpand-1", .func = macroexpand1Fn },
    .{ .name = "macroexpand", .func = macroexpandFn },
    .{ .name = "resolve", .func = resolveFn },
    // sorted コレクション
    .{ .name = "sorted-map", .func = sortedMapFn },
    .{ .name = "sorted-map-by", .func = sortedMapByFn },
    .{ .name = "sorted-set", .func = sortedSetFn },
    .{ .name = "sorted-set-by", .func = sortedSetByFn },
    .{ .name = "subseq", .func = subseqFn },
    .{ .name = "rsubseq", .func = rsubseqFn },
};
