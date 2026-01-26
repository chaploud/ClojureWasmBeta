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
    _ = allocator;
    if (args.len < 2) return error.ArityError;

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        if (!a.eql(b)) {
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
        .var_val => try writer.writeAll("#<var>"),
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
    }
}

/// 値を出力（ArrayListUnmanaged 版）
fn printValueToBuf(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), val: Value) !void {
    const Context = struct {
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
    var ctx = Context{ .buf = buf, .allocator = allocator };
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
    if (args.len < 1 or args.len > 3) return error.ArityError;

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
            // マップ → キーバリューペアを追加
            var map = m.*;
            var i: usize = 0;
            while (i + 1 < from_items.len) : (i += 2) {
                map = try map.assoc(allocator, from_items[i], from_items[i + 1]);
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
        else => error.TypeError,
    };
}

/// repeat : 値を n 回繰り返したリストを生成
pub fn repeat(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
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
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .atom => |a| a.value,
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
    const match = switch (args[1]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const replacement = switch (args[2]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };

    if (match.len == 0) {
        // 空文字列マッチはそのまま返す
        const str_obj = try allocator.create(value_mod.String);
        str_obj.* = .{ .data = s };
        return Value{ .string = str_obj };
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (i + match.len <= s.len and std.mem.eql(u8, s[i..][0..match.len], match)) {
            try buf.appendSlice(allocator, replacement);
            i += match.len;
        } else {
            try buf.append(allocator, s[i]);
            i += 1;
        }
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
    if (args.len != 1) return error.ArityError;
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

/// string-split : 文字列を区切り文字で分割（clojure.string/split 簡易版）
pub fn stringSplit(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .string or args[1] != .string) return error.TypeError;
    const s = args[0].string.data;
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
    // コンストラクタ
    .{ .name = "list", .func = list },
    .{ .name = "vector", .func = vector },
    .{ .name = "hash-map", .func = hashMap },
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
};

/// clojure.core の組み込み関数を Env に登録
pub fn registerCore(env: *Env) !void {
    const core_ns = try env.findOrCreateNs("clojure.core");

    for (builtins) |b| {
        const v = try core_ns.intern(b.name);
        const fn_obj = try env.allocator.create(Fn);
        fn_obj.* = Fn.initBuiltin(b.name, b.func);
        v.bindRoot(Value{ .fn_val = fn_obj });
    }
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
