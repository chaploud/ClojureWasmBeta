//! Transient・Transduce
//!
//! transient, persistent!, conj!, assoc!, transduce, completing, cat, eduction, halt-when, iteration

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const BuiltinDef = defs.BuiltinDef;

const helpers = @import("helpers.zig");
const lazy = @import("lazy.zig");

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
    const call = defs.call_fn orelse return error.TypeError;

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
    const items = try helpers.collectToSlice(allocator, coll);

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
    const call = defs.call_fn orelse return error.TypeError;
    const rf = args[0];
    var result = args[1];
    const input = args[2];

    // input がコレクションなら各要素を rf に渡す
    const items = helpers.collectToSlice(allocator, input) catch {
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
    const call = defs.call_fn orelse return error.TypeError;

    // 最後の引数がコレクション、それ以前がトランスデューサ
    const coll = args[args.len - 1];
    const items = try helpers.collectToSlice(allocator, coll);

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
        current_items = try helpers.collectToSlice(allocator, acc);
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
    const call = defs.call_fn orelse return error.TypeError;
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
    const call = defs.call_fn orelse return error.TypeError;

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
// builtins テーブル
// ============================================================

pub const builtins = [_]BuiltinDef{
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
};
