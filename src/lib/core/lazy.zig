//! LazySeq force/transform 基盤
//!
//! 遅延シーケンスの一段 force、遅延変換、遅延 concat、ジェネレータ。

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;

// ============================================================
// LazySeq force
// ============================================================

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

    // 遅延 take の場合
    if (ls.take) |t| {
        try forceTakeOneStep(allocator, ls, t);
        return;
    }

    // サンク形式の場合: body_fn を呼んで結果を取得
    const body_fn = ls.body_fn orelse {
        // body_fn も cons_head もない → 空
        ls.realized = value_mod.nil;
        return;
    };
    const force_fn = defs.force_lazy_seq_fn orelse return error.TypeError;
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
        ls.take = inner.take;
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
    const call = defs.call_fn orelse return error.TypeError;

    switch (t.kind) {
        .map => {
            // source が空かどうかチェック (nil 要素と区別)
            if (try isSourceExhausted(allocator, t.source)) {
                ls.transform = null;
                ls.realized = value_mod.nil;
                return;
            }
            // source の first を取得
            const src_first = try seqFirst(allocator, t.source);
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
                if (try isSourceExhausted(allocator, current)) {
                    ls.transform = null;
                    ls.realized = value_mod.nil;
                    return;
                }
                const elem = try seqFirst(allocator, current);
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
                if (try isSourceExhausted(allocator, current)) {
                    ls.transform = null;
                    ls.realized = value_mod.nil;
                    return;
                }
                const src_elem = try seqFirst(allocator, current);
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
        .take_while => {
            // source の先頭要素に pred を適用 → truthy なら cons、falsy なら停止
            if (try isSourceExhausted(allocator, t.source)) {
                ls.transform = null;
                ls.realized = value_mod.nil;
                return;
            }
            const elem = try seqFirst(allocator, t.source);
            const pred_result = try call(t.fn_val, &[_]Value{elem}, allocator);
            if (!pred_result.isTruthy()) {
                // pred が偽 → 停止（空シーケンス）
                ls.transform = null;
                ls.realized = value_mod.nil;
                return;
            }
            // cons(elem, lazy-take-while(pred, rest))
            const src_rest = try seqRest(allocator, t.source);
            ls.transform = null;
            ls.cons_head = elem;
            if (isSeqEmpty(src_rest)) {
                ls.cons_tail = value_mod.nil;
            } else {
                const tail_ls = try allocator.create(value_mod.LazySeq);
                tail_ls.* = value_mod.LazySeq.initTransform(.take_while, t.fn_val, src_rest);
                ls.cons_tail = Value{ .lazy_seq = tail_ls };
            }
        },
        .drop_while => {
            // pred が truthy な間スキップ → 最初の falsy 要素から全て返す
            var current = t.source;
            while (true) {
                if (try isSourceExhausted(allocator, current)) {
                    ls.transform = null;
                    ls.realized = value_mod.nil;
                    return;
                }
                const elem = try seqFirst(allocator, current);
                const pred_result = try call(t.fn_val, &[_]Value{elem}, allocator);
                if (!pred_result.isTruthy()) {
                    // 最初の falsy 要素 → cons(elem, rest) をそのまま返す
                    const rest_val = try seqRest(allocator, current);
                    ls.transform = null;
                    ls.cons_head = elem;
                    ls.cons_tail = if (isSeqEmpty(rest_val)) value_mod.nil else rest_val;
                    return;
                }
                current = try seqRest(allocator, current);
            }
        },
        .map_indexed => {
            // source の先頭要素に (f index elem) を適用
            if (try isSourceExhausted(allocator, t.source)) {
                ls.transform = null;
                ls.realized = value_mod.nil;
                return;
            }
            const elem = try seqFirst(allocator, t.source);
            const idx_val = value_mod.intVal(@intCast(t.index));
            const mapped = try call(t.fn_val, &[_]Value{ idx_val, elem }, allocator);
            const src_rest = try seqRest(allocator, t.source);
            ls.transform = null;
            ls.cons_head = mapped;
            if (isSeqEmpty(src_rest)) {
                ls.cons_tail = value_mod.nil;
            } else {
                const tail_ls = try allocator.create(value_mod.LazySeq);
                tail_ls.* = value_mod.LazySeq.initTransformIndexed(t.fn_val, src_rest, t.index + 1);
                ls.cons_tail = Value{ .lazy_seq = tail_ls };
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
            const call = defs.call_fn orelse return error.TypeError;
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

/// 遅延 take を一段 force する
fn forceTakeOneStep(
    allocator: std.mem.Allocator,
    ls: *value_mod.LazySeq,
    t: value_mod.LazySeq.Take,
) anyerror!void {
    // 残り 0 の場合は空
    if (t.n == 0) {
        ls.take = null;
        ls.realized = value_mod.nil;
        return;
    }

    // ソースから first を取得
    const first = try seqFirst(allocator, t.source);
    if (first == .nil) {
        // ソースが空 → 終了
        ls.take = null;
        ls.realized = value_mod.nil;
        return;
    }

    // cons(first, lazy-take(n-1, rest(source)))
    ls.take = null;
    ls.cons_head = first;

    const rest = try seqRest(allocator, t.source);
    const tail_ls = try allocator.create(value_mod.LazySeq);
    tail_ls.* = value_mod.LazySeq.initTake(rest, t.n - 1);
    ls.cons_tail = Value{ .lazy_seq = tail_ls };
}

// ============================================================
// シーケンスアクセス
// ============================================================

/// シーケンスの first を取得（lazy-seq/list/vector/nil 対応）
pub fn seqFirst(allocator: std.mem.Allocator, val: Value) anyerror!Value {
    return switch (val) {
        .lazy_seq => |ls| lazyFirst(allocator, ls),
        .list => |l| if (l.items.len > 0) l.items[0] else value_mod.nil,
        .vector => |v| if (v.items.len > 0) v.items[0] else value_mod.nil,
        .nil => value_mod.nil,
        else => value_mod.nil,
    };
}

/// シーケンスの rest を取得（lazy-seq/list/vector/nil 対応）
pub fn seqRest(allocator: std.mem.Allocator, val: Value) anyerror!Value {
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

/// シーケンスが空かどうか (確定的に判定できる場合のみ)
pub fn isSeqEmpty(val: Value) bool {
    return switch (val) {
        .nil => true,
        .list => |l| l.items.len == 0,
        .vector => |v| v.items.len == 0,
        else => false, // lazy-seq は空かわからない
    };
}

/// シーケンスが空かどうか (lazy-seq も force して判定)
pub fn isSourceExhausted(allocator: std.mem.Allocator, val: Value) anyerror!bool {
    return switch (val) {
        .nil => true,
        .list => |l| l.items.len == 0,
        .vector => |v| v.items.len == 0,
        .lazy_seq => |ls_ptr| {
            // 1ステップ force して判定
            try forceLazySeqOneStep(allocator, ls_ptr);
            if (ls_ptr.cons_head != null) return false; // 要素あり
            if (ls_ptr.realized) |r| {
                return switch (r) {
                    .nil => true,
                    .list => |l| l.items.len == 0,
                    .vector => |v| v.items.len == 0,
                    else => false,
                };
            }
            // transform/concat/generator/take がまだあれば非空
            if (ls_ptr.transform != null or ls_ptr.concat_sources != null or ls_ptr.generator != null or ls_ptr.take != null) return false;
            return true;
        },
        else => false,
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
