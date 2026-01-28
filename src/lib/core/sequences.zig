//! シーケンス操作
//!
//! map, filter, take, drop, range, reduce, apply, sort-by, group-by etc.

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const BuiltinDef = defs.BuiltinDef;

const helpers = @import("helpers.zig");
const lazy = @import("lazy.zig");

const arithmetic = @import("arithmetic.zig");

const Fn = defs.Fn;

// ============================================================
// シーケンス基本操作
// ============================================================

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
                const elem = try lazy.lazyFirst(allocator, current.lazy_seq);
                if (elem == .nil) break; // 空
                items_buf.append(allocator, elem) catch return error.OutOfMemory;
                current = try lazy.lazyRest(allocator, current.lazy_seq);
                taken += 1;
            } else {
                // 具体値に到達
                const remaining = n - taken;
                const rest_items = helpers.getItems(current) orelse break;
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

    const items = helpers.getItems(args[1]) orelse return error.TypeError;
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
                const f = try lazy.lazyFirst(allocator, current.lazy_seq);
                if (f == .nil) break;
                current = try lazy.lazyRest(allocator, current.lazy_seq);
                dropped += 1;
            } else {
                // 具体値に到達
                const remaining_items = helpers.getItems(current) orelse break;
                const skip = @min(n - dropped, remaining_items.len);
                const new_items = try allocator.dupe(Value, remaining_items[skip..]);
                const result = try allocator.create(value_mod.PersistentList);
                result.* = .{ .items = new_items };
                return Value{ .list = result };
            }
        }
        return current;
    }

    const items = helpers.getItems(args[1]) orelse return error.TypeError;
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
    const items = (try helpers.getItemsRealized(allocator, args[0])) orelse return error.TypeError;
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
    const items = helpers.getItems(args[0]) orelse return error.TypeError;

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
// インターリーブ・インターポーズ・頻度
// ============================================================

/// interleave : 複数コレクションの要素を交互に配置
/// (interleave [1 2 3] [:a :b :c]) => (1 :a 2 :b 3 :c)
pub fn interleave(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;

    // 各コレクションの要素を取得
    var colls = allocator.alloc([]const Value, args.len) catch return error.OutOfMemory;
    var min_len: usize = std.math.maxInt(usize);
    for (args, 0..) |arg, i| {
        colls[i] = helpers.getItems(arg) orelse return error.TypeError;
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
    const items = helpers.getItems(args[1]) orelse return error.TypeError;
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
    const items = helpers.getItems(args[0]) orelse return error.TypeError;

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

// ============================================================
// パーティション
// ============================================================

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

    const items = helpers.getItems(args[coll_idx]) orelse return error.TypeError;

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

    const items = helpers.getItems(args[coll_idx]) orelse return error.TypeError;

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

// ============================================================
// split / take-last / drop-last / take-nth / shuffle
// ============================================================

/// split-at : (split-at n coll) => [(take n coll) (drop n coll)]
pub fn splitAt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int) return error.TypeError;
    const n_raw = args[0].int;
    const n: usize = if (n_raw < 0) 0 else @intCast(n_raw);
    const items = helpers.getItems(args[1]) orelse return error.TypeError;
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

/// take-last : 末尾 n 個
pub fn takeLast(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int) return error.TypeError;
    const n_raw = args[0].int;
    const n: usize = if (n_raw < 0) 0 else @intCast(n_raw);
    const items = helpers.getItems(args[1]) orelse return error.TypeError;
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
    const items = helpers.getItems(args[coll_idx]) orelse return error.TypeError;
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
    const items = helpers.getItems(args[1]) orelse return error.TypeError;

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
    const items = helpers.getItems(args[0]) orelse return error.TypeError;
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

// ============================================================
// rand / rand-int
// ============================================================

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

// ============================================================
// rand-nth / repeatedly / reductions
// ============================================================

/// rand-nth : コレクションからランダムに1つ選ぶ
pub fn randNth(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = (try helpers.getItemsRealized(allocator, args[0])) orelse return error.TypeError;
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
    const call = defs.call_fn orelse return error.TypeError;

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
    const call = defs.call_fn orelse return error.TypeError;

    var acc: Value = undefined;
    var items: []const Value = undefined;

    if (args.len == 2) {
        // (reductions f coll)
        const coll_items = (try helpers.getItemsRealized(allocator, args[1])) orelse return error.TypeError;
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
        items = (try helpers.getItemsRealized(allocator, args[2])) orelse return error.TypeError;
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

// ============================================================
// split-with / dedupe / rseq / max-key / min-key
// ============================================================

/// split-with : 述語を満たす先頭部分と残りに分割
/// (split-with pred coll) → [(take-while pred coll) (drop-while pred coll)]
pub fn splitWith(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const pred = args[0];
    const coll = args[1];
    const call = defs.call_fn orelse return error.TypeError;

    const items = (try helpers.getItemsRealized(allocator, coll)) orelse return error.TypeError;
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
    const items = (try helpers.getItemsRealized(allocator, args[0])) orelse return error.TypeError;
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
    const call = defs.call_fn orelse return error.TypeError;

    var best = args[1];
    const call_args0 = [_]Value{best};
    var best_score = try call(f, &call_args0, allocator);

    for (args[2..]) |item| {
        const call_args = [_]Value{item};
        const score = try call(f, &call_args, allocator);
        if (helpers.compareValues(score, best_score) > 0) {
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
    const call = defs.call_fn orelse return error.TypeError;

    var best = args[1];
    const call_args0 = [_]Value{best};
    var best_score = try call(f, &call_args0, allocator);

    for (args[2..]) |item| {
        const call_args = [_]Value{item};
        const score = try call(f, &call_args, allocator);
        if (helpers.compareValues(score, best_score) < 0) {
            best = item;
            best_score = score;
        }
    }
    return best;
}

// ============================================================
// replicate / random-sample
// ============================================================

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
    const items = try helpers.collectToSlice(allocator, args[1]);
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

// ============================================================
// Phase Q1a: 特殊形式 → 通常 builtin 移行 (7 関数)
// ============================================================

/// apply : (apply f args) (apply f x y args)
/// 最終引数をシーケンスとして展開し、中間引数と結合して関数を呼び出す
pub fn applyFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const call = defs.call_fn orelse return error.TypeError;

    const fn_val = args[0];
    // 最終引数（シーケンス）
    const last_arg = args[args.len - 1];
    const seq_items: []const Value = switch (last_arg) {
        .list => |l| l.items,
        .vector => |v| v.items,
        .nil => &[_]Value{},
        .lazy_seq => try helpers.collectToSlice(allocator, last_arg),
        else => return error.TypeError,
    };

    // 中間引数 (args[1..len-1])
    const middle = args[1 .. args.len - 1];
    const total_len = middle.len + seq_items.len;
    const all_args = try allocator.alloc(Value, total_len);
    @memcpy(all_args[0..middle.len], middle);
    @memcpy(all_args[middle.len..], seq_items);

    return call(fn_val, all_args, allocator);
}

/// partial : (partial f arg1 arg2 ...) → 部分適用関数
pub fn partialFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;

    const fn_val = args[0];
    const partial_args = try allocator.alloc(Value, args.len - 1);
    @memcpy(partial_args, args[1..]);

    const pf = try allocator.create(value_mod.PartialFn);
    pf.* = .{
        .fn_val = fn_val,
        .args = partial_args,
    };

    return Value{ .partial_fn = pf };
}

/// comp : (comp) → identity, (comp f) → f, (comp f g ...) → 合成関数
pub fn compFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // (comp) → identity を返す
    if (args.len == 0) {
        // identity 関数を返す (builtin)
        const fn_obj = try allocator.create(Fn);
        fn_obj.* = Fn.initBuiltin("identity", arithmetic.identity);
        return Value{ .fn_val = fn_obj };
    }

    // (comp f) → f をそのまま返す
    if (args.len == 1) {
        return args[0];
    }

    // (comp f g h ...) → CompFn を作成
    const fns = try allocator.alloc(Value, args.len);
    @memcpy(fns, args);

    const cf = try allocator.create(value_mod.CompFn);
    cf.* = .{ .fns = fns };

    return Value{ .comp_fn = cf };
}

/// reduce : (reduce f coll) (reduce f init coll)
pub fn reduceFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    const call = defs.call_fn orelse return error.TypeError;

    const fn_val = args[0];

    // コレクションと初期値を決定
    var acc: Value = undefined;
    var start_idx: usize = 0;
    var items: []const Value = undefined;

    if (args.len == 3) {
        // (reduce f init coll)
        acc = args[1];
        items = try helpers.collectToSlice(allocator, args[2]);
    } else {
        // (reduce f coll)
        items = try helpers.collectToSlice(allocator, args[1]);
        if (items.len == 0) {
            // 空コレクションで初期値なし → (f) を呼び出す
            return call(fn_val, &[_]Value{}, allocator);
        }
        acc = items[0];
        start_idx = 1;
    }

    // 畳み込み
    for (items[start_idx..]) |item| {
        const call_args = try allocator.alloc(Value, 2);
        call_args[0] = acc;
        call_args[1] = item;
        acc = try call(fn_val, call_args, allocator);
        // reduced による早期終了
        if (acc == .reduced_val) {
            return acc.reduced_val.value;
        }
    }

    return acc;
}

/// 値の比較（sort-by 用内部ヘルパー）
fn sortValueCompare(a: Value, b: Value) std.math.Order {
    if (a == .int and b == .int) {
        return std.math.order(a.int, b.int);
    }
    if (a == .float and b == .float) {
        return std.math.order(a.float, b.float);
    }
    if (a == .int and b == .float) {
        return std.math.order(@as(f64, @floatFromInt(a.int)), b.float);
    }
    if (a == .float and b == .int) {
        return std.math.order(a.float, @as(f64, @floatFromInt(b.int)));
    }
    if (a == .string and b == .string) {
        return std.mem.order(u8, a.string.data, b.string.data);
    }
    if (a == .keyword and b == .keyword) {
        return std.mem.order(u8, a.keyword.name, b.keyword.name);
    }
    return .eq;
}

/// sort-by : (sort-by keyfn coll)
pub fn sortByFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const call = defs.call_fn orelse return error.TypeError;

    const fn_val = args[0];
    const items = try helpers.collectToSlice(allocator, args[1]);

    if (items.len == 0) {
        const result = try allocator.create(value_mod.PersistentList);
        result.* = .{ .items = &[_]Value{} };
        return Value{ .list = result };
    }

    // 各要素のキーを計算
    const sort_keys = try allocator.alloc(Value, items.len);
    for (items, 0..) |item, i| {
        const call_args = try allocator.alloc(Value, 1);
        call_args[0] = item;
        sort_keys[i] = try call(fn_val, call_args, allocator);
    }

    // insertion sort（安定ソート）
    var sorted = try allocator.dupe(Value, items);
    var sorted_keys = try allocator.dupe(Value, sort_keys);
    for (1..sorted.len) |i| {
        const val_i = sorted[i];
        const key_i = sorted_keys[i];
        var j: usize = i;
        while (j > 0 and sortValueCompare(sorted_keys[j - 1], key_i) == .gt) {
            sorted[j] = sorted[j - 1];
            sorted_keys[j] = sorted_keys[j - 1];
            j -= 1;
        }
        sorted[j] = val_i;
        sorted_keys[j] = key_i;
    }

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = sorted };
    return Value{ .list = result };
}

/// group-by : (group-by f coll)
pub fn groupByFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const call = defs.call_fn orelse return error.TypeError;

    const fn_val = args[0];
    const items = try helpers.collectToSlice(allocator, args[1]);

    // キーごとにグループ化
    var group_keys: std.ArrayListUnmanaged(Value) = .empty;
    var group_vals: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Value)) = .empty;

    for (items) |item| {
        const call_args = try allocator.alloc(Value, 1);
        call_args[0] = item;
        const key = try call(fn_val, call_args, allocator);

        // 既存キーを探す
        var found = false;
        for (group_keys.items, 0..) |gk, i| {
            if (key.eql(gk)) {
                try group_vals.items[i].append(allocator, item);
                found = true;
                break;
            }
        }
        if (!found) {
            try group_keys.append(allocator, key);
            var new_list: std.ArrayListUnmanaged(Value) = .empty;
            try new_list.append(allocator, item);
            try group_vals.append(allocator, new_list);
        }
    }

    // マップに変換: {key1 [v1 v2], key2 [v3] ...}
    const entries = try allocator.alloc(Value, group_keys.items.len * 2);
    for (group_keys.items, 0..) |key, i| {
        entries[i * 2] = key;
        const vec_items = try group_vals.items[i].toOwnedSlice(allocator);
        const vec = try allocator.create(value_mod.PersistentVector);
        vec.* = .{ .items = vec_items };
        entries[i * 2 + 1] = Value{ .vector = vec };
    }

    const result = try allocator.create(value_mod.PersistentMap);
    result.* = .{ .entries = entries };
    return Value{ .map = result };
}

/// swap! : (swap! atom f) (swap! atom f x y ...)
pub fn swapBangFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const call = defs.call_fn orelse return error.TypeError;

    const atom_ptr = switch (args[0]) {
        .atom => |a| a,
        else => return error.TypeError,
    };

    const fn_val = args[1];
    const old_val = atom_ptr.value;

    // (f current-val extra-args...) の引数を構築
    const extra = args[2..];
    const total = 1 + extra.len;
    const call_args = try allocator.alloc(Value, total);
    call_args[0] = atom_ptr.value; // 現在の値
    @memcpy(call_args[1..], extra);

    // 関数を適用
    const new_val = try call(fn_val, call_args, allocator);

    // scratch 参照を排除するためディープクローン
    const cloned = try new_val.deepClone(allocator);

    // Atom を更新
    atom_ptr.value = cloned;

    // ウォッチャー通知
    const concurrency = @import("concurrency.zig");
    concurrency.notifyWatchesPublic(atom_ptr.watches, args[0], old_val, cloned, allocator);

    return cloned;
}

// ============================================================
// Phase Q1b: 遅延特殊形式 → builtin 移行 (5 関数)
// ============================================================

/// map : (map f coll) → 遅延シーケンス
/// 全入力型に対して Transform ベースの LazySeq を返す
pub fn mapFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const fn_val = args[0];
    const coll = args[1];

    // nil → 空リスト
    if (coll == .nil) {
        const result = try allocator.create(value_mod.PersistentList);
        result.* = .{ .items = &[_]Value{} };
        return Value{ .list = result };
    }

    // 全入力型に対して遅延 Transform を返す
    const ls = try allocator.create(value_mod.LazySeq);
    ls.* = value_mod.LazySeq.initTransform(.map, fn_val, coll);
    return Value{ .lazy_seq = ls };
}

/// filter : (filter pred coll) → 遅延シーケンス
pub fn filterFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const fn_val = args[0];
    const coll = args[1];

    if (coll == .nil) {
        const result = try allocator.create(value_mod.PersistentList);
        result.* = .{ .items = &[_]Value{} };
        return Value{ .list = result };
    }

    const ls = try allocator.create(value_mod.LazySeq);
    ls.* = value_mod.LazySeq.initTransform(.filter, fn_val, coll);
    return Value{ .lazy_seq = ls };
}

/// take-while : (take-while pred coll) → 遅延シーケンス
pub fn takeWhileFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const fn_val = args[0];
    const coll = args[1];

    if (coll == .nil) {
        const result = try allocator.create(value_mod.PersistentList);
        result.* = .{ .items = &[_]Value{} };
        return Value{ .list = result };
    }

    const ls = try allocator.create(value_mod.LazySeq);
    ls.* = value_mod.LazySeq.initTransform(.take_while, fn_val, coll);
    return Value{ .lazy_seq = ls };
}

/// drop-while : (drop-while pred coll) → 遅延シーケンス
pub fn dropWhileFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const fn_val = args[0];
    const coll = args[1];

    if (coll == .nil) {
        const result = try allocator.create(value_mod.PersistentList);
        result.* = .{ .items = &[_]Value{} };
        return Value{ .list = result };
    }

    const ls = try allocator.create(value_mod.LazySeq);
    ls.* = value_mod.LazySeq.initTransform(.drop_while, fn_val, coll);
    return Value{ .lazy_seq = ls };
}

/// map-indexed : (map-indexed f coll) → 遅延シーケンス
/// f は (f index element) の 2 引数
pub fn mapIndexedFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const fn_val = args[0];
    const coll = args[1];

    if (coll == .nil) {
        const result = try allocator.create(value_mod.PersistentList);
        result.* = .{ .items = &[_]Value{} };
        return Value{ .list = result };
    }

    const ls = try allocator.create(value_mod.LazySeq);
    ls.* = value_mod.LazySeq.initTransformIndexed(fn_val, coll, 0);
    return Value{ .lazy_seq = ls };
}

// ============================================================
// Phase 12E: HOF・遅延操作
// ============================================================

/// trampoline : 関数を呼び続ける（結果が関数でなくなるまで）
/// (trampoline f & args) — f を args で呼び、結果が関数なら再度呼ぶ
pub fn trampolineFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    const call = defs.call_fn orelse return error.TypeError;

    // 初回呼び出し
    var result = try call(args[0], args[1..], allocator);

    // 結果が関数の間ループ
    while (helpers.isFnValue(result)) {
        result = try call(result, &[_]Value{}, allocator);
    }
    return result;
}

/// tree-seq : ツリーを深さ優先で走査
/// (tree-seq branch? children root)
pub fn treeSeqFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const call = defs.call_fn orelse return error.TypeError;
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
            const children_slice = try helpers.collectToSlice(allocator, children_val);
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
    const call = defs.call_fn orelse return error.TypeError;
    const f = args[0];
    const items = try helpers.collectToSlice(allocator, args[1]);
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

/// walk : データ構造を再帰的に変換
/// (walk inner outer form)
///   inner を各要素に適用し、outer を結果に適用
pub fn walkFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const call = defs.call_fn orelse return error.TypeError;
    const inner = args[0];
    const outer = args[1];
    const form = args[2];

    const transformed: Value = switch (form) {
        .list => |l| blk: {
            // (apply list (map inner form))
            var items: std.ArrayListUnmanaged(Value) = .empty;
            for (l.items) |item| {
                const r = try call(inner, &[_]Value{item}, allocator);
                items.append(allocator, r) catch return error.OutOfMemory;
            }
            const result = try allocator.create(value_mod.PersistentList);
            result.* = .{ .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
            break :blk Value{ .list = result };
        },
        .vector => |v| blk: {
            // (mapv inner form)
            var items: std.ArrayListUnmanaged(Value) = .empty;
            for (v.items) |item| {
                const r = try call(inner, &[_]Value{item}, allocator);
                items.append(allocator, r) catch return error.OutOfMemory;
            }
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = .{ .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
            break :blk Value{ .vector = result };
        },
        .map => |m| blk: {
            // (into {} (map inner form)) — inner は [k v] ペアを受け取る
            var entries: std.ArrayListUnmanaged(Value) = .empty;
            var i: usize = 0;
            while (i < m.entries.len) : (i += 2) {
                // map-entry を vector [k v] として渡す
                const pair_items = try allocator.alloc(Value, 2);
                pair_items[0] = m.entries[i];
                pair_items[1] = m.entries[i + 1];
                const pair_vec = try allocator.create(value_mod.PersistentVector);
                pair_vec.* = .{ .items = pair_items };
                const r = try call(inner, &[_]Value{Value{ .vector = pair_vec }}, allocator);
                // 結果は [k v] ベクタであるべき
                if (r == .vector and r.vector.items.len == 2) {
                    entries.append(allocator, r.vector.items[0]) catch return error.OutOfMemory;
                    entries.append(allocator, r.vector.items[1]) catch return error.OutOfMemory;
                } else {
                    return error.TypeError;
                }
            }
            const result = try allocator.create(value_mod.PersistentMap);
            result.* = .{ .entries = entries.toOwnedSlice(allocator) catch return error.OutOfMemory };
            break :blk Value{ .map = result };
        },
        .set => |s| blk: {
            // (into #{} (map inner form))
            var items: std.ArrayListUnmanaged(Value) = .empty;
            for (s.items) |item| {
                const r = try call(inner, &[_]Value{item}, allocator);
                // 重複除去
                var found = false;
                for (items.items) |existing| {
                    if (r.eql(existing)) { found = true; break; }
                }
                if (!found) {
                    items.append(allocator, r) catch return error.OutOfMemory;
                }
            }
            const result = try allocator.create(value_mod.PersistentSet);
            result.* = .{ .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
            break :blk Value{ .set = result };
        },
        else => form, // atom の場合はそのまま
    };

    // outer を適用
    return call(outer, &[_]Value{transformed}, allocator);
}

/// postwalk : ボトムアップ walk (inner = postwalk(f), outer = f)
/// (postwalk f form)
pub fn postwalkFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const call = defs.call_fn orelse return error.TypeError;
    const f = args[0];
    const form = args[1];

    return postwalkImpl(allocator, call, f, form);
}

fn postwalkImpl(allocator: std.mem.Allocator, call: defs.CallFn, f: Value, form: Value) anyerror!Value {
    const walked: Value = switch (form) {
        .list => |l| blk: {
            var items: std.ArrayListUnmanaged(Value) = .empty;
            for (l.items) |item| {
                const r = try postwalkImpl(allocator, call, f, item);
                items.append(allocator, r) catch return error.OutOfMemory;
            }
            const result = try allocator.create(value_mod.PersistentList);
            result.* = .{ .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
            break :blk Value{ .list = result };
        },
        .vector => |v| blk: {
            var items: std.ArrayListUnmanaged(Value) = .empty;
            for (v.items) |item| {
                const r = try postwalkImpl(allocator, call, f, item);
                items.append(allocator, r) catch return error.OutOfMemory;
            }
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = .{ .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
            break :blk Value{ .vector = result };
        },
        .map => |m| blk: {
            var entries: std.ArrayListUnmanaged(Value) = .empty;
            var i: usize = 0;
            while (i < m.entries.len) : (i += 2) {
                const k = try postwalkImpl(allocator, call, f, m.entries[i]);
                const v = try postwalkImpl(allocator, call, f, m.entries[i + 1]);
                entries.append(allocator, k) catch return error.OutOfMemory;
                entries.append(allocator, v) catch return error.OutOfMemory;
            }
            const result = try allocator.create(value_mod.PersistentMap);
            result.* = .{ .entries = entries.toOwnedSlice(allocator) catch return error.OutOfMemory };
            break :blk Value{ .map = result };
        },
        .set => |s| blk: {
            var items: std.ArrayListUnmanaged(Value) = .empty;
            for (s.items) |item| {
                const r = try postwalkImpl(allocator, call, f, item);
                var found = false;
                for (items.items) |existing| {
                    if (r.eql(existing)) { found = true; break; }
                }
                if (!found) {
                    items.append(allocator, r) catch return error.OutOfMemory;
                }
            }
            const result = try allocator.create(value_mod.PersistentSet);
            result.* = .{ .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
            break :blk Value{ .set = result };
        },
        else => form,
    };

    return call(f, &[_]Value{walked}, allocator);
}

/// prewalk : トップダウン walk (inner = prewalk(f), outer = identity)
/// (prewalk f form)
pub fn prewalkFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const call = defs.call_fn orelse return error.TypeError;
    const f = args[0];
    const form = args[1];

    return prewalkImpl(allocator, call, f, form);
}

fn prewalkImpl(allocator: std.mem.Allocator, call: defs.CallFn, f: Value, form: Value) anyerror!Value {
    // まず f を適用
    const transformed = try call(f, &[_]Value{form}, allocator);

    // 次に子要素を再帰的に prewalk
    return switch (transformed) {
        .list => |l| blk: {
            var items: std.ArrayListUnmanaged(Value) = .empty;
            for (l.items) |item| {
                const r = try prewalkImpl(allocator, call, f, item);
                items.append(allocator, r) catch return error.OutOfMemory;
            }
            const result = try allocator.create(value_mod.PersistentList);
            result.* = .{ .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
            break :blk Value{ .list = result };
        },
        .vector => |v| blk: {
            var items: std.ArrayListUnmanaged(Value) = .empty;
            for (v.items) |item| {
                const r = try prewalkImpl(allocator, call, f, item);
                items.append(allocator, r) catch return error.OutOfMemory;
            }
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = .{ .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
            break :blk Value{ .vector = result };
        },
        .map => |m| blk: {
            var entries: std.ArrayListUnmanaged(Value) = .empty;
            var i: usize = 0;
            while (i < m.entries.len) : (i += 2) {
                const k = try prewalkImpl(allocator, call, f, m.entries[i]);
                const v = try prewalkImpl(allocator, call, f, m.entries[i + 1]);
                entries.append(allocator, k) catch return error.OutOfMemory;
                entries.append(allocator, v) catch return error.OutOfMemory;
            }
            const result = try allocator.create(value_mod.PersistentMap);
            result.* = .{ .entries = entries.toOwnedSlice(allocator) catch return error.OutOfMemory };
            break :blk Value{ .map = result };
        },
        .set => |s| blk: {
            var items: std.ArrayListUnmanaged(Value) = .empty;
            for (s.items) |item| {
                const r = try prewalkImpl(allocator, call, f, item);
                var found = false;
                for (items.items) |existing| {
                    if (r.eql(existing)) { found = true; break; }
                }
                if (!found) {
                    items.append(allocator, r) catch return error.OutOfMemory;
                }
            }
            const result = try allocator.create(value_mod.PersistentSet);
            result.* = .{ .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
            break :blk Value{ .set = result };
        },
        else => transformed,
    };
}

// ============================================================
// Builtins 登録テーブル
// ============================================================

pub const builtins = [_]BuiltinDef{
    // シーケンス操作
    .{ .name = "take", .func = take },
    .{ .name = "drop", .func = drop },
    .{ .name = "range", .func = range },
    .{ .name = "repeat", .func = repeat },
    .{ .name = "iterate", .func = iterate },
    .{ .name = "cycle", .func = cycle },
    .{ .name = "mapcat", .func = mapcat },
    .{ .name = "distinct", .func = distinct },
    .{ .name = "flatten", .func = flatten },
    .{ .name = "interleave", .func = interleave },
    .{ .name = "interpose", .func = interpose },
    .{ .name = "frequencies", .func = frequencies },
    .{ .name = "partition", .func = partition },
    .{ .name = "partition-all", .func = partitionAll },
    .{ .name = "split-at", .func = splitAt },
    .{ .name = "take-last", .func = takeLast },
    .{ .name = "drop-last", .func = dropLast },
    .{ .name = "take-nth", .func = takeNth },
    .{ .name = "shuffle", .func = shuffle },
    .{ .name = "rand", .func = randFn },
    .{ .name = "rand-int", .func = randInt },
    .{ .name = "rand-nth", .func = randNth },
    .{ .name = "repeatedly", .func = repeatedly },
    .{ .name = "reductions", .func = reductions },
    .{ .name = "split-with", .func = splitWith },
    .{ .name = "dedupe", .func = dedupeFn },
    .{ .name = "rseq", .func = rseq },
    .{ .name = "max-key", .func = maxKey },
    .{ .name = "min-key", .func = minKey },
    .{ .name = "replicate", .func = replicateFn },
    .{ .name = "random-sample", .func = randomSample },
    // Phase Q1a: 特殊形式 → builtin 移行
    .{ .name = "apply", .func = applyFn },
    .{ .name = "partial", .func = partialFn },
    .{ .name = "comp", .func = compFn },
    .{ .name = "reduce", .func = reduceFn },
    .{ .name = "sort-by", .func = sortByFn },
    .{ .name = "group-by", .func = groupByFn },
    .{ .name = "swap!", .func = swapBangFn },
    // Phase Q1b: 遅延特殊形式 → builtin 移行
    .{ .name = "map", .func = mapFn },
    .{ .name = "filter", .func = filterFn },
    .{ .name = "take-while", .func = takeWhileFn },
    .{ .name = "drop-while", .func = dropWhileFn },
    .{ .name = "map-indexed", .func = mapIndexedFn },
    // Phase 12E: HOF・遅延操作
    .{ .name = "trampoline", .func = trampolineFn },
    .{ .name = "tree-seq", .func = treeSeqFn },
    .{ .name = "partition-by", .func = partitionByFn },
    // walk
    .{ .name = "walk", .func = walkFn },
    .{ .name = "postwalk", .func = postwalkFn },
    .{ .name = "prewalk", .func = prewalkFn },
};
