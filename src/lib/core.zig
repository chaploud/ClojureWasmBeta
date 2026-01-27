//! clojure.core 組み込み関数
//!
//! Clojure標準ライブラリの中核関数群。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md

const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const Fn = value_mod.Fn;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const var_mod = @import("../runtime/var.zig");
const Var = var_mod.Var;
const namespace_mod = @import("../runtime/namespace.zig");
const Namespace = namespace_mod.Namespace;
const Reader = @import("../reader/reader.zig").Reader;
const Analyzer = @import("../analyzer/analyze.zig").Analyzer;
const tree_walk = @import("../runtime/evaluator.zig");
const Context = @import("../runtime/context.zig").Context;
const regex_mod = @import("../regex/regex.zig");
const regex_matcher = @import("../regex/matcher.zig");

/// 組み込み関数の型（value.zig との循環依存を避けるためここで定義）
pub const BuiltinFn = *const fn (allocator: std.mem.Allocator, args: []const Value) anyerror!Value;

/// LazySeq force コールバック型
/// 引数なし fn を呼び出して結果を返す。evaluator/VM がそれぞれ設定する。
pub const ForceFn = *const fn (fn_val: Value, allocator: std.mem.Allocator) anyerror!Value;
pub const CallFn = *const fn (fn_val: Value, args: []const Value, allocator: std.mem.Allocator) anyerror!Value;

/// 現在の force コールバック（threadlocal）
/// evaluator/VM が builtin 呼び出し前に設定する
pub threadlocal var force_lazy_seq_fn: ?ForceFn = null;
/// 関数呼び出しコールバック（lazy map/filter 用）
pub threadlocal var call_fn: ?CallFn = null;
/// 現在の Env（find-var, intern 等で使用）
pub threadlocal var current_env: ?*Env = null;

/// ロード済みライブラリ管理
const LoadedLibsSet = std.StringHashMapUnmanaged(void);
var loaded_libs: LoadedLibsSet = .empty;
/// ロード済みライブラリ用アロケータ（persistent メモリ）
var loaded_libs_allocator: ?std.mem.Allocator = null;

/// ロード済みライブラリの初期化
pub fn initLoadedLibs(allocator: std.mem.Allocator) void {
    loaded_libs_allocator = allocator;
}

/// クラスパスルート（ファイルロード時の基準ディレクトリ）
var classpath_roots: [16]?[]const u8 = .{null} ** 16;
var classpath_count: usize = 0;

/// クラスパスルートを追加
pub fn addClasspathRoot(path: []const u8) void {
    if (classpath_count < classpath_roots.len) {
        classpath_roots[classpath_count] = path;
        classpath_count += 1;
    }
}

/// NS名からファイルパスに変換 (例: "my.lib.core" + ".clj" → "my/lib/core.clj")
fn nsNameToPath(allocator: std.mem.Allocator, ns_name: []const u8, ext: []const u8) ![]const u8 {
    // ドットをスラッシュに、ハイフンをアンダースコアに変換
    var path = try allocator.alloc(u8, ns_name.len + ext.len);
    var pi: usize = 0;
    for (ns_name) |c| {
        path[pi] = switch (c) {
            '.' => '/',
            '-' => '_',
            else => c,
        };
        pi += 1;
    }
    @memcpy(path[pi..][0..ext.len], ext);
    return path[0 .. pi + ext.len];
}

/// ファイルをロードして評価する
fn loadFileContent(allocator: std.mem.Allocator, content: []const u8) anyerror!Value {
    const env = current_env orelse return error.TypeError;
    var reader = Reader.init(allocator, content);
    const forms = reader.readAll() catch |e| {
        // 現在のリーダー位置を取得
        const pos = reader.tokenizer.pos;
        const line = reader.tokenizer.line;
        debugLog("[reader-error] line {d} pos {d}: {any}", .{ line, pos, e });
        return error.EvalError;
    };
    var result: Value = value_mod.nil;
    for (forms, 0..) |form, fi| {
        var analyzer = Analyzer.init(allocator, env);
        const node = analyzer.analyze(form) catch |e| {
            debugLog("[analyze-error] form #{d}: {any}", .{ fi, e });
            return error.EvalError;
        };
        var ctx = Context.init(allocator, env);
        result = tree_walk.run(node, &ctx) catch |e| {
            debugLog("[eval-error] form #{d}: {any}", .{ fi, e });
            return error.EvalError;
        };
    }
    return result;
}

/// デバッグログ出力（stderr）
fn debugLog(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    const stderr = &writer.interface;
    stderr.print(fmt ++ "\n", args) catch {};
    stderr.flush() catch {};
}

/// LazySeq を実体化する（force）
/// サンク関数を呼び出し、結果を cached realized に格納して返す
/// LazySeq を一段だけ force する（サンク → cons形式 or 具体値に変換）
/// cons 形式の場合はそのまま返す（tail は force しない）
pub fn forceLazySeqOneStep(allocator: std.mem.Allocator, ls: *value_mod.LazySeq) anyerror!void {
    // 既に実体化済み or cons形式
    if (ls.realized != null or ls.cons_head != null) return;

    // 遅延変換（lazy map/filter）の場合
    if (ls.transform) |t| {
        try forceTransformOneStep(allocator, ls, t);
        return;
    }

    // 遅延 concat の場合
    if (ls.concat_sources) |sources| {
        try forceConcatOneStep(allocator, ls, sources);
        return;
    }

    // ジェネレータの場合
    if (ls.generator) |g| {
        try forceGeneratorOneStep(allocator, ls, g);
        return;
    }

    // サンク形式の場合: body_fn を呼んで結果を取得
    const body_fn = ls.body_fn orelse {
        // body_fn も cons_head もない → 空
        ls.realized = value_mod.nil;
        return;
    };
    const force_fn = force_lazy_seq_fn orelse return error.TypeError;
    const result = try force_fn(body_fn, allocator);
    ls.body_fn = null; // サンクを解放

    // 結果が lazy-seq の場合、その内容を引き継ぐ
    if (result == .lazy_seq) {
        const inner = result.lazy_seq;
        ls.body_fn = inner.body_fn;
        ls.realized = inner.realized;
        ls.cons_head = inner.cons_head;
        ls.cons_tail = inner.cons_tail;
        ls.transform = inner.transform;
        ls.concat_sources = inner.concat_sources;
        ls.generator = inner.generator;
        // 再帰的に一段 force（内側もサンク形式かもしれない）
        return forceLazySeqOneStep(allocator, ls);
    }

    // 具体値（nil, list, vector）の場合
    ls.realized = result;
}

/// 遅延変換（lazy map/filter）を一段 force する
fn forceTransformOneStep(
    allocator: std.mem.Allocator,
    ls: *value_mod.LazySeq,
    t: value_mod.LazySeq.Transform,
) anyerror!void {
    const call = call_fn orelse return error.TypeError;

    switch (t.kind) {
        .map => {
            // source の first を取得
            const src_first = try seqFirst(allocator, t.source);
            if (src_first == .nil) {
                // source が空 → 結果も空
                ls.transform = null;
                ls.realized = value_mod.nil;
                return;
            }
            // f(first) を計算
            const mapped = try call(t.fn_val, &[_]Value{src_first}, allocator);
            // rest(source) を取得
            const src_rest = try seqRest(allocator, t.source);
            // cons(mapped, lazy-map(f, rest))
            ls.transform = null;
            ls.cons_head = mapped;
            // tail: empty なら nil、そうでなければ lazy-map
            if (isSeqEmpty(src_rest)) {
                ls.cons_tail = value_mod.nil;
            } else {
                const tail_ls = try allocator.create(value_mod.LazySeq);
                tail_ls.* = value_mod.LazySeq.initTransform(.map, t.fn_val, src_rest);
                ls.cons_tail = Value{ .lazy_seq = tail_ls };
            }
        },
        .filter => {
            // source を走査して pred が真の要素を見つける
            var current = t.source;
            while (true) {
                const elem = try seqFirst(allocator, current);
                if (elem == .nil) {
                    // source を使い切った → 結果も空
                    ls.transform = null;
                    ls.realized = value_mod.nil;
                    return;
                }
                // pred(elem)
                const pred_result = try call(t.fn_val, &[_]Value{elem}, allocator);
                const rest_val = try seqRest(allocator, current);
                if (pred_result.isTruthy()) {
                    // マッチ → cons(elem, lazy-filter(pred, rest))
                    ls.transform = null;
                    ls.cons_head = elem;
                    if (isSeqEmpty(rest_val)) {
                        ls.cons_tail = value_mod.nil;
                    } else {
                        const tail_ls = try allocator.create(value_mod.LazySeq);
                        tail_ls.* = value_mod.LazySeq.initTransform(.filter, t.fn_val, rest_val);
                        ls.cons_tail = Value{ .lazy_seq = tail_ls };
                    }
                    return;
                }
                // マッチしない → 次の要素へ
                current = rest_val;
            }
        },
        .mapcat => {
            // source を走査して非空のサブコレクションを見つける
            var current = t.source;
            while (true) {
                const src_elem = try seqFirst(allocator, current);
                if (src_elem == .nil) {
                    // source 終了 → 空
                    ls.transform = null;
                    ls.realized = value_mod.nil;
                    return;
                }
                // f(elem) → サブコレクション
                const sub_coll = try call(t.fn_val, &[_]Value{src_elem}, allocator);
                const src_rest = try seqRest(allocator, current);

                // サブコレクションの first を取得
                const sub_first = try seqFirst(allocator, sub_coll);
                if (sub_first == .nil) {
                    // サブコレクションが空 → 次の要素へスキップ
                    current = src_rest;
                    continue;
                }

                // cons(sub_first, concat(rest(sub_coll), lazy-mapcat(f, rest(source))))
                ls.transform = null;
                ls.cons_head = sub_first;

                const sub_rest = try seqRest(allocator, sub_coll);
                if (isSeqEmpty(src_rest)) {
                    // source の残りがない → tail は rest(sub_coll)
                    ls.cons_tail = if (isSeqEmpty(sub_rest)) value_mod.nil else sub_rest;
                } else if (isSeqEmpty(sub_rest)) {
                    // サブコレクションの残りがない → tail は lazy-mapcat(f, rest(source))
                    const tail_ls = try allocator.create(value_mod.LazySeq);
                    tail_ls.* = value_mod.LazySeq.initTransform(.mapcat, t.fn_val, src_rest);
                    ls.cons_tail = Value{ .lazy_seq = tail_ls };
                } else {
                    // 両方ある → concat(rest(sub_coll), lazy-mapcat(f, rest(source)))
                    const mapcat_tail = try allocator.create(value_mod.LazySeq);
                    mapcat_tail.* = value_mod.LazySeq.initTransform(.mapcat, t.fn_val, src_rest);
                    const sources = try allocator.alloc(Value, 2);
                    sources[0] = sub_rest;
                    sources[1] = Value{ .lazy_seq = mapcat_tail };
                    const concat_ls = try allocator.create(value_mod.LazySeq);
                    concat_ls.* = value_mod.LazySeq.initConcat(sources);
                    ls.cons_tail = Value{ .lazy_seq = concat_ls };
                }
                return;
            }
        },
    }
}

/// 遅延 concat を一段 force する
/// sources 配列の先頭コレクションから要素を取り出し、cons 形式にする
fn forceConcatOneStep(
    allocator: std.mem.Allocator,
    ls: *value_mod.LazySeq,
    sources: []const Value,
) anyerror!void {
    // 空でない source を探す
    var idx: usize = 0;
    while (idx < sources.len) {
        const src = sources[idx];
        // source が nil/空リスト/空ベクターなら次へ
        if (isSeqEmpty(src)) {
            idx += 1;
            continue;
        }
        // lazy-seq の場合: first を取ってみる
        const elem = try seqFirst(allocator, src);
        if (elem == .nil and src == .lazy_seq) {
            // lazy-seq を force したら空だった
            idx += 1;
            continue;
        }
        if (elem == .nil) {
            idx += 1;
            continue;
        }
        // 要素が見つかった: cons(elem, lazy-concat(rest(src), remaining_sources))
        const src_rest = try seqRest(allocator, src);
        ls.concat_sources = null;
        ls.cons_head = elem;

        // 残り: rest(current_source) + remaining_sources
        const remaining_count = sources.len - idx - 1;
        if (isSeqEmpty(src_rest) and remaining_count == 0) {
            // 残りなし
            ls.cons_tail = value_mod.nil;
        } else {
            // 新しい sources 配列を作成: [rest(src)] ++ sources[idx+1..]
            var new_sources_count: usize = 0;
            if (!isSeqEmpty(src_rest)) new_sources_count += 1;
            new_sources_count += remaining_count;

            if (new_sources_count == 0) {
                ls.cons_tail = value_mod.nil;
            } else {
                const new_sources = try allocator.alloc(Value, new_sources_count);
                var j: usize = 0;
                if (!isSeqEmpty(src_rest)) {
                    new_sources[j] = src_rest;
                    j += 1;
                }
                if (remaining_count > 0) {
                    @memcpy(new_sources[j..], sources[idx + 1 ..]);
                }
                const tail_ls = try allocator.create(value_mod.LazySeq);
                tail_ls.* = value_mod.LazySeq.initConcat(new_sources);
                ls.cons_tail = Value{ .lazy_seq = tail_ls };
            }
        }
        return;
    }

    // 全ての source が空 → 結果も空
    ls.concat_sources = null;
    ls.realized = value_mod.nil;
}

/// ジェネレータを一段 force する
fn forceGeneratorOneStep(
    allocator: std.mem.Allocator,
    ls: *value_mod.LazySeq,
    g: value_mod.LazySeq.Generator,
) anyerror!void {
    switch (g.kind) {
        .iterate => {
            // cons(current, lazy-iterate(f, f(current)))
            const f = g.fn_val orelse return error.TypeError;
            const call = call_fn orelse return error.TypeError;
            const next_val = try call(f, &[_]Value{g.current}, allocator);
            ls.generator = null;
            ls.cons_head = g.current;
            const tail_ls = try allocator.create(value_mod.LazySeq);
            tail_ls.* = value_mod.LazySeq.initIterate(f, next_val);
            ls.cons_tail = Value{ .lazy_seq = tail_ls };
        },
        .repeat_infinite => {
            // cons(current, lazy-repeat(current))
            ls.generator = null;
            ls.cons_head = g.current;
            const tail_ls = try allocator.create(value_mod.LazySeq);
            tail_ls.* = value_mod.LazySeq.initRepeatInfinite(g.current);
            ls.cons_tail = Value{ .lazy_seq = tail_ls };
        },
        .cycle => {
            // cons(source[idx], lazy-cycle(source, (idx+1) % len))
            const source = g.source orelse return error.TypeError;
            if (source.len == 0) {
                ls.generator = null;
                ls.realized = value_mod.nil;
                return;
            }
            const idx = g.source_idx % source.len;
            ls.generator = null;
            ls.cons_head = source[idx];
            const tail_ls = try allocator.create(value_mod.LazySeq);
            tail_ls.* = value_mod.LazySeq.initCycle(source, idx + 1);
            ls.cons_tail = Value{ .lazy_seq = tail_ls };
        },
        .range_infinite => {
            // cons(current, lazy-range(current + 1))
            const n = g.current.int;
            ls.generator = null;
            ls.cons_head = g.current;
            const tail_ls = try allocator.create(value_mod.LazySeq);
            tail_ls.* = value_mod.LazySeq.initRangeInfinite(value_mod.intVal(n + 1));
            ls.cons_tail = Value{ .lazy_seq = tail_ls };
        },
    }
}

/// シーケンスの first を取得（lazy-seq/list/vector/nil 対応）
fn seqFirst(allocator: std.mem.Allocator, val: Value) anyerror!Value {
    return switch (val) {
        .lazy_seq => |ls| lazyFirst(allocator, ls),
        .list => |l| if (l.items.len > 0) l.items[0] else value_mod.nil,
        .vector => |v| if (v.items.len > 0) v.items[0] else value_mod.nil,
        .nil => value_mod.nil,
        else => value_mod.nil,
    };
}

/// シーケンスの rest を取得（lazy-seq/list/vector/nil 対応）
fn seqRest(allocator: std.mem.Allocator, val: Value) anyerror!Value {
    return switch (val) {
        .lazy_seq => |ls| lazyRest(allocator, ls),
        .list => |l| {
            if (l.items.len <= 1) return Value{ .list = try value_mod.PersistentList.empty(allocator) };
            return Value{ .list = try value_mod.PersistentList.fromSlice(allocator, l.items[1..]) };
        },
        .vector => |v| {
            if (v.items.len <= 1) return Value{ .list = try value_mod.PersistentList.empty(allocator) };
            return Value{ .list = try value_mod.PersistentList.fromSlice(allocator, v.items[1..]) };
        },
        .nil => Value{ .list = try value_mod.PersistentList.empty(allocator) },
        else => Value{ .list = try value_mod.PersistentList.empty(allocator) },
    };
}

/// シーケンスが空かどうか
fn isSeqEmpty(val: Value) bool {
    return switch (val) {
        .nil => true,
        .list => |l| l.items.len == 0,
        .vector => |v| v.items.len == 0,
        else => false, // lazy-seq は空かわからない
    };
}

/// LazySeq の最初の要素を取得（全体を force しない）
pub fn lazyFirst(allocator: std.mem.Allocator, ls: *value_mod.LazySeq) anyerror!Value {
    try forceLazySeqOneStep(allocator, ls);

    // cons 形式
    if (ls.cons_head) |head| return head;

    // 具体値
    if (ls.realized) |r| {
        return switch (r) {
            .nil => value_mod.nil,
            .list => |l| if (l.items.len > 0) l.items[0] else value_mod.nil,
            .vector => |v| if (v.items.len > 0) v.items[0] else value_mod.nil,
            else => value_mod.nil,
        };
    }
    return value_mod.nil;
}

/// LazySeq の rest を取得（全体を force しない）
/// cons 形式の場合、tail をそのまま返す（lazy-seq のまま）
pub fn lazyRest(allocator: std.mem.Allocator, ls: *value_mod.LazySeq) anyerror!Value {
    try forceLazySeqOneStep(allocator, ls);

    // cons 形式: tail を返す
    if (ls.cons_tail) |tail| return tail;
    if (ls.cons_head != null) return value_mod.nil; // head のみ、tail なし

    // 具体値
    if (ls.realized) |r| {
        return switch (r) {
            .nil => Value{ .list = try value_mod.PersistentList.empty(allocator) },
            .list => |l| {
                if (l.items.len <= 1) return Value{ .list = try value_mod.PersistentList.empty(allocator) };
                return Value{ .list = try value_mod.PersistentList.fromSlice(allocator, l.items[1..]) };
            },
            .vector => |v| {
                if (v.items.len <= 1) return Value{ .list = try value_mod.PersistentList.empty(allocator) };
                return Value{ .list = try value_mod.PersistentList.fromSlice(allocator, v.items[1..]) };
            },
            else => Value{ .list = try value_mod.PersistentList.empty(allocator) },
        };
    }
    return Value{ .list = try value_mod.PersistentList.empty(allocator) };
}

/// LazySeq を完全に force する（有限のもののみ！無限シーケンスでは使用禁止）
pub fn forceLazySeq(allocator: std.mem.Allocator, ls: *value_mod.LazySeq) anyerror!Value {
    // 既に実体化済み（かつ cons 形式でない）
    if (ls.realized != null and ls.cons_head == null) return ls.realized.?;

    // 要素を一つずつ収集
    var items: std.ArrayListUnmanaged(Value) = .empty;
    var current: Value = Value{ .lazy_seq = ls };

    while (true) {
        if (current == .lazy_seq) {
            const cur_ls = current.lazy_seq;
            try forceLazySeqOneStep(allocator, cur_ls);

            if (cur_ls.cons_head) |head| {
                items.append(allocator, head) catch return error.OutOfMemory;
                current = cur_ls.cons_tail orelse value_mod.nil;
                continue;
            }

            if (cur_ls.realized) |r| {
                current = r;
                continue;
            }

            break; // 空
        }

        // 具体値（list, vector, nil）
        switch (current) {
            .nil => break,
            .list => |l| {
                for (l.items) |item| {
                    items.append(allocator, item) catch return error.OutOfMemory;
                }
                break;
            },
            .vector => |v| {
                for (v.items) |item| {
                    items.append(allocator, item) catch return error.OutOfMemory;
                }
                break;
            },
            else => break,
        }
    }

    const result_list = try allocator.create(value_mod.PersistentList);
    result_list.* = .{ .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
    const result = Value{ .list = result_list };

    // キャッシュ
    ls.realized = result;
    ls.cons_head = null;
    ls.cons_tail = null;
    ls.body_fn = null;
    return result;
}

/// Value が LazySeq なら実体化して返す、そうでなければそのまま返す
pub fn ensureRealized(allocator: std.mem.Allocator, val: Value) anyerror!Value {
    if (val == .lazy_seq) {
        return forceLazySeq(allocator, val.lazy_seq);
    }
    return val;
}

/// コレクション（list, vector, set, lazy_seq）の要素をスライスとして取得
/// 呼び出し側で allocator.free が必要
pub fn collectToSlice(allocator: std.mem.Allocator, val: Value) anyerror![]const Value {
    const realized = try ensureRealized(allocator, val);
    return switch (realized) {
        .list => |l| blk: {
            const result = try allocator.alloc(Value, l.items.len);
            @memcpy(result, l.items);
            break :blk result;
        },
        .vector => |v| blk: {
            const result = try allocator.alloc(Value, v.items.len);
            @memcpy(result, v.items);
            break :blk result;
        },
        .set => |s| blk: {
            const result = try allocator.alloc(Value, s.items.len);
            @memcpy(result, s.items);
            break :blk result;
        },
        .nil => try allocator.alloc(Value, 0),
        .string => |s| blk: {
            // 文字列は各文字をcharに変換
            var items = std.ArrayList(Value).empty;
            defer items.deinit(allocator);
            for (s.data) |c| {
                try items.append(allocator, Value{ .char_val = c });
            }
            break :blk try items.toOwnedSlice(allocator);
        },
        else => error.TypeError,
    };
}

/// 組み込み関数エラー
pub const CoreError = error{
    TypeError,
    ArityError,
    DivisionByZero,
    OutOfMemory,
};

// ============================================================
// 算術演算
// ============================================================

/// + : 可変長引数の加算
pub fn add(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    var result: i64 = 0;
    var has_float = false;
    var float_result: f64 = 0.0;

    for (args) |arg| {
        switch (arg) {
            .int => |n| {
                if (has_float) {
                    float_result += @as(f64, @floatFromInt(n));
                } else {
                    result += n;
                }
            },
            .float => |f| {
                if (!has_float) {
                    float_result = @as(f64, @floatFromInt(result));
                    has_float = true;
                }
                float_result += f;
            },
            else => return error.TypeError,
        }
    }

    if (has_float) {
        return Value{ .float = float_result };
    }
    return Value{ .int = result };
}

/// - : 減算
pub fn sub(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len == 0) return error.ArityError;

    var has_float = false;
    var result: i64 = 0;
    var float_result: f64 = 0.0;

    // 最初の引数
    switch (args[0]) {
        .int => |n| result = n,
        .float => |f| {
            float_result = f;
            has_float = true;
        },
        else => return error.TypeError,
    }

    // 単項マイナス
    if (args.len == 1) {
        if (has_float) {
            return Value{ .float = -float_result };
        }
        return Value{ .int = -result };
    }

    // 残りの引数を減算
    for (args[1..]) |arg| {
        switch (arg) {
            .int => |n| {
                if (has_float) {
                    float_result -= @as(f64, @floatFromInt(n));
                } else {
                    result -= n;
                }
            },
            .float => |f| {
                if (!has_float) {
                    float_result = @as(f64, @floatFromInt(result));
                    has_float = true;
                }
                float_result -= f;
            },
            else => return error.TypeError,
        }
    }

    if (has_float) {
        return Value{ .float = float_result };
    }
    return Value{ .int = result };
}

/// * : 乗算
pub fn mul(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    var result: i64 = 1;
    var has_float = false;
    var float_result: f64 = 1.0;

    for (args) |arg| {
        switch (arg) {
            .int => |n| {
                if (has_float) {
                    float_result *= @as(f64, @floatFromInt(n));
                } else {
                    result *= n;
                }
            },
            .float => |f| {
                if (!has_float) {
                    float_result = @as(f64, @floatFromInt(result));
                    has_float = true;
                }
                float_result *= f;
            },
            else => return error.TypeError,
        }
    }

    if (has_float) {
        return Value{ .float = float_result };
    }
    return Value{ .int = result };
}

/// / : 除算（常に float を返す）
pub fn div(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len == 0) return error.ArityError;

    // 最初の引数を取得
    var result: f64 = switch (args[0]) {
        .int => |n| @as(f64, @floatFromInt(n)),
        .float => |f| f,
        else => return error.TypeError,
    };

    // 単項 (/ x) は 1/x
    if (args.len == 1) {
        if (result == 0.0) return error.DivisionByZero;
        return Value{ .float = 1.0 / result };
    }

    // 残りの引数で除算
    for (args[1..]) |arg| {
        const divisor: f64 = switch (arg) {
            .int => |n| @as(f64, @floatFromInt(n)),
            .float => |f| f,
            else => return error.TypeError,
        };
        if (divisor == 0.0) return error.DivisionByZero;
        result /= divisor;
    }

    return Value{ .float = result };
}

/// inc : 1加算
pub fn inc(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .int => |n| Value{ .int = n + 1 },
        .float => |f| Value{ .float = f + 1.0 },
        else => error.TypeError,
    };
}

/// dec : 1減算
pub fn dec(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .int => |n| Value{ .int = n - 1 },
        .float => |f| Value{ .float = f - 1.0 },
        else => error.TypeError,
    };
}

// ============================================================
// 比較演算
// ============================================================

/// = : 等価比較
pub fn eq(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        // lazy-seq は実体化してから比較
        const ra = try ensureRealized(allocator, a);
        const rb = try ensureRealized(allocator, b);
        if (!ra.eql(rb)) {
            return value_mod.false_val;
        }
    }
    return value_mod.true_val;
}

/// < : 小なり
pub fn lt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) return error.ArityError;

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        const cmp = try compareNumbers(a, b);
        if (cmp >= 0) return value_mod.false_val;
    }
    return value_mod.true_val;
}

/// > : 大なり
pub fn gt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) return error.ArityError;

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        const cmp = try compareNumbers(a, b);
        if (cmp <= 0) return value_mod.false_val;
    }
    return value_mod.true_val;
}

/// <= : 小なりイコール
pub fn lte(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) return error.ArityError;

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        const cmp = try compareNumbers(a, b);
        if (cmp > 0) return value_mod.false_val;
    }
    return value_mod.true_val;
}

/// >= : 大なりイコール
pub fn gte(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) return error.ArityError;

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        const cmp = try compareNumbers(a, b);
        if (cmp < 0) return value_mod.false_val;
    }
    return value_mod.true_val;
}

/// 数値比較ヘルパー（-1, 0, 1 を返す）
fn compareNumbers(a: Value, b: Value) CoreError!i8 {
    const fa: f64 = switch (a) {
        .int => |n| @as(f64, @floatFromInt(n)),
        .float => |f| f,
        else => return error.TypeError,
    };
    const fb: f64 = switch (b) {
        .int => |n| @as(f64, @floatFromInt(n)),
        .float => |f| f,
        else => return error.TypeError,
    };

    if (fa < fb) return -1;
    if (fa > fb) return 1;
    return 0;
}

// ============================================================
// 論理演算
// ============================================================

/// not : 論理否定（nil と false が truthy でない）
pub fn notFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    // nil と false が falsy、それ以外は truthy
    return switch (args[0]) {
        .nil => value_mod.true_val,
        .bool_val => |b| if (b) value_mod.false_val else value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// not= : 等しくないかどうか
pub fn notEq(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    return if (args[0].eql(args[1])) value_mod.false_val else value_mod.true_val;
}

/// identity : 引数をそのまま返す
pub fn identity(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return args[0];
}

/// some? : nil でないかどうか
pub fn isSome(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0].isNil()) value_mod.false_val else value_mod.true_val;
}

/// zero? : 0 かどうか
pub fn isZero(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| if (n == 0) value_mod.true_val else value_mod.false_val,
        .float => |n| if (n == 0.0) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// pos? : 正数かどうか
pub fn isPos(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| if (n > 0) value_mod.true_val else value_mod.false_val,
        .float => |n| if (n > 0.0) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// neg? : 負数かどうか
pub fn isNeg(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| if (n < 0) value_mod.true_val else value_mod.false_val,
        .float => |n| if (n < 0.0) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// even? : 偶数かどうか
pub fn isEven(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| if (@mod(n, 2) == 0) value_mod.true_val else value_mod.false_val,
        else => error.TypeError,
    };
}

/// odd? : 奇数かどうか
pub fn isOdd(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| if (@mod(n, 2) != 0) value_mod.true_val else value_mod.false_val,
        else => error.TypeError,
    };
}

/// max : 最大値
pub fn max(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1) return error.ArityError;
    var result = args[0];
    for (args[1..]) |arg| {
        const is_less = switch (result) {
            .int => |a| switch (arg) {
                .int => |b| a < b,
                .float => |b| @as(f64, @floatFromInt(a)) < b,
                else => return error.TypeError,
            },
            .float => |a| switch (arg) {
                .int => |b| a < @as(f64, @floatFromInt(b)),
                .float => |b| a < b,
                else => return error.TypeError,
            },
            else => return error.TypeError,
        };
        if (is_less) result = arg;
    }
    return result;
}

/// min : 最小値
pub fn min(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1) return error.ArityError;
    var result = args[0];
    for (args[1..]) |arg| {
        const is_greater = switch (result) {
            .int => |a| switch (arg) {
                .int => |b| a > b,
                .float => |b| @as(f64, @floatFromInt(a)) > b,
                else => return error.TypeError,
            },
            .float => |a| switch (arg) {
                .int => |b| a > @as(f64, @floatFromInt(b)),
                .float => |b| a > b,
                else => return error.TypeError,
            },
            else => return error.TypeError,
        };
        if (is_greater) result = arg;
    }
    return result;
}

/// abs : 絶対値
pub fn abs(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| value_mod.intVal(if (n < 0) -n else n),
        .float => |n| value_mod.floatVal(@abs(n)),
        else => error.TypeError,
    };
}

/// mod : 剰余
pub fn modFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const a = args[0].int;
    const b = args[1].int;
    if (b == 0) return error.DivisionByZero;
    return value_mod.intVal(@mod(a, b));
}

// ============================================================
// 述語
// ============================================================

/// nil? : nil かどうか
pub fn isNil(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .nil => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// number? : 数値かどうか
pub fn isNumber(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .int, .float => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// integer? : 整数かどうか
pub fn isInteger(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .int => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// float? : 浮動小数点かどうか
pub fn isFloat(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .float => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// string? : 文字列かどうか
pub fn isString(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .string => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// keyword? : キーワードかどうか
pub fn isKeyword(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .keyword => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// symbol? : シンボルかどうか
pub fn isSymbol(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .symbol => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// fn? : 関数かどうか
pub fn isFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .fn_val => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// coll? : コレクションかどうか
pub fn isColl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .list, .vector, .map, .set => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// list? : リストかどうか
pub fn isList(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .list => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// vector? : ベクタかどうか
pub fn isVector(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .vector => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// map? : マップかどうか
pub fn isMap(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .map => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// set? : セットかどうか
pub fn isSet(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .set => value_mod.true_val,
        else => value_mod.false_val,
    };
}

// ============================================================
// コンストラクタ
// ============================================================

/// list : 引数からリストを作成
pub fn list(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    const items = allocator.alloc(Value, args.len) catch return error.OutOfMemory;
    @memcpy(items, args);

    const lst = allocator.create(value_mod.PersistentList) catch return error.OutOfMemory;
    lst.* = .{ .items = items };

    return Value{ .list = lst };
}

/// vector : 引数からベクタを作成
pub fn vector(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    const items = allocator.alloc(Value, args.len) catch return error.OutOfMemory;
    @memcpy(items, args);

    const vec = allocator.create(value_mod.PersistentVector) catch return error.OutOfMemory;
    vec.* = .{ .items = items };

    return Value{ .vector = vec };
}

// ============================================================
// コレクション操作
// ============================================================

/// first : コレクションの最初の要素
pub fn first(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    // lazy-seq の場合: 全体を force せず first だけ取得
    if (args[0] == .lazy_seq) {
        return lazyFirst(allocator, args[0].lazy_seq);
    }

    return switch (args[0]) {
        .nil => value_mod.nil,
        .list => |l| if (l.items.len > 0) l.items[0] else value_mod.nil,
        .vector => |v| if (v.items.len > 0) v.items[0] else value_mod.nil,
        else => error.TypeError,
    };
}

/// rest : コレクションの最初以外
pub fn rest(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    // lazy-seq の場合: 全体を force せず rest を取得
    if (args[0] == .lazy_seq) {
        return lazyRest(allocator, args[0].lazy_seq);
    }

    return switch (args[0]) {
        .nil => Value{ .list = try value_mod.PersistentList.empty(allocator) },
        .list => |l| blk: {
            if (l.items.len <= 1) {
                break :blk Value{ .list = try value_mod.PersistentList.empty(allocator) };
            }
            break :blk Value{ .list = try value_mod.PersistentList.fromSlice(allocator, l.items[1..]) };
        },
        .vector => |v| blk: {
            if (v.items.len <= 1) {
                break :blk Value{ .list = try value_mod.PersistentList.empty(allocator) };
            }
            break :blk Value{ .list = try value_mod.PersistentList.fromSlice(allocator, v.items[1..]) };
        },
        else => error.TypeError,
    };
}

/// cons : 先頭に要素を追加
pub fn cons(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;

    const elem = args[0];
    const tail = args[1];

    // lazy-seq の場合: force せずに ConsLazySeq を作成
    // (cons x lazy-tail) → x が先頭、lazy-tail は遅延のまま保持
    if (tail == .lazy_seq) {
        const ls = try allocator.create(value_mod.LazySeq);
        ls.* = value_mod.LazySeq.initCons(elem, tail);
        return Value{ .lazy_seq = ls };
    }

    const coll = tail;

    // コレクションの要素を取得
    const items: []const Value = switch (coll) {
        .nil => &[_]Value{},
        .list => |l| l.items,
        .vector => |v| v.items,
        else => return error.TypeError,
    };

    // 新しいリストを作成
    const new_items = try allocator.alloc(Value, items.len + 1);
    new_items[0] = elem;
    @memcpy(new_items[1..], items);

    const new_list = try allocator.create(value_mod.PersistentList);
    new_list.* = .{ .items = new_items };
    return Value{ .list = new_list };
}

/// conj : コレクションに要素を追加（型に応じた位置）
pub fn conj(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;

    const coll = args[0];
    const elems = args[1..];

    switch (coll) {
        .nil => {
            // nil は空リストとして扱う
            const new_list = try allocator.create(value_mod.PersistentList);
            const items = try allocator.alloc(Value, elems.len);
            // リストは逆順で追加
            for (elems, 0..) |e, i| {
                items[elems.len - 1 - i] = e;
            }
            new_list.* = .{ .items = items };
            return Value{ .list = new_list };
        },
        .list => |l| {
            // リストは先頭に追加
            const new_items = try allocator.alloc(Value, l.items.len + elems.len);
            // 新しい要素を先頭に（逆順で）
            for (elems, 0..) |e, i| {
                new_items[elems.len - 1 - i] = e;
            }
            @memcpy(new_items[elems.len..], l.items);

            const new_list = try allocator.create(value_mod.PersistentList);
            new_list.* = .{ .items = new_items };
            return Value{ .list = new_list };
        },
        .vector => |v| {
            // ベクタは末尾に追加
            const new_items = try allocator.alloc(Value, v.items.len + elems.len);
            @memcpy(new_items[0..v.items.len], v.items);
            @memcpy(new_items[v.items.len..], elems);

            const new_vec = try allocator.create(value_mod.PersistentVector);
            new_vec.* = .{ .items = new_items };
            return Value{ .vector = new_vec };
        },
        .set => |s| {
            // セットは重複を除いて要素を追加
            var result = std.ArrayList(Value).empty;
            defer result.deinit(allocator);
            // 既存要素をコピー
            try result.appendSlice(allocator, s.items);
            // 新しい要素を重複チェックしながら追加
            for (elems) |e| {
                var found = false;
                for (result.items) |existing| {
                    if (existing.eql(e)) { found = true; break; }
                }
                if (!found) try result.append(allocator, e);
            }
            const items = try allocator.alloc(Value, result.items.len);
            @memcpy(items, result.items);
            const new_set = try allocator.create(value_mod.PersistentSet);
            new_set.* = .{ .items = items };
            return Value{ .set = new_set };
        },
        .map => |m| {
            // マップは [k v] ベクターまたはマップエントリを追加
            var current = m.*;
            for (elems) |e| {
                if (e == .vector and e.vector.items.len == 2) {
                    current = try current.assoc(allocator, e.vector.items[0], e.vector.items[1]);
                } else if (e == .map) {
                    // マップのマージ
                    var i: usize = 0;
                    while (i + 1 < e.map.entries.len) : (i += 2) {
                        current = try current.assoc(allocator, e.map.entries[i], e.map.entries[i + 1]);
                    }
                } else {
                    return error.TypeError;
                }
            }
            const new_map = try allocator.create(value_mod.PersistentMap);
            new_map.* = current;
            return Value{ .map = new_map };
        },
        else => return error.TypeError,
    }
}

/// count : コレクションの要素数
/// 注意: 無限 lazy-seq に対して呼ぶと無限ループになる
pub fn count(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    // lazy-seq の場合: 完全に force して数える
    const val = if (args[0] == .lazy_seq)
        try forceLazySeq(allocator, args[0].lazy_seq)
    else
        args[0];
    const n: i64 = switch (val) {
        .nil => 0,
        .list => |l| @intCast(l.items.len),
        .vector => |v| @intCast(v.items.len),
        .map => |m| @intCast(m.count()),
        .set => |s| @intCast(s.items.len),
        .string => |s| @intCast(s.data.len),
        else => return error.TypeError,
    };

    return Value{ .int = n };
}

/// empty? : コレクションが空かどうか
pub fn isEmpty(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    // lazy-seq の場合: first だけ force して空かどうか判定
    if (args[0] == .lazy_seq) {
        const f = try lazyFirst(allocator, args[0].lazy_seq);
        return Value{ .bool_val = f == .nil };
    }

    const val = args[0];
    const empty = switch (val) {
        .nil => true,
        .list => |l| l.items.len == 0,
        .vector => |v| v.items.len == 0,
        .map => |m| m.entries.len == 0,
        .set => |s| s.items.len == 0,
        .string => |s| s.data.len == 0,
        else => return error.TypeError,
    };

    if (empty) return value_mod.true_val;
    return value_mod.false_val;
}

/// nth : インデックスで要素取得
pub fn nth(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2 or args.len > 3) return error.ArityError;

    const coll = args[0];
    const idx: usize = switch (args[1]) {
        .int => |n| if (n >= 0) @intCast(n) else return error.TypeError,
        else => return error.TypeError,
    };

    const not_found = if (args.len == 3) args[2] else null;

    const items: []const Value = switch (coll) {
        .list => |l| l.items,
        .vector => |v| v.items,
        else => return error.TypeError,
    };

    if (idx < items.len) {
        return items[idx];
    } else if (not_found) |nf| {
        return nf;
    } else {
        return error.TypeError; // IndexOutOfBounds
    }
}

// ============================================================
// 出力
// ============================================================

/// println : 改行付き出力（文字列はクォートなし）
pub fn println_fn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout.writer(&buf);
    const writer = &file_writer.interface;

    for (args, 0..) |arg, i| {
        if (i > 0) writer.writeByte(' ') catch {};
        printValueForPrint(writer, arg) catch {};
    }
    writer.writeByte('\n') catch {};
    // flush via interface
    writer.flush() catch {};

    return value_mod.nil;
}

/// 値を出力（print/println 用 - 文字列はクォートなし）
fn printValueForPrint(writer: anytype, val: Value) !void {
    switch (val) {
        .string => |s| try writer.writeAll(s.data), // クォートなし
        else => try printValue(writer, val),
    }
}

/// pr-str : 文字列表現を返す（print 用）
/// lazy-seq は自動的に realize してから出力
pub fn prStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (args, 0..) |arg, i| {
        if (i > 0) try buf.append(allocator, ' ');
        const realized = try ensureRealized(allocator, arg);
        try printValueToBuf(allocator, &buf, realized);
    }

    const str = try allocator.create(value_mod.String);
    str.* = .{ .data = try buf.toOwnedSlice(allocator) };
    return Value{ .string = str };
}

/// 値を出力（writer 版）
fn printValue(writer: anytype, val: Value) !void {
    switch (val) {
        .nil => try writer.writeAll("nil"),
        .bool_val => |b| try writer.writeAll(if (b) "true" else "false"),
        .int => |n| try writer.print("{d}", .{n}),
        .float => |f| try writer.print("{d}", .{f}),
        .char_val => |c| {
            try writer.writeByte('\\');
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c, &buf) catch 1;
            try writer.writeAll(buf[0..len]);
        },
        .string => |s| {
            try writer.writeByte('"');
            try writer.writeAll(s.data);
            try writer.writeByte('"');
        },
        .keyword => |k| {
            try writer.writeByte(':');
            if (k.namespace) |ns| {
                try writer.writeAll(ns);
                try writer.writeByte('/');
            }
            try writer.writeAll(k.name);
        },
        .symbol => |s| {
            if (s.namespace) |ns| {
                try writer.writeAll(ns);
                try writer.writeByte('/');
            }
            try writer.writeAll(s.name);
        },
        .list => |l| {
            try writer.writeByte('(');
            for (l.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(' ');
                try printValue(writer, item);
            }
            try writer.writeByte(')');
        },
        .vector => |v| {
            try writer.writeByte('[');
            for (v.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(' ');
                try printValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .map => |m| {
            try writer.writeByte('{');
            // entries はフラット配列 [k1, v1, k2, v2, ...]
            var idx: usize = 0;
            while (idx < m.entries.len) : (idx += 2) {
                if (idx > 0) try writer.writeAll(", ");
                try printValue(writer, m.entries[idx]);
                try writer.writeByte(' ');
                if (idx + 1 < m.entries.len) {
                    try printValue(writer, m.entries[idx + 1]);
                }
            }
            try writer.writeByte('}');
        },
        .set => |s| {
            try writer.writeAll("#{");
            for (s.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(' ');
                try printValue(writer, item);
            }
            try writer.writeByte('}');
        },
        .fn_val => |f| {
            try writer.writeAll("#<fn");
            if (f.name) |name| {
                try writer.writeByte(' ');
                if (name.namespace) |ns| {
                    try writer.writeAll(ns);
                    try writer.writeByte('/');
                }
                try writer.writeAll(name.name);
            }
            try writer.writeByte('>');
        },
        .partial_fn => try writer.writeAll("#<partial-fn>"),
        .comp_fn => try writer.writeAll("#<comp-fn>"),
        .multi_fn => |mf| {
            if (mf.name) |name| {
                try writer.writeAll("#<multi-fn ");
                try writer.writeAll(name.name);
                try writer.writeByte('>');
            } else {
                try writer.writeAll("#<multi-fn>");
            }
        },
        .fn_proto => try writer.writeAll("#<fn-proto>"),
        .var_val => |vp| {
            const v: *const var_mod.Var = @ptrCast(@alignCast(vp));
            try writer.writeAll("#'");
            if (v.ns_name.len > 0) {
                try writer.writeAll(v.ns_name);
                try writer.writeByte('/');
            }
            try writer.writeAll(v.sym.name);
        },
        .atom => |a| {
            try writer.writeAll("#<atom ");
            try printValue(writer, a.value);
            try writer.writeByte('>');
        },
        .protocol => |p| {
            try writer.writeAll("#<protocol ");
            try writer.writeAll(p.name.name);
            try writer.writeByte('>');
        },
        .protocol_fn => |pf| {
            try writer.writeAll("#<protocol-fn ");
            try writer.writeAll(pf.method_name);
            try writer.writeByte('>');
        },
        .lazy_seq => |ls| {
            // 実体化済みなら中身を表示
            if (ls.realized) |realized| {
                try printValue(writer, realized);
            } else {
                try writer.writeAll("#<lazy-seq>");
            }
        },
        .delay_val => |d| {
            if (d.realized) {
                try writer.writeAll("#<delay ");
                if (d.cached) |cached| {
                    try printValue(writer, cached);
                }
                try writer.writeByte('>');
            } else {
                try writer.writeAll("#<delay :pending>");
            }
        },
        .volatile_val => |v| {
            try writer.writeAll("#<volatile ");
            try printValue(writer, v.value);
            try writer.writeByte('>');
        },
        .reduced_val => |r| {
            try writer.writeAll("#<reduced ");
            try printValue(writer, r.value);
            try writer.writeByte('>');
        },
        .transient => |t| {
            const kind_str: []const u8 = switch (t.kind) {
                .vector => "vector",
                .map => "map",
                .set => "set",
            };
            try writer.print("#<transient-{s}>", .{kind_str});
        },
        .promise => |p| {
            if (p.delivered) {
                try writer.writeAll("#<promise (delivered)>");
            } else {
                try writer.writeAll("#<promise (pending)>");
            }
        },
        .regex => |pat| {
            try writer.writeAll("#\"");
            try writer.writeAll(pat.source);
            try writer.writeByte('"');
        },
        .matcher => try writer.writeAll("#<matcher>"),
    }
}

/// 値を出力（ArrayListUnmanaged 版）
fn printValueToBuf(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), val: Value) !void {
    const BufWriter = struct {
        buf: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,

        pub fn writeByte(self: *@This(), byte: u8) !void {
            try self.buf.append(self.allocator, byte);
        }

        pub fn writeAll(self: *@This(), data: []const u8) !void {
            try self.buf.appendSlice(self.allocator, data);
        }

        pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
            var local_buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&local_buf, fmt, args) catch return error.OutOfMemory;
            try self.buf.appendSlice(self.allocator, s);
        }
    };
    var ctx = BufWriter{ .buf = buf, .allocator = allocator };
    try printValue(&ctx, val);
}

// ============================================================
// 文字列操作
// ============================================================

/// str : 引数を連結して文字列を返す
/// lazy-seq は自動的に realize してから出力
pub fn strFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (args) |arg| {
        const realized = ensureRealized(allocator, arg) catch arg;
        try valueToString(allocator, &buf, realized);
    }

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = try buf.toOwnedSlice(allocator) };
    return Value{ .string = str_obj };
}

/// 値を文字列に変換（str 用 - pr-str と違ってクォートなし）
fn valueToString(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), val: Value) !void {
    switch (val) {
        .nil => {}, // nil は空文字列
        .bool_val => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .int => |n| {
            var local_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&local_buf, "{d}", .{n}) catch return error.OutOfMemory;
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            var local_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&local_buf, "{d}", .{f}) catch return error.OutOfMemory;
            try buf.appendSlice(allocator, s);
        },
        .string => |s| try buf.appendSlice(allocator, s.data),
        .keyword => |k| {
            try buf.append(allocator, ':');
            if (k.namespace) |ns| {
                try buf.appendSlice(allocator, ns);
                try buf.append(allocator, '/');
            }
            try buf.appendSlice(allocator, k.name);
        },
        .symbol => |s| {
            if (s.namespace) |ns| {
                try buf.appendSlice(allocator, ns);
                try buf.append(allocator, '/');
            }
            try buf.appendSlice(allocator, s.name);
        },
        else => {
            // その他の型は pr-str と同じ表現
            try printValueToBuf(allocator, buf, val);
        },
    }
}

// ============================================================
// コレクションアクセス
// ============================================================

/// get : コレクションから値を取得（見つからない場合は nil または not-found）
pub fn get(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2 or args.len > 3) return error.ArityError;

    const coll = args[0];
    const key = args[1];
    const not_found = if (args.len == 3) args[2] else value_mod.nil;

    return switch (coll) {
        .nil => not_found,
        .vector => |vec| {
            // ベクターはインデックスでアクセス
            if (key != .int) return not_found;
            const idx = key.int;
            if (idx < 0 or idx >= vec.items.len) return not_found;
            return vec.items[@intCast(idx)];
        },
        .list => |lst| {
            // リストもインデックスでアクセス
            if (key != .int) return not_found;
            const idx = key.int;
            if (idx < 0 or idx >= lst.items.len) return not_found;
            return lst.items[@intCast(idx)];
        },
        .map => |m| {
            // マップはキーでアクセス
            return m.get(key) orelse not_found;
        },
        .set => |s| {
            // セットは要素の存在確認
            for (s.items) |item| {
                if (key.eql(item)) return key;
            }
            return not_found;
        },
        else => not_found,
    };
}

/// assoc : マップにキー値を追加/更新
pub fn assoc(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 3 or (args.len - 1) % 2 != 0) return error.ArityError;

    const coll = args[0];

    switch (coll) {
        .nil => {
            // nil に assoc すると新しいマップを作成
            const entries = try allocator.alloc(Value, args.len - 1);
            @memcpy(entries, args[1..]);
            const m = try allocator.create(value_mod.PersistentMap);
            m.* = .{ .entries = entries };
            return Value{ .map = m };
        },
        .map => |m| {
            var result = m.*;
            var i: usize = 1;
            while (i < args.len) : (i += 2) {
                result = try result.assoc(allocator, args[i], args[i + 1]);
            }
            const new_map = try allocator.create(value_mod.PersistentMap);
            new_map.* = result;
            return Value{ .map = new_map };
        },
        .vector => |vec| {
            // ベクターの assoc はインデックス更新
            if (args.len != 3) return error.ArityError;
            if (args[1] != .int) return error.TypeError;
            const idx = args[1].int;
            if (idx < 0 or idx > vec.items.len) return error.IndexOutOfBounds;
            const uidx: usize = @intCast(idx);

            var new_items: []Value = undefined;
            if (uidx == vec.items.len) {
                // 末尾に追加
                new_items = try allocator.alloc(Value, vec.items.len + 1);
                @memcpy(new_items[0..vec.items.len], vec.items);
                new_items[vec.items.len] = args[2];
            } else {
                // 既存要素を更新
                new_items = try allocator.dupe(Value, vec.items);
                new_items[uidx] = args[2];
            }
            const new_vec = try allocator.create(value_mod.PersistentVector);
            new_vec.* = .{ .items = new_items };
            return Value{ .vector = new_vec };
        },
        else => return error.TypeError,
    }
}

/// dissoc : マップからキーを削除
pub fn dissoc(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;

    const coll = args[0];
    if (coll == .nil) return value_mod.nil;
    if (coll != .map) return error.TypeError;

    const m = coll.map;
    var result = m.*;

    for (args[1..]) |key| {
        result = try result.dissoc(allocator, key);
    }

    const new_map = try allocator.create(value_mod.PersistentMap);
    new_map.* = result;
    return Value{ .map = new_map };
}

/// keys : マップのキーをシーケンスで返す
pub fn keys(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    const coll = args[0];
    if (coll == .nil) return value_mod.nil;
    if (coll != .map) return error.TypeError;

    const m = coll.map;
    const count_val = m.count();
    if (count_val == 0) return value_mod.nil;

    const key_vals = try allocator.alloc(Value, count_val);
    var i: usize = 0;
    var j: usize = 0;
    while (j < m.entries.len) : (j += 2) {
        key_vals[i] = m.entries[j];
        i += 1;
    }

    const lst = try allocator.create(value_mod.PersistentList);
    lst.* = .{ .items = key_vals };
    return Value{ .list = lst };
}

/// vals : マップの値をシーケンスで返す
pub fn vals(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    const coll = args[0];
    if (coll == .nil) return value_mod.nil;
    if (coll != .map) return error.TypeError;

    const m = coll.map;
    const count_val = m.count();
    if (count_val == 0) return value_mod.nil;

    const val_vals = try allocator.alloc(Value, count_val);
    var i: usize = 0;
    var j: usize = 1;
    while (j < m.entries.len) : (j += 2) {
        val_vals[i] = m.entries[j];
        i += 1;
    }

    const lst = try allocator.create(value_mod.PersistentList);
    lst.* = .{ .items = val_vals };
    return Value{ .list = lst };
}

/// hash-map : キー値ペアからマップを作成
pub fn hashMap(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len % 2 != 0) return error.ArityError;

    if (args.len == 0) {
        const m = try allocator.create(value_mod.PersistentMap);
        m.* = value_mod.PersistentMap.empty();
        return Value{ .map = m };
    }

    const entries = try allocator.dupe(Value, args);
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

/// contains? : コレクションにキーが含まれるか
pub fn containsKey(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;

    const coll = args[0];
    const key = args[1];

    return switch (coll) {
        .nil => value_mod.false_val,
        .map => |m| if (m.get(key) != null) value_mod.true_val else value_mod.false_val,
        .set => |s| blk: {
            for (s.items) |item| {
                if (key.eql(item)) break :blk value_mod.true_val;
            }
            break :blk value_mod.false_val;
        },
        .vector => |vec| blk: {
            if (key != .int) break :blk value_mod.false_val;
            const idx = key.int;
            if (idx >= 0 and idx < vec.items.len) break :blk value_mod.true_val;
            break :blk value_mod.false_val;
        },
        else => value_mod.false_val,
    };
}

// ============================================================
// シーケンス操作
// ============================================================

/// コレクションの要素を取得するヘルパー
fn getItems(val: Value) ?[]const Value {
    return switch (val) {
        .list => |l| l.items,
        .vector => |v| v.items,
        .nil => &[_]Value{},
        else => null,
    };
}

/// LazySeq 対応版 getItems — force してから items を取得
fn getItemsRealized(allocator: std.mem.Allocator, val: Value) anyerror!?[]const Value {
    const realized = try ensureRealized(allocator, val);
    return getItems(realized);
}

/// take : 先頭 n 個の要素を取得
pub fn take(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int) return error.TypeError;
    const n_raw = args[0].int;
    const n: usize = if (n_raw < 0) 0 else @intCast(n_raw);

    // lazy-seq の場合: 一要素ずつ取得（無限シーケンス対応）
    if (args[1] == .lazy_seq) {
        var items_buf: std.ArrayListUnmanaged(Value) = .empty;
        var current: Value = args[1];
        var taken: usize = 0;
        while (taken < n) {
            if (current == .lazy_seq) {
                const elem = try lazyFirst(allocator, current.lazy_seq);
                if (elem == .nil) break; // 空
                items_buf.append(allocator, elem) catch return error.OutOfMemory;
                current = try lazyRest(allocator, current.lazy_seq);
                taken += 1;
            } else {
                // 具体値に到達
                const remaining = n - taken;
                const rest_items = getItems(current) orelse break;
                const take_rest = @min(remaining, rest_items.len);
                for (rest_items[0..take_rest]) |item| {
                    items_buf.append(allocator, item) catch return error.OutOfMemory;
                }
                break;
            }
        }
        const result = try allocator.create(value_mod.PersistentList);
        result.* = .{ .items = items_buf.toOwnedSlice(allocator) catch return error.OutOfMemory };
        return Value{ .list = result };
    }

    const items = getItems(args[1]) orelse return error.TypeError;
    const take_count = @min(n, items.len);

    const new_items = try allocator.dupe(Value, items[0..take_count]);
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = new_items };
    return Value{ .list = result };
}

/// drop : 先頭 n 個を除いた残りの要素
pub fn drop(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int) return error.TypeError;
    const n_raw = args[0].int;
    const n: usize = if (n_raw < 0) 0 else @intCast(n_raw);

    // lazy-seq の場合: n 個スキップして残りを返す（遅延のまま）
    if (args[1] == .lazy_seq) {
        var current: Value = args[1];
        var dropped: usize = 0;
        while (dropped < n) {
            if (current == .lazy_seq) {
                const f = try lazyFirst(allocator, current.lazy_seq);
                if (f == .nil) break;
                current = try lazyRest(allocator, current.lazy_seq);
                dropped += 1;
            } else {
                // 具体値に到達
                const remaining_items = getItems(current) orelse break;
                const skip = @min(n - dropped, remaining_items.len);
                const new_items = try allocator.dupe(Value, remaining_items[skip..]);
                const result = try allocator.create(value_mod.PersistentList);
                result.* = .{ .items = new_items };
                return Value{ .list = result };
            }
        }
        return current;
    }

    const items = getItems(args[1]) orelse return error.TypeError;
    const drop_count = @min(n, items.len);

    const new_items = try allocator.dupe(Value, items[drop_count..]);
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = new_items };
    return Value{ .list = result };
}

/// range : 数列を生成
/// (range end), (range start end), (range start end step)
pub fn range(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len > 3) return error.ArityError;

    // (range) → 無限 lazy-seq: (0 1 2 3 ...)
    if (args.len == 0) {
        const ls = try allocator.create(value_mod.LazySeq);
        ls.* = value_mod.LazySeq.initRangeInfinite(value_mod.intVal(0));
        return Value{ .lazy_seq = ls };
    }

    var start: i64 = 0;
    var end: i64 = undefined;
    var step: i64 = 1;

    if (args.len == 1) {
        if (args[0] != .int) return error.TypeError;
        end = args[0].int;
    } else if (args.len == 2) {
        if (args[0] != .int or args[1] != .int) return error.TypeError;
        start = args[0].int;
        end = args[1].int;
    } else {
        if (args[0] != .int or args[1] != .int or args[2] != .int) return error.TypeError;
        start = args[0].int;
        end = args[1].int;
        step = args[2].int;
        if (step == 0) return error.TypeError;
    }

    // 要素数を計算
    var count_val: usize = 0;
    if (step > 0 and start < end) {
        count_val = @intCast(@divTrunc(end - start + step - 1, step));
    } else if (step < 0 and start > end) {
        count_val = @intCast(@divTrunc(start - end - step - 1, -step));
    }

    const items = try allocator.alloc(Value, count_val);
    var val = start;
    for (0..count_val) |i| {
        items[i] = value_mod.intVal(val);
        val += step;
    }

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = items };
    return Value{ .list = result };
}

/// concat : 複数のコレクションを連結
pub fn concat(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // lazy-seq が含まれる場合: 遅延 concat を返す
    var has_lazy = false;
    for (args) |arg| {
        if (arg == .lazy_seq) {
            has_lazy = true;
            break;
        }
    }
    if (has_lazy) {
        const sources = try allocator.dupe(Value, args);
        const ls = try allocator.create(value_mod.LazySeq);
        ls.* = value_mod.LazySeq.initConcat(sources);
        return Value{ .lazy_seq = ls };
    }

    // 全要素数を計算（eager 版）
    var total: usize = 0;
    for (args) |arg| {
        const items = (try getItemsRealized(allocator, arg)) orelse return error.TypeError;
        total += items.len;
    }

    const new_items = try allocator.alloc(Value, total);
    var offset: usize = 0;
    for (args) |arg| {
        const items = (try getItemsRealized(allocator, arg)).?;
        @memcpy(new_items[offset .. offset + items.len], items);
        offset += items.len;
    }

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = new_items };
    return Value{ .list = result };
}

/// into : コレクションに要素を追加
/// (into to from) — to の型に応じて結合
pub fn into(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;

    const from_items = (try getItemsRealized(allocator, args[1])) orelse return error.TypeError;

    switch (args[0]) {
        .nil => {
            // nil → リストとして返す（逆順）
            const new_items = try allocator.alloc(Value, from_items.len);
            for (from_items, 0..) |item, i| {
                new_items[from_items.len - 1 - i] = item;
            }
            const result = try allocator.create(value_mod.PersistentList);
            result.* = .{ .items = new_items };
            return Value{ .list = result };
        },
        .list => |l| {
            // リスト → 先頭に追加（逆順）
            const new_items = try allocator.alloc(Value, l.items.len + from_items.len);
            for (from_items, 0..) |item, i| {
                new_items[from_items.len - 1 - i] = item;
            }
            @memcpy(new_items[from_items.len..], l.items);
            const result = try allocator.create(value_mod.PersistentList);
            result.* = .{ .items = new_items };
            return Value{ .list = result };
        },
        .vector => |v| {
            // ベクター → 末尾に追加
            const new_items = try allocator.alloc(Value, v.items.len + from_items.len);
            @memcpy(new_items[0..v.items.len], v.items);
            @memcpy(new_items[v.items.len..], from_items);
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = .{ .items = new_items };
            return Value{ .vector = result };
        },
        .set => |s| {
            // セット → 追加（重複除外）
            var set = s.*;
            for (from_items) |item| {
                set = try set.conj(allocator, item);
            }
            const result = try allocator.create(value_mod.PersistentSet);
            result.* = set;
            return Value{ .set = result };
        },
        .map => |m| {
            // マップ → 各要素を conj（[k v] ベクタまたはマップエントリ）
            var map = m.*;
            for (from_items) |item| {
                if (item == .vector and item.vector.items.len == 2) {
                    // [k v] ベクタ → assoc
                    map = try map.assoc(allocator, item.vector.items[0], item.vector.items[1]);
                } else if (item == .map) {
                    // マップのマージ
                    var j: usize = 0;
                    while (j + 1 < item.map.entries.len) : (j += 2) {
                        map = try map.assoc(allocator, item.map.entries[j], item.map.entries[j + 1]);
                    }
                } else if (item == .list and item.list.items.len == 2) {
                    // (k v) リスト → assoc
                    map = try map.assoc(allocator, item.list.items[0], item.list.items[1]);
                } else {
                    return error.TypeError;
                }
            }
            const result = try allocator.create(value_mod.PersistentMap);
            result.* = map;
            return Value{ .map = result };
        },
        else => return error.TypeError,
    }
}

/// reverse : コレクションを逆順に
pub fn reverseFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;

    const new_items = try allocator.alloc(Value, items.len);
    for (items, 0..) |item, i| {
        new_items[items.len - 1 - i] = item;
    }

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = new_items };
    return Value{ .list = result };
}

/// seq : シーケンスに変換（空なら nil）
pub fn seq(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    // lazy-seq の場合: first だけ force して空チェック
    if (args[0] == .lazy_seq) {
        const f = try lazyFirst(allocator, args[0].lazy_seq);
        if (f == .nil) return value_mod.nil;
        // 非空の lazy-seq → そのまま返す（遅延のまま）
        return args[0];
    }

    const val = args[0];
    return switch (val) {
        .nil => value_mod.nil,
        .list => |l| if (l.items.len == 0) value_mod.nil else val,
        .vector => |v| blk: {
            if (v.items.len == 0) break :blk value_mod.nil;
            const result = try value_mod.PersistentList.fromSlice(allocator, v.items);
            break :blk Value{ .list = result };
        },
        .map => |m| blk: {
            if (m.count() == 0) break :blk value_mod.nil;
            // マップはキーバリューペアのベクタのリストに変換
            const pair_count = m.count();
            const items = try allocator.alloc(Value, pair_count);
            var i: usize = 0;
            var entry_idx: usize = 0;
            while (entry_idx < m.entries.len) : (entry_idx += 2) {
                const pair_items = try allocator.alloc(Value, 2);
                pair_items[0] = m.entries[entry_idx];
                pair_items[1] = m.entries[entry_idx + 1];
                const pair_vec = try allocator.create(value_mod.PersistentVector);
                pair_vec.* = .{ .items = pair_items };
                items[i] = Value{ .vector = pair_vec };
                i += 1;
            }
            const result = try allocator.create(value_mod.PersistentList);
            result.* = .{ .items = items };
            break :blk Value{ .list = result };
        },
        .set => |s| blk: {
            if (s.items.len == 0) break :blk value_mod.nil;
            const result = try value_mod.PersistentList.fromSlice(allocator, s.items);
            break :blk Value{ .list = result };
        },
        .string => |s| blk: {
            if (s.data.len == 0) break :blk value_mod.nil;
            // 文字列を1文字ずつのリストに（UTF-8バイト単位で簡易実装）
            const items = try allocator.alloc(Value, s.data.len);
            for (s.data, 0..) |byte, idx| {
                const char_str = try allocator.alloc(u8, 1);
                char_str[0] = byte;
                const str_obj = try allocator.create(value_mod.String);
                str_obj.* = value_mod.String.init(char_str);
                items[idx] = Value{ .string = str_obj };
            }
            const result = try allocator.create(value_mod.PersistentList);
            result.* = .{ .items = items };
            break :blk Value{ .list = result };
        },
        else => error.TypeError,
    };
}

/// vec : ベクターに変換
pub fn vecFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .nil => blk: {
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = value_mod.PersistentVector.empty();
            break :blk Value{ .vector = result };
        },
        .vector => args[0],
        .list => |l| blk: {
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = .{ .items = try allocator.dupe(Value, l.items) };
            break :blk Value{ .vector = result };
        },
        .set => |s| blk: {
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = .{ .items = try allocator.dupe(Value, s.items) };
            break :blk Value{ .vector = result };
        },
        .lazy_seq => blk: {
            // lazy-seq を実体化してから vector に変換
            const realized = try ensureRealized(allocator, args[0]);
            const items = switch (realized) {
                .list => |l| l.items,
                .nil => &[_]Value{},
                else => return error.TypeError,
            };
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = .{ .items = try allocator.dupe(Value, items) };
            break :blk Value{ .vector = result };
        },
        else => error.TypeError,
    };
}

/// repeat : 値を n 回繰り返したリストを生成
pub fn repeat(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;

    // (repeat x) → 無限 lazy-seq: (x x x ...)
    if (args.len == 1) {
        const ls = try allocator.create(value_mod.LazySeq);
        ls.* = value_mod.LazySeq.initRepeatInfinite(args[0]);
        return Value{ .lazy_seq = ls };
    }

    // (repeat n x) → 有限リスト
    if (args[0] != .int) return error.TypeError;
    const n_raw = args[0].int;
    if (n_raw < 0) return error.TypeError;
    const n: usize = @intCast(n_raw);

    const items = try allocator.alloc(Value, n);
    for (0..n) |i| {
        items[i] = args[1];
    }

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = items };
    return Value{ .list = result };
}

/// mapcat : (mapcat f coll) → lazy concat of (map f coll)
pub fn mapcat(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const fn_val = args[0];
    const coll_val = args[1];

    // lazy-seq/コレクション問わず lazy mapcat を返す
    const ls = try allocator.create(value_mod.LazySeq);
    ls.* = value_mod.LazySeq.initTransform(.mapcat, fn_val, coll_val);
    return Value{ .lazy_seq = ls };
}

/// iterate : (iterate f x) → 無限 lazy-seq (x (f x) (f (f x)) ...)
pub fn iterate(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const ls = try allocator.create(value_mod.LazySeq);
    ls.* = value_mod.LazySeq.initIterate(args[0], args[1]);
    return Value{ .lazy_seq = ls };
}

/// cycle : (cycle coll) → 無限 lazy-seq（coll の要素を繰り返す）
pub fn cycle(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = (try getItemsRealized(allocator, args[0])) orelse return error.TypeError;
    if (items.len == 0) return value_mod.nil;
    // items を永続化（元の参照が消えても安全なようにコピー）
    const owned = try allocator.dupe(Value, items);
    const ls = try allocator.create(value_mod.LazySeq);
    ls.* = value_mod.LazySeq.initCycle(owned, 0);
    return Value{ .lazy_seq = ls };
}

/// distinct : 重複を除いたリストを返す
pub fn distinct(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;

    var result_buf: std.ArrayListUnmanaged(Value) = .empty;
    for (items) |item| {
        var found = false;
        for (result_buf.items) |existing| {
            if (item.eql(existing)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try result_buf.append(allocator, item);
        }
    }

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = try result_buf.toOwnedSlice(allocator) };
    return Value{ .list = result };
}

/// flatten : ネストされたコレクションを平坦化
pub fn flatten(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    var result_buf: std.ArrayListUnmanaged(Value) = .empty;
    try flattenInto(allocator, args[0], &result_buf);

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = try result_buf.toOwnedSlice(allocator) };
    return Value{ .list = result };
}

fn flattenInto(allocator: std.mem.Allocator, val: Value, buf: *std.ArrayListUnmanaged(Value)) !void {
    switch (val) {
        .list => |l| {
            for (l.items) |item| try flattenInto(allocator, item, buf);
        },
        .vector => |v| {
            for (v.items) |item| try flattenInto(allocator, item, buf);
        },
        .nil => {},
        else => try buf.append(allocator, val),
    }
}

// ============================================================
// 例外処理
// ============================================================

/// ex-info: (ex-info msg data) → {:message msg, :data data}
pub fn exInfo(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;

    const msg = args[0];
    const data = args[1];

    // {:message msg, :data data} マップを作成
    const Keyword = value_mod.Keyword;
    const map_ptr = try allocator.create(value_mod.PersistentMap);
    const entries = try allocator.alloc(Value, 4);

    // :message キー
    const msg_kw = try allocator.create(Keyword);
    msg_kw.* = Keyword.init("message");
    entries[0] = Value{ .keyword = msg_kw };
    entries[1] = msg;

    // :data キー
    const data_kw = try allocator.create(Keyword);
    data_kw.* = Keyword.init("data");
    entries[2] = Value{ .keyword = data_kw };
    entries[3] = data;

    map_ptr.* = .{ .entries = entries };
    return Value{ .map = map_ptr };
}

/// ex-message: (ex-message ex) → (:message ex) 相当
pub fn exMessage(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    const ex = args[0];
    if (ex != .map) return value_mod.nil;

    // :message キーで検索
    const entries = ex.map.entries;
    var i: usize = 0;
    while (i < entries.len) : (i += 2) {
        if (entries[i] == .keyword) {
            if (std.mem.eql(u8, entries[i].keyword.name, "message")) {
                return entries[i + 1];
            }
        }
    }
    return value_mod.nil;
}

/// ex-data: (ex-data ex) → (:data ex) 相当
pub fn exData(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    const ex = args[0];
    if (ex != .map) return value_mod.nil;

    // :data キーで検索
    const entries = ex.map.entries;
    var i: usize = 0;
    while (i < entries.len) : (i += 2) {
        if (entries[i] == .keyword) {
            if (std.mem.eql(u8, entries[i].keyword.name, "data")) {
                return entries[i + 1];
            }
        }
    }
    return value_mod.nil;
}

// ============================================================
// Atom 操作
// ============================================================

/// atom: Atom を生成
/// (atom val) → #<atom val>
pub fn atomFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const a = try allocator.create(value_mod.Atom);
    a.* = value_mod.Atom.init(args[0]);
    return Value{ .atom = a };
}

/// deref: Atom の現在値を返す
/// (deref atom) → val
pub fn derefFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .atom => |a| a.value,
        .volatile_val => |v| v.value,
        .delay_val => |d| {
            if (d.realized) {
                return d.cached orelse Value.nil;
            }
            return forceFn(allocator, args);
        },
        .promise => |p| p.value orelse value_mod.nil,
        else => error.TypeError,
    };
}

/// reset!: Atom の値を新しい値に置換
/// (reset! atom new-val) → new-val
pub fn resetBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return switch (args[0]) {
        .atom => |a| {
            // scratch 参照を排除するためディープクローン
            const cloned = try args[1].deepClone(allocator);
            a.value = cloned;
            return cloned;
        },
        else => error.TypeError,
    };
}

/// atom?: Atom かどうか
pub fn isAtom(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .atom => value_mod.true_val,
        else => value_mod.false_val,
    };
}

// ============================================================
// プロトコル
// ============================================================

/// satisfies?: 型がプロトコルを実装しているか
/// (satisfies? Protocol value) → bool
pub fn satisfiesPred(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;

    // 第1引数はプロトコル
    const proto = switch (args[0]) {
        .protocol => |p| p,
        else => return error.TypeError,
    };

    // 第2引数の型キーワード
    const type_key_str = args[1].typeKeyword();
    const type_key_s = try allocator.create(value_mod.String);
    type_key_s.* = value_mod.String.init(type_key_str);
    const type_key = Value{ .string = type_key_s };

    // impls に型があるか検索
    if (proto.impls.get(type_key)) |_| {
        return value_mod.true_val;
    }
    return value_mod.false_val;
}

// ============================================================
// 文字列操作（拡充）
// ============================================================

/// subs: 部分文字列
/// (subs s start) または (subs s start end)
pub fn subs(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const start: usize = switch (args[1]) {
        .int => |n| if (n >= 0) @intCast(n) else return error.TypeError,
        else => return error.TypeError,
    };
    if (start > s.len) return error.TypeError;

    const end: usize = if (args.len == 3)
        switch (args[2]) {
            .int => |n| if (n >= 0) @intCast(n) else return error.TypeError,
            else => return error.TypeError,
        }
    else
        s.len;
    if (end > s.len or end < start) return error.TypeError;

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = s[start..end] };
    return Value{ .string = str_obj };
}

/// name: keyword/symbol/string の名前部分
/// (name :foo) → "foo", (name 'bar) → "bar", (name "baz") → "baz"
pub fn nameFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const data = switch (args[0]) {
        .keyword => |k| k.name,
        .symbol => |s| s.name,
        .string => |s| s.data,
        else => return error.TypeError,
    };
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = data };
    return Value{ .string = str_obj };
}

/// namespace: keyword/symbol の名前空間部分
/// (namespace :foo/bar) → "foo", (namespace :foo) → nil
pub fn namespaceFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const ns = switch (args[0]) {
        .keyword => |k| k.namespace,
        .symbol => |s| s.namespace,
        else => return error.TypeError,
    };
    if (ns) |n| {
        const str_obj = try allocator.create(value_mod.String);
        str_obj.* = .{ .data = n };
        return Value{ .string = str_obj };
    }
    return value_mod.nil;
}

/// str/join 相当: (string-join sep coll)
/// 将来 clojure.string/join にマッピング
pub fn stringJoin(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;

    // (string-join coll) または (string-join sep coll)
    var sep: []const u8 = "";
    const coll: Value = if (args.len == 2) blk: {
        sep = switch (args[0]) {
            .string => |s| s.data,
            else => return error.TypeError,
        };
        break :blk args[1];
    } else args[0];

    const items: []const Value = switch (coll) {
        .list => |l| l.items,
        .vector => |v| v.items,
        .nil => &[_]Value{},
        else => return error.TypeError,
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (items, 0..) |item, i| {
        if (i > 0 and sep.len > 0) try buf.appendSlice(allocator, sep);
        try valueToString(allocator, &buf, item);
    }

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = try buf.toOwnedSlice(allocator) };
    return Value{ .string = str_obj };
}

/// str/upper-case 相当
pub fn upperCase(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const upper = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        upper[i] = std.ascii.toUpper(c);
    }
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = upper };
    return Value{ .string = str_obj };
}

/// str/lower-case 相当
pub fn lowerCase(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const lower = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        lower[i] = std.ascii.toLower(c);
    }
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = lower };
    return Value{ .string = str_obj };
}

/// str/trim 相当
pub fn trimStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const trimmed = std.mem.trim(u8, s, " \t\n\r");
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = trimmed };
    return Value{ .string = str_obj };
}

/// str/triml 相当（左トリム）
pub fn trimlStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const trimmed = std.mem.trimLeft(u8, s, " \t\n\r");
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = trimmed };
    return Value{ .string = str_obj };
}

/// str/trimr 相当（右トリム）
pub fn trimrStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const trimmed = std.mem.trimRight(u8, s, " \t\n\r");
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = trimmed };
    return Value{ .string = str_obj };
}

/// str/blank? 相当
pub fn isBlank(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .nil => value_mod.true_val,
        .string => |s| if (std.mem.trim(u8, s.data, " \t\n\r").len == 0)
            value_mod.true_val
        else
            value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// str/starts-with? 相当
pub fn startsWith(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const prefix = switch (args[1]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    return if (std.mem.startsWith(u8, s, prefix)) value_mod.true_val else value_mod.false_val;
}

/// str/ends-with? 相当
pub fn endsWith(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const suffix = switch (args[1]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    return if (std.mem.endsWith(u8, s, suffix)) value_mod.true_val else value_mod.false_val;
}

/// str/includes? 相当
pub fn includesStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const substr = switch (args[1]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    return if (std.mem.indexOf(u8, s, substr) != null) value_mod.true_val else value_mod.false_val;
}

/// str/replace 相当: (string-replace s match replacement)
pub fn stringReplace(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };

    // Pattern の場合: 正規表現置換
    if (args[1] == .regex) {
        const replacement = switch (args[2]) {
            .string => |str| str.data,
            else => return error.TypeError,
        };
        return regexReplaceAll(allocator, s, args[1].regex, replacement);
    }

    const match_str = switch (args[1]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const replacement = switch (args[2]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };

    if (match_str.len == 0) {
        const str_obj = try allocator.create(value_mod.String);
        str_obj.* = .{ .data = s };
        return Value{ .string = str_obj };
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (i + match_str.len <= s.len and std.mem.eql(u8, s[i..][0..match_str.len], match_str)) {
            try buf.appendSlice(allocator, replacement);
            i += match_str.len;
        } else {
            try buf.append(allocator, s[i]);
            i += 1;
        }
    }

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = try buf.toOwnedSlice(allocator) };
    return Value{ .string = str_obj };
}

/// 正規表現で全置換（内部ヘルパー）
fn regexReplaceAll(allocator: std.mem.Allocator, input: []const u8, pat: *value_mod.Pattern, replacement: []const u8) anyerror!Value {
    const compiled: *const regex_mod.CompiledRegex = @ptrCast(@alignCast(pat.compiled));
    var m = try regex_matcher.Matcher.init(allocator, compiled, input);
    defer m.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    var pos: usize = 0;
    while (pos <= input.len) {
        const result = try m.find(pos) orelse {
            // 残りをコピー
            try buf.appendSlice(allocator, input[pos..]);
            break;
        };
        // マッチ前の部分をコピー
        try buf.appendSlice(allocator, input[pos..result.start]);
        // 置換文字列を展開（$1, $2 等のグループ参照を処理）
        try appendReplacement(allocator, &buf, replacement, result, input);
        // 位置を進める（ゼロ幅マッチのとき無限ループを防ぐ）
        pos = if (result.end > result.start) result.end else result.end + 1;
    }

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = try buf.toOwnedSlice(allocator) };
    return Value{ .string = str_obj };
}

/// 置換文字列を展開（$1, $2 でグループ参照）
fn appendReplacement(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    replacement: []const u8,
    result: regex_matcher.MatchResult,
    input: []const u8,
) !void {
    var i: usize = 0;
    while (i < replacement.len) {
        if (replacement[i] == '\\' and i + 1 < replacement.len) {
            // エスケープ: \$ → $, \\ → \
            try buf.append(allocator, replacement[i + 1]);
            i += 2;
        } else if (replacement[i] == '$' and i + 1 < replacement.len and replacement[i + 1] >= '0' and replacement[i + 1] <= '9') {
            // グループ参照: $0, $1, $2, ...
            const group_idx: usize = replacement[i + 1] - '0';
            if (group_idx < result.groups.len) {
                if (result.groups[group_idx]) |span| {
                    try buf.appendSlice(allocator, input[span.start..span.end]);
                }
            }
            i += 2;
        } else {
            try buf.append(allocator, replacement[i]);
            i += 1;
        }
    }
}

/// string-replace-first : 最初のマッチのみ置換
pub fn stringReplaceFirst(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const replacement = switch (args[2]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };

    if (args[1] == .regex) {
        // 正規表現で最初のマッチのみ置換
        const pat = args[1].regex;
        const compiled: *const regex_mod.CompiledRegex = @ptrCast(@alignCast(pat.compiled));
        var m = try regex_matcher.Matcher.init(allocator, compiled, s);
        defer m.deinit();

        const result = try m.find(0) orelse {
            // マッチなし: 元の文字列をそのまま返す
            const str_obj = try allocator.create(value_mod.String);
            str_obj.* = .{ .data = try allocator.dupe(u8, s) };
            return Value{ .string = str_obj };
        };

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, s[0..result.start]);
        try appendReplacement(allocator, &buf, replacement, result, s);
        try buf.appendSlice(allocator, s[result.end..]);

        const str_obj = try allocator.create(value_mod.String);
        str_obj.* = .{ .data = try buf.toOwnedSlice(allocator) };
        return Value{ .string = str_obj };
    }

    // 文字列マッチの場合: 最初のマッチのみ置換
    const match_str = switch (args[1]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };

    if (std.mem.indexOf(u8, s, match_str)) |idx| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, s[0..idx]);
        try buf.appendSlice(allocator, replacement);
        try buf.appendSlice(allocator, s[idx + match_str.len ..]);

        const str_obj = try allocator.create(value_mod.String);
        str_obj.* = .{ .data = try buf.toOwnedSlice(allocator) };
        return Value{ .string = str_obj };
    }

    // マッチなし
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = try allocator.dupe(u8, s) };
    return Value{ .string = str_obj };
}

/// re-quote-replacement : 置換文字列の $ と \ をエスケープ
pub fn reQuoteReplacement(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const s = args[0].string.data;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (s) |c| {
        if (c == '$' or c == '\\') {
            try buf.append(allocator, '\\');
        }
        try buf.append(allocator, c);
    }

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = try buf.toOwnedSlice(allocator) };
    return Value{ .string = str_obj };
}

/// char-at: 文字列のインデックス位置の文字を返す
/// (char-at s idx) → 文字列
pub fn charAt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const idx: usize = switch (args[1]) {
        .int => |n| if (n >= 0) @intCast(n) else return error.TypeError,
        else => return error.TypeError,
    };
    if (idx >= s.len) return error.TypeError;
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = s[idx .. idx + 1] };
    return Value{ .string = str_obj };
}

// ============================================================
// ユーティリティ関数（Phase 8.16）
// ============================================================

/// merge : マップ結合（後勝ち）
/// (merge) → nil, (merge m1) → m1, (merge m1 m2 ...) → 統合マップ
pub fn merge(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return value_mod.nil;

    // 最初の非nil引数を見つける
    var result: ?*const value_mod.PersistentMap = null;
    var start_idx: usize = 0;
    for (args, 0..) |arg, i| {
        switch (arg) {
            .nil => continue,
            .map => |m| {
                result = m;
                start_idx = i + 1;
                break;
            },
            else => return error.TypeError,
        }
    }

    if (result == null) return value_mod.nil;

    var current = result.?.*;
    for (args[start_idx..]) |arg| {
        switch (arg) {
            .nil => continue,
            .map => |m| {
                // m の全エントリを current に assoc
                var j: usize = 0;
                while (j < m.entries.len) : (j += 2) {
                    current = try current.assoc(allocator, m.entries[j], m.entries[j + 1]);
                }
            },
            else => return error.TypeError,
        }
    }

    const new_map = try allocator.create(value_mod.PersistentMap);
    new_map.* = current;
    return Value{ .map = new_map };
}

/// get-in : キーパスで再帰的に get
/// (get-in m ks) / (get-in m ks default)
pub fn getIn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2 or args.len > 3) return error.ArityError;

    const not_found = if (args.len == 3) args[2] else value_mod.nil;
    const ks = switch (args[1]) {
        .vector => |v| v.items,
        .list => |l| l.items,
        .nil => return args[0], // 空パス → 元のマップをそのまま返す
        else => return error.TypeError,
    };

    var current = args[0];
    for (ks) |key| {
        switch (current) {
            .map => |m| {
                current = m.get(key) orelse return not_found;
            },
            .vector => |v| {
                if (key != .int) return not_found;
                const idx = key.int;
                if (idx < 0 or idx >= v.items.len) return not_found;
                current = v.items[@intCast(idx)];
            },
            .nil => return not_found,
            else => return not_found,
        }
    }
    return current;
}

/// assoc-in : キーパスで再帰的に assoc
/// (assoc-in m ks v)
pub fn assocIn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;

    const ks = switch (args[1]) {
        .vector => |v| v.items,
        .list => |l| l.items,
        else => return error.TypeError,
    };

    if (ks.len == 0) return args[0];

    return assocInHelper(allocator, args[0], ks, args[2]);
}

fn assocInHelper(allocator: std.mem.Allocator, m: Value, ks: []const Value, v: Value) anyerror!Value {
    const key = ks[0];
    if (ks.len == 1) {
        // ベースケース: (assoc m key v)
        const assoc_args = [_]Value{ m, key, v };
        return assoc(allocator, &assoc_args);
    }

    // 再帰: (assoc m key (assoc-in (get m key) rest-keys v))
    const get_args = [_]Value{ m, key };
    const inner = try get(allocator, &get_args);
    const nested = try assocInHelper(allocator, inner, ks[1..], v);
    const assoc_args = [_]Value{ m, key, nested };
    return assoc(allocator, &assoc_args);
}

/// select-keys : 指定キーのみ残す
/// (select-keys m ks)
pub fn selectKeys(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;

    const coll = args[0];
    if (coll == .nil) return Value{ .map = try allocator.create(value_mod.PersistentMap) };
    if (coll != .map) return error.TypeError;

    const ks = switch (args[1]) {
        .vector => |v| v.items,
        .list => |l| l.items,
        .nil => &[_]Value{},
        else => return error.TypeError,
    };

    // 結果マップを構築
    var entries_buf: std.ArrayListUnmanaged(Value) = .empty;
    for (ks) |key| {
        if (coll.map.get(key)) |val| {
            entries_buf.append(allocator, key) catch return error.OutOfMemory;
            entries_buf.append(allocator, val) catch return error.OutOfMemory;
        }
    }

    const new_map = try allocator.create(value_mod.PersistentMap);
    new_map.* = .{ .entries = entries_buf.toOwnedSlice(allocator) catch return error.OutOfMemory };

    if (coll == .nil) {
        new_map.* = .{ .entries = &[_]Value{} };
    }

    return Value{ .map = new_map };
}

/// zipmap : 2つのシーケンスからマップ作成
/// (zipmap keys vals)
pub fn zipmap(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;

    const keys_items = getItems(args[0]) orelse return error.TypeError;
    const vals_items = getItems(args[1]) orelse return error.TypeError;

    const len = @min(keys_items.len, vals_items.len);
    const entries = try allocator.alloc(Value, len * 2);
    for (0..len) |i| {
        entries[i * 2] = keys_items[i];
        entries[i * 2 + 1] = vals_items[i];
    }

    const new_map = try allocator.create(value_mod.PersistentMap);
    new_map.* = .{ .entries = entries };
    return Value{ .map = new_map };
}

/// not-empty : 空なら nil、そうでなければ coll
/// (not-empty coll)
pub fn notEmpty(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    const coll = args[0];
    return switch (coll) {
        .nil => value_mod.nil,
        .list => |l| if (l.items.len == 0) value_mod.nil else coll,
        .vector => |v| if (v.items.len == 0) value_mod.nil else coll,
        .map => |m| if (m.entries.len == 0) value_mod.nil else coll,
        .set => |s| if (s.items.len == 0) value_mod.nil else coll,
        .string => |s| if (s.data.len == 0) value_mod.nil else coll,
        else => coll,
    };
}

/// type : 型名を文字列で返す
/// (type x)
pub fn typeFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    const type_name: []const u8 = switch (args[0]) {
        .nil => "nil",
        .bool_val => "boolean",
        .int => "integer",
        .float => "float",
        .char_val => "char",
        .string => "string",
        .keyword => "keyword",
        .symbol => "symbol",
        .list => "list",
        .vector => "vector",
        .map => "map",
        .set => "set",
        .fn_val => "function",
        .partial_fn => "function",
        .comp_fn => "function",
        .multi_fn => "multimethod",
        .protocol => "protocol",
        .protocol_fn => "function",
        .fn_proto => "function",
        .var_val => "var",
        .atom => "atom",
        .lazy_seq => "lazy-seq",
        .delay_val => "delay",
        .volatile_val => "volatile",
        .reduced_val => "reduced",
        .transient => "transient",
        .promise => "promise",
        .regex => "regex",
        .matcher => "matcher",
    };

    const str = try allocator.create(value_mod.String);
    str.* = value_mod.String.init(type_name);
    return Value{ .string = str };
}

// ============================================================
// Phase 8.19: シーケンス関数・ユーティリティ追加
// ============================================================

/// second : コレクションの2番目の要素
pub fn second(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .nil => value_mod.nil,
        .list => |l| if (l.items.len > 1) l.items[1] else value_mod.nil,
        .vector => |v| if (v.items.len > 1) v.items[1] else value_mod.nil,
        else => error.TypeError,
    };
}

/// last : コレクションの最後の要素
pub fn last(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;
    return if (items.len > 0) items[items.len - 1] else value_mod.nil;
}

/// butlast : 最後の要素を除いたシーケンス
pub fn butlast(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;
    if (items.len <= 1) return value_mod.nil;
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = try allocator.dupe(Value, items[0 .. items.len - 1]) };
    return Value{ .list = result };
}

/// next : rest と同じだが、空なら nil を返す
pub fn next(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;
    if (items.len <= 1) return value_mod.nil;
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = try allocator.dupe(Value, items[1..]) };
    return Value{ .list = result };
}

/// ffirst : (first (first coll))
pub fn ffirst(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const outer = switch (args[0]) {
        .nil => return value_mod.nil,
        .list => |l| if (l.items.len > 0) l.items[0] else return value_mod.nil,
        .vector => |v| if (v.items.len > 0) v.items[0] else return value_mod.nil,
        else => return error.TypeError,
    };
    return switch (outer) {
        .nil => value_mod.nil,
        .list => |l| if (l.items.len > 0) l.items[0] else value_mod.nil,
        .vector => |v| if (v.items.len > 0) v.items[0] else value_mod.nil,
        else => error.TypeError,
    };
}

/// fnext : (first (next coll))
pub fn fnext(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;
    if (items.len < 2) return value_mod.nil;
    return items[1];
}

/// nfirst : (next (first coll))
pub fn nfirst(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const outer = switch (args[0]) {
        .nil => return value_mod.nil,
        .list => |l| if (l.items.len > 0) l.items[0] else return value_mod.nil,
        .vector => |v| if (v.items.len > 0) v.items[0] else return value_mod.nil,
        else => return error.TypeError,
    };
    const inner_items = getItems(outer) orelse return error.TypeError;
    if (inner_items.len <= 1) return value_mod.nil;
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = try allocator.dupe(Value, inner_items[1..]) };
    return Value{ .list = result };
}

/// nnext : (next (next coll))
pub fn nnext(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;
    if (items.len <= 2) return value_mod.nil;
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = try allocator.dupe(Value, items[2..]) };
    return Value{ .list = result };
}

/// interleave : 複数コレクションの要素を交互に配置
/// (interleave [1 2 3] [:a :b :c]) => (1 :a 2 :b 3 :c)
pub fn interleave(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;

    // 各コレクションの要素を取得
    var colls = allocator.alloc([]const Value, args.len) catch return error.OutOfMemory;
    var min_len: usize = std.math.maxInt(usize);
    for (args, 0..) |arg, i| {
        colls[i] = getItems(arg) orelse return error.TypeError;
        min_len = @min(min_len, colls[i].len);
    }

    const result_len = min_len * args.len;
    const result_items = try allocator.alloc(Value, result_len);
    for (0..min_len) |i| {
        for (0..args.len) |c| {
            result_items[i * args.len + c] = colls[c][i];
        }
    }

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = result_items };
    return Value{ .list = result };
}

/// interpose : 要素間にセパレータを挿入
/// (interpose :x [1 2 3]) => (1 :x 2 :x 3)
pub fn interpose(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const sep = args[0];
    const items = getItems(args[1]) orelse return error.TypeError;
    if (items.len == 0) {
        const result = try allocator.create(value_mod.PersistentList);
        result.* = .{ .items = &[_]Value{} };
        return Value{ .list = result };
    }
    const result_len = items.len * 2 - 1;
    const result_items = try allocator.alloc(Value, result_len);
    for (items, 0..) |item, i| {
        result_items[i * 2] = item;
        if (i + 1 < items.len) {
            result_items[i * 2 + 1] = sep;
        }
    }
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = result_items };
    return Value{ .list = result };
}

/// frequencies : 各要素の出現回数をマップで返す
/// (frequencies [1 1 2 3 2 1]) => {1 3, 2 2, 3 1}
pub fn frequencies(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;

    // 要素をカウント（順序保持のため配列ベースで）
    var keys_buf: std.ArrayListUnmanaged(Value) = .empty;
    var counts_buf: std.ArrayListUnmanaged(i64) = .empty;

    for (items) |item| {
        var found = false;
        for (keys_buf.items, 0..) |key, i| {
            if (item.eql(key)) {
                counts_buf.items[i] += 1;
                found = true;
                break;
            }
        }
        if (!found) {
            keys_buf.append(allocator, item) catch return error.OutOfMemory;
            counts_buf.append(allocator, 1) catch return error.OutOfMemory;
        }
    }

    // マップに変換
    const entries = try allocator.alloc(Value, keys_buf.items.len * 2);
    for (keys_buf.items, 0..) |key, i| {
        entries[i * 2] = key;
        entries[i * 2 + 1] = value_mod.intVal(counts_buf.items[i]);
    }

    const result = try allocator.create(value_mod.PersistentMap);
    result.* = .{ .entries = entries };
    return Value{ .map = result };
}

/// partition : n 個ずつのグループに分割
/// (partition 2 [1 2 3 4 5]) => ((1 2) (3 4))
/// (partition 2 1 [1 2 3 4 5]) => ((1 2) (2 3) (3 4) (4 5))
pub fn partition(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;

    if (args[0] != .int) return error.TypeError;
    const n: usize = if (args[0].int <= 0) return error.TypeError else @intCast(args[0].int);

    var step: usize = n;
    var coll_idx: usize = 1;
    if (args.len == 3) {
        if (args[1] != .int) return error.TypeError;
        step = if (args[1].int <= 0) return error.TypeError else @intCast(args[1].int);
        coll_idx = 2;
    }

    const items = getItems(args[coll_idx]) orelse return error.TypeError;

    var groups: std.ArrayListUnmanaged(Value) = .empty;
    var i: usize = 0;
    while (i + n <= items.len) : (i += step) {
        const group_items = try allocator.dupe(Value, items[i .. i + n]);
        const group = try allocator.create(value_mod.PersistentList);
        group.* = .{ .items = group_items };
        groups.append(allocator, Value{ .list = group }) catch return error.OutOfMemory;
    }

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = groups.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return Value{ .list = result };
}

/// partition-all : partition と同じだが、末尾の不完全なグループも含む
/// (partition-all 2 [1 2 3 4 5]) => ((1 2) (3 4) (5))
pub fn partitionAll(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;

    if (args[0] != .int) return error.TypeError;
    const n: usize = if (args[0].int <= 0) return error.TypeError else @intCast(args[0].int);

    var step: usize = n;
    var coll_idx: usize = 1;
    if (args.len == 3) {
        if (args[1] != .int) return error.TypeError;
        step = if (args[1].int <= 0) return error.TypeError else @intCast(args[1].int);
        coll_idx = 2;
    }

    const items = getItems(args[coll_idx]) orelse return error.TypeError;

    var groups: std.ArrayListUnmanaged(Value) = .empty;
    var i: usize = 0;
    while (i < items.len) : (i += step) {
        const end = @min(i + n, items.len);
        const group_items = try allocator.dupe(Value, items[i..end]);
        const group = try allocator.create(value_mod.PersistentList);
        group.* = .{ .items = group_items };
        groups.append(allocator, Value{ .list = group }) catch return error.OutOfMemory;
    }

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = groups.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return Value{ .list = result };
}

/// set : コレクションをセットに変換
/// (set [1 2 2 3]) => #{1 2 3}
pub fn setFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;

    // 重複除去
    var unique: std.ArrayListUnmanaged(Value) = .empty;
    for (items) |item| {
        var found = false;
        for (unique.items) |existing| {
            if (item.eql(existing)) {
                found = true;
                break;
            }
        }
        if (!found) {
            unique.append(allocator, item) catch return error.OutOfMemory;
        }
    }

    const result = try allocator.create(value_mod.PersistentSet);
    result.* = .{ .items = unique.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return Value{ .set = result };
}

/// disj : セットから要素を削除
/// (disj #{1 2 3} 2) => #{1 3}
pub fn disjFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (args[0] != .set) return error.TypeError;
    const s = args[0].set;

    var result_items: std.ArrayListUnmanaged(Value) = .empty;
    for (s.items) |item| {
        var remove = false;
        for (args[1..]) |to_remove| {
            if (item.eql(to_remove)) {
                remove = true;
                break;
            }
        }
        if (!remove) {
            result_items.append(allocator, item) catch return error.OutOfMemory;
        }
    }

    const result = try allocator.create(value_mod.PersistentSet);
    result.* = .{ .items = result_items.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return Value{ .set = result };
}

/// find : マップからキーに対応するエントリ [key val] を返す
/// (find {:a 1 :b 2} :a) => [:a 1]
pub fn findFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .map) return error.TypeError;
    const m = args[0].map;
    const key = args[1];

    var i: usize = 0;
    while (i < m.entries.len) : (i += 2) {
        if (key.eql(m.entries[i])) {
            const pair = try allocator.alloc(Value, 2);
            pair[0] = m.entries[i];
            pair[1] = m.entries[i + 1];
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = .{ .items = pair };
            return Value{ .vector = result };
        }
    }
    return value_mod.nil;
}

/// update : マップの値を関数で更新
/// (update {:a 1} :a inc) => {:a 2}
/// ※ これは組み込み関数版（マクロ版 expandUpdate もある）
/// ※ 関数呼び出しが必要なため、analyzerでspecial node化されている

/// replace : コレクション内の値をマップで置換
/// (replace {:a 1 :b 2} [:a :b :c :a]) => [1 2 :c 1]
pub fn replaceFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .map) return error.TypeError;
    const smap = args[0].map;
    const items = getItems(args[1]) orelse return error.TypeError;

    const result_items = try allocator.alloc(Value, items.len);
    for (items, 0..) |item, i| {
        if (smap.get(item)) |replacement| {
            result_items[i] = replacement;
        } else {
            result_items[i] = item;
        }
    }

    // 入力の型を保持
    return switch (args[1]) {
        .vector => blk: {
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = .{ .items = result_items };
            break :blk Value{ .vector = result };
        },
        else => blk: {
            const result = try allocator.create(value_mod.PersistentList);
            result.* = .{ .items = result_items };
            break :blk Value{ .list = result };
        },
    };
}

/// sort : コレクションを数値またはデフォルト順でソート
/// (sort [3 1 2]) => (1 2 3)
pub fn sortFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;
    if (items.len == 0) {
        const result = try allocator.create(value_mod.PersistentList);
        result.* = .{ .items = &[_]Value{} };
        return Value{ .list = result };
    }

    const sorted = try allocator.dupe(Value, items);
    std.mem.sort(Value, sorted, {}, valueLessThan);

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = sorted };
    return Value{ .list = result };
}

/// 値の比較関数（sort用）
fn valueLessThan(_: void, a: Value, b: Value) bool {
    // 数値比較
    if (a == .int and b == .int) return a.int < b.int;
    if (a == .float and b == .float) return a.float < b.float;
    if (a == .int and b == .float) return @as(f64, @floatFromInt(a.int)) < b.float;
    if (a == .float and b == .int) return a.float < @as(f64, @floatFromInt(b.int));
    // 文字列比較
    if (a == .string and b == .string) {
        return std.mem.order(u8, a.string.data, b.string.data) == .lt;
    }
    // キーワード比較
    if (a == .keyword and b == .keyword) {
        return std.mem.order(u8, a.keyword.name, b.keyword.name) == .lt;
    }
    return false;
}

/// distinct? : 全要素が異なるかどうか
/// (distinct? 1 2 3) => true
pub fn isDistinctValues(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1) return error.ArityError;
    for (args, 0..) |a, i| {
        for (args[i + 1 ..]) |b| {
            if (a.eql(b)) return value_mod.false_val;
        }
    }
    return value_mod.true_val;
}

/// rand : 0.0〜1.0 の乱数を返す
/// (rand) => 0.123...
/// (rand n) => 0〜n の乱数
pub fn randFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len > 1) return error.ArityError;
    // 簡易的な疑似乱数（Zig標準のRNGを使用）
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();
    const val = random.float(f64);
    if (args.len == 1) {
        return switch (args[0]) {
            .int => |n| Value{ .float = val * @as(f64, @floatFromInt(n)) },
            .float => |f| Value{ .float = val * f },
            else => error.TypeError,
        };
    }
    return Value{ .float = val };
}

/// rand-int : 0〜n の整数乱数
/// (rand-int 10) => 0-9
pub fn randInt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    if (args[0] != .int) return error.TypeError;
    const n = args[0].int;
    if (n <= 0) return error.TypeError;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();
    const val = random.intRangeLessThan(i64, 0, n);
    return value_mod.intVal(val);
}

/// boolean : 値を真偽値に変換
/// (boolean nil) => false, (boolean 0) => true
pub fn booleanFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0].isTruthy()) value_mod.true_val else value_mod.false_val;
}

/// true? : true かどうか
pub fn isTrue(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .bool_val and args[0].bool_val) value_mod.true_val else value_mod.false_val;
}

/// false? : false かどうか
pub fn isFalse(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .bool_val and !args[0].bool_val) value_mod.true_val else value_mod.false_val;
}

/// int : 値を整数に変換
pub fn intFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => args[0],
        .float => |f| value_mod.intVal(@intFromFloat(f)),
        else => error.TypeError,
    };
}

/// double : 値を浮動小数点に変換
pub fn doubleFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .float => args[0],
        .int => |n| Value{ .float = @floatFromInt(n) },
        else => error.TypeError,
    };
}

/// rem : 剰余（Java 互換）
pub fn remFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] == .int and args[1] == .int) {
        if (args[1].int == 0) return error.DivisionByZero;
        return value_mod.intVal(@rem(args[0].int, args[1].int));
    }
    return error.TypeError;
}

/// quot : 整数除算
pub fn quotFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] == .int and args[1] == .int) {
        if (args[1].int == 0) return error.DivisionByZero;
        return value_mod.intVal(@divTrunc(args[0].int, args[1].int));
    }
    return error.TypeError;
}

/// bit-and, bit-or, bit-xor, bit-not, bit-shift-left, bit-shift-right
pub fn bitAnd(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    return value_mod.intVal(args[0].int & args[1].int);
}

pub fn bitOr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    return value_mod.intVal(args[0].int | args[1].int);
}

pub fn bitXor(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    return value_mod.intVal(args[0].int ^ args[1].int);
}

pub fn bitNot(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    if (args[0] != .int) return error.TypeError;
    return value_mod.intVal(~args[0].int);
}

pub fn bitShiftLeft(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const shift: u6 = @intCast(@min(@max(args[1].int, 0), 63));
    return value_mod.intVal(args[0].int << shift);
}

pub fn bitShiftRight(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const shift: u6 = @intCast(@min(@max(args[1].int, 0), 63));
    return value_mod.intVal(args[0].int >> shift);
}

/// keyword : 文字列/シンボルからキーワードを作成
pub fn keywordFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;
    if (args.len == 1) {
        return switch (args[0]) {
            .keyword => args[0],
            .string => |s| blk: {
                const kw = try allocator.create(value_mod.Keyword);
                kw.* = .{ .name = s.data, .namespace = null };
                break :blk Value{ .keyword = kw };
            },
            .symbol => |sym| blk: {
                const kw = try allocator.create(value_mod.Keyword);
                kw.* = .{ .name = sym.name, .namespace = sym.namespace };
                break :blk Value{ .keyword = kw };
            },
            else => error.TypeError,
        };
    }
    // (keyword ns name) — 2引数: 名前空間付きキーワード作成
    const ns_str = if (args[0] == .string) args[0].string.data else if (args[0] == .nil) null else return error.TypeError;
    if (args[1] != .string) return error.TypeError;
    const kw = try allocator.create(value_mod.Keyword);
    kw.* = .{ .name = args[1].string.data, .namespace = ns_str };
    return Value{ .keyword = kw };
}

/// symbol : 文字列からシンボルを作成
pub fn symbolFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;
    if (args.len == 1) {
        return switch (args[0]) {
            .symbol => args[0],
            .string => |s| blk: {
                const sym = try allocator.create(value_mod.Symbol);
                sym.* = .{ .name = s.data, .namespace = null };
                break :blk Value{ .symbol = sym };
            },
            .keyword => |kw| blk: {
                const sym = try allocator.create(value_mod.Symbol);
                sym.* = .{ .name = kw.name, .namespace = kw.namespace };
                break :blk Value{ .symbol = sym };
            },
            else => error.TypeError,
        };
    }
    // (symbol ns name)
    if (args[0] != .string or args[1] != .string) return error.TypeError;
    const sym = try allocator.create(value_mod.Symbol);
    sym.* = .{ .name = args[1].string.data, .namespace = args[0].string.data };
    return Value{ .symbol = sym };
}

/// update-in : ネストしたキーパスの値を関数で更新（関数呼び出し不要版 — 単純な assoc-in に委譲）
/// ※ 実際の update-in は関数呼び出しが必要なため HOF として実装する必要がある
/// ここでは get-in + assoc-in パターンで近似できない

/// merge-with : 重複キーを関数で結合
/// ※ 関数呼び出しが必要なため HOF — 将来実装

/// split-at : (split-at n coll) => [(take n coll) (drop n coll)]
pub fn splitAt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int) return error.TypeError;
    const n_raw = args[0].int;
    const n: usize = if (n_raw < 0) 0 else @intCast(n_raw);
    const items = getItems(args[1]) orelse return error.TypeError;
    const split = @min(n, items.len);

    const left = try allocator.create(value_mod.PersistentList);
    left.* = .{ .items = try allocator.dupe(Value, items[0..split]) };
    const right = try allocator.create(value_mod.PersistentList);
    right.* = .{ .items = try allocator.dupe(Value, items[split..]) };

    const pair = try allocator.alloc(Value, 2);
    pair[0] = Value{ .list = left };
    pair[1] = Value{ .list = right };
    const result = try allocator.create(value_mod.PersistentVector);
    result.* = .{ .items = pair };
    return Value{ .vector = result };
}

/// split-with : 述語で分割 — HOF なので将来実装

/// take-last : 末尾 n 個
pub fn takeLast(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int) return error.TypeError;
    const n_raw = args[0].int;
    const n: usize = if (n_raw < 0) 0 else @intCast(n_raw);
    const items = getItems(args[1]) orelse return error.TypeError;
    const start = if (n >= items.len) 0 else items.len - n;
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = try allocator.dupe(Value, items[start..]) };
    return Value{ .list = result };
}

/// drop-last : 末尾 n 個を除く（デフォルト n=1）
pub fn dropLast(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;
    var n: usize = 1;
    var coll_idx: usize = 0;
    if (args.len == 2) {
        if (args[0] != .int) return error.TypeError;
        n = if (args[0].int < 0) 0 else @intCast(args[0].int);
        coll_idx = 1;
    }
    const items = getItems(args[coll_idx]) orelse return error.TypeError;
    const end = if (n >= items.len) 0 else items.len - n;
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = try allocator.dupe(Value, items[0..end]) };
    return Value{ .list = result };
}

/// take-nth : n 個おきに要素を取得
/// (take-nth 2 [1 2 3 4 5]) => (1 3 5)
pub fn takeNth(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int) return error.TypeError;
    const n: usize = if (args[0].int <= 0) return error.TypeError else @intCast(args[0].int);
    const items = getItems(args[1]) orelse return error.TypeError;

    var result_buf: std.ArrayListUnmanaged(Value) = .empty;
    var i: usize = 0;
    while (i < items.len) : (i += n) {
        result_buf.append(allocator, items[i]) catch return error.OutOfMemory;
    }
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = result_buf.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return Value{ .list = result };
}

/// shuffle : コレクションの要素をランダムに並べ替え
pub fn shuffle(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;
    const result_items = try allocator.dupe(Value, items);

    // Fisher-Yates シャッフル
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();

    var i: usize = result_items.len;
    while (i > 1) {
        i -= 1;
        const j = random.intRangeLessThan(usize, 0, i + 1);
        const tmp = result_items[i];
        result_items[i] = result_items[j];
        result_items[j] = tmp;
    }

    const result = try allocator.create(value_mod.PersistentVector);
    result.* = .{ .items = result_items };
    return Value{ .vector = result };
}

/// subvec : ベクタの部分を取得
/// (subvec [1 2 3 4 5] 1 3) => [2 3]
pub fn subvec(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    if (args[0] != .vector) return error.TypeError;
    if (args[1] != .int) return error.TypeError;
    const v = args[0].vector;
    const start: usize = if (args[1].int < 0) return error.TypeError else @intCast(args[1].int);
    const end: usize = if (args.len == 3) blk: {
        if (args[2] != .int) return error.TypeError;
        break :blk if (args[2].int < 0) return error.TypeError else @intCast(args[2].int);
    } else v.items.len;

    if (start > end or end > v.items.len) return error.TypeError;
    const result = try allocator.create(value_mod.PersistentVector);
    result.* = .{ .items = try allocator.dupe(Value, v.items[start..end]) };
    return Value{ .vector = result };
}

/// peek : コレクションの先頭/末尾を取得（型による）
/// list → first, vector → last
pub fn peek(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .nil => value_mod.nil,
        .list => |l| if (l.items.len > 0) l.items[0] else value_mod.nil,
        .vector => |v| if (v.items.len > 0) v.items[v.items.len - 1] else value_mod.nil,
        else => error.TypeError,
    };
}

/// pop : コレクションの先頭/末尾を除去（型による）
/// list → rest, vector → butlast
pub fn pop(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .list => |l| blk: {
            if (l.items.len == 0) return error.TypeError;
            const result = try allocator.create(value_mod.PersistentList);
            result.* = .{ .items = try allocator.dupe(Value, l.items[1..]) };
            break :blk Value{ .list = result };
        },
        .vector => |v| blk: {
            if (v.items.len == 0) return error.TypeError;
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = .{ .items = try allocator.dupe(Value, v.items[0 .. v.items.len - 1]) };
            break :blk Value{ .vector = result };
        },
        else => error.TypeError,
    };
}

/// hash : 値のハッシュを返す
pub fn hashFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    // 簡易ハッシュ（型タグベース）
    const h: i64 = switch (args[0]) {
        .nil => 0,
        .bool_val => |b| if (b) @as(i64, 1231) else @as(i64, 1237),
        .int => |n| n,
        .float => |f| @as(i64, @intFromFloat(f * 1000000)),
        .string => |s| blk: {
            var hash_val: i64 = 0;
            for (s.data) |c| {
                hash_val = hash_val *% 31 +% @as(i64, c);
            }
            break :blk hash_val;
        },
        .keyword => |kw| blk: {
            var hash_val: i64 = 0;
            for (kw.name) |c| {
                hash_val = hash_val *% 31 +% @as(i64, c);
            }
            break :blk hash_val;
        },
        else => 42,
    };
    return value_mod.intVal(h);
}

/// seq? : シーケンスかどうか（list のみ）
pub fn isSeq(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .list => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// seqable? : シーケンスにできるかどうか
pub fn isSeqable(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .nil, .list, .vector, .map, .set, .string => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// sequential? : 順序付きコレクションかどうか
pub fn isSequential(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .list, .vector => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// associative? : 連想コレクションかどうか
pub fn isAssociative(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .map, .vector => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// counted? : 要素数を O(1) で取得可能かどうか
pub fn isCounted(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .list, .vector, .map, .set => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// reversible? : reverse 可能かどうか
pub fn isReversible(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .vector => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// sorted? : ソート済みかどうか（常に false — sorted-set/sorted-map 未実装）
pub fn isSorted(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

// === Phase 11: PURE 述語バッチ ===

/// any? : 常に true を返す（任意の値に対して true）
pub fn isAny(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.true_val;
}

/// boolean? : 真偽値かどうか
pub fn isBoolean(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .bool_val) value_mod.true_val else value_mod.false_val;
}

/// int? : 整数かどうか（integer? と同じ）
pub fn isInt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .int) value_mod.true_val else value_mod.false_val;
}

/// double? : 浮動小数点かどうか（float? と同じ）
pub fn isDouble(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .float) value_mod.true_val else value_mod.false_val;
}

/// char? : 文字かどうか
pub fn isChar(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .char_val) value_mod.true_val else value_mod.false_val;
}

/// ident? : 識別子（キーワードまたはシンボル）かどうか
pub fn isIdent(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .keyword, .symbol => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// simple-ident? : 名前空間なしの識別子かどうか
pub fn isSimpleIdent(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .keyword => |k| if (k.namespace == null) value_mod.true_val else value_mod.false_val,
        .symbol => |s| if (s.namespace == null) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// simple-keyword? : 名前空間なしのキーワードかどうか
pub fn isSimpleKeyword(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .keyword => |k| if (k.namespace == null) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// simple-symbol? : 名前空間なしのシンボルかどうか
pub fn isSimpleSymbol(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .symbol => |s| if (s.namespace == null) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// qualified-ident? : 名前空間付きの識別子かどうか
pub fn isQualifiedIdent(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .keyword => |k| if (k.namespace != null) value_mod.true_val else value_mod.false_val,
        .symbol => |s| if (s.namespace != null) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// qualified-keyword? : 名前空間付きのキーワードかどうか
pub fn isQualifiedKeyword(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .keyword => |k| if (k.namespace != null) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// qualified-symbol? : 名前空間付きのシンボルかどうか
pub fn isQualifiedSymbol(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .symbol => |s| if (s.namespace != null) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// indexed? : インデックスアクセス可能かどうか（vector）
pub fn isIndexed(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .vector) value_mod.true_val else value_mod.false_val;
}

/// ifn? : 関数として呼び出し可能かどうか
pub fn isIFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .fn_val, .partial_fn, .comp_fn, .multi_fn, .protocol_fn,
        .keyword, .symbol, .vector, .map, .set,
        => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// identical? : 参照同一性（同一オブジェクト）かどうか
pub fn isIdentical(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const a = args[0];
    const b = args[1];
    // タグが異なれば false
    const a_tag = std.meta.activeTag(a);
    const b_tag = std.meta.activeTag(b);
    if (a_tag != b_tag) return value_mod.false_val;
    // 値型はビット一致で判定
    return switch (a) {
        .nil => value_mod.true_val,
        .bool_val => |av| if (av == b.bool_val) value_mod.true_val else value_mod.false_val,
        .int => |av| if (av == b.int) value_mod.true_val else value_mod.false_val,
        .float => |av| if (av == b.float) value_mod.true_val else value_mod.false_val,
        .char_val => |av| if (av == b.char_val) value_mod.true_val else value_mod.false_val,
        // ポインタ型はポインタ比較
        .string => |av| if (av == b.string) value_mod.true_val else value_mod.false_val,
        .keyword => |av| blk: {
            // キーワードは Clojure では intern されるため名前比較で identical? = true
            const bk = b.keyword;
            const name_eq = std.mem.eql(u8, av.name, bk.name);
            const ns_eq = if (av.namespace) |ans|
                (if (bk.namespace) |bns| std.mem.eql(u8, ans, bns) else false)
            else
                bk.namespace == null;
            break :blk if (name_eq and ns_eq) value_mod.true_val else value_mod.false_val;
        },
        .symbol => |av| if (av == b.symbol) value_mod.true_val else value_mod.false_val,
        .list => |av| if (av == b.list) value_mod.true_val else value_mod.false_val,
        .vector => |av| if (av == b.vector) value_mod.true_val else value_mod.false_val,
        .map => |av| if (av == b.map) value_mod.true_val else value_mod.false_val,
        .set => |av| if (av == b.set) value_mod.true_val else value_mod.false_val,
        .fn_val => |av| if (av == b.fn_val) value_mod.true_val else value_mod.false_val,
        .atom => |av| if (av == b.atom) value_mod.true_val else value_mod.false_val,
        .lazy_seq => |av| if (av == b.lazy_seq) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// NaN? : NaN かどうか
pub fn isNaN(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .float => |f| if (std.math.isNan(f)) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// infinite? : 無限大かどうか
pub fn isInfinite(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .float => |f| if (std.math.isInf(f)) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// nat-int? : 非負整数（0以上の整数）かどうか
pub fn isNatInt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |i| if (i >= 0) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// neg-int? : 負の整数かどうか
pub fn isNegInt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |i| if (i < 0) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// pos-int? : 正の整数（1以上）かどうか
pub fn isPosInt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |i| if (i > 0) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// special-symbol? : 特殊形式のシンボルかどうか
pub fn isSpecialSymbol(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .symbol => |s| {
            if (s.namespace != null) return value_mod.false_val;
            const name = s.name;
            // Clojure の特殊形式一覧
            const specials = [_][]const u8{
                "def", "if", "do", "let*", "fn*", "quote", "var",
                "loop*", "recur", "throw", "try", "catch", "finally",
                "monitor-enter", "monitor-exit", "new", "set!", ".",
                "&", "deftype*", "reify*", "case*", "import*",
                "letfn*",
            };
            for (specials) |sp| {
                if (std.mem.eql(u8, name, sp)) return value_mod.true_val;
            }
            return value_mod.false_val;
        },
        else => value_mod.false_val,
    };
}

/// var? : Var かどうか
pub fn isVar(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .var_val) value_mod.true_val else value_mod.false_val;
}

/// map-entry? : マップエントリ（2要素ベクタ）かどうか
pub fn isMapEntry(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .vector => |v| if (v.items.len == 2) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

// === Phase 11 追加: PURE コレクション/ユーティリティ ===

/// key : マップエントリのキーを返す（2要素ベクタの first）
pub fn keyFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .vector => |v| if (v.items.len >= 1) v.items[0] else error.TypeError,
        else => error.TypeError,
    };
}

/// val : マップエントリの値を返す（2要素ベクタの second）
pub fn valFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .vector => |v| if (v.items.len >= 2) v.items[1] else error.TypeError,
        else => error.TypeError,
    };
}

/// array-map : キーと値のペアからマップを作成（hash-map と同じ）
pub fn arrayMap(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len % 2 != 0) return error.ArityError;
    const new_map = try allocator.create(value_mod.PersistentMap);
    new_map.* = value_mod.PersistentMap.empty();
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        new_map.* = try new_map.assoc(allocator, args[i], args[i + 1]);
    }
    return Value{ .map = new_map };
}

/// hash-set : 要素からセットを作成
pub fn hashSet(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    var new_set = value_mod.PersistentSet.empty();
    for (args) |item| {
        new_set = try new_set.conj(allocator, item);
    }
    const set_ptr = try allocator.create(value_mod.PersistentSet);
    set_ptr.* = new_set;
    return Value{ .set = set_ptr };
}

/// list* : 最後の引数をシーケンスとして展開した list を返す
/// (list* 1 2 [3 4]) → (1 2 3 4)
pub fn listStar(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    if (args.len == 1) {
        // (list* coll) → (seq coll)
        return seq(allocator, args);
    }

    var items: std.ArrayListUnmanaged(Value) = .empty;
    // 先頭 n-1 個の引数を追加
    for (args[0 .. args.len - 1]) |arg| {
        items.append(allocator, arg) catch return error.OutOfMemory;
    }
    // 最後の引数をシーケンスとして展開
    const last_arg = args[args.len - 1];
    const tail_items = (try getItemsRealized(allocator, last_arg)) orelse &[_]Value{};
    for (tail_items) |item| {
        items.append(allocator, item) catch return error.OutOfMemory;
    }

    if (items.items.len == 0) return value_mod.nil;
    const result = try value_mod.PersistentList.fromSlice(allocator, items.items);
    return Value{ .list = result };
}

/// remove : filter の否定版（述語が false の要素を返す）
pub fn removeFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const pred = args[0];
    const coll = args[1];
    const call = call_fn orelse return error.TypeError;

    const items = (try getItemsRealized(allocator, coll)) orelse return error.TypeError;
    var result: std.ArrayListUnmanaged(Value) = .empty;
    for (items) |item| {
        const call_args = [_]Value{item};
        const r = try call(pred, &call_args, allocator);
        if (!r.isTruthy()) {
            result.append(allocator, item) catch return error.OutOfMemory;
        }
    }

    if (result.items.len == 0) return value_mod.nil;
    const list_ptr = try value_mod.PersistentList.fromSlice(allocator, result.items);
    return Value{ .list = list_ptr };
}

/// nthnext : (drop n coll) して seq を返す
pub fn nthnext(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const n = switch (args[1]) {
        .int => |i| i,
        else => return error.TypeError,
    };
    if (n < 0) return error.TypeError;

    const items = (try getItemsRealized(allocator, args[0])) orelse return error.TypeError;
    const idx: usize = @intCast(n);
    if (idx >= items.len) return value_mod.nil;

    const remaining = items[idx..];
    if (remaining.len == 0) return value_mod.nil;
    const list_ptr = try value_mod.PersistentList.fromSlice(allocator, remaining);
    return Value{ .list = list_ptr };
}

/// nthrest : (drop n coll) して空でも () を返す
pub fn nthrest(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const n = switch (args[1]) {
        .int => |i| i,
        else => return error.TypeError,
    };
    if (n < 0) return error.TypeError;

    const items = (try getItemsRealized(allocator, args[0])) orelse return error.TypeError;
    const idx: usize = @intCast(n);
    const remaining = if (idx >= items.len) &[_]Value{} else items[idx..];

    const list_ptr = try value_mod.PersistentList.fromSlice(allocator, remaining);
    return Value{ .list = list_ptr };
}

/// reduce-kv : マップを k,v ペアでリデュース
/// (reduce-kv f init coll)
pub fn reduceKv(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const f = args[0];
    var acc = args[1];
    const coll = args[2];
    const call = call_fn orelse return error.TypeError;

    switch (coll) {
        .map => |m| {
            var i: usize = 0;
            while (i < m.entries.len) : (i += 2) {
                const call_args = [_]Value{ acc, m.entries[i], m.entries[i + 1] };
                acc = try call(f, &call_args, allocator);
                if (acc == .reduced_val) return acc.reduced_val.value;
            }
        },
        .vector => |v| {
            for (v.items, 0..) |item, i| {
                const call_args = [_]Value{ acc, value_mod.intVal(@intCast(i)), item };
                acc = try call(f, &call_args, allocator);
                if (acc == .reduced_val) return acc.reduced_val.value;
            }
        },
        .nil => {},
        else => return error.TypeError,
    }
    return acc;
}

/// merge-with : 衝突時に関数で結合する merge
/// (merge-with f & maps)
pub fn mergeWith(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    const f = args[0];
    const maps = args[1..];
    const call = call_fn orelse return error.TypeError;

    if (maps.len == 0) return value_mod.nil;

    // 最初の非nil マップを見つける
    var current: ?value_mod.PersistentMap = null;
    var start_idx: usize = 0;
    for (maps, 0..) |m, i| {
        switch (m) {
            .nil => continue,
            .map => |mp| {
                current = mp.*;
                start_idx = i + 1;
                break;
            },
            else => return error.TypeError,
        }
    }

    if (current == null) return value_mod.nil;

    for (maps[start_idx..]) |m| {
        switch (m) {
            .nil => continue,
            .map => |mp| {
                var j: usize = 0;
                while (j < mp.entries.len) : (j += 2) {
                    const k = mp.entries[j];
                    const new_v = mp.entries[j + 1];
                    if (current.?.get(k)) |old_v| {
                        // 衝突: f を適用
                        const call_args = [_]Value{ old_v, new_v };
                        const merged_v = try call(f, &call_args, allocator);
                        current = try current.?.assoc(allocator, k, merged_v);
                    } else {
                        current = try current.?.assoc(allocator, k, new_v);
                    }
                }
            },
            else => return error.TypeError,
        }
    }

    const new_map = try allocator.create(value_mod.PersistentMap);
    new_map.* = current.?;
    return Value{ .map = new_map };
}

/// update-in : ネストされたキーパスの値を関数で更新
/// (update-in m ks f & args)
pub fn updateIn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 3) return error.ArityError;
    const m = args[0];
    const ks = switch (args[1]) {
        .vector => |v| v.items,
        .list => |l| l.items,
        else => return error.TypeError,
    };
    const f = args[2];
    const extra_args = args[3..];
    const call = call_fn orelse return error.TypeError;

    if (ks.len == 0) {
        // 空パス: f を m 自体に適用
        var call_args: std.ArrayListUnmanaged(Value) = .empty;
        call_args.append(allocator, m) catch return error.OutOfMemory;
        for (extra_args) |a| {
            call_args.append(allocator, a) catch return error.OutOfMemory;
        }
        return call(f, call_args.items, allocator);
    }

    return updateInHelper(allocator, m, ks, f, extra_args, call);
}

fn updateInHelper(
    allocator: std.mem.Allocator,
    m: Value,
    ks: []const Value,
    f: Value,
    extra_args: []const Value,
    call: CallFn,
) anyerror!Value {
    const key = ks[0];
    if (ks.len == 1) {
        // ベースケース: (update m key f args...)
        const get_args = [_]Value{ m, key };
        const old_val = try get(allocator, &get_args);
        var call_args: std.ArrayListUnmanaged(Value) = .empty;
        call_args.append(allocator, old_val) catch return error.OutOfMemory;
        for (extra_args) |a| {
            call_args.append(allocator, a) catch return error.OutOfMemory;
        }
        const new_val = try call(f, call_args.items, allocator);
        const assoc_args = [_]Value{ m, key, new_val };
        return assoc(allocator, &assoc_args);
    }

    // 再帰: (assoc m key (update-in (get m key) rest-ks f args...))
    const get_args = [_]Value{ m, key };
    const inner_map = try get(allocator, &get_args);
    const inner_result = try updateInHelper(allocator, inner_map, ks[1..], f, extra_args, call);
    const assoc_args = [_]Value{ m, key, inner_result };
    return assoc(allocator, &assoc_args);
}

/// update-keys : マップの全キーに関数を適用
/// (update-keys m f)
pub fn updateKeys(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const m = args[0];
    const f = args[1];
    const call = call_fn orelse return error.TypeError;

    switch (m) {
        .nil => return value_mod.nil,
        .map => |mp| {
            var new_map = value_mod.PersistentMap.empty();
            var i: usize = 0;
            while (i < mp.entries.len) : (i += 2) {
                const call_args = [_]Value{mp.entries[i]};
                const new_key = try call(f, &call_args, allocator);
                new_map = try new_map.assoc(allocator, new_key, mp.entries[i + 1]);
            }
            const result = try allocator.create(value_mod.PersistentMap);
            result.* = new_map;
            return Value{ .map = result };
        },
        else => return error.TypeError,
    }
}

/// update-vals : マップの全値に関数を適用
/// (update-vals m f)
pub fn updateVals(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const m = args[0];
    const f = args[1];
    const call = call_fn orelse return error.TypeError;

    switch (m) {
        .nil => return value_mod.nil,
        .map => |mp| {
            var new_map = value_mod.PersistentMap.empty();
            var i: usize = 0;
            while (i < mp.entries.len) : (i += 2) {
                const call_args = [_]Value{mp.entries[i + 1]};
                const new_val = try call(f, &call_args, allocator);
                new_map = try new_map.assoc(allocator, mp.entries[i], new_val);
            }
            const result = try allocator.create(value_mod.PersistentMap);
            result.* = new_map;
            return Value{ .map = result };
        },
        else => return error.TypeError,
    }
}

/// bounded-count : コレクションの要素数を最大 n まで数える
/// (bounded-count n coll)
pub fn boundedCount(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const limit = switch (args[0]) {
        .int => |i| i,
        else => return error.TypeError,
    };
    if (limit < 0) return error.TypeError;
    const n: usize = @intCast(limit);

    return switch (args[1]) {
        .vector => |v| value_mod.intVal(@intCast(@min(v.items.len, n))),
        .list => |l| value_mod.intVal(@intCast(@min(l.items.len, n))),
        .map => |m| value_mod.intVal(@intCast(@min(m.count(), n))),
        .set => |s| value_mod.intVal(@intCast(@min(s.count(), n))),
        .nil => value_mod.intVal(0),
        .string => |s| value_mod.intVal(@intCast(@min(s.data.len, n))),
        else => value_mod.intVal(0),
    };
}

/// compare : 2つの値を比較（-1, 0, 1 を返す）
pub fn compareFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const a = args[0];
    const b = args[1];

    // 数値比較
    if (a == .int and b == .int) {
        if (a.int < b.int) return value_mod.intVal(-1);
        if (a.int > b.int) return value_mod.intVal(1);
        return value_mod.intVal(0);
    }
    if ((a == .int or a == .float) and (b == .int or b == .float)) {
        const af: f64 = if (a == .int) @floatFromInt(a.int) else a.float;
        const bf: f64 = if (b == .int) @floatFromInt(b.int) else b.float;
        if (af < bf) return value_mod.intVal(-1);
        if (af > bf) return value_mod.intVal(1);
        return value_mod.intVal(0);
    }
    // 文字列比較
    if (a == .string and b == .string) {
        const order = std.mem.order(u8, a.string.data, b.string.data);
        return value_mod.intVal(switch (order) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        });
    }
    // キーワード比較
    if (a == .keyword and b == .keyword) {
        const order = std.mem.order(u8, a.keyword.name, b.keyword.name);
        return value_mod.intVal(switch (order) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        });
    }
    // シンボル比較
    if (a == .symbol and b == .symbol) {
        const order = std.mem.order(u8, a.symbol.name, b.symbol.name);
        return value_mod.intVal(switch (order) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        });
    }

    return error.TypeError;
}

/// empty : コレクションの同型空コレクションを返す
pub fn emptyFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .list => Value{ .list = try value_mod.PersistentList.empty(allocator) },
        .vector => blk: {
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = value_mod.PersistentVector.empty();
            break :blk Value{ .vector = result };
        },
        .map => blk: {
            const result = try allocator.create(value_mod.PersistentMap);
            result.* = value_mod.PersistentMap.empty();
            break :blk Value{ .map = result };
        },
        .set => blk: {
            const result = try allocator.create(value_mod.PersistentSet);
            result.* = value_mod.PersistentSet.empty();
            break :blk Value{ .set = result };
        },
        .nil => value_mod.nil,
        else => value_mod.nil,
    };
}

/// sequence : coll を seq に変換、空なら nil
pub fn sequenceFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return seq(allocator, args);
}

// === Phase 11 追加: ビット演算・ユーティリティ ===

/// bit-and-not : (bit-and x (bit-not y))
pub fn bitAndNot(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    return value_mod.intVal(args[0].int & ~args[1].int);
}

/// bit-clear : n 番目のビットをクリア
pub fn bitClear(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const shift: u6 = @intCast(@min(@max(args[1].int, 0), 63));
    return value_mod.intVal(args[0].int & ~(@as(i64, 1) << shift));
}

/// bit-flip : n 番目のビットを反転
pub fn bitFlip(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const shift: u6 = @intCast(@min(@max(args[1].int, 0), 63));
    return value_mod.intVal(args[0].int ^ (@as(i64, 1) << shift));
}

/// bit-set : n 番目のビットをセット
pub fn bitSet(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const shift: u6 = @intCast(@min(@max(args[1].int, 0), 63));
    return value_mod.intVal(args[0].int | (@as(i64, 1) << shift));
}

/// bit-test : n 番目のビットをテスト
pub fn bitTest(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const shift: u6 = @intCast(@min(@max(args[1].int, 0), 63));
    const result = (args[0].int >> shift) & 1;
    return if (result == 1) value_mod.true_val else value_mod.false_val;
}

/// unsigned-bit-shift-right : 符号なし右シフト
pub fn unsignedBitShiftRight(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const shift: u6 = @intCast(@min(@max(args[1].int, 0), 63));
    const unsigned_val: u64 = @bitCast(args[0].int);
    const shifted = unsigned_val >> shift;
    return value_mod.intVal(@bitCast(shifted));
}

/// parse-long : 文字列を整数にパース
pub fn parseLong(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .string => |s| {
            const trimmed = std.mem.trim(u8, s.data, &[_]u8{ ' ', '\t', '\n', '\r' });
            const val = std.fmt.parseInt(i64, trimmed, 10) catch return value_mod.nil;
            return value_mod.intVal(val);
        },
        else => value_mod.nil,
    };
}

/// parse-double : 文字列を浮動小数点にパース
pub fn parseDouble(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .string => |s| {
            const trimmed = std.mem.trim(u8, s.data, &[_]u8{ ' ', '\t', '\n', '\r' });
            const val = std.fmt.parseFloat(f64, trimmed) catch return value_mod.nil;
            return value_mod.floatVal(val);
        },
        else => value_mod.nil,
    };
}

/// parse-boolean : 文字列を真偽値にパース（"true"→true, "false"→false, その他→nil）
pub fn parseBooleanFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .string => |s| {
            if (std.mem.eql(u8, s.data, "true")) return value_mod.true_val;
            if (std.mem.eql(u8, s.data, "false")) return value_mod.false_val;
            return value_mod.nil;
        },
        else => value_mod.nil,
    };
}

/// rand-nth : コレクションからランダムに1つ選ぶ
pub fn randNth(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = (try getItemsRealized(allocator, args[0])) orelse return error.TypeError;
    if (items.len == 0) return error.TypeError;
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const idx = rng.intRangeAtMost(usize, 0, items.len - 1);
    return items[idx];
}

/// repeatedly : f を n 回呼んでリストにする
/// (repeatedly n f)
pub fn repeatedly(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const n = switch (args[0]) {
        .int => |i| i,
        else => return error.TypeError,
    };
    if (n < 0) return error.TypeError;
    const repeat_count: usize = @intCast(n);
    const f = args[1];
    const call = call_fn orelse return error.TypeError;

    var result: std.ArrayListUnmanaged(Value) = .empty;
    for (0..repeat_count) |_| {
        const r = try call(f, &[_]Value{}, allocator);
        result.append(allocator, r) catch return error.OutOfMemory;
    }

    if (result.items.len == 0) return value_mod.nil;
    const list_ptr = try value_mod.PersistentList.fromSlice(allocator, result.items);
    return Value{ .list = list_ptr };
}

/// reductions : reduce の中間結果をリストにする
/// (reductions f coll) / (reductions f init coll)
pub fn reductions(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    const f = args[0];
    const call = call_fn orelse return error.TypeError;

    var acc: Value = undefined;
    var items: []const Value = undefined;

    if (args.len == 2) {
        // (reductions f coll)
        const coll_items = (try getItemsRealized(allocator, args[1])) orelse return error.TypeError;
        if (coll_items.len == 0) {
            // 空コレクション → 初期値なし → ()
            const list_ptr = try value_mod.PersistentList.empty(allocator);
            return Value{ .list = list_ptr };
        }
        acc = coll_items[0];
        items = coll_items[1..];
    } else {
        // (reductions f init coll)
        acc = args[1];
        items = (try getItemsRealized(allocator, args[2])) orelse return error.TypeError;
    }

    var result: std.ArrayListUnmanaged(Value) = .empty;
    result.append(allocator, acc) catch return error.OutOfMemory;
    for (items) |item| {
        const call_args = [_]Value{ acc, item };
        acc = try call(f, &call_args, allocator);
        result.append(allocator, acc) catch return error.OutOfMemory;
    }

    const list_ptr = try value_mod.PersistentList.fromSlice(allocator, result.items);
    return Value{ .list = list_ptr };
}

/// split-with : 述語を満たす先頭部分と残りに分割
/// (split-with pred coll) → [(take-while pred coll) (drop-while pred coll)]
pub fn splitWith(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const pred = args[0];
    const coll = args[1];
    const call = call_fn orelse return error.TypeError;

    const items = (try getItemsRealized(allocator, coll)) orelse return error.TypeError;
    var split_idx: usize = 0;
    for (items) |item| {
        const call_args = [_]Value{item};
        const r = try call(pred, &call_args, allocator);
        if (!r.isTruthy()) break;
        split_idx += 1;
    }

    const taken = items[0..split_idx];
    const dropped = items[split_idx..];

    // ベクタに2つのリストを入れる
    const vec_items = try allocator.alloc(Value, 2);

    if (taken.len == 0) {
        vec_items[0] = Value{ .list = try value_mod.PersistentList.empty(allocator) };
    } else {
        vec_items[0] = Value{ .list = try value_mod.PersistentList.fromSlice(allocator, taken) };
    }
    if (dropped.len == 0) {
        vec_items[1] = Value{ .list = try value_mod.PersistentList.empty(allocator) };
    } else {
        vec_items[1] = Value{ .list = try value_mod.PersistentList.fromSlice(allocator, dropped) };
    }

    const vec_ptr = try allocator.create(value_mod.PersistentVector);
    vec_ptr.* = .{ .items = vec_items };
    return Value{ .vector = vec_ptr };
}

/// dedupe : 連続する重複要素を除去
pub fn dedupeFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = (try getItemsRealized(allocator, args[0])) orelse return error.TypeError;
    if (items.len == 0) return value_mod.nil;

    var result: std.ArrayListUnmanaged(Value) = .empty;
    result.append(allocator, items[0]) catch return error.OutOfMemory;
    for (items[1..]) |item| {
        if (!item.eql(result.items[result.items.len - 1])) {
            result.append(allocator, item) catch return error.OutOfMemory;
        }
    }

    const list_ptr = try value_mod.PersistentList.fromSlice(allocator, result.items);
    return Value{ .list = list_ptr };
}

/// rseq : ベクタの逆順シーケンス
pub fn rseq(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .vector => |v| {
            if (v.items.len == 0) return value_mod.nil;
            const reversed = try allocator.alloc(Value, v.items.len);
            for (v.items, 0..) |item, i| {
                reversed[v.items.len - 1 - i] = item;
            }
            const list_ptr = try value_mod.PersistentList.fromSlice(allocator, reversed);
            return Value{ .list = list_ptr };
        },
        else => error.TypeError,
    };
}

/// max-key : f の結果が最大の要素を返す
pub fn maxKey(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const f = args[0];
    const call = call_fn orelse return error.TypeError;

    var best = args[1];
    const call_args0 = [_]Value{best};
    var best_score = try call(f, &call_args0, allocator);

    for (args[2..]) |item| {
        const call_args = [_]Value{item};
        const score = try call(f, &call_args, allocator);
        if (compareValues(score, best_score) > 0) {
            best = item;
            best_score = score;
        }
    }
    return best;
}

/// min-key : f の結果が最小の要素を返す
pub fn minKey(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const f = args[0];
    const call = call_fn orelse return error.TypeError;

    var best = args[1];
    const call_args0 = [_]Value{best};
    var best_score = try call(f, &call_args0, allocator);

    for (args[2..]) |item| {
        const call_args = [_]Value{item};
        const score = try call(f, &call_args, allocator);
        if (compareValues(score, best_score) < 0) {
            best = item;
            best_score = score;
        }
    }
    return best;
}

/// 内部比較ヘルパー（数値のみ、compare と同じロジック）
fn compareValues(a: Value, b: Value) i64 {
    if (a == .int and b == .int) {
        if (a.int < b.int) return -1;
        if (a.int > b.int) return 1;
        return 0;
    }
    const af: f64 = if (a == .int) @floatFromInt(a.int) else if (a == .float) a.float else return 0;
    const bf: f64 = if (b == .int) @floatFromInt(b.int) else if (b == .float) b.float else return 0;
    if (af < bf) return -1;
    if (af > bf) return 1;
    return 0;
}

/// string-split : 文字列を区切り文字で分割（clojure.string/split 簡易版）
pub fn stringSplit(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const s = args[0].string.data;

    // Pattern の場合: 正規表現で分割
    if (args[1] == .regex) {
        return regexSplit(allocator, s, args[1].regex);
    }

    if (args[1] != .string) return error.TypeError;
    const sep = args[1].string.data;

    var result_buf: std.ArrayListUnmanaged(Value) = .empty;

    if (sep.len == 0) {
        // 空セパレータ: 1文字ずつ
        for (s) |byte| {
            const char_str = try allocator.alloc(u8, 1);
            char_str[0] = byte;
            const str_obj = try allocator.create(value_mod.String);
            str_obj.* = value_mod.String.init(char_str);
            result_buf.append(allocator, Value{ .string = str_obj }) catch return error.OutOfMemory;
        }
    } else {
        var start: usize = 0;
        while (start <= s.len) {
            if (std.mem.indexOfPos(u8, s, start, sep)) |idx| {
                const part = try allocator.dupe(u8, s[start..idx]);
                const str_obj = try allocator.create(value_mod.String);
                str_obj.* = value_mod.String.init(part);
                result_buf.append(allocator, Value{ .string = str_obj }) catch return error.OutOfMemory;
                start = idx + sep.len;
            } else {
                const part = try allocator.dupe(u8, s[start..]);
                const str_obj = try allocator.create(value_mod.String);
                str_obj.* = value_mod.String.init(part);
                result_buf.append(allocator, Value{ .string = str_obj }) catch return error.OutOfMemory;
                break;
            }
        }
    }

    const result = try allocator.create(value_mod.PersistentVector);
    result.* = .{ .items = result_buf.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return Value{ .vector = result };
}

/// 正規表現で分割（内部ヘルパー）
fn regexSplit(allocator: std.mem.Allocator, input: []const u8, pat: *value_mod.Pattern) anyerror!Value {
    const compiled: *const regex_mod.CompiledRegex = @ptrCast(@alignCast(pat.compiled));
    var m = try regex_matcher.Matcher.init(allocator, compiled, input);
    defer m.deinit();

    var result_buf: std.ArrayListUnmanaged(Value) = .empty;
    var pos: usize = 0;

    while (pos <= input.len) {
        const result = try m.find(pos) orelse {
            // 残りを追加
            const part = try allocator.dupe(u8, input[pos..]);
            const str_obj = try allocator.create(value_mod.String);
            str_obj.* = value_mod.String.init(part);
            try result_buf.append(allocator, Value{ .string = str_obj });
            break;
        };

        // マッチ前の部分を追加
        const part = try allocator.dupe(u8, input[pos..result.start]);
        const str_obj = try allocator.create(value_mod.String);
        str_obj.* = value_mod.String.init(part);
        try result_buf.append(allocator, Value{ .string = str_obj });

        // 位置を進める
        pos = if (result.end > result.start) result.end else result.end + 1;
    }

    const vec = try allocator.create(value_mod.PersistentVector);
    vec.* = .{ .items = try result_buf.toOwnedSlice(allocator) };
    return Value{ .vector = vec };
}

/// format : 簡易フォーマット（%s, %d のみ対応）
pub fn formatFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const fmt_str = args[0].string.data;
    const fmt_args = args[1..];

    var result_buf: std.ArrayListUnmanaged(u8) = .empty;
    var arg_idx: usize = 0;
    var i: usize = 0;

    while (i < fmt_str.len) {
        if (fmt_str[i] == '%' and i + 1 < fmt_str.len) {
            const spec = fmt_str[i + 1];
            if (spec == 's' or spec == 'd') {
                if (arg_idx < fmt_args.len) {
                    try valueToString(allocator, &result_buf, fmt_args[arg_idx]);
                    arg_idx += 1;
                }
                i += 2;
                continue;
            } else if (spec == '%') {
                result_buf.append(allocator, '%') catch return error.OutOfMemory;
                i += 2;
                continue;
            }
        }
        result_buf.append(allocator, fmt_str[i]) catch return error.OutOfMemory;
        i += 1;
    }

    const result_str = result_buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = value_mod.String.init(result_str);
    return Value{ .string = str_obj };
}

/// apply-to : 引数リストを展開して関数適用（組み込み関数専用）
/// ※ apply は special form だが、引数なしバージョンのヘルパー

/// map-indexed 用ヘルパーは既にノードとして実装済み

/// pr : 値を印字（改行なし、readably）
pub fn prFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout.writer(&buf);
    const writer = &file_writer.interface;

    for (args, 0..) |arg, i| {
        if (i > 0) writer.writeByte(' ') catch {};
        printValue(writer, arg) catch {};
    }
    writer.flush() catch {};
    return value_mod.nil;
}

/// print : 値を印字（改行なし、文字列はクォートなし）
pub fn printFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout.writer(&buf);
    const writer = &file_writer.interface;

    for (args, 0..) |arg, i| {
        if (i > 0) writer.writeByte(' ') catch {};
        printValueForPrint(writer, arg) catch {};
    }
    writer.flush() catch {};
    return value_mod.nil;
}

/// prn : pr + 改行
pub fn prnFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout.writer(&buf);
    const writer = &file_writer.interface;

    for (args, 0..) |arg, i| {
        if (i > 0) writer.writeByte(' ') catch {};
        printValue(writer, arg) catch {};
    }
    writer.writeByte('\n') catch {};
    writer.flush() catch {};
    return value_mod.nil;
}

/// print-str : 値を文字列に変換（readably=false）
pub fn printStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    var result_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer result_buf.deinit(allocator);

    for (args, 0..) |arg, i| {
        if (i > 0) result_buf.append(allocator, ' ') catch return error.OutOfMemory;
        try valueToString(allocator, &result_buf, arg);
    }

    const result_str = result_buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = value_mod.String.init(result_str);
    return Value{ .string = str_obj };
}

/// prn-str : pr-str と同じ（readably=true、改行は含まない）
pub fn prnStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    return prStr(allocator, args);
}

/// with-meta : 値にメタデータを付与（簡易版）
/// ※ 実際にはコレクションの meta フィールドを設定する
pub fn withMeta(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[1] != .map) return error.TypeError;
    const meta = args[1];

    // メタデータをヒープに確保
    const meta_ptr = try allocator.create(Value);
    meta_ptr.* = meta;

    return switch (args[0]) {
        .list => |l| blk: {
            const new_list = try allocator.create(value_mod.PersistentList);
            new_list.* = .{ .items = l.items, .meta = meta_ptr };
            break :blk Value{ .list = new_list };
        },
        .vector => |v| blk: {
            const new_vec = try allocator.create(value_mod.PersistentVector);
            new_vec.* = .{ .items = v.items, .meta = meta_ptr };
            break :blk Value{ .vector = new_vec };
        },
        .map => |m| blk: {
            const new_map = try allocator.create(value_mod.PersistentMap);
            new_map.* = .{ .entries = m.entries, .meta = meta_ptr };
            break :blk Value{ .map = new_map };
        },
        .set => |s| blk: {
            const new_set = try allocator.create(value_mod.PersistentSet);
            new_set.* = .{ .items = s.items, .meta = meta_ptr };
            break :blk Value{ .set = new_set };
        },
        else => error.TypeError,
    };
}

/// realized? : LazySeq が実体化済みかどうか
pub fn isRealized(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .lazy_seq => |ls| if (ls.isRealized()) value_mod.true_val else value_mod.false_val,
        else => value_mod.true_val, // lazy-seq 以外は常に realized
    };
}

/// lazy-seq? : LazySeq かどうか
pub fn isLazySeq(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .lazy_seq) value_mod.true_val else value_mod.false_val;
}

/// doall : 遅延シーケンスを完全に実体化して返す
pub fn doall(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return ensureRealized(allocator, args[0]);
}

/// meta : 値のメタデータを取得
pub fn metaFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const m: ?*const Value = switch (args[0]) {
        .list => |l| l.meta,
        .vector => |v| v.meta,
        .map => |mp| mp.meta,
        .set => |s| s.meta,
        else => null,
    };
    return if (m) |ptr| ptr.* else value_mod.nil;
}

// ============================================================
// Phase 12: PURE 述語・型キャスト・算術・ユーティリティ
// ============================================================

// --- 述語 ---

/// bytes? : バイト配列かどうか（Zig実装では常に false）
pub fn isBytes(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// class? : クラスかどうか（JVMなし、常に false）
pub fn isClass(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// decimal? : BigDecimalかどうか（Zig実装では常に false）
pub fn isDecimal(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// ratio? : 有理数かどうか（Ratio型未実装、常に false）
pub fn isRatio(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// rational? : 有理数的かどうか（整数は rational）
pub fn isRational(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .int) value_mod.true_val else value_mod.false_val;
}

/// record? : レコードかどうか（defrecord未実装、常に false）
pub fn isRecord(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// inst? : インスタントかどうか（常に false）
pub fn isInst(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// uri? : URIかどうか（常に false）
pub fn isUri(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// uuid? : UUIDかどうか（常に false — uuid型未実装）
pub fn isUuid(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// tagged-literal? : タグ付きリテラルかどうか（常に false）
pub fn isTaggedLiteral(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// reader-conditional? : リーダー条件式かどうか（常に false）
pub fn isReaderConditional(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

// delay?, volatile?, reduced? は Phase 13 で本実装（core.zig 末尾の Phase 13 セクション）

/// instance? : 型チェック（内部タグ検査で簡略実装）
pub fn instanceCheck(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    // (instance? type-name val) — type-name はキーワード/文字列/シンボルで型名を指定
    const type_name = switch (args[0]) {
        .keyword => |kw| kw.name,
        .string => |s| s.data,
        .symbol => |s| s.name,
        else => return value_mod.false_val,
    };
    const val = args[1];
    const is_match =
        if (std.mem.eql(u8, type_name, "Integer") or
        std.mem.eql(u8, type_name, "Long") or
        std.mem.eql(u8, type_name, "java.lang.Long") or
        std.mem.eql(u8, type_name, "java.lang.Integer") or
        std.mem.eql(u8, type_name, "Number") or
        std.mem.eql(u8, type_name, "java.lang.Number"))
        val == .int or val == .float
    else if (std.mem.eql(u8, type_name, "Double") or
        std.mem.eql(u8, type_name, "Float") or
        std.mem.eql(u8, type_name, "java.lang.Double") or
        std.mem.eql(u8, type_name, "java.lang.Float"))
        val == .float
    else if (std.mem.eql(u8, type_name, "String") or
        std.mem.eql(u8, type_name, "java.lang.String") or
        std.mem.eql(u8, type_name, "CharSequence") or
        std.mem.eql(u8, type_name, "java.lang.CharSequence"))
        val == .string
    else if (std.mem.eql(u8, type_name, "Boolean") or
        std.mem.eql(u8, type_name, "java.lang.Boolean"))
        val == .bool_val
    else if (std.mem.eql(u8, type_name, "Keyword") or
        std.mem.eql(u8, type_name, "clojure.lang.Keyword"))
        val == .keyword
    else if (std.mem.eql(u8, type_name, "Symbol") or
        std.mem.eql(u8, type_name, "clojure.lang.Symbol"))
        val == .symbol
    else if (std.mem.eql(u8, type_name, "clojure.lang.IEditableCollection"))
        val == .vector or val == .map or val == .set
    else if (std.mem.eql(u8, type_name, "Throwable") or
        std.mem.eql(u8, type_name, "java.lang.Throwable") or
        std.mem.eql(u8, type_name, "Exception") or
        std.mem.eql(u8, type_name, "java.lang.Exception"))
        // エラーは ex-info マップとして表現される（特別なタグなし）
        false
    else if (std.mem.eql(u8, type_name, "java.util.UUID"))
        // UUID はシンボルに false (未実装なら)
        false
    else if (std.mem.eql(u8, type_name, "java.util.regex.Pattern") or
        std.mem.eql(u8, type_name, "Pattern"))
        val == .regex
    else if (std.mem.eql(u8, type_name, "clojure.lang.PersistentVector") or
        std.mem.eql(u8, type_name, "clojure.lang.IPersistentVector"))
        val == .vector
    else if (std.mem.eql(u8, type_name, "clojure.lang.PersistentHashMap") or
        std.mem.eql(u8, type_name, "clojure.lang.IPersistentMap") or
        std.mem.eql(u8, type_name, "clojure.lang.PersistentArrayMap"))
        val == .map
    else if (std.mem.eql(u8, type_name, "clojure.lang.PersistentHashSet") or
        std.mem.eql(u8, type_name, "clojure.lang.IPersistentSet"))
        val == .set
    else if (std.mem.eql(u8, type_name, "clojure.lang.PersistentList") or
        std.mem.eql(u8, type_name, "clojure.lang.IPersistentList") or
        std.mem.eql(u8, type_name, "clojure.lang.ISeq"))
        val == .list or val == .lazy_seq
    else if (std.mem.eql(u8, type_name, "clojure.lang.IFn"))
        val == .fn_val or val == .partial_fn or val == .comp_fn or val == .multi_fn or val == .keyword or val == .map or val == .set or val == .vector
    else if (std.mem.eql(u8, type_name, "clojure.lang.Atom") or
        std.mem.eql(u8, type_name, "clojure.lang.IAtom"))
        val == .atom
    else if (std.mem.eql(u8, type_name, "clojure.lang.Var"))
        val == .var_val
    else if (std.mem.eql(u8, type_name, "clojure.lang.PersistentQueue"))
        false // 未実装型
    else if (std.mem.eql(u8, type_name, "Character") or
        std.mem.eql(u8, type_name, "java.lang.Character"))
        val == .char_val
    else
        false;
    return if (is_match) value_mod.true_val else value_mod.false_val;
}

// --- 型キャスト ---

/// char : 整数を文字に変換
pub fn charFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .char_val => args[0],
        .int => |n| Value{ .char_val = @intCast(n) },
        else => error.TypeError,
    };
}

/// byte : 整数をバイト範囲にキャスト
pub fn byteFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| value_mod.intVal(@as(i64, @as(i8, @truncate(n)))),
        else => error.TypeError,
    };
}

/// short : 整数をshort範囲にキャスト
pub fn shortFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| value_mod.intVal(@as(i64, @as(i16, @truncate(n)))),
        else => error.TypeError,
    };
}

/// long : 値をlong（i64）に変換
pub fn longFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => args[0],
        .float => |f| value_mod.intVal(@intFromFloat(f)),
        .char_val => |c| value_mod.intVal(@as(i64, c)),
        else => error.TypeError,
    };
}

/// float : 値をfloat（f64）に変換（double のエイリアス）
pub fn floatFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .float => args[0],
        .int => |n| Value{ .float = @floatFromInt(n) },
        else => error.TypeError,
    };
}

/// num : 数値をそのまま返す（数値でなければエラー）
pub fn numFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int, .float => args[0],
        else => error.TypeError,
    };
}

// --- オーバーフロー安全算術 ---

/// +' : オーバーフロー時に ArithmeticOverflow エラー
pub fn addChecked(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    var result: i64 = 0;
    var has_float = false;
    var float_result: f64 = 0.0;

    for (args) |arg| {
        switch (arg) {
            .int => |n| {
                if (has_float) {
                    float_result += @as(f64, @floatFromInt(n));
                } else {
                    const ov = @addWithOverflow(result, n);
                    if (ov[1] != 0) return error.ArithmeticOverflow;
                    result = ov[0];
                }
            },
            .float => |f| {
                if (!has_float) {
                    float_result = @as(f64, @floatFromInt(result));
                    has_float = true;
                }
                float_result += f;
            },
            else => return error.TypeError,
        }
    }
    return if (has_float) Value{ .float = float_result } else value_mod.intVal(result);
}

/// -' : オーバーフロー安全減算
pub fn subChecked(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len == 0) return error.ArityError;

    if (args.len == 1) {
        // 単項マイナス
        return switch (args[0]) {
            .int => |n| blk: {
                const ov = @subWithOverflow(@as(i64, 0), n);
                if (ov[1] != 0) return error.ArithmeticOverflow;
                break :blk value_mod.intVal(ov[0]);
            },
            .float => |f| Value{ .float = -f },
            else => error.TypeError,
        };
    }

    // float が含まれるかチェック
    var has_float = false;
    for (args) |arg| {
        if (arg == .float) {
            has_float = true;
            break;
        }
    }

    if (has_float) {
        // float 演算
        var fr: f64 = switch (args[0]) {
            .int => |n| @as(f64, @floatFromInt(n)),
            .float => |f| f,
            else => return error.TypeError,
        };
        for (args[1..]) |arg| {
            switch (arg) {
                .int => |n| fr -= @as(f64, @floatFromInt(n)),
                .float => |f| fr -= f,
                else => return error.TypeError,
            }
        }
        return Value{ .float = fr };
    }

    // 整数のみ — オーバーフロー検出
    var result: i64 = switch (args[0]) {
        .int => |n| n,
        else => return error.TypeError,
    };
    for (args[1..]) |arg| {
        const n = switch (arg) {
            .int => |v| v,
            else => return error.TypeError,
        };
        const ov = @subWithOverflow(result, n);
        if (ov[1] != 0) return error.ArithmeticOverflow;
        result = ov[0];
    }
    return value_mod.intVal(result);
}

/// *' : オーバーフロー安全乗算
pub fn mulChecked(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    var result: i64 = 1;
    var has_float = false;
    var float_result: f64 = 1.0;

    for (args) |arg| {
        switch (arg) {
            .int => |n| {
                if (has_float) {
                    float_result *= @as(f64, @floatFromInt(n));
                } else {
                    const ov = @mulWithOverflow(result, n);
                    if (ov[1] != 0) return error.ArithmeticOverflow;
                    result = ov[0];
                }
            },
            .float => |f| {
                if (!has_float) {
                    float_result = @as(f64, @floatFromInt(result));
                    has_float = true;
                }
                float_result *= f;
            },
            else => return error.TypeError,
        }
    }
    return if (has_float) Value{ .float = float_result } else value_mod.intVal(result);
}

/// inc' : オーバーフロー安全インクリメント
pub fn incChecked(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| blk: {
            const ov = @addWithOverflow(n, @as(i64, 1));
            if (ov[1] != 0) return error.ArithmeticOverflow;
            break :blk value_mod.intVal(ov[0]);
        },
        .float => |f| Value{ .float = f + 1.0 },
        else => error.TypeError,
    };
}

/// dec' : オーバーフロー安全デクリメント
pub fn decChecked(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| blk: {
            const ov = @subWithOverflow(n, @as(i64, 1));
            if (ov[1] != 0) return error.ArithmeticOverflow;
            break :blk value_mod.intVal(ov[0]);
        },
        .float => |f| Value{ .float = f - 1.0 },
        else => error.TypeError,
    };
}

// --- 出力・文字列ユーティリティ ---

/// clojure-version : バージョン文字列を返す
pub fn clojureVersion(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = args;
    const s = try allocator.create(value_mod.String);
    s.* = value_mod.String.init("1.12.0-zig");
    return Value{ .string = s };
}

/// newline : 改行を出力
pub fn newlineFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    _ = args;
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout.writer(&buf);
    const writer = &file_writer.interface;
    writer.writeAll("\n") catch {};
    writer.flush() catch {};
    return value_mod.nil;
}

/// println-str : println と同じフォーマットで文字列を返す（出力しない）
pub fn printlnStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    var result_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer result_buf.deinit(allocator);

    for (args, 0..) |arg, i| {
        if (i > 0) result_buf.append(allocator, ' ') catch return error.OutOfMemory;
        try valueToString(allocator, &result_buf, arg);
    }
    result_buf.append(allocator, '\n') catch return error.OutOfMemory;

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = value_mod.String.init(result_buf.toOwnedSlice(allocator) catch return error.OutOfMemory);
    return Value{ .string = str_obj };
}

/// printf : format + print（書式付き出力）
pub fn printfFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // (printf fmt & args) — 簡略実装: format を呼んで print
    if (args.len == 0) return error.ArityError;
    const formatted = try formatFn(allocator, args);
    const s = switch (formatted) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout.writer(&buf);
    const writer = &file_writer.interface;
    writer.writeAll(s) catch {};
    writer.flush() catch {};
    return value_mod.nil;
}

// --- ハッシュユーティリティ ---

/// hash-combine : 2つのハッシュを結合
pub fn hashCombine(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const seed = switch (args[0]) {
        .int => |n| n,
        else => return error.TypeError,
    };
    const hash = switch (args[1]) {
        .int => |n| n,
        else => return error.TypeError,
    };
    // Clojure の hashCombine: seed ^ (hash + 0x9e3779b9 + (seed << 6) + (seed >> 2))
    const result = seed ^ (hash +% 0x9e3779b9 +% (seed << 6) +% @as(i64, @intCast(@as(u64, @bitCast(seed)) >> 2)));
    return value_mod.intVal(result);
}

/// hash-ordered-coll : 順序付きコレクションのハッシュ
pub fn hashOrderedColl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = try collectToSlice(allocator, args[0]);
    defer allocator.free(items);
    var h: i64 = 1;
    for (items) |item| {
        const item_hash = try hashFn(allocator, &[_]Value{item});
        h = h *% 31 +% item_hash.int;
    }
    return value_mod.intVal(h);
}

/// hash-unordered-coll : 順序なしコレクションのハッシュ
pub fn hashUnorderedColl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = try collectToSlice(allocator, args[0]);
    defer allocator.free(items);
    var h: i64 = 0;
    for (items) |item| {
        const item_hash = try hashFn(allocator, &[_]Value{item});
        h +%= item_hash.int;
    }
    return value_mod.intVal(h);
}

/// mix-collection-hash : コレクションハッシュの最終混合
pub fn mixCollectionHash(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const hash_val = switch (args[0]) {
        .int => |n| @as(u32, @truncate(@as(u64, @bitCast(n)))),
        else => return error.TypeError,
    };
    const count_val = switch (args[1]) {
        .int => |n| @as(u32, @truncate(@as(u64, @bitCast(n)))),
        else => return error.TypeError,
    };
    // Murmur3 最終混合
    var h = hash_val;
    h ^= count_val;
    h ^= h >> 16;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;
    return value_mod.intVal(@as(i64, h));
}

// --- find-keyword ---

/// find-keyword : 既存のキーワードを検索（インターン済みならキーワード、なければ nil）
pub fn findKeywordFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;
    if (args.len == 1) {
        // (find-keyword name)
        return switch (args[0]) {
            .keyword => args[0], // キーワードならそのまま返す
            .string => |s| blk: {
                const kw = try allocator.create(value_mod.Keyword);
                kw.* = value_mod.Keyword.init(s.data);
                break :blk Value{ .keyword = kw };
            },
            else => value_mod.nil,
        };
    } else {
        // (find-keyword ns name)
        const ns_name = switch (args[0]) {
            .string => |s| s.data,
            else => return error.TypeError,
        };
        const kw_name = switch (args[1]) {
            .string => |s| s.data,
            else => return error.TypeError,
        };
        var qualified_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer qualified_buf.deinit(allocator);
        qualified_buf.appendSlice(allocator, ns_name) catch return error.OutOfMemory;
        qualified_buf.append(allocator, '/') catch return error.OutOfMemory;
        qualified_buf.appendSlice(allocator, kw_name) catch return error.OutOfMemory;
        const kw = try allocator.create(value_mod.Keyword);
        kw.* = value_mod.Keyword.init(qualified_buf.toOwnedSlice(allocator) catch return error.OutOfMemory);
        return Value{ .keyword = kw };
    }
}

/// gensym : ユニークシンボルを生成
var gensym_counter: u64 = 0;
pub fn gensymFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    const prefix = if (args.len >= 1)
        switch (args[0]) {
            .string => |s| s.data,
            else => "G__",
        }
    else
        "G__";

    gensym_counter += 1;
    var buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, gensym_counter }) catch return error.TypeError;
    const owned = try allocator.alloc(u8, name.len);
    @memcpy(owned, name);
    const sym = try allocator.create(value_mod.Symbol);
    sym.* = value_mod.Symbol.init(owned);
    return Value{ .symbol = sym };
}

/// comparator : 述語関数をコンパレータに変換
/// (comparator pred) → pred が true なら -1、false なら 1 を返す関数
/// 注: 高階関数を返すにはクロージャが必要。簡略実装として pred を呼んで -1/0/1 を返す
pub fn comparatorFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    // comparator は関数を返す — ここでは引数の関数をそのまま返す（ラッパーは Phase 12E で改善）
    return switch (args[0]) {
        .fn_val, .partial_fn, .comp_fn => args[0],
        else => error.TypeError,
    };
}

/// replicate : (replicate n x) — n個のxからなるシーケンスを返す（非推奨、repeat で代替可能）
pub fn replicateFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const n = switch (args[0]) {
        .int => |v| v,
        else => return error.TypeError,
    };
    if (n <= 0) {
        const empty = try value_mod.PersistentList.empty(allocator);
        return Value{ .list = empty };
    }
    const items = try allocator.alloc(Value, @intCast(n));
    defer allocator.free(items);
    for (items) |*item| {
        item.* = args[1];
    }
    const result = try value_mod.PersistentList.fromSlice(allocator, items);
    return Value{ .list = result };
}

/// random-sample : 確率 prob でシーケンスから要素をサンプリング
pub fn randomSample(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const prob = switch (args[0]) {
        .float => |f| f,
        .int => |n| @as(f64, @floatFromInt(n)),
        else => return error.TypeError,
    };
    const items = try collectToSlice(allocator, args[1]);
    defer allocator.free(items);

    var result_items = std.ArrayList(Value).empty;
    defer result_items.deinit(allocator);

    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();
    for (items) |item| {
        if (random.float(f64) < prob) {
            try result_items.append(allocator, item);
        }
    }

    const result = try value_mod.PersistentList.fromSlice(allocator, result_items.items);
    return Value{ .list = result };
}

/// == : 数値等価比較（数値型同士のみ true）
pub fn numericEq(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1) return error.ArityError;
    if (args.len == 1) return value_mod.true_val;

    const first_f = numToFloat(args[0]) orelse return value_mod.false_val;
    for (args[1..]) |arg| {
        const b_f = numToFloat(arg) orelse return value_mod.false_val;
        if (first_f != b_f) return value_mod.false_val;
    }
    return value_mod.true_val;
}

fn numToFloat(v: Value) ?f64 {
    return switch (v) {
        .int => |n| @as(f64, @floatFromInt(n)),
        .float => |f| f,
        else => null,
    };
}

// --- マルチメソッド拡張 ---

/// get-method : マルチメソッドのディスパッチ値に対応するメソッドを取得
pub fn getMethod(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const mf = switch (args[0]) {
        .multi_fn => |m| m,
        else => return error.TypeError,
    };
    // ディスパッチ値でメソッドを検索
    if (mf.methods.get(args[1])) |method| {
        return method;
    }
    // default メソッドチェック
    if (mf.default_method) |dm| {
        return dm;
    }
    return value_mod.nil;
}

/// methods : マルチメソッドの全メソッドをマップで返す
pub fn methodsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const mf = switch (args[0]) {
        .multi_fn => |m| m,
        else => return error.TypeError,
    };
    return Value{ .map = mf.methods };
}

/// remove-method : マルチメソッドからディスパッチ値に対応するメソッドを削除
pub fn removeMethod(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const mf = switch (args[0]) {
        .multi_fn => |m| m,
        else => return error.TypeError,
    };
    const new_map_val = try mf.methods.dissoc(allocator, args[1]);
    const new_map = try allocator.create(value_mod.PersistentMap);
    new_map.* = new_map_val;
    mf.methods = new_map;
    return args[0];
}

/// remove-all-methods : マルチメソッドの全メソッドを削除
pub fn removeAllMethods(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const mf = switch (args[0]) {
        .multi_fn => |m| m,
        else => return error.TypeError,
    };
    const empty_map = try allocator.create(value_mod.PersistentMap);
    empty_map.* = value_mod.PersistentMap.empty();
    mf.methods = empty_map;
    mf.default_method = null;
    return args[0];
}

/// prefer-method : マルチメソッドの優先度を設定
/// (prefer-method mf dispatch-val-x dispatch-val-y)
/// → x を y より優先する
pub fn preferMethod(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const mf = switch (args[0]) {
        .multi_fn => |m| m,
        else => return error.TypeError,
    };
    const preferred = args[1];
    const over = args[2];

    // prefer テーブルの取得または新規作成
    var pt = if (mf.prefer_table) |t| t.* else value_mod.PersistentMap.empty();

    // preferred の既存セットを取得、なければ空セット作成
    const existing = pt.get(preferred);
    var items: []Value = undefined;
    if (existing) |ex| {
        if (ex == .set) {
            // 既存セットに追加
            const old = ex.set.items;
            items = try allocator.alloc(Value, old.len + 1);
            @memcpy(items[0..old.len], old);
            items[old.len] = over;
        } else {
            items = try allocator.alloc(Value, 1);
            items[0] = over;
        }
    } else {
        items = try allocator.alloc(Value, 1);
        items[0] = over;
    }

    const new_set = try allocator.create(value_mod.PersistentSet);
    new_set.* = .{ .items = items };
    const set_val = Value{ .set = new_set };

    const new_table = try allocator.create(value_mod.PersistentMap);
    new_table.* = try pt.assoc(allocator, preferred, set_val);
    mf.prefer_table = new_table;

    return args[0];
}

/// prefers : マルチメソッドの優先度マップを返す
pub fn prefersFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    _ = switch (args[0]) {
        .multi_fn => |m| m,
        else => return error.TypeError,
    };
    // 現在は空マップを返す（階層システム実装時に有効化）
    const empty_map = try allocator.create(value_mod.PersistentMap);
    empty_map.* = value_mod.PersistentMap.empty();
    return Value{ .map = empty_map };
}

// ============================================================
// Phase 12E: HOF・遅延操作
// ============================================================

/// trampoline : 関数を呼び続ける（結果が関数でなくなるまで）
/// (trampoline f & args) — f を args で呼び、結果が関数なら再度呼ぶ
pub fn trampolineFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    const call = call_fn orelse return error.TypeError;

    // 初回呼び出し
    var result = try call(args[0], args[1..], allocator);

    // 結果が関数の間ループ
    while (isFnValue(result)) {
        result = try call(result, &[_]Value{}, allocator);
    }
    return result;
}

/// tree-seq : ツリーを深さ優先で走査
/// (tree-seq branch? children root)
pub fn treeSeqFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const call = call_fn orelse return error.TypeError;
    const branch_pred = args[0];
    const children_fn = args[1];
    const root = args[2];

    // 深さ優先走査（eager）
    var result_items = std.ArrayList(Value).empty;
    defer result_items.deinit(allocator);

    var stack = std.ArrayList(Value).empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, root);

    while (stack.items.len > 0) {
        const node = stack.pop().?;
        try result_items.append(allocator, node);

        // branch? 判定
        const is_branch = try call(branch_pred, &[_]Value{node}, allocator);
        if (is_branch.isTruthy()) {
            // children 取得
            const children_val = try call(children_fn, &[_]Value{node}, allocator);
            const children_slice = try collectToSlice(allocator, children_val);
            defer allocator.free(children_slice);

            // スタックに逆順でpush（深さ優先のため）
            var i: usize = children_slice.len;
            while (i > 0) {
                i -= 1;
                try stack.append(allocator, children_slice[i]);
            }
        }
    }

    const result = try value_mod.PersistentList.fromSlice(allocator, result_items.items);
    return Value{ .list = result };
}

/// partition-by : 述語の結果が変わるたびにグループを分割
/// (partition-by f coll)
pub fn partitionByFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const call = call_fn orelse return error.TypeError;
    const f = args[0];
    const items = try collectToSlice(allocator, args[1]);
    defer allocator.free(items);

    if (items.len == 0) {
        const empty = try value_mod.PersistentList.empty(allocator);
        return Value{ .list = empty };
    }

    var result_groups = std.ArrayList(Value).empty;
    defer result_groups.deinit(allocator);

    var current_group = std.ArrayList(Value).empty;
    defer current_group.deinit(allocator);

    var prev_key = try call(f, &[_]Value{items[0]}, allocator);
    try current_group.append(allocator, items[0]);

    for (items[1..]) |item| {
        const key = try call(f, &[_]Value{item}, allocator);
        if (!key.eql(prev_key)) {
            // 新グループ開始
            const group_list = try value_mod.PersistentList.fromSlice(allocator, current_group.items);
            try result_groups.append(allocator, Value{ .list = group_list });
            current_group.clearRetainingCapacity();
            prev_key = key;
        }
        try current_group.append(allocator, item);
    }

    // 最後のグループ
    if (current_group.items.len > 0) {
        const group_list = try value_mod.PersistentList.fromSlice(allocator, current_group.items);
        try result_groups.append(allocator, Value{ .list = group_list });
    }

    const result = try value_mod.PersistentList.fromSlice(allocator, result_groups.items);
    return Value{ .list = result };
}

/// isFnValue : 値が関数かどうか判定（内部ヘルパー）
fn isFnValue(v: Value) bool {
    return switch (v) {
        .fn_val, .partial_fn, .comp_fn, .fn_proto => true,
        else => false,
    };
}

// ============================================================
// Phase 13: delay/volatile/reduced
// ============================================================

/// __delay-create : Delay オブジェクトを作成（内部用）
/// (delay expr) マクロから呼ばれる: (__delay-create (fn [] expr))
pub fn delayCreate(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    // 引数は (fn [] expr) 形式の関数
    if (!isFnValue(args[0])) return error.TypeError;
    const d = try allocator.create(value_mod.Delay);
    d.* = value_mod.Delay.init(args[0]);
    return Value{ .delay_val = d };
}

/// force : delay の値を取得（未評価なら評価してキャッシュ）
pub fn forceFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .delay_val => |d| {
            if (d.realized) {
                return d.cached orelse value_mod.nil;
            }
            // 関数を呼び出して結果をキャッシュ
            const call = call_fn orelse return error.TypeError;
            const result = try call(d.fn_val.?, &[_]Value{}, allocator);
            d.cached = result;
            d.fn_val = null;
            d.realized = true;
            return result;
        },
        else => args[0], // delay でない値はそのまま返す
    };
}

/// delay? : Delay オブジェクトかどうか
pub fn isDelayFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .delay_val) value_mod.true_val else value_mod.false_val;
}

/// volatile! : Volatile ボックスを作成
pub fn volatileBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const v = try allocator.create(value_mod.Volatile);
    v.* = value_mod.Volatile.init(args[0]);
    return Value{ .volatile_val = v };
}

/// volatile? : Volatile かどうか
pub fn isVolatileFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .volatile_val) value_mod.true_val else value_mod.false_val;
}

/// vreset! : Volatile の値をリセット
pub fn vresetBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const v = switch (args[0]) {
        .volatile_val => |vol| vol,
        else => return error.TypeError,
    };
    v.value = args[1];
    return args[1];
}

/// vswap! : Volatile の値を関数で更新 (vswap! vol f & args)
pub fn vswapBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const v = switch (args[0]) {
        .volatile_val => |vol| vol,
        else => return error.TypeError,
    };
    const call = call_fn orelse return error.TypeError;
    // (f current-val & extra-args)
    var call_args = std.ArrayList(Value).empty;
    defer call_args.deinit(allocator);
    try call_args.append(allocator, v.value);
    for (args[2..]) |extra| {
        try call_args.append(allocator, extra);
    }
    const new_val = try call(args[1], call_args.items, allocator);
    v.value = new_val;
    return new_val;
}

/// reduced : 値を Reduced でラップ（reduce の早期終了用）
pub fn reducedFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const r = try allocator.create(value_mod.Reduced);
    r.* = value_mod.Reduced.init(args[0]);
    return Value{ .reduced_val = r };
}

/// reduced? : Reduced かどうか
pub fn isReducedFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .reduced_val) value_mod.true_val else value_mod.false_val;
}

/// unreduced : Reduced の内部値を取得（Reduced でなければそのまま）
pub fn unreducedFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .reduced_val => |r| r.value,
        else => args[0],
    };
}

/// ensure-reduced : Reduced でなければ Reduced でラップ
pub fn ensureReducedFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .reduced_val => args[0], // 既に Reduced
        else => {
            const r = try allocator.create(value_mod.Reduced);
            r.* = value_mod.Reduced.init(args[0]);
            return Value{ .reduced_val = r };
        },
    };
}

// ============================================================
// Phase 14: transient / transduce
// ============================================================

/// transient : 永続コレクションからミュータブルな一時コレクションを作成
/// (transient coll) → Transient
pub fn transientFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const t = try allocator.create(value_mod.Transient);
    t.* = switch (args[0]) {
        .vector => |v| try value_mod.Transient.initVector(allocator, v.items),
        .map => |m| try value_mod.Transient.initMap(allocator, m.entries),
        .set => |s| try value_mod.Transient.initSet(allocator, s.items),
        else => return error.TypeError,
    };
    return Value{ .transient = t };
}

/// persistent! : Transient を永続コレクションに変換
/// (persistent! tcoll) → PersistentVector/PersistentMap/PersistentSet
pub fn persistentBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const t = switch (args[0]) {
        .transient => |tr| tr,
        else => return error.TypeError,
    };
    if (t.persisted) return error.TypeError; // 二重 persistent! を防止
    t.persisted = true;
    return switch (t.kind) {
        .vector => blk: {
            const v = try allocator.create(value_mod.PersistentVector);
            v.* = .{ .items = if (t.items) |items| items.items else &[_]Value{} };
            break :blk Value{ .vector = v };
        },
        .map => blk: {
            const m = try allocator.create(value_mod.PersistentMap);
            m.* = .{ .entries = if (t.entries) |entries| entries.items else &[_]Value{} };
            break :blk Value{ .map = m };
        },
        .set => blk: {
            const s = try allocator.create(value_mod.PersistentSet);
            s.* = .{ .items = if (t.items) |items| items.items else &[_]Value{} };
            break :blk Value{ .set = s };
        },
    };
}

/// conj! : Transient に要素を追加（インプレース）
/// (conj! tcoll val) → tcoll
pub fn conjBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const t = switch (args[0]) {
        .transient => |tr| tr,
        else => return error.TypeError,
    };
    if (t.persisted) return error.TypeError;
    switch (t.kind) {
        .vector => {
            var items = &(t.items.?);
            for (args[1..]) |val| {
                try items.append(allocator, val);
            }
        },
        .map => {
            // conj! でマップに追加: val は [k v] ベクター or MapEntry
            var entries = &(t.entries.?);
            for (args[1..]) |val| {
                switch (val) {
                    .vector => |v| {
                        if (v.items.len != 2) return error.TypeError;
                        // 既存キーの上書きチェック
                        var found = false;
                        var i: usize = 0;
                        while (i < entries.items.len) : (i += 2) {
                            if (entries.items[i].eql(v.items[0])) {
                                entries.items[i + 1] = v.items[1];
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            try entries.append(allocator, v.items[0]);
                            try entries.append(allocator, v.items[1]);
                        }
                    },
                    else => return error.TypeError,
                }
            }
        },
        .set => {
            var items = &(t.items.?);
            for (args[1..]) |val| {
                // 重複チェック
                var found = false;
                for (items.items) |existing| {
                    if (existing.eql(val)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try items.append(allocator, val);
                }
            }
        },
    }
    return args[0]; // transient を返す
}

/// assoc! : Transient マップにキー・値を追加（インプレース）
/// (assoc! tmap key val) → tmap
pub fn assocBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 3 or (args.len - 1) % 2 != 0) return error.ArityError;
    const t = switch (args[0]) {
        .transient => |tr| tr,
        else => return error.TypeError,
    };
    if (t.persisted) return error.TypeError;
    if (t.kind != .map and t.kind != .vector) return error.TypeError;

    if (t.kind == .map) {
        var entries = &(t.entries.?);
        var i: usize = 1;
        while (i < args.len) : (i += 2) {
            const key = args[i];
            const val = args[i + 1];
            // 既存キーの上書きチェック
            var found = false;
            var j: usize = 0;
            while (j < entries.items.len) : (j += 2) {
                if (entries.items[j].eql(key)) {
                    entries.items[j + 1] = val;
                    found = true;
                    break;
                }
            }
            if (!found) {
                try entries.append(allocator, key);
                try entries.append(allocator, val);
            }
        }
    } else {
        // vector: assoc! でインデックス指定更新
        var items = &(t.items.?);
        var i: usize = 1;
        while (i < args.len) : (i += 2) {
            const idx = switch (args[i]) {
                .int => |n| blk: {
                    if (n < 0) return error.TypeError;
                    break :blk @as(usize, @intCast(n));
                },
                else => return error.TypeError,
            };
            const val = args[i + 1];
            if (idx > items.items.len) return error.TypeError;
            if (idx == items.items.len) {
                try items.append(allocator, val);
            } else {
                items.items[idx] = val;
            }
        }
    }
    return args[0];
}

/// dissoc! : Transient マップからキーを削除（インプレース）
/// (dissoc! tmap key) → tmap
pub fn dissocBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) return error.ArityError;
    const t = switch (args[0]) {
        .transient => |tr| tr,
        else => return error.TypeError,
    };
    if (t.persisted) return error.TypeError;
    if (t.kind != .map) return error.TypeError;

    var entries = &(t.entries.?);
    for (args[1..]) |key| {
        var i: usize = 0;
        while (i < entries.items.len) {
            if (i + 1 < entries.items.len and entries.items[i].eql(key)) {
                // エントリを削除（順序入れ替え）
                _ = entries.orderedRemove(i);
                _ = entries.orderedRemove(i);
            } else {
                i += 2;
            }
        }
    }
    return args[0];
}

/// disj! : Transient セットから要素を削除（インプレース）
/// (disj! tset val) → tset
pub fn disjBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) return error.ArityError;
    const t = switch (args[0]) {
        .transient => |tr| tr,
        else => return error.TypeError,
    };
    if (t.persisted) return error.TypeError;
    if (t.kind != .set) return error.TypeError;

    var items = &(t.items.?);
    for (args[1..]) |val| {
        for (items.items, 0..) |existing, i| {
            if (existing.eql(val)) {
                _ = items.orderedRemove(i);
                break;
            }
        }
    }
    return args[0];
}

/// pop! : Transient ベクターの末尾を削除（インプレース）
/// (pop! tvec) → tvec
pub fn popBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const t = switch (args[0]) {
        .transient => |tr| tr,
        else => return error.TypeError,
    };
    if (t.persisted) return error.TypeError;
    if (t.kind != .vector) return error.TypeError;

    var items = &(t.items.?);
    if (items.items.len == 0) return error.TypeError;
    _ = items.pop();
    return args[0];
}

/// completing : 2-arity 関数を 0/1-arity にも対応させる
/// (completing f) → f と同じ（0-arity は identity で補完）
/// (completing f cf) → cf を完了関数として合成
pub fn completingFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;
    // 簡易実装: f をそのまま返す（Clojure の completing は
    // 1-arity 完了呼び出しを追加するが、我々の transduce が直接処理する）
    _ = allocator;
    return args[0];
}

/// transduce : トランスデューサによるリダクション
/// (transduce xform f coll)
/// (transduce xform f init coll)
pub fn transduceFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 3 or args.len > 4) return error.ArityError;
    const call = call_fn orelse return error.TypeError;

    const xform = args[0];
    const f = args[1];

    // xform を f に適用してリデューサを得る: (xform f)
    const xf = try call(xform, &[_]Value{f}, allocator);

    var acc: Value = undefined;
    var coll: Value = undefined;

    if (args.len == 4) {
        // (transduce xform f init coll)
        acc = args[2];
        coll = args[3];
    } else {
        // (transduce xform f coll) — 初期値は (f)
        acc = try call(f, &[_]Value{}, allocator);
        coll = args[2];
    }

    // コレクションの要素を取得
    const items = try collectToSlice(allocator, coll);

    // reduce ループ（reduced 対応）
    for (items) |item| {
        acc = try call(xf, &[_]Value{ acc, item }, allocator);
        // reduced チェック
        if (acc == .reduced_val) {
            acc = acc.reduced_val.value;
            break;
        }
    }

    // 完了ステップ: (xf acc) — 1-arity が未定義ならスキップ
    return call(xf, &[_]Value{acc}, allocator) catch acc;
}

/// cat : トランスデューサ — 内部コレクションを連結する
/// (cat rf) → rf を受け取って concat-reducing 関数を返す
/// cat 自体がトランスデューサ（rf → reducing-fn）として機能する
pub fn catFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    // rf を部分適用した cat-step 関数を返す
    const pf = try allocator.create(value_mod.PartialFn);
    pf.* = .{
        .fn_val = blk: {
            const fn_obj = try allocator.create(value_mod.Fn);
            fn_obj.* = value_mod.Fn.initBuiltin("__cat-step", @ptrCast(&catStep));
            break :blk Value{ .fn_val = fn_obj };
        },
        .args = try allocator.dupe(Value, args[0..1]),
    };
    return Value{ .partial_fn = pf };
}

/// cat の step 関数: (rf result input) — input がコレクションなら各要素を rf に渡す
fn catStep(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // PartialFn から呼ばれるので args = [rf, ...remaining]
    if (args.len == 2) {
        // 完了ステップ: (step result) — 1-arity
        return args[1];
    }
    if (args.len != 3) return error.ArityError;
    const call = call_fn orelse return error.TypeError;
    const rf = args[0];
    var result = args[1];
    const input = args[2];

    // input がコレクションなら各要素を rf に渡す
    const items = collectToSlice(allocator, input) catch {
        // コレクションでなければそのまま rf に渡す
        return try call(rf, &[_]Value{ result, input }, allocator);
    };

    for (items) |item| {
        result = try call(rf, &[_]Value{ result, item }, allocator);
        if (result == .reduced_val) break;
    }
    return result;
}

/// eduction : トランスデューサとコレクションをラップして遅延的に繰り返し可能にする
/// (eduction xform* coll) — 簡易実装: 即座に変換を適用してリストを返す
pub fn eductionFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    const call = call_fn orelse return error.TypeError;

    // 最後の引数がコレクション、それ以前がトランスデューサ
    const coll = args[args.len - 1];
    const items = try collectToSlice(allocator, coll);

    // xform を comp する（複数の場合）
    if (args.len == 1) {
        // コレクションだけ → そのまま返す
        return coll;
    }

    // 各 xform を合成: (comp xf1 xf2 ...) の効果
    // 簡易版: xform を順に適用
    var current_items = items;
    for (args[0 .. args.len - 1]) |xform| {
        // conj を reducing 関数として使用
        const conj_fn = try allocator.create(value_mod.Fn);
        conj_fn.* = value_mod.Fn.initBuiltin("conj", @ptrCast(&conjFn));
        const rf = try call(xform, &[_]Value{Value{ .fn_val = conj_fn }}, allocator);

        // reduce
        var acc: Value = blk: {
            const v = try allocator.create(value_mod.PersistentVector);
            v.* = .{ .items = &[_]Value{} };
            break :blk Value{ .vector = v };
        };
        for (current_items) |item| {
            acc = try call(rf, &[_]Value{ acc, item }, allocator);
            if (acc == .reduced_val) {
                acc = acc.reduced_val.value;
                break;
            }
        }
        // 完了ステップ（1-arity が未定義ならスキップ）
        acc = call(rf, &[_]Value{acc}, allocator) catch acc;
        current_items = try collectToSlice(allocator, acc);
    }

    // リストとして返す
    const result = try allocator.create(value_mod.PersistentList);
    const result_items = try allocator.alloc(Value, current_items.len);
    @memcpy(result_items, current_items);
    result.* = .{ .items = result_items };
    return Value{ .list = result };
}

/// conj の builtin 関数（eduction 内で使用）
fn conjFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) {
        // 0-arity: 空ベクター
        const v = try allocator.create(value_mod.PersistentVector);
        v.* = .{ .items = &[_]Value{} };
        return Value{ .vector = v };
    }
    if (args.len == 1) {
        // 1-arity: 完了（そのまま返す）
        return args[0];
    }
    // 2-arity: コレクションに要素追加
    return switch (args[0]) {
        .vector => |v| blk: {
            const new_items = try allocator.alloc(Value, v.items.len + 1);
            @memcpy(new_items[0..v.items.len], v.items);
            new_items[v.items.len] = args[1];
            const new_v = try allocator.create(value_mod.PersistentVector);
            new_v.* = .{ .items = new_items };
            break :blk Value{ .vector = new_v };
        },
        .list => |l| blk: {
            const new_items = try allocator.alloc(Value, l.items.len + 1);
            new_items[0] = args[1];
            @memcpy(new_items[1..], l.items);
            const new_l = try allocator.create(value_mod.PersistentList);
            new_l.* = .{ .items = new_items };
            break :blk Value{ .list = new_l };
        },
        else => error.TypeError,
    };
}

/// halt-when : トランスデューサ — 述語が真になったら停止
/// (halt-when pred) → トランスデューサ（rf を受け取る関数）
pub fn haltWhenFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;
    // pred を部分適用した xform 関数を返す
    const pf = try allocator.create(value_mod.PartialFn);
    pf.* = .{
        .fn_val = blk: {
            const fn_obj = try allocator.create(value_mod.Fn);
            fn_obj.* = value_mod.Fn.initBuiltin("__halt-when-xform", @ptrCast(&haltWhenXform));
            break :blk Value{ .fn_val = fn_obj };
        },
        .args = try allocator.dupe(Value, args[0..1]), // [pred]
    };
    return Value{ .partial_fn = pf };
}

/// halt-when xform: (pred rf) → reducing 関数を返す
fn haltWhenXform(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // PartialFn 経由: args = [pred, rf]
    if (args.len != 2) return error.ArityError;
    // [pred, rf] を部分適用した step 関数を返す
    const pf = try allocator.create(value_mod.PartialFn);
    pf.* = .{
        .fn_val = blk: {
            const fn_obj = try allocator.create(value_mod.Fn);
            fn_obj.* = value_mod.Fn.initBuiltin("__halt-when-step", @ptrCast(&haltWhenStep));
            break :blk Value{ .fn_val = fn_obj };
        },
        .args = try allocator.dupe(Value, args[0..2]), // [pred, rf]
    };
    return Value{ .partial_fn = pf };
}

/// halt-when step 関数
/// PartialFn 経由: args = [pred, rf, result(, input)]
fn haltWhenStep(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // 完了ステップ: (step result) → 3 args [pred, rf, result]
    if (args.len == 3) {
        return args[2]; // result をそのまま返す
    }
    // step: (step result input) → 4 args [pred, rf, result, input]
    if (args.len != 4) return error.ArityError;
    const call = call_fn orelse return error.TypeError;
    const pred = args[0];
    const rf = args[1];
    const result = args[2];
    const input = args[3];

    const pred_result = try call(pred, &[_]Value{input}, allocator);
    if (pred_result.isTruthy()) {
        // halt: reduced を返す
        const r = try allocator.create(value_mod.Reduced);
        r.* = value_mod.Reduced.init(result);
        return Value{ .reduced_val = r };
    }
    return try call(rf, &[_]Value{ result, input }, allocator);
}

/// iteration : 遅延ステートフルイテレータ
/// (iteration step-fn & {:keys [initk vf kf]})
/// 簡易実装: step を繰り返し適用する遅延シーケンスを返す
pub fn iterationFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // 簡易実装: (iteration f {:seed s :vf vf :kf kf})
    // Clojure 1.11 の iteration は複雑だが、基本形を実装
    if (args.len < 1) return error.ArityError;
    const call = call_fn orelse return error.TypeError;

    const step_fn = args[0];

    // キーワード引数をパース
    var seed: Value = value_mod.nil;
    var vf: ?Value = null;
    var kf: ?Value = null;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        if (args[i] == .keyword) {
            const name = args[i].keyword.name;
            if (std.mem.eql(u8, name, "seed")) {
                seed = args[i + 1];
            } else if (std.mem.eql(u8, name, "vf")) {
                vf = args[i + 1];
            } else if (std.mem.eql(u8, name, "kf")) {
                kf = args[i + 1];
            }
        }
    }

    // step を適用して即座にシーケンスを生成（上限付き）
    var results = std.ArrayList(Value).empty;
    defer results.deinit(allocator);
    var current_key = seed;
    const max_iter: usize = 1000; // 安全上限
    var iter_count: usize = 0;

    while (iter_count < max_iter) : (iter_count += 1) {
        const step_result = try call(step_fn, &[_]Value{current_key}, allocator);

        // step_result はマップ {:val v :next-key k} を期待
        // 簡易版: 結果をそのまま value/key として使う
        const val = if (vf) |vf_fn|
            try call(vf_fn, &[_]Value{step_result}, allocator)
        else
            step_result;

        const next_key = if (kf) |kf_fn|
            try call(kf_fn, &[_]Value{step_result}, allocator)
        else
            step_result;

        // nil で終了
        if (val.isNil()) break;

        try results.append(allocator, val);
        current_key = next_key;
    }

    // リストとして返す
    const result_items = try allocator.alloc(Value, results.items.len);
    @memcpy(result_items, results.items);
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = result_items };
    return Value{ .list = result };
}

// ============================================================
// Phase 15: Atom 拡張・Var 操作・メタデータ
// ============================================================

/// add-watch : Atom にウォッチャーを登録
/// (add-watch atom key fn) → atom
/// fn は (fn [key atom old-val new-val] ...) 形式
pub fn addWatchFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const a = switch (args[0]) {
        .atom => |atom| atom,
        else => return error.TypeError,
    };
    const key = args[1];
    const watch_fn = args[2];
    // watches 配列に [key, fn] を追加
    var new_watches = std.ArrayList(Value).empty;
    if (a.watches) |ws| {
        try new_watches.appendSlice(allocator, ws);
    }
    try new_watches.append(allocator, key);
    try new_watches.append(allocator, watch_fn);
    a.watches = new_watches.items;
    return args[0];
}

/// remove-watch : Atom からウォッチャーを削除
/// (remove-watch atom key) → atom
pub fn removeWatchFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const a = switch (args[0]) {
        .atom => |atom| atom,
        else => return error.TypeError,
    };
    const key = args[1];
    if (a.watches) |ws| {
        // [key1, fn1, key2, fn2, ...] からキーを検索して削除
        var i: usize = 0;
        while (i + 1 < ws.len) {
            if (ws[i].eql(key)) {
                // 見つかった: key, fn の2要素を除去した新配列を作成
                // 簡易版: null 化（GC で回収）
                // TODO: 配列を再構築
                break;
            }
            i += 2;
        }
    }
    return args[0];
}

/// get-validator : Atom のバリデータを取得
/// (get-validator atom) → fn or nil
pub fn getValidatorFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const a = switch (args[0]) {
        .atom => |atom| atom,
        else => return error.TypeError,
    };
    return a.validator orelse value_mod.nil;
}

/// set-validator! : Atom にバリデータを設定
/// (set-validator! atom fn) → nil
pub fn setValidatorBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const a = switch (args[0]) {
        .atom => |atom| atom,
        else => return error.TypeError,
    };
    a.validator = if (args[1].isNil()) null else args[1];
    return value_mod.nil;
}

/// compare-and-set! : Atom の値を CAS で更新
/// (compare-and-set! atom oldval newval) → bool
pub fn compareAndSetBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const a = switch (args[0]) {
        .atom => |atom| atom,
        else => return error.TypeError,
    };
    if (a.value.eql(args[1])) {
        const cloned = try args[2].deepClone(allocator);
        a.value = cloned;
        return value_mod.true_val;
    }
    return value_mod.false_val;
}

/// reset-vals! : Atom を新値に設定し [old new] を返す
/// (reset-vals! atom newval) → [old-val new-val]
pub fn resetValsBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const a = switch (args[0]) {
        .atom => |atom| atom,
        else => return error.TypeError,
    };
    const old_val = a.value;
    const cloned = try args[1].deepClone(allocator);
    a.value = cloned;
    // [old new] ベクターを返す
    const items = try allocator.alloc(Value, 2);
    items[0] = old_val;
    items[1] = cloned;
    const v = try allocator.create(value_mod.PersistentVector);
    v.* = .{ .items = items };
    return Value{ .vector = v };
}

/// swap-vals! : Atom に関数を適用し [old new] を返す
/// (swap-vals! atom f & args) → [old-val new-val]
pub fn swapValsBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const a = switch (args[0]) {
        .atom => |atom| atom,
        else => return error.TypeError,
    };
    const call = call_fn orelse return error.TypeError;
    const old_val = a.value;
    // (f current-val extra-args...)
    var call_args = std.ArrayList(Value).empty;
    defer call_args.deinit(allocator);
    try call_args.append(allocator, a.value);
    for (args[2..]) |extra| {
        try call_args.append(allocator, extra);
    }
    const new_val = try call(args[1], call_args.items, allocator);
    const cloned = try new_val.deepClone(allocator);
    a.value = cloned;
    // [old new] ベクターを返す
    const items = try allocator.alloc(Value, 2);
    items[0] = old_val;
    items[1] = cloned;
    const v = try allocator.create(value_mod.PersistentVector);
    v.* = .{ .items = items };
    return Value{ .vector = v };
}

/// var-get : Var の値を取得
/// (var-get var) → val
pub fn varGetFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const v = switch (args[0]) {
        .var_val => |vp| @as(*Var, @ptrCast(@alignCast(vp))),
        else => return error.TypeError,
    };
    return v.deref();
}

/// var-set : スレッドバインディングの値を設定 (binding 内でのみ有効)
/// (var-set var val) → val
pub fn varSetFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const v = switch (args[0]) {
        .var_val => |vp| @as(*Var, @ptrCast(@alignCast(vp))),
        else => return error.TypeError,
    };
    try var_mod.setThreadBinding(v, args[1]);
    return args[1];
}

/// alter-var-root : Var の root 値を関数で更新
/// (alter-var-root var f & args) → new-val
pub fn alterVarRootFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const v = switch (args[0]) {
        .var_val => |vp| @as(*Var, @ptrCast(@alignCast(vp))),
        else => return error.TypeError,
    };
    const call = call_fn orelse return error.TypeError;
    // (f current-val extra-args...)
    var call_args = std.ArrayList(Value).empty;
    defer call_args.deinit(allocator);
    try call_args.append(allocator, v.getRawRoot());
    for (args[2..]) |extra| {
        try call_args.append(allocator, extra);
    }
    const new_val = try call(args[1], call_args.items, allocator);
    v.bindRoot(new_val);
    return new_val;
}

/// find-var : 名前空間修飾シンボルから Var を検索
/// (find-var 'ns/name) → var or nil
pub fn findVarFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const sym = switch (args[0]) {
        .symbol => |s| s,
        else => return error.TypeError,
    };
    const env = current_env orelse return error.TypeError;
    const ns_name = sym.namespace orelse return value_mod.nil;
    const ns = env.findNs(ns_name) orelse return value_mod.nil;
    const v = ns.resolve(sym.name) orelse return value_mod.nil;
    return Value{ .var_val = @ptrCast(v) };
}

/// intern : 名前空間に Var を定義
/// (intern ns-sym name-sym) or (intern ns-sym name-sym val)
pub fn internFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    const env = current_env orelse return error.TypeError;
    const ns_name = switch (args[0]) {
        .symbol => |s| s.name,
        .string => |s| s.data,
        else => return error.TypeError,
    };
    const sym_name = switch (args[1]) {
        .symbol => |s| s.name,
        .string => |s| s.data,
        else => return error.TypeError,
    };
    const ns = try env.findOrCreateNs(ns_name);
    const v = try ns.intern(sym_name);
    if (args.len == 3) {
        const cloned = try args[2].deepClone(allocator);
        v.bindRoot(cloned);
    }
    return Value{ .var_val = @ptrCast(v) };
}

/// bound? : Var が束縛されているか（root が nil でない）
/// (bound? var) → bool
pub fn boundPred(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1) return error.ArityError;
    // 全引数が bound であれば true
    for (args) |arg| {
        const v = switch (arg) {
            .var_val => |vp| @as(*Var, @ptrCast(@alignCast(vp))),
            else => return error.TypeError,
        };
        if (v.deref().isNil()) return value_mod.false_val;
    }
    return value_mod.true_val;
}

/// alter-meta! : 参照のメタデータを関数で更新
/// (alter-meta! ref f & args) → new-meta
pub fn alterMetaBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const call = call_fn orelse return error.TypeError;

    // 現在のメタを取得
    const current_meta: Value = switch (args[0]) {
        .atom => |a| a.meta orelse value_mod.nil,
        .var_val => |vp| blk: {
            const v: *Var = @ptrCast(@alignCast(vp));
            break :blk if (v.meta) |m| m.* else value_mod.nil;
        },
        else => return error.TypeError,
    };

    // (f current-meta extra-args...)
    var call_args = std.ArrayList(Value).empty;
    defer call_args.deinit(allocator);
    try call_args.append(allocator, current_meta);
    for (args[2..]) |extra| {
        try call_args.append(allocator, extra);
    }
    const new_meta = try call(args[1], call_args.items, allocator);

    // メタを更新
    switch (args[0]) {
        .atom => |a| {
            a.meta = new_meta;
        },
        .var_val => |vp| {
            const v: *Var = @ptrCast(@alignCast(vp));
            const meta_ptr = try allocator.create(Value);
            meta_ptr.* = new_meta;
            v.meta = meta_ptr;
        },
        else => return error.TypeError,
    }
    return new_meta;
}

/// reset-meta! : 参照のメタデータを新値に置換
/// (reset-meta! ref new-meta) → new-meta
pub fn resetMetaBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    switch (args[0]) {
        .atom => |a| {
            a.meta = args[1];
        },
        .var_val => |vp| {
            const v: *Var = @ptrCast(@alignCast(vp));
            const meta_ptr = try allocator.create(Value);
            meta_ptr.* = args[1];
            v.meta = meta_ptr;
        },
        else => return error.TypeError,
    }
    return args[1];
}

/// vary-meta : オブジェクトのメタデータを関数で変更した新オブジェクトを返す
/// (vary-meta obj f & args) → obj-with-new-meta
/// 簡易実装: alter-meta! と同等（永続オブジェクトのメタ変更）
pub fn varyMetaFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    // vary-meta は immutable オブジェクトのメタを変更する
    // 現時点では alter-meta! と同等に処理
    _ = try alterMetaBang(allocator, args);
    return args[0];
}

// ============================================================
// Phase 17: 階層システム
// ============================================================

/// グローバル階層（シンプルなマップベース実装）
/// parents: {child -> #{parent1 parent2 ...}}
/// ancestors: {child -> #{ancestor1 ancestor2 ...}}
/// descendants: {parent -> #{descendant1 descendant2 ...}}
var global_hierarchy: ?Value = null;

/// 空の階層マップを作成
fn emptyHierarchy(allocator: std.mem.Allocator) !Value {
    // {:parents {} :descendants {} :ancestors {}}
    const entries = try allocator.alloc(Value, 6);
    const kw_parents = try allocator.create(value_mod.Keyword);
    kw_parents.* = value_mod.Keyword.init("parents");
    const kw_descendants = try allocator.create(value_mod.Keyword);
    kw_descendants.* = value_mod.Keyword.init("descendants");
    const kw_ancestors = try allocator.create(value_mod.Keyword);
    kw_ancestors.* = value_mod.Keyword.init("ancestors");

    const empty_map = try allocator.create(value_mod.PersistentMap);
    empty_map.* = .{ .entries = &[_]Value{} };
    const empty_map_val = Value{ .map = empty_map };

    entries[0] = Value{ .keyword = kw_parents };
    entries[1] = empty_map_val;
    entries[2] = Value{ .keyword = kw_descendants };
    entries[3] = empty_map_val;
    entries[4] = Value{ .keyword = kw_ancestors };
    entries[5] = empty_map_val;

    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

/// 階層マップから特定のキーのサブマップを取得
fn getHierarchyMap(h: Value, key_name: []const u8) ?*value_mod.PersistentMap {
    const m = switch (h) {
        .map => |map| map,
        else => return null,
    };
    // キーワードで検索
    var i: usize = 0;
    while (i + 1 < m.entries.len) : (i += 2) {
        if (m.entries[i] == .keyword) {
            if (std.mem.eql(u8, m.entries[i].keyword.name, key_name)) {
                return switch (m.entries[i + 1]) {
                    .map => |sub_map| sub_map,
                    else => null,
                };
            }
        }
    }
    return null;
}

/// make-hierarchy : 空の階層マップを作成
/// (make-hierarchy) → {:parents {} :descendants {} :ancestors {}}
pub fn makeHierarchyFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    return try emptyHierarchy(allocator);
}

/// derive : 親子関係を登録
/// (derive child parent) — グローバル階層に登録
/// (derive h child parent) — ローカル階層に登録
pub fn deriveFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;

    var h: Value = undefined;
    var child: Value = undefined;
    var parent: Value = undefined;
    var use_global = false;

    if (args.len == 2) {
        // グローバル階層
        if (global_hierarchy == null) {
            global_hierarchy = try emptyHierarchy(allocator);
        }
        h = global_hierarchy.?;
        // スクラッチメモリの引数を persistent にクローン
        child = try args[0].deepClone(allocator);
        parent = try args[1].deepClone(allocator);
        use_global = true;
    } else {
        // ローカル階層
        h = args[0];
        child = try args[1].deepClone(allocator);
        parent = try args[2].deepClone(allocator);
    }

    // parents マップを更新: child -> #{...parent}
    const parents_map = getHierarchyMap(h, "parents") orelse return error.TypeError;
    var new_parent_set_items = std.ArrayList(Value).empty;
    defer new_parent_set_items.deinit(allocator);

    // 既存の親セットを取得
    if (parents_map.get(child)) |existing| {
        switch (existing) {
            .set => |s| {
                try new_parent_set_items.appendSlice(allocator, s.items);
            },
            else => {},
        }
    }
    // 新しい親を追加（重複チェック）
    var found = false;
    for (new_parent_set_items.items) |item| {
        if (item.eql(parent)) {
            found = true;
            break;
        }
    }
    if (!found) {
        try new_parent_set_items.append(allocator, parent);
    }

    // 新しい parents セット
    const new_set_items = try allocator.alloc(Value, new_parent_set_items.items.len);
    @memcpy(new_set_items, new_parent_set_items.items);
    const new_set = try allocator.create(value_mod.PersistentSet);
    new_set.* = .{ .items = new_set_items };

    // parents マップを更新
    const new_parents_val = try parents_map.assoc(allocator, child, Value{ .set = new_set });
    const new_parents_ptr = try allocator.create(value_mod.PersistentMap);
    new_parents_ptr.* = new_parents_val;

    // ancestors/descendants は parents から動的計算するためダミー空マップで構築
    const empty_map = try allocator.create(value_mod.PersistentMap);
    empty_map.* = .{ .entries = &[_]Value{} };
    const new_h = try buildHierarchy(allocator, new_parents_ptr, empty_map, empty_map);
    if (use_global) {
        global_hierarchy = new_h;
        return value_mod.nil; // Clojure 互換: derive はグローバルなら nil を返す（alter-var-root 経由）
    }
    return new_h;
}

/// 祖先を再帰的に収集
fn collectAncestors(allocator: std.mem.Allocator, parents_map: Value, tag: Value, result: *std.ArrayList(Value)) !void {
    const pm = switch (parents_map) {
        .map => |m| m,
        else => return,
    };
    if (pm.get(tag)) |parent_set| {
        if (parent_set == .set) {
            for (parent_set.set.items) |p| {
                var dup = false;
                for (result.items) |r| {
                    if (r.eql(p)) { dup = true; break; }
                }
                if (!dup) {
                    try result.append(allocator, p);
                    try collectAncestors(allocator, parents_map, p, result);
                }
            }
        }
    }
}

/// 階層マップを構築
fn buildHierarchy(allocator: std.mem.Allocator, parents: *value_mod.PersistentMap, ancestors: *value_mod.PersistentMap, descendants: *value_mod.PersistentMap) !Value {
    const entries = try allocator.alloc(Value, 6);
    const kw_parents = try allocator.create(value_mod.Keyword);
    kw_parents.* = value_mod.Keyword.init("parents");
    const kw_descendants = try allocator.create(value_mod.Keyword);
    kw_descendants.* = value_mod.Keyword.init("descendants");
    const kw_ancestors = try allocator.create(value_mod.Keyword);
    kw_ancestors.* = value_mod.Keyword.init("ancestors");
    entries[0] = Value{ .keyword = kw_parents };
    entries[1] = Value{ .map = parents };
    entries[2] = Value{ .keyword = kw_descendants };
    entries[3] = Value{ .map = descendants };
    entries[4] = Value{ .keyword = kw_ancestors };
    entries[5] = Value{ .map = ancestors };
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

/// underive : 親子関係を削除
/// (underive child parent) or (underive h child parent)
pub fn underiveFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;

    var h: Value = undefined;
    var child: Value = undefined;
    var parent: Value = undefined;
    var use_global = false;

    if (args.len == 2) {
        if (global_hierarchy == null) return value_mod.nil;
        h = global_hierarchy.?;
        child = try args[0].deepClone(allocator);
        parent = try args[1].deepClone(allocator);
        use_global = true;
    } else {
        h = args[0];
        child = try args[1].deepClone(allocator);
        parent = try args[2].deepClone(allocator);
    }

    // parents マップから child の親セットを取得し、parent を除去
    const parents_map = getHierarchyMap(h, "parents") orelse return if (use_global) value_mod.nil else h;
    const existing_set = parents_map.get(child) orelse return if (use_global) value_mod.nil else h;
    if (existing_set != .set) return if (use_global) value_mod.nil else h;

    // parent を除いた新しいセットを作成
    var new_items = std.ArrayList(Value).empty;
    defer new_items.deinit(allocator);
    for (existing_set.set.items) |item| {
        if (!item.eql(parent)) {
            try new_items.append(allocator, item);
        }
    }

    // 新しい parents マップを構築
    var new_parents_map: value_mod.PersistentMap = undefined;
    if (new_items.items.len == 0) {
        // 親がなくなった: child エントリを削除
        new_parents_map = try parents_map.dissoc(allocator, child);
    } else {
        const items = try allocator.alloc(Value, new_items.items.len);
        @memcpy(items, new_items.items);
        const new_set = try allocator.create(value_mod.PersistentSet);
        new_set.* = .{ .items = items };
        new_parents_map = try parents_map.assoc(allocator, child, Value{ .set = new_set });
    }

    // 階層を再構築（ancestors/descendants は parents から動的計算するので、
    // parents だけ更新すれば十分）
    const new_parents_ptr = try allocator.create(value_mod.PersistentMap);
    new_parents_ptr.* = new_parents_map;

    // 既存の ancestors/descendants マップはダミーで渡す（動的計算するので無視される）
    const empty_map = try allocator.create(value_mod.PersistentMap);
    empty_map.* = .{ .entries = &[_]Value{} };
    const new_h = try buildHierarchy(allocator, new_parents_ptr, empty_map, empty_map);

    if (use_global) {
        global_hierarchy = new_h;
        return value_mod.nil;
    }
    return new_h;
}

/// parents : タグの直接の親のセットを返す
/// (parents tag) or (parents h tag)
pub fn parentsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1 or args.len > 2) return error.ArityError;
    const h = if (args.len == 2) args[0] else (global_hierarchy orelse return value_mod.nil);
    const tag = if (args.len == 2) args[1] else args[0];
    const parents_map = getHierarchyMap(h, "parents") orelse return value_mod.nil;
    return parents_map.get(tag) orelse value_mod.nil;
}

/// ancestors : タグの全祖先のセットを返す（parents から再帰計算）
/// (ancestors tag) or (ancestors h tag)
pub fn ancestorsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;
    const h = if (args.len == 2) args[0] else (global_hierarchy orelse return value_mod.nil);
    const tag = if (args.len == 2) args[1] else args[0];
    const parents_map = getHierarchyMap(h, "parents") orelse return value_mod.nil;

    // 再帰的に全祖先を収集
    var result = std.ArrayList(Value).empty;
    defer result.deinit(allocator);
    try collectAncestors(allocator, Value{ .map = parents_map }, tag, &result);
    if (result.items.len == 0) return value_mod.nil;

    const items = try allocator.alloc(Value, result.items.len);
    @memcpy(items, result.items);
    const set = try allocator.create(value_mod.PersistentSet);
    set.* = .{ .items = items };
    return Value{ .set = set };
}

/// descendants : タグの全子孫のセットを返す（parents から逆引き計算）
/// (descendants tag) or (descendants h tag)
pub fn descendantsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;
    const h = if (args.len == 2) args[0] else (global_hierarchy orelse return value_mod.nil);
    const tag = if (args.len == 2) args[1] else args[0];
    const parents_map = getHierarchyMap(h, "parents") orelse return value_mod.nil;

    // parents マップの全エントリを走査して、tag を祖先に持つものを収集
    var result = std.ArrayList(Value).empty;
    defer result.deinit(allocator);
    var i: usize = 0;
    while (i + 1 < parents_map.entries.len) : (i += 2) {
        const candidate = parents_map.entries[i];
        // candidate が tag の子孫かチェック
        if (isaTransitive(parents_map, candidate, tag, 0)) {
            var dup = false;
            for (result.items) |r| {
                if (r.eql(candidate)) { dup = true; break; }
            }
            if (!dup) try result.append(allocator, candidate);
        }
    }
    if (result.items.len == 0) return value_mod.nil;

    const items = try allocator.alloc(Value, result.items.len);
    @memcpy(items, result.items);
    const set = try allocator.create(value_mod.PersistentSet);
    set.* = .{ .items = items };
    return Value{ .set = set };
}

/// isa? : child が parent の子孫か（等価も含む）
/// (isa? child parent) or (isa? h child parent)
/// ベクタ同士の場合: 各要素ペアが全て isa? なら true
pub fn isaPred(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    const h = if (args.len == 3) args[0] else global_hierarchy;
    const child = if (args.len == 3) args[1] else args[0];
    const parent = if (args.len == 3) args[2] else args[1];

    return if (try isaCheck(allocator, h, child, parent)) value_mod.true_val else value_mod.false_val;
}

/// isa? の内部判定（ベクタ対応）
fn isaCheck(allocator: std.mem.Allocator, h: ?Value, child: Value, parent: Value) anyerror!bool {
    // 等価チェック
    if (child.eql(parent)) return true;

    // ベクタ同士: 要素ごとに isa? を確認
    if (child == .vector and parent == .vector) {
        const c_items = child.vector.items;
        const p_items = parent.vector.items;
        if (c_items.len != p_items.len) return false;
        for (c_items, p_items) |c, p| {
            if (!try isaCheck(allocator, h, c, p)) return false;
        }
        return true;
    }

    // 階層チェック: parents を再帰的にたどる（推移的関係）
    if (h) |hier| {
        const parents_map = getHierarchyMap(hier, "parents") orelse return false;
        if (isaTransitive(parents_map, child, parent, 0)) return true;
    }
    return false;
}

/// parents マップを再帰的にたどって isa? を判定
fn isaTransitive(parents_map: *value_mod.PersistentMap, child: Value, target: Value, depth: usize) bool {
    if (depth > 100) return false; // 無限ループ防止
    if (parents_map.get(child)) |parent_set| {
        if (parent_set == .set) {
            for (parent_set.set.items) |p| {
                if (p.eql(target)) return true;
                // 再帰: p の親もたどる
                if (isaTransitive(parents_map, p, target, depth + 1)) return true;
            }
        }
    }
    return false;
}

/// isa? ベースでマルチメソッドのメソッドを検索（evaluator/VM 共用）
pub fn findIsaMethodFromMultiFn(allocator: std.mem.Allocator, mf: *const value_mod.MultiFn, dispatch_value: Value) !?Value {
    const Match = struct { key: Value, method: Value };
    var matches = std.ArrayList(Match).empty;
    defer matches.deinit(allocator);

    // methods マップの全エントリを走査
    var i: usize = 0;
    while (i + 1 < mf.methods.entries.len) : (i += 2) {
        const method_key = mf.methods.entries[i];
        const method_val = mf.methods.entries[i + 1];
        if (method_key.eql(dispatch_value)) continue;
        if (try isaCheck(allocator, global_hierarchy, dispatch_value, method_key)) {
            try matches.append(allocator, .{ .key = method_key, .method = method_val });
        }
    }

    if (matches.items.len == 0) return null;
    if (matches.items.len == 1) return matches.items[0].method;

    // 複数マッチ: prefer テーブルで解決
    if (mf.prefer_table) |pt| {
        for (matches.items) |candidate| {
            var is_preferred = true;
            for (matches.items) |other| {
                if (candidate.key.eql(other.key)) continue;
                // candidate が other より優先?
                if (pt.get(candidate.key)) |pref_set| {
                    if (pref_set == .set) {
                        var found = false;
                        for (pref_set.set.items) |p| {
                            if (p.eql(other.key)) { found = true; break; }
                        }
                        if (found) continue;
                    }
                }
                // other が candidate より優先?
                if (pt.get(other.key)) |pref_set| {
                    if (pref_set == .set) {
                        for (pref_set.set.items) |p| {
                            if (p.eql(candidate.key)) { is_preferred = false; break; }
                        }
                    }
                }
                if (!is_preferred) break;
            }
            if (is_preferred) return candidate.method;
        }
    }

    return matches.items[0].method;
}

// ============================================================
// Phase 18: promise/deliver, ユーティリティ
// ============================================================

/// promise : 空の promise を作成
/// (promise) → #<promise (pending)>
pub fn promiseFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    const p = try allocator.create(value_mod.Promise);
    p.* = value_mod.Promise.init();
    return Value{ .promise = p };
}

/// deliver : promise に値を配送（1回だけ）
/// (deliver p val) → p
pub fn deliverFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .promise) return error.TypeError;
    const p = args[0].promise;
    if (!p.delivered) {
        p.value = try args[1].deepClone(allocator);
        p.delivered = true;
    }
    return args[0];
}

/// realized? : delay/promise/lazy-seq が実体化済みか
/// (realized? x) → bool
pub fn realizedPred(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .delay_val => |d| if (d.realized) value_mod.true_val else value_mod.false_val,
        .promise => |p| if (p.delivered) value_mod.true_val else value_mod.false_val,
        .lazy_seq => |ls| if (ls.realized != null) value_mod.true_val else value_mod.false_val,
        else => error.TypeError,
    };
}

/// ex-cause : 例外のcauseを返す（簡易実装: 常に nil）
pub fn exCauseFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.nil;
}

/// Throwable->map : エラーを map に変換（簡易実装）
pub fn throwableToMapFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    // {:cause "error"} を返す
    const entries = try allocator.alloc(Value, 2);
    const kw = try allocator.create(value_mod.Keyword);
    kw.* = value_mod.Keyword.init("cause");
    entries[0] = Value{ .keyword = kw };
    entries[1] = if (args[0] == .string) args[0] else blk: {
        const s = try allocator.create(value_mod.String);
        s.* = .{ .data = "unknown error" };
        break :blk Value{ .string = s };
    };
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

/// random-uuid : ランダム UUID 文字列を返す（v4 簡易版）
pub fn randomUuidFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    // 疑似ランダム UUID v4 生成（timestamp ベース）
    const ts: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var buf: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    // 128ビットを timestamp から生成
    var hash: u64 = ts;
    for (0..36) |i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            buf[i] = '-';
        } else {
            hash = hash *% 6364136223846793005 +% 1442695040888963407;
            buf[i] = hex[@as(usize, @intCast((hash >> 32) & 0xf))];
        }
    }
    // v4 マーカー
    buf[14] = '4';
    // variant マーカー (8, 9, a, b)
    buf[19] = hex[8 + @as(usize, @intCast((ts >> 4) & 0x3))];

    const str_data = try allocator.dupe(u8, &buf);
    const s = try allocator.create(value_mod.String);
    s.* = .{ .data = str_data };
    return Value{ .string = s };
}

/// char-escape-string : エスケープ文字の表現マップを返す
pub fn charEscapeStringFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    // {\newline "\\n", \tab "\\t", \return "\\r", \backspace "\\b", \formfeed "\\f", \" "\\\"", \\ "\\\\"}
    const pairs = [_]struct { ch: u21, esc: []const u8 }{
        .{ .ch = '\n', .esc = "\\n" },
        .{ .ch = '\t', .esc = "\\t" },
        .{ .ch = '\r', .esc = "\\r" },
        .{ .ch = 0x08, .esc = "\\b" },   // backspace
        .{ .ch = 0x0C, .esc = "\\f" },   // formfeed
        .{ .ch = '"', .esc = "\\\"" },
        .{ .ch = '\\', .esc = "\\\\" },
    };
    const entries = try allocator.alloc(Value, pairs.len * 2);
    for (pairs, 0..) |pair, idx| {
        entries[idx * 2] = Value{ .char_val = pair.ch };
        const s = try allocator.create(value_mod.String);
        s.* = .{ .data = pair.esc };
        entries[idx * 2 + 1] = Value{ .string = s };
    }
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

/// char-name-string : 名前付き文字のマップを返す
pub fn charNameStringFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    // {\newline "newline", \tab "tab", \space "space", \backspace "backspace",
    //  \formfeed "formfeed", \return "return"}
    const pairs = [_]struct { ch: u21, name: []const u8 }{
        .{ .ch = '\n', .name = "newline" },
        .{ .ch = '\t', .name = "tab" },
        .{ .ch = ' ', .name = "space" },
        .{ .ch = 0x08, .name = "backspace" },
        .{ .ch = 0x0C, .name = "formfeed" },
        .{ .ch = '\r', .name = "return" },
    };
    const entries = try allocator.alloc(Value, pairs.len * 2);
    for (pairs, 0..) |pair, idx| {
        entries[idx * 2] = Value{ .char_val = pair.ch };
        const s = try allocator.create(value_mod.String);
        s.* = .{ .data = pair.name };
        entries[idx * 2 + 1] = Value{ .string = s };
    }
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

/// tagged-literal : タグ付きリテラルを作成
/// (tagged-literal tag form) → {:tag tag :form form}
pub fn taggedLiteralFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .symbol) return error.TypeError;
    const entries = try allocator.alloc(Value, 4);
    const kw_tag = try allocator.create(value_mod.Keyword);
    kw_tag.* = value_mod.Keyword.init("tag");
    const kw_form = try allocator.create(value_mod.Keyword);
    kw_form.* = value_mod.Keyword.init("form");
    entries[0] = Value{ .keyword = kw_tag };
    entries[1] = args[0];
    entries[2] = Value{ .keyword = kw_form };
    entries[3] = args[1];
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

/// inst-ms : inst（文字列 ISO 日時）からミリ秒を返す（簡易実装: 文字列を返す）
pub fn instMsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    // 簡易: inst 文字列がない場合は 0 を返す
    return Value{ .int = 0 };
}

// ============================================================
// Phase 18b: 追加 PURE/DESIGN 関数群
// ============================================================

/// parse-uuid : UUID 文字列をバリデーション（簡易: 文字列をそのまま返す）
pub fn parseUuidFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    // UUID 形式チェック: 8-4-4-4-12
    const s = args[0].string.data;
    if (s.len != 36) return error.TypeError;
    if (s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-') return error.TypeError;
    return args[0]; // UUID 文字列をそのまま返す
}

/// partitionv : partition のベクター版（各パーティションをベクターで返す）
pub fn partitionvFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // (partitionv n coll) — partition と同じだがベクターで返す
    if (args.len < 2 or args.len > 3) return error.ArityError;
    // partition を呼んでからリスト→ベクター変換
    const result = try partition(allocator, args);
    return listOfListsToListOfVectors(allocator, result);
}

/// partitionv-all : partition-all のベクター版
pub fn partitionvAllFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const result = try partitionAll(allocator, args);
    return listOfListsToListOfVectors(allocator, result);
}

/// リストのリストをリストのベクターに変換（partitionv 用）
fn listOfListsToListOfVectors(allocator: std.mem.Allocator, val: Value) !Value {
    if (val == .list) {
        var converted = std.ArrayList(Value).empty;
        defer converted.deinit(allocator);
        for (val.list.items) |item| {
            const vec_val = try toVector(allocator, item);
            try converted.append(allocator, vec_val);
        }
        const items = try allocator.alloc(Value, converted.items.len);
        @memcpy(items, converted.items);
        const new_list = try allocator.create(value_mod.PersistentList);
        new_list.* = .{ .items = items };
        return Value{ .list = new_list };
    }
    return val;
}

/// Value をベクターに変換
fn toVector(allocator: std.mem.Allocator, val: Value) !Value {
    if (val == .vector) return val;
    if (val == .list) {
        const arr = try allocator.alloc(Value, val.list.items.len);
        @memcpy(arr, val.list.items);
        const vec = try allocator.create(value_mod.PersistentVector);
        vec.* = .{ .items = arr };
        return Value{ .vector = vec };
    }
    return val;
}

/// splitv-at : split-at のベクター版
pub fn splitvAtFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int) return error.TypeError;
    const n: usize = if (args[0].int >= 0) @intCast(args[0].int) else 0;
    // コレクションの要素を取得
    const coll_items = try collectToSlice(allocator, args[1]);
    defer allocator.free(coll_items);
    const split_at = @min(n, coll_items.len);

    // 前半ベクター
    const first_items = try allocator.alloc(Value, split_at);
    @memcpy(first_items, coll_items[0..split_at]);
    const first_vec = try allocator.create(value_mod.PersistentVector);
    first_vec.* = .{ .items = first_items };

    // 後半ベクター
    const second_items = try allocator.alloc(Value, coll_items.len - split_at);
    @memcpy(second_items, coll_items[split_at..]);
    const second_vec = try allocator.create(value_mod.PersistentVector);
    second_vec.* = .{ .items = second_items };

    // [first second] ベクターで返す
    const result_items = try allocator.alloc(Value, 2);
    result_items[0] = Value{ .vector = first_vec };
    result_items[1] = Value{ .vector = second_vec };
    const result_vec = try allocator.create(value_mod.PersistentVector);
    result_vec.* = .{ .items = result_items };
    return Value{ .vector = result_vec };
}

/// vector-of : 型ヒント付きベクター（Zig では型は単一なので vector と同等）
pub fn vectorOfFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    // 最初の引数は型キーワード（無視）、残りは要素
    // (vector-of :int 1 2 3) → [1 2 3]
    const items = try allocator.alloc(Value, args.len - 1);
    @memcpy(items, args[1..]);
    const vec = try allocator.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };
    return Value{ .vector = vec };
}

// タップシステム（グローバル）
var global_taps: ?std.ArrayList(Value) = null;

/// add-tap : タップ関数を登録
pub fn addTapFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (global_taps == null) {
        global_taps = std.ArrayList(Value).empty;
    }
    try global_taps.?.append(allocator, args[0]);
    return value_mod.nil;
}

/// remove-tap : タップ関数を削除
pub fn removeTapFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    if (global_taps) |*taps| {
        for (taps.items, 0..) |t, i| {
            if (t.eql(args[0])) {
                _ = taps.orderedRemove(i);
                break;
            }
        }
    }
    return value_mod.nil;
}

/// tap> : 値をタップ関数に送信
pub fn tapSendFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (global_taps) |taps| {
        for (taps.items) |tap_fn| {
            if (call_fn) |cfn| {
                _ = cfn(tap_fn, &[_]Value{args[0]}, allocator) catch {};
            }
        }
    }
    return value_mod.true_val;
}

/// test : Var のテスト関数を実行（簡易: テストメタデータを探して呼ぶ）
pub fn testFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    // 簡易実装: :test メタデータがなければ :ok
    return value_mod.nil;
}

// ============================================================
// Phase 19: macroexpand/eval + ユーティリティ
// ============================================================

/// class : 値の型名を文字列で返す
/// (class 42) → "Integer"
pub fn classFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const name: []const u8 = switch (args[0]) {
        .nil => "nil",
        .bool_val => "Boolean",
        .int => "Long",
        .float => "Double",
        .string => "String",
        .keyword => "Keyword",
        .symbol => "Symbol",
        .list => "PersistentList",
        .vector => "PersistentVector",
        .map => "PersistentArrayMap",
        .set => "PersistentHashSet",
        .fn_val, .partial_fn, .comp_fn => "Function",
        .multi_fn => "MultiFn",
        .protocol => "Protocol",
        .protocol_fn => "ProtocolFn",
        .atom => "Atom",
        .lazy_seq => "LazySeq",
        .delay_val => "Delay",
        .volatile_val => "Volatile",
        .reduced_val => "Reduced",
        .transient => "Transient",
        .promise => "Promise",
        .var_val => "Var",
        .char_val => "Character",
        .fn_proto => "FnProto",
        .regex => "Pattern",
        .matcher => "Matcher",
    };
    const s = try allocator.create(value_mod.String);
    s.* = .{ .data = name };
    return Value{ .string = s };
}

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
    const items = try collectToSlice(allocator, args[0]);
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
        const env = current_env orelse return error.TypeError;
        var analyzer = Analyzer.init(allocator, env);
        return analyzer.formToValue(f) catch return error.EvalError;
    }
    return value_mod.nil;
}

/// eval : Value（データ構造）を評価する
pub fn evalFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const env = current_env orelse return error.TypeError;

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
    const env = current_env orelse return error.TypeError;

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
    const env = current_env orelse return error.TypeError;
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
    return seq(allocator, args[0..1]);
}

/// rsubseq : 逆順部分列（簡易: reverse + subseq相当）
pub fn rsubseqFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 3) return error.ArityError;
    // 簡易実装: コレクションをseqとしてreverse
    const seq_val = try seq(allocator, args[0..1]);
    return reverseFn(allocator, &[_]Value{seq_val});
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

/// print-method / print-dup / print-simple: 出力スタブ
pub fn printMethodFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // (print-method x writer) — 簡易: str と同じ
    if (args.len < 1) return error.ArityError;
    return strFn(allocator, args[0..1]);
}

/// flush : 出力フラッシュ（スタブ、何もしない）
pub fn flushFn(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    return value_mod.nil;
}

// ============================================================
// 名前空間操作（簡易実装）
// ============================================================

// === 名前空間ヘルパー ===

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
    const env = current_env orelse return null;
    const name = nsArgName(arg) orelse return null;
    return env.findNs(name);
}

/// find-ns : 名前空間を検索
pub fn findNsFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const env = current_env orelse return error.TypeError;
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
    const env = current_env orelse return error.TypeError;
    const name = nsArgName(args[0]) orelse return error.TypeError;
    _ = env.findOrCreateNs(name) catch return error.EvalError;
    return args[0];
}

/// all-ns : すべての名前空間をリストで返す
pub fn allNsFn(allocator: std.mem.Allocator, _: []const Value) anyerror!Value {
    const env = current_env orelse return error.TypeError;
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
            const env = current_env orelse return value_mod.nil;
            if (env.findNs("clojure.core")) |core| {
                if (core.resolve(args[1].symbol.name)) |v| {
                    return v.deref();
                }
            }
        }
    }
    // フォールバック: resolveFn に委譲
    return resolveFn(allocator, args[1..2]);
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
    const env = current_env orelse return value_mod.nil;
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
        return readStringFn(allocator, args[0..1]);
    }
    return value_mod.nil;
}

/// read+string : 読み取り結果と元文字列のベクターを返す
pub fn readPlusStringFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const form_val = try readStringFn(allocator, args[0..1]);
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
        var lib_iter = loaded_libs.iterator();
        while (lib_iter.next()) |_| lib_count += 1;
    }
    const items = try allocator.alloc(Value, lib_count);
    var lib_iter = loaded_libs.iterator();
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
    return loadFileContent(allocator, content);
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
    const call_fn_opt = call_fn orelse return error.TypeError;
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
    const env = current_env orelse return error.TypeError;
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
    const env = current_env orelse return error.TypeError;
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
    const env = current_env orelse return error.TypeError;
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
    if (!force_reload and loaded_libs.contains(ns_name)) return;

    // NS名 → ファイルパス変換 (.clj と .cljc の両方)
    const rel_path_clj = try nsNameToPath(allocator, ns_name, ".clj");
    const rel_path_cljc = try nsNameToPath(allocator, ns_name, ".cljc");

    // クラスパスルートからファイルを探索 (.clj → .cljc フォールバック)
    var loaded = false;
    var ri: usize = 0;
    while (ri < classpath_count) : (ri += 1) {
        if (classpath_roots[ri]) |root| {
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
    const alloc = loaded_libs_allocator orelse allocator;
    const key = try alloc.dupe(u8, ns_name);
    loaded_libs.put(alloc, key, {}) catch {};
}

/// ファイルを読み込んで評価（失敗時は false）
fn tryLoadFile(allocator: std.mem.Allocator, path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();
    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return false;
    // 現在の NS を退避（ファイル内で ns が変更される可能性がある）
    const env = current_env orelse return false;
    const saved_ns = env.getCurrentNs();
    _ = loadFileContent(allocator, content) catch |e| {
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
    const env = current_env orelse return error.TypeError;
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
    const env = current_env orelse return error.TypeError;
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
    const env = current_env orelse return error.TypeError;
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
    return cons(allocator, args);
}

/// chunk-first — first のエイリアス
pub fn chunkFirstFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    return first(allocator, args);
}

/// chunk-next — next のエイリアス
pub fn chunkNextFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    return next(allocator, args);
}

/// chunk-rest — rest のエイリアス
pub fn chunkRestFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    return rest(allocator, args);
}

/// chunked-seq? — スタブ: false
pub fn chunkedSeqPred(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    return value_mod.false_val;
}

// --- Regex functions ---

/// Pattern を取得（regex Value またはパターン文字列からコンパイル）
fn getPattern(allocator: std.mem.Allocator, val: Value) anyerror!*value_mod.Pattern {
    switch (val) {
        .regex => |pat| return pat,
        .string => |s| {
            // 文字列からコンパイル
            const compiled = try allocator.create(regex_mod.CompiledRegex);
            compiled.* = try regex_matcher.compile(allocator, s.data);
            const pat = try allocator.create(value_mod.Pattern);
            pat.* = .{
                .source = s.data,
                .compiled = @ptrCast(compiled),
                .group_count = compiled.group_count,
            };
            return pat;
        },
        else => return error.TypeError,
    }
}

/// マッチ結果を Clojure 値に変換
/// グループなし: マッチ文字列 (String)
/// グループあり: [全体, group1, group2, ...] (Vector)
fn matchResultToValue(allocator: std.mem.Allocator, result: regex_matcher.MatchResult, input: []const u8) anyerror!Value {
    // キャプチャグループの有無を確認（groups[0] は全体マッチ）
    var has_groups = false;
    if (result.groups.len > 1) {
        for (result.groups[1..]) |g| {
            if (g != null) {
                has_groups = true;
                break;
            }
        }
    }

    if (!has_groups) {
        // グループなし: マッチ文字列を返す
        const match_text = input[result.start..result.end];
        const str = try allocator.create(value_mod.String);
        const data = try allocator.dupe(u8, match_text);
        str.* = .{ .data = data };
        return Value{ .string = str };
    }

    // グループあり: Vector を返す
    const items = try allocator.alloc(Value, result.groups.len);
    for (result.groups, 0..) |group_opt, i| {
        if (group_opt) |span| {
            const text = input[span.start..span.end];
            const str = try allocator.create(value_mod.String);
            const data = try allocator.dupe(u8, text);
            str.* = .{ .data = data };
            items[i] = Value{ .string = str };
        } else {
            items[i] = value_mod.nil;
        }
    }
    const vec = try allocator.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };
    return Value{ .vector = vec };
}

/// re-pattern — 文字列 → Pattern コンパイル。既に Pattern ならそのまま返す。
pub fn rePatternFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    switch (args[0]) {
        .regex => return args[0], // 既に Pattern
        .string => |s| {
            const compiled = try allocator.create(regex_mod.CompiledRegex);
            compiled.* = try regex_matcher.compile(allocator, s.data);
            const pat = try allocator.create(value_mod.Pattern);
            pat.* = .{
                .source = try allocator.dupe(u8, s.data),
                .compiled = @ptrCast(compiled),
                .group_count = compiled.group_count,
            };
            return Value{ .regex = pat };
        },
        else => return error.TypeError,
    }
}

/// re-matcher — Pattern + 文字列 → ステートフル Matcher 生成
pub fn reMatcherFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const pat = try getPattern(allocator, args[0]);
    if (args[1] != .string) return error.TypeError;
    const input = args[1].string.data;

    const m = try allocator.create(value_mod.RegexMatcher);
    m.* = .{
        .pattern = pat,
        .input = input,
        .pos = 0,
        .last_groups = null,
    };
    return Value{ .matcher = m };
}

/// re-find — 2引数: Pattern + 文字列で最初のマッチ。1引数: Matcher を次のマッチに進める。
pub fn reFindFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;

    if (args.len == 1) {
        // 1引数: Matcher のステートフル検索
        if (args[0] != .matcher) return error.TypeError;
        const rm = args[0].matcher;
        const compiled: *const regex_mod.CompiledRegex = @ptrCast(@alignCast(rm.pattern.compiled));

        var m = try regex_matcher.Matcher.init(allocator, compiled, rm.input);
        defer m.deinit();

        const result = try m.find(rm.pos) orelse {
            rm.last_groups = null;
            return value_mod.nil;
        };

        // 位置を進める（ゼロ幅マッチのとき無限ループを防ぐ）
        rm.pos = if (result.end > result.start) result.end else result.end + 1;

        // グループを保存
        const groups = try matchResultToGroups(allocator, result, rm.input);
        rm.last_groups = groups;

        return matchResultToValue(allocator, result, rm.input);
    }

    // 2引数: Pattern + 文字列
    const pat = try getPattern(allocator, args[0]);
    if (args[1] != .string) return error.TypeError;
    const input = args[1].string.data;
    const compiled: *const regex_mod.CompiledRegex = @ptrCast(@alignCast(pat.compiled));

    const result = try regex_matcher.findFirst(allocator, compiled, input) orelse {
        return value_mod.nil;
    };
    return matchResultToValue(allocator, result, input);
}

/// マッチ結果をグループ Value スライスに変換（re-groups 用）
fn matchResultToGroups(allocator: std.mem.Allocator, result: regex_matcher.MatchResult, input: []const u8) anyerror![]const Value {
    const groups = try allocator.alloc(Value, result.groups.len);
    for (result.groups, 0..) |group_opt, i| {
        if (group_opt) |span| {
            const text = input[span.start..span.end];
            const str = try allocator.create(value_mod.String);
            const data = try allocator.dupe(u8, text);
            str.* = .{ .data = data };
            groups[i] = Value{ .string = str };
        } else {
            groups[i] = value_mod.nil;
        }
    }
    return groups;
}

/// re-matches — 文字列全体がパターンに一致するか検証
pub fn reMatchesFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const pat = try getPattern(allocator, args[0]);
    if (args[1] != .string) return error.TypeError;
    const input = args[1].string.data;
    const compiled: *const regex_mod.CompiledRegex = @ptrCast(@alignCast(pat.compiled));

    var m = try regex_matcher.Matcher.init(allocator, compiled, input);
    defer m.deinit();

    const result = try m.fullMatch() orelse {
        return value_mod.nil;
    };
    return matchResultToValue(allocator, result, input);
}

/// re-seq — 全マッチのリストを返す（eager）
pub fn reSeqFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const pat = try getPattern(allocator, args[0]);
    if (args[1] != .string) return error.TypeError;
    const input = args[1].string.data;
    const compiled: *const regex_mod.CompiledRegex = @ptrCast(@alignCast(pat.compiled));

    var results: std.ArrayListUnmanaged(Value) = .empty;

    var m = try regex_matcher.Matcher.init(allocator, compiled, input);
    defer m.deinit();

    var pos: usize = 0;
    while (pos <= input.len) {
        const result = try m.find(pos) orelse break;
        const val = try matchResultToValue(allocator, result, input);
        try results.append(allocator, val);
        // 位置を進める（ゼロ幅マッチのとき無限ループを防ぐ）
        pos = if (result.end > result.start) result.end else result.end + 1;
    }

    const l = try allocator.create(value_mod.PersistentList);
    l.* = .{ .items = try results.toOwnedSlice(allocator) };
    return Value{ .list = l };
}

/// re-groups — Matcher の最後のマッチのキャプチャグループを返す
pub fn reGroupsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .matcher) return error.TypeError;
    const rm = args[0].matcher;

    const groups = rm.last_groups orelse return value_mod.nil;

    // グループが1つ（全体マッチのみ）なら文字列を返す
    if (groups.len <= 1) {
        return if (groups.len == 1) groups[0] else value_mod.nil;
    }

    // 複数グループなら [全体, group1, group2, ...] の Vector を返す
    const items = try allocator.dupe(Value, groups);
    const vec = try allocator.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };
    return Value{ .vector = vec };
}

// --- IO stubs ---

/// read-line — スタブ: nil（stdin 読み取りは未実装）
pub fn readLineFn(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    return value_mod.nil;
}

/// slurp — ファイル読み込み
pub fn slurpFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const path = args[0].string.data;
    const file = std.fs.cwd().openFile(path, .{}) catch return value_mod.nil;
    defer file.close();
    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return value_mod.nil;
    const str = try allocator.create(value_mod.String);
    str.* = value_mod.String.init(content);
    return Value{ .string = str };
}

/// spit — ファイル書き出し
pub fn spitFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const path = args[0].string.data;
    const content = switch (args[1]) {
        .string => |s| s.data,
        else => return error.TypeError,
    };
    const file = std.fs.cwd().createFile(path, .{}) catch return value_mod.nil;
    defer file.close();
    file.writeAll(content) catch return value_mod.nil;
    return value_mod.nil;
}

/// file-seq — スタブ: 空リスト
pub fn fileSeqFn(allocator: std.mem.Allocator, _: []const Value) anyerror!Value {
    const l = try allocator.create(value_mod.PersistentList);
    l.* = .{ .items = &[_]Value{} };
    return Value{ .list = l };
}

/// line-seq — スタブ: 空リスト
pub fn lineSeqFn(allocator: std.mem.Allocator, _: []const Value) anyerror!Value {
    const l = try allocator.create(value_mod.PersistentList);
    l.* = .{ .items = &[_]Value{} };
    return Value{ .list = l };
}

// ============================================================
// Env への登録
// ============================================================

/// 組み込み関数の定義
const BuiltinDef = struct {
    name: []const u8,
    func: BuiltinFn,
};

/// 登録する組み込み関数リスト
const builtins = [_]BuiltinDef{
    // 算術
    .{ .name = "+", .func = add },
    .{ .name = "-", .func = sub },
    .{ .name = "*", .func = mul },
    .{ .name = "/", .func = div },
    .{ .name = "inc", .func = inc },
    .{ .name = "dec", .func = dec },
    // 比較
    .{ .name = "=", .func = eq },
    .{ .name = "<", .func = lt },
    .{ .name = ">", .func = gt },
    .{ .name = "<=", .func = lte },
    .{ .name = ">=", .func = gte },
    // 論理
    .{ .name = "not", .func = notFn },
    .{ .name = "not=", .func = notEq },
    // ユーティリティ
    .{ .name = "identity", .func = identity },
    .{ .name = "abs", .func = abs },
    .{ .name = "mod", .func = modFn },
    .{ .name = "max", .func = max },
    .{ .name = "min", .func = min },
    // 述語
    .{ .name = "nil?", .func = isNil },
    .{ .name = "number?", .func = isNumber },
    .{ .name = "integer?", .func = isInteger },
    .{ .name = "float?", .func = isFloat },
    .{ .name = "string?", .func = isString },
    .{ .name = "keyword?", .func = isKeyword },
    .{ .name = "symbol?", .func = isSymbol },
    .{ .name = "fn?", .func = isFn },
    .{ .name = "coll?", .func = isColl },
    .{ .name = "list?", .func = isList },
    .{ .name = "vector?", .func = isVector },
    .{ .name = "map?", .func = isMap },
    .{ .name = "set?", .func = isSet },
    .{ .name = "empty?", .func = isEmpty },
    .{ .name = "some?", .func = isSome },
    .{ .name = "zero?", .func = isZero },
    .{ .name = "pos?", .func = isPos },
    .{ .name = "neg?", .func = isNeg },
    .{ .name = "even?", .func = isEven },
    .{ .name = "odd?", .func = isOdd },
    // Phase 11 述語
    .{ .name = "any?", .func = isAny },
    .{ .name = "boolean?", .func = isBoolean },
    .{ .name = "int?", .func = isInt },
    .{ .name = "double?", .func = isDouble },
    .{ .name = "char?", .func = isChar },
    .{ .name = "ident?", .func = isIdent },
    .{ .name = "simple-ident?", .func = isSimpleIdent },
    .{ .name = "simple-keyword?", .func = isSimpleKeyword },
    .{ .name = "simple-symbol?", .func = isSimpleSymbol },
    .{ .name = "qualified-ident?", .func = isQualifiedIdent },
    .{ .name = "qualified-keyword?", .func = isQualifiedKeyword },
    .{ .name = "qualified-symbol?", .func = isQualifiedSymbol },
    .{ .name = "indexed?", .func = isIndexed },
    .{ .name = "ifn?", .func = isIFn },
    .{ .name = "identical?", .func = isIdentical },
    .{ .name = "NaN?", .func = isNaN },
    .{ .name = "infinite?", .func = isInfinite },
    .{ .name = "nat-int?", .func = isNatInt },
    .{ .name = "neg-int?", .func = isNegInt },
    .{ .name = "pos-int?", .func = isPosInt },
    .{ .name = "special-symbol?", .func = isSpecialSymbol },
    .{ .name = "var?", .func = isVar },
    .{ .name = "map-entry?", .func = isMapEntry },
    // コンストラクタ
    .{ .name = "list", .func = list },
    .{ .name = "list*", .func = listStar },
    .{ .name = "vector", .func = vector },
    .{ .name = "hash-map", .func = hashMap },
    .{ .name = "array-map", .func = arrayMap },
    .{ .name = "hash-set", .func = hashSet },
    // コレクション
    .{ .name = "first", .func = first },
    .{ .name = "rest", .func = rest },
    .{ .name = "cons", .func = cons },
    .{ .name = "conj", .func = conj },
    .{ .name = "count", .func = count },
    .{ .name = "nth", .func = nth },
    .{ .name = "get", .func = get },
    .{ .name = "assoc", .func = assoc },
    .{ .name = "dissoc", .func = dissoc },
    .{ .name = "keys", .func = keys },
    .{ .name = "vals", .func = vals },
    .{ .name = "contains?", .func = containsKey },
    // シーケンス操作
    .{ .name = "take", .func = take },
    .{ .name = "drop", .func = drop },
    .{ .name = "range", .func = range },
    .{ .name = "concat", .func = concat },
    .{ .name = "into", .func = into },
    .{ .name = "reverse", .func = reverseFn },
    .{ .name = "seq", .func = seq },
    .{ .name = "vec", .func = vecFn },
    .{ .name = "repeat", .func = repeat },
    .{ .name = "iterate", .func = iterate },
    .{ .name = "cycle", .func = cycle },
    .{ .name = "mapcat", .func = mapcat },
    .{ .name = "distinct", .func = distinct },
    .{ .name = "flatten", .func = flatten },
    // 文字列
    .{ .name = "str", .func = strFn },
    // 出力
    .{ .name = "println", .func = println_fn },
    .{ .name = "pr-str", .func = prStr },
    // 例外
    .{ .name = "ex-info", .func = exInfo },
    .{ .name = "ex-message", .func = exMessage },
    .{ .name = "ex-data", .func = exData },
    // Atom
    .{ .name = "atom", .func = atomFn },
    .{ .name = "deref", .func = derefFn },
    .{ .name = "reset!", .func = resetBang },
    .{ .name = "atom?", .func = isAtom },
    // 文字列操作（拡充）
    .{ .name = "subs", .func = subs },
    .{ .name = "name", .func = nameFn },
    .{ .name = "namespace", .func = namespaceFn },
    .{ .name = "string-join", .func = stringJoin },
    .{ .name = "upper-case", .func = upperCase },
    .{ .name = "lower-case", .func = lowerCase },
    .{ .name = "trim", .func = trimStr },
    .{ .name = "triml", .func = trimlStr },
    .{ .name = "trimr", .func = trimrStr },
    .{ .name = "blank?", .func = isBlank },
    .{ .name = "starts-with?", .func = startsWith },
    .{ .name = "ends-with?", .func = endsWith },
    .{ .name = "includes?", .func = includesStr },
    .{ .name = "string-replace", .func = stringReplace },
    .{ .name = "string-replace-first", .func = stringReplaceFirst },
    .{ .name = "re-quote-replacement", .func = reQuoteReplacement },
    .{ .name = "char-at", .func = charAt },
    // プロトコル
    .{ .name = "satisfies?", .func = satisfiesPred },
    // ユーティリティ（Phase 8.16）
    .{ .name = "merge", .func = merge },
    .{ .name = "get-in", .func = getIn },
    .{ .name = "assoc-in", .func = assocIn },
    .{ .name = "select-keys", .func = selectKeys },
    .{ .name = "zipmap", .func = zipmap },
    .{ .name = "not-empty", .func = notEmpty },
    .{ .name = "type", .func = typeFn },
    // Phase 11 追加
    .{ .name = "key", .func = keyFn },
    .{ .name = "val", .func = valFn },
    .{ .name = "remove", .func = removeFn },
    .{ .name = "nthnext", .func = nthnext },
    .{ .name = "nthrest", .func = nthrest },
    .{ .name = "reduce-kv", .func = reduceKv },
    .{ .name = "merge-with", .func = mergeWith },
    .{ .name = "update-in", .func = updateIn },
    .{ .name = "update-keys", .func = updateKeys },
    .{ .name = "update-vals", .func = updateVals },
    .{ .name = "bounded-count", .func = boundedCount },
    .{ .name = "compare", .func = compareFn },
    .{ .name = "empty", .func = emptyFn },
    .{ .name = "sequence", .func = sequenceFn },
    // Phase 8.19: シーケンス・ユーティリティ拡充
    .{ .name = "second", .func = second },
    .{ .name = "last", .func = last },
    .{ .name = "butlast", .func = butlast },
    .{ .name = "next", .func = next },
    .{ .name = "ffirst", .func = ffirst },
    .{ .name = "fnext", .func = fnext },
    .{ .name = "nfirst", .func = nfirst },
    .{ .name = "nnext", .func = nnext },
    .{ .name = "interleave", .func = interleave },
    .{ .name = "interpose", .func = interpose },
    .{ .name = "frequencies", .func = frequencies },
    .{ .name = "partition", .func = partition },
    .{ .name = "partition-all", .func = partitionAll },
    .{ .name = "set", .func = setFn },
    .{ .name = "disj", .func = disjFn },
    .{ .name = "find", .func = findFn },
    .{ .name = "replace", .func = replaceFn },
    .{ .name = "sort", .func = sortFn },
    .{ .name = "distinct?", .func = isDistinctValues },
    .{ .name = "rand", .func = randFn },
    .{ .name = "rand-int", .func = randInt },
    .{ .name = "boolean", .func = booleanFn },
    .{ .name = "true?", .func = isTrue },
    .{ .name = "false?", .func = isFalse },
    .{ .name = "int", .func = intFn },
    .{ .name = "double", .func = doubleFn },
    .{ .name = "rem", .func = remFn },
    .{ .name = "quot", .func = quotFn },
    .{ .name = "bit-and", .func = bitAnd },
    .{ .name = "bit-or", .func = bitOr },
    .{ .name = "bit-xor", .func = bitXor },
    .{ .name = "bit-not", .func = bitNot },
    .{ .name = "bit-shift-left", .func = bitShiftLeft },
    .{ .name = "bit-shift-right", .func = bitShiftRight },
    .{ .name = "bit-and-not", .func = bitAndNot },
    .{ .name = "bit-clear", .func = bitClear },
    .{ .name = "bit-flip", .func = bitFlip },
    .{ .name = "bit-set", .func = bitSet },
    .{ .name = "bit-test", .func = bitTest },
    .{ .name = "unsigned-bit-shift-right", .func = unsignedBitShiftRight },
    .{ .name = "keyword", .func = keywordFn },
    .{ .name = "symbol", .func = symbolFn },
    .{ .name = "split-at", .func = splitAt },
    .{ .name = "take-last", .func = takeLast },
    .{ .name = "drop-last", .func = dropLast },
    .{ .name = "take-nth", .func = takeNth },
    .{ .name = "shuffle", .func = shuffle },
    .{ .name = "subvec", .func = subvec },
    .{ .name = "peek", .func = peek },
    .{ .name = "pop", .func = pop },
    .{ .name = "hash", .func = hashFn },
    .{ .name = "seq?", .func = isSeq },
    .{ .name = "seqable?", .func = isSeqable },
    .{ .name = "sequential?", .func = isSequential },
    .{ .name = "associative?", .func = isAssociative },
    .{ .name = "counted?", .func = isCounted },
    .{ .name = "reversible?", .func = isReversible },
    .{ .name = "sorted?", .func = isSorted },
    .{ .name = "string-split", .func = stringSplit },
    .{ .name = "format", .func = formatFn },
    .{ .name = "pr", .func = prFn },
    .{ .name = "print", .func = printFn },
    .{ .name = "prn", .func = prnFn },
    .{ .name = "print-str", .func = printStr },
    .{ .name = "prn-str", .func = prnStr },
    .{ .name = "with-meta", .func = withMeta },
    .{ .name = "meta", .func = metaFn },
    // 遅延シーケンス
    .{ .name = "realized?", .func = isRealized },
    .{ .name = "lazy-seq?", .func = isLazySeq },
    .{ .name = "doall", .func = doall },
    // Phase 11 追加（ユーティリティ）
    .{ .name = "parse-long", .func = parseLong },
    .{ .name = "parse-double", .func = parseDouble },
    .{ .name = "parse-boolean", .func = parseBooleanFn },
    .{ .name = "rand-nth", .func = randNth },
    .{ .name = "repeatedly", .func = repeatedly },
    .{ .name = "reductions", .func = reductions },
    .{ .name = "split-with", .func = splitWith },
    .{ .name = "dedupe", .func = dedupeFn },
    .{ .name = "rseq", .func = rseq },
    .{ .name = "max-key", .func = maxKey },
    .{ .name = "min-key", .func = minKey },
    // Phase 12: 述語
    .{ .name = "bytes?", .func = isBytes },
    .{ .name = "class?", .func = isClass },
    .{ .name = "decimal?", .func = isDecimal },
    .{ .name = "ratio?", .func = isRatio },
    .{ .name = "rational?", .func = isRational },
    .{ .name = "record?", .func = isRecord },
    .{ .name = "inst?", .func = isInst },
    .{ .name = "uri?", .func = isUri },
    .{ .name = "uuid?", .func = isUuid },
    .{ .name = "tagged-literal?", .func = isTaggedLiteral },
    .{ .name = "reader-conditional?", .func = isReaderConditional },
    .{ .name = "delay?", .func = isDelayFn },
    .{ .name = "volatile?", .func = isVolatileFn },
    .{ .name = "reduced?", .func = isReducedFn },
    .{ .name = "instance?", .func = instanceCheck },
    // Phase 12: 型キャスト
    .{ .name = "char", .func = charFn },
    .{ .name = "byte", .func = byteFn },
    .{ .name = "short", .func = shortFn },
    .{ .name = "long", .func = longFn },
    .{ .name = "float", .func = floatFn },
    .{ .name = "num", .func = numFn },
    // Phase 12: オーバーフロー安全算術
    .{ .name = "+'", .func = addChecked },
    .{ .name = "-'", .func = subChecked },
    .{ .name = "*'", .func = mulChecked },
    .{ .name = "inc'", .func = incChecked },
    .{ .name = "dec'", .func = decChecked },
    // Phase 12: 出力・ユーティリティ
    .{ .name = "clojure-version", .func = clojureVersion },
    .{ .name = "newline", .func = newlineFn },
    .{ .name = "println-str", .func = printlnStr },
    .{ .name = "printf", .func = printfFn },
    // Phase 12: ハッシュ
    .{ .name = "hash-combine", .func = hashCombine },
    .{ .name = "hash-ordered-coll", .func = hashOrderedColl },
    .{ .name = "hash-unordered-coll", .func = hashUnorderedColl },
    .{ .name = "mix-collection-hash", .func = mixCollectionHash },
    // Phase 12: キーワード・シンボル
    .{ .name = "find-keyword", .func = findKeywordFn },
    .{ .name = "gensym", .func = gensymFn },
    // Phase 12: ユーティリティ
    .{ .name = "comparator", .func = comparatorFn },
    .{ .name = "replicate", .func = replicateFn },
    .{ .name = "random-sample", .func = randomSample },
    .{ .name = "==", .func = numericEq },
    // Phase 12: マルチメソッド拡張
    .{ .name = "get-method", .func = getMethod },
    .{ .name = "methods", .func = methodsFn },
    .{ .name = "remove-method", .func = removeMethod },
    .{ .name = "remove-all-methods", .func = removeAllMethods },
    .{ .name = "prefer-method", .func = preferMethod },
    .{ .name = "prefers", .func = prefersFn },
    // Phase 12E: HOF・遅延操作
    .{ .name = "trampoline", .func = trampolineFn },
    .{ .name = "tree-seq", .func = treeSeqFn },
    .{ .name = "partition-by", .func = partitionByFn },
    // Phase 13: delay/volatile/reduced
    .{ .name = "__delay-create", .func = delayCreate },
    .{ .name = "force", .func = forceFn },
    .{ .name = "volatile!", .func = volatileBang },
    .{ .name = "vreset!", .func = vresetBang },
    .{ .name = "vswap!", .func = vswapBang },
    .{ .name = "reduced", .func = reducedFn },
    .{ .name = "unreduced", .func = unreducedFn },
    .{ .name = "ensure-reduced", .func = ensureReducedFn },
    // Phase 14: transient / transduce
    .{ .name = "transient", .func = transientFn },
    .{ .name = "persistent!", .func = persistentBang },
    .{ .name = "conj!", .func = conjBang },
    .{ .name = "assoc!", .func = assocBang },
    .{ .name = "dissoc!", .func = dissocBang },
    .{ .name = "disj!", .func = disjBang },
    .{ .name = "pop!", .func = popBang },
    .{ .name = "completing", .func = completingFn },
    .{ .name = "transduce", .func = transduceFn },
    .{ .name = "cat", .func = catFn },
    .{ .name = "eduction", .func = eductionFn },
    .{ .name = "halt-when", .func = haltWhenFn },
    .{ .name = "iteration", .func = iterationFn },
    // Phase 15: Atom 拡張・Var 操作・メタデータ
    .{ .name = "add-watch", .func = addWatchFn },
    .{ .name = "remove-watch", .func = removeWatchFn },
    .{ .name = "get-validator", .func = getValidatorFn },
    .{ .name = "set-validator!", .func = setValidatorBang },
    .{ .name = "compare-and-set!", .func = compareAndSetBang },
    .{ .name = "reset-vals!", .func = resetValsBang },
    .{ .name = "swap-vals!", .func = swapValsBang },
    .{ .name = "var-get", .func = varGetFn },
    .{ .name = "var-set", .func = varSetFn },
    .{ .name = "alter-var-root", .func = alterVarRootFn },
    .{ .name = "find-var", .func = findVarFn },
    .{ .name = "intern", .func = internFn },
    .{ .name = "bound?", .func = boundPred },
    .{ .name = "alter-meta!", .func = alterMetaBang },
    .{ .name = "reset-meta!", .func = resetMetaBang },
    .{ .name = "vary-meta", .func = varyMetaFn },
    // Phase 17: 階層システム
    .{ .name = "make-hierarchy", .func = makeHierarchyFn },
    .{ .name = "derive", .func = deriveFn },
    .{ .name = "underive", .func = underiveFn },
    .{ .name = "parents", .func = parentsFn },
    .{ .name = "ancestors", .func = ancestorsFn },
    .{ .name = "descendants", .func = descendantsFn },
    .{ .name = "isa?", .func = isaPred },
    // Phase 18: promise/deliver, ユーティリティ
    .{ .name = "promise", .func = promiseFn },
    .{ .name = "deliver", .func = deliverFn },
    .{ .name = "realized?", .func = realizedPred },
    .{ .name = "ex-cause", .func = exCauseFn },
    .{ .name = "Throwable->map", .func = throwableToMapFn },
    .{ .name = "random-uuid", .func = randomUuidFn },
    .{ .name = "char-escape-string", .func = charEscapeStringFn },
    .{ .name = "char-name-string", .func = charNameStringFn },
    .{ .name = "tagged-literal", .func = taggedLiteralFn },
    .{ .name = "inst-ms*", .func = instMsFn },
    // Phase 18b: 追加 PURE/DESIGN
    .{ .name = "parse-uuid", .func = parseUuidFn },
    .{ .name = "partitionv", .func = partitionvFn },
    .{ .name = "partitionv-all", .func = partitionvAllFn },
    .{ .name = "splitv-at", .func = splitvAtFn },
    .{ .name = "vector-of", .func = vectorOfFn },
    .{ .name = "add-tap", .func = addTapFn },
    .{ .name = "remove-tap", .func = removeTapFn },
    .{ .name = "tap>", .func = tapSendFn },
    .{ .name = "test", .func = testFn },
    // Phase 19: macroexpand/eval + ユーティリティ
    .{ .name = "class", .func = classFn },
    .{ .name = "destructure", .func = destructureFn },
    .{ .name = "seq-to-map-for-destructuring", .func = seqToMapFn },
    .{ .name = "xml-seq", .func = xmlSeqFn },
    .{ .name = "the-ns", .func = theNsFn },
    .{ .name = "accessor", .func = accessorFn },
    .{ .name = "create-struct", .func = createStructFn },
    .{ .name = "struct", .func = structFn },
    .{ .name = "struct-map", .func = structMapFn },
    // Phase 19b: eval/read-string/sorted/dynamic-vars
    .{ .name = "read-string", .func = readStringFn },
    .{ .name = "eval", .func = evalFn },
    .{ .name = "load-string", .func = loadStringFn },
    .{ .name = "macroexpand-1", .func = macroexpand1Fn },
    .{ .name = "macroexpand", .func = macroexpandFn },
    .{ .name = "resolve", .func = resolveFn },
    .{ .name = "sorted-map", .func = sortedMapFn },
    .{ .name = "sorted-map-by", .func = sortedMapByFn },
    .{ .name = "sorted-set", .func = sortedSetFn },
    .{ .name = "sorted-set-by", .func = sortedSetByFn },
    .{ .name = "subseq", .func = subseqFn },
    .{ .name = "rsubseq", .func = rsubseqFn },
    .{ .name = "print-method", .func = printMethodFn },
    .{ .name = "print-simple", .func = printMethodFn },
    .{ .name = "print-dup", .func = printMethodFn },
    .{ .name = "flush", .func = flushFn },
    // Phase 19c: 名前空間・Reader・ユーティリティ
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
    // Phase 20: regex stubs
    .{ .name = "re-pattern", .func = rePatternFn },
    .{ .name = "re-matcher", .func = reMatcherFn },
    .{ .name = "re-find", .func = reFindFn },
    .{ .name = "re-matches", .func = reMatchesFn },
    .{ .name = "re-seq", .func = reSeqFn },
    .{ .name = "re-groups", .func = reGroupsFn },
    // Phase 20: IO
    .{ .name = "read-line", .func = readLineFn },
    .{ .name = "slurp", .func = slurpFn },
    .{ .name = "spit", .func = spitFn },
    .{ .name = "file-seq", .func = fileSeqFn },
    .{ .name = "line-seq", .func = lineSeqFn },
};

/// clojure.core の組み込み関数を Env に登録
/// value_allocator: Value/Fn 等の Clojure オブジェクト用アロケータ
///   （GcAllocator 経由で GC 追跡される）
/// env.allocator: Namespace/Var/HashMap 等のインフラ用アロケータ
pub fn registerCore(env: *Env, value_allocator: std.mem.Allocator) !void {
    const core_ns = try env.findOrCreateNs("clojure.core");

    for (builtins) |b| {
        const v = try core_ns.intern(b.name);
        const fn_obj = try value_allocator.create(Fn);
        fn_obj.* = Fn.initBuiltin(b.name, b.func);
        v.bindRoot(Value{ .fn_val = fn_obj });
    }

    // 動的 Var（値として登録）
    try registerDynamicVars(value_allocator, core_ns);
}

/// 動的 Var の初期値を登録
fn registerDynamicVars(allocator: std.mem.Allocator, core_ns: anytype) !void {
    // *clojure-version*
    {
        const v = try core_ns.intern("*clojure-version*");
        v.dynamic = true;
        const ver = try clojureVersionFn(allocator, &[_]Value{});
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

const gc_mod = @import("../gc/gc.zig");

/// GC ルート用グローバル参照を取得
pub fn getGcGlobals() gc_mod.GcGlobals {
    return .{
        .hierarchy = global_hierarchy,
        .taps = if (global_taps) |t| t.items else null,
    };
}

// ============================================================
// テスト
// ============================================================

test "add" {
    const alloc = std.testing.allocator;
    const args = [_]Value{ value_mod.intVal(1), value_mod.intVal(2), value_mod.intVal(3) };
    const result = try add(alloc, &args);
    try std.testing.expect(result.eql(value_mod.intVal(6)));
}

test "add with float" {
    const alloc = std.testing.allocator;
    const args = [_]Value{ value_mod.intVal(1), Value{ .float = 2.5 } };
    const result = try add(alloc, &args);
    try std.testing.expectEqual(@as(f64, 3.5), result.float);
}

test "sub" {
    const alloc = std.testing.allocator;
    const args = [_]Value{ value_mod.intVal(10), value_mod.intVal(3) };
    const result = try sub(alloc, &args);
    try std.testing.expect(result.eql(value_mod.intVal(7)));
}

test "sub unary" {
    const alloc = std.testing.allocator;
    const args = [_]Value{value_mod.intVal(5)};
    const result = try sub(alloc, &args);
    try std.testing.expect(result.eql(value_mod.intVal(-5)));
}

test "mul" {
    const alloc = std.testing.allocator;
    const args = [_]Value{ value_mod.intVal(2), value_mod.intVal(3), value_mod.intVal(4) };
    const result = try mul(alloc, &args);
    try std.testing.expect(result.eql(value_mod.intVal(24)));
}

test "div" {
    const alloc = std.testing.allocator;
    const args = [_]Value{ value_mod.intVal(10), value_mod.intVal(2) };
    const result = try div(alloc, &args);
    try std.testing.expectEqual(@as(f64, 5.0), result.float);
}

test "div by zero" {
    const alloc = std.testing.allocator;
    const args = [_]Value{ value_mod.intVal(10), value_mod.intVal(0) };
    const result = div(alloc, &args);
    try std.testing.expectError(error.DivisionByZero, result);
}

test "eq" {
    const alloc = std.testing.allocator;
    const args_eq = [_]Value{ value_mod.intVal(1), value_mod.intVal(1) };
    const result_eq = try eq(alloc, &args_eq);
    try std.testing.expect(result_eq.eql(value_mod.true_val));

    const args_neq = [_]Value{ value_mod.intVal(1), value_mod.intVal(2) };
    const result_neq = try eq(alloc, &args_neq);
    try std.testing.expect(result_neq.eql(value_mod.false_val));
}

test "lt" {
    const alloc = std.testing.allocator;
    const args = [_]Value{ value_mod.intVal(1), value_mod.intVal(2), value_mod.intVal(3) };
    const result = try lt(alloc, &args);
    try std.testing.expect(result.eql(value_mod.true_val));
}

test "isNil" {
    const alloc = std.testing.allocator;
    const args_nil = [_]Value{value_mod.nil};
    const result_nil = try isNil(alloc, &args_nil);
    try std.testing.expect(result_nil.eql(value_mod.true_val));

    const args_not_nil = [_]Value{value_mod.intVal(1)};
    const result_not_nil = try isNil(alloc, &args_not_nil);
    try std.testing.expect(result_not_nil.eql(value_mod.false_val));
}

test "first" {
    const alloc = std.testing.allocator;

    const test_list = try value_mod.PersistentList.fromSlice(alloc, &[_]Value{
        value_mod.intVal(1),
        value_mod.intVal(2),
        value_mod.intVal(3),
    });
    defer alloc.destroy(test_list);
    defer alloc.free(test_list.items);

    const args = [_]Value{Value{ .list = test_list }};
    const result = try first(alloc, &args);
    try std.testing.expect(result.eql(value_mod.intVal(1)));
}

test "rest" {
    const alloc = std.testing.allocator;

    const test_list = try value_mod.PersistentList.fromSlice(alloc, &[_]Value{
        value_mod.intVal(1),
        value_mod.intVal(2),
        value_mod.intVal(3),
    });
    defer alloc.destroy(test_list);
    defer alloc.free(test_list.items);

    const args = [_]Value{Value{ .list = test_list }};
    const result = try rest(alloc, &args);

    // rest は新しいリストを返す
    try std.testing.expectEqual(@as(usize, 2), result.list.items.len);
    try std.testing.expect(result.list.items[0].eql(value_mod.intVal(2)));
    try std.testing.expect(result.list.items[1].eql(value_mod.intVal(3)));

    alloc.destroy(result.list);
    alloc.free(result.list.items);
}

test "cons" {
    const alloc = std.testing.allocator;

    const test_list = try value_mod.PersistentList.fromSlice(alloc, &[_]Value{
        value_mod.intVal(2),
        value_mod.intVal(3),
    });
    defer alloc.destroy(test_list);
    defer alloc.free(test_list.items);

    const args = [_]Value{ value_mod.intVal(1), Value{ .list = test_list } };
    const result = try cons(alloc, &args);

    try std.testing.expectEqual(@as(usize, 3), result.list.items.len);
    try std.testing.expect(result.list.items[0].eql(value_mod.intVal(1)));
    try std.testing.expect(result.list.items[1].eql(value_mod.intVal(2)));
    try std.testing.expect(result.list.items[2].eql(value_mod.intVal(3)));

    alloc.destroy(result.list);
    alloc.free(result.list.items);
}

test "count" {
    const alloc = std.testing.allocator;

    const test_list = try value_mod.PersistentList.fromSlice(alloc, &[_]Value{
        value_mod.intVal(1),
        value_mod.intVal(2),
        value_mod.intVal(3),
    });
    defer alloc.destroy(test_list);
    defer alloc.free(test_list.items);

    const args = [_]Value{Value{ .list = test_list }};
    const result = try count(alloc, &args);
    try std.testing.expect(result.eql(value_mod.intVal(3)));
}
