//! コレクション操作
//!
//! conj, assoc, get, nth, merge, keys, vals, constructors etc.

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const BuiltinDef = defs.BuiltinDef;

const helpers = @import("helpers.zig");
const lazy = @import("lazy.zig");

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
        return lazy.lazyFirst(allocator, args[0].lazy_seq);
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
        return lazy.lazyRest(allocator, args[0].lazy_seq);
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
        try lazy.forceLazySeq(allocator, args[0].lazy_seq)
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
        const f = try lazy.lazyFirst(allocator, args[0].lazy_seq);
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

    const m = try allocator.create(value_mod.PersistentMap);
    m.* = try value_mod.PersistentMap.fromUnsortedEntries(allocator, args);
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
        const items = (try helpers.getItemsRealized(allocator, arg)) orelse return error.TypeError;
        total += items.len;
    }

    const new_items = try allocator.alloc(Value, total);
    var offset: usize = 0;
    for (args) |arg| {
        const items = (try helpers.getItemsRealized(allocator, arg)).?;
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

    const from_items = (try helpers.getItemsRealized(allocator, args[1])) orelse return error.TypeError;

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
    // lazy-seq 対応: collectToSlice で全要素を取得
    const items = helpers.collectToSlice(allocator, args[0]) catch return error.TypeError;

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
        const f = try lazy.lazyFirst(allocator, args[0].lazy_seq);
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
            const realized = try helpers.ensureRealized(allocator, args[0]);
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

/// doall : 遅延シーケンスを完全に実体化して返す
pub fn doall(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return helpers.ensureRealized(allocator, args[0]);
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

    const keys_items = helpers.getItems(args[0]) orelse return error.TypeError;
    const vals_items = helpers.getItems(args[1]) orelse return error.TypeError;

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
    const items = helpers.getItems(args[0]) orelse return error.TypeError;
    return if (items.len > 0) items[items.len - 1] else value_mod.nil;
}

/// butlast : 最後の要素を除いたシーケンス
pub fn butlast(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = helpers.getItems(args[0]) orelse return error.TypeError;
    if (items.len <= 1) return value_mod.nil;
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = try allocator.dupe(Value, items[0 .. items.len - 1]) };
    return Value{ .list = result };
}

/// next : rest と同じだが、空なら nil を返す
pub fn next(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = helpers.getItems(args[0]) orelse return error.TypeError;
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
    const items = helpers.getItems(args[0]) orelse return error.TypeError;
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
    const inner_items = helpers.getItems(outer) orelse return error.TypeError;
    if (inner_items.len <= 1) return value_mod.nil;
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = try allocator.dupe(Value, inner_items[1..]) };
    return Value{ .list = result };
}

/// nnext : (next (next coll))
pub fn nnext(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = helpers.getItems(args[0]) orelse return error.TypeError;
    if (items.len <= 2) return value_mod.nil;
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = try allocator.dupe(Value, items[2..]) };
    return Value{ .list = result };
}

/// set : コレクションをセットに変換 (lazy-seq 対応)
/// (set [1 2 2 3]) => #{1 2 3}
pub fn setFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] == .nil) return value_mod.nil;
    // set 自体はそのまま返す
    if (args[0] == .set) return args[0];
    // lazy-seq, map 等もサポート
    const items = try helpers.collectToSlice(allocator, args[0]);

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

/// set-union : 複数セットの和集合
/// (set-union #{1 2} #{2 3}) => #{1 2 3}
pub fn setUnion(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) {
        const empty = try allocator.create(value_mod.PersistentSet);
        empty.* = value_mod.PersistentSet.empty();
        return Value{ .set = empty };
    }
    if (args[0] == .nil) {
        // nil を先頭にした場合、残りのセットの union
        if (args.len == 1) return value_mod.nil;
        return setUnion(allocator, args[1..]);
    }
    if (args[0] != .set) return error.TypeError;

    if (args.len == 1) return args[0];

    // 最初のセットの要素をリストに入れる
    var items: std.ArrayListUnmanaged(Value) = .empty;
    for (args[0].set.items) |item| {
        items.append(allocator, item) catch return error.OutOfMemory;
    }

    // 残りのセットの要素を追加 (重複除去)
    for (args[1..]) |arg| {
        if (arg == .nil) continue;
        if (arg != .set) return error.TypeError;
        for (arg.set.items) |item| {
            var found = false;
            for (items.items) |existing| {
                if (item.eql(existing)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                items.append(allocator, item) catch return error.OutOfMemory;
            }
        }
    }

    const result = try allocator.create(value_mod.PersistentSet);
    result.* = .{ .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return Value{ .set = result };
}

/// set-intersection : 複数セットの積集合
/// (set-intersection #{1 2 3} #{2 3 4}) => #{2 3}
pub fn setIntersection(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    if (args[0] != .set) return error.TypeError;
    if (args.len == 1) return args[0];

    var items: std.ArrayListUnmanaged(Value) = .empty;
    for (args[0].set.items) |item| {
        var in_all = true;
        for (args[1..]) |arg| {
            if (arg != .set) return error.TypeError;
            if (!arg.set.contains(item)) {
                in_all = false;
                break;
            }
        }
        if (in_all) {
            items.append(allocator, item) catch return error.OutOfMemory;
        }
    }

    const result = try allocator.create(value_mod.PersistentSet);
    result.* = .{ .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return Value{ .set = result };
}

/// set-difference : 差集合 (最初のセットから残りの要素を除去)
/// (set-difference #{1 2 3} #{2 3 4}) => #{1}
pub fn setDifference(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    if (args[0] != .set) return error.TypeError;
    if (args.len == 1) return args[0];

    var items: std.ArrayListUnmanaged(Value) = .empty;
    for (args[0].set.items) |item| {
        var in_any = false;
        for (args[1..]) |arg| {
            if (arg == .nil) continue;
            if (arg != .set) return error.TypeError;
            if (arg.set.contains(item)) {
                in_any = true;
                break;
            }
        }
        if (!in_any) {
            items.append(allocator, item) catch return error.OutOfMemory;
        }
    }

    const result = try allocator.create(value_mod.PersistentSet);
    result.* = .{ .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return Value{ .set = result };
}

/// set-subset? : s1 が s2 の部分集合か
/// (set-subset? #{1 2} #{1 2 3}) => true
pub fn setSubset(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .set or args[1] != .set) return error.TypeError;

    for (args[0].set.items) |item| {
        if (!args[1].set.contains(item)) return value_mod.false_val;
    }
    return value_mod.true_val;
}

/// set-superset? : s1 が s2 の上位集合か
/// (set-superset? #{1 2 3} #{1 2}) => true
pub fn setSuperset(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .set or args[1] != .set) return error.TypeError;

    for (args[1].set.items) |item| {
        if (!args[0].set.contains(item)) return value_mod.false_val;
    }
    return value_mod.true_val;
}

/// set-select : 述語を満たす要素のみのセットを返す
/// (set-select odd? #{1 2 3 4}) => #{1 3}
pub fn setSelect(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[1] != .set) return error.TypeError;

    const call = defs.call_fn orelse return error.TypeError;
    const pred = args[0];
    var items: std.ArrayListUnmanaged(Value) = .empty;

    for (args[1].set.items) |item| {
        const call_args = [_]Value{item};
        const result = try call(pred, &call_args, allocator);
        if (result.isTruthy()) {
            items.append(allocator, item) catch return error.OutOfMemory;
        }
    }

    const result_set = try allocator.create(value_mod.PersistentSet);
    result_set.* = .{ .items = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return Value{ .set = result_set };
}

/// set-rename-keys : マップのキーを別名に変換
/// (set-rename-keys {:a 1 :b 2} {:a :new-a}) => {:new-a 1 :b 2}
pub fn setRenameKeys(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .map or args[1] != .map) return error.TypeError;

    const m = args[0].map;
    const kmap = args[1].map;

    var entries: std.ArrayListUnmanaged(Value) = .empty;
    var i: usize = 0;
    while (i < m.entries.len) : (i += 2) {
        const old_key = m.entries[i];
        const val = m.entries[i + 1];
        // kmap にキーがあれば新名、なければ元名
        if (kmap.get(old_key)) |new_key| {
            entries.append(allocator, new_key) catch return error.OutOfMemory;
        } else {
            entries.append(allocator, old_key) catch return error.OutOfMemory;
        }
        entries.append(allocator, val) catch return error.OutOfMemory;
    }

    const result = try allocator.create(value_mod.PersistentMap);
    result.* = .{ .entries = entries.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return Value{ .map = result };
}

/// set-map-invert : マップのキーと値を逆転
/// (set-map-invert {:a 1 :b 2}) => {1 :a 2 :b}
pub fn setMapInvert(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .map) return error.TypeError;

    const m = args[0].map;
    var entries: std.ArrayListUnmanaged(Value) = .empty;
    var i: usize = 0;
    while (i < m.entries.len) : (i += 2) {
        entries.append(allocator, m.entries[i + 1]) catch return error.OutOfMemory; // val → key
        entries.append(allocator, m.entries[i]) catch return error.OutOfMemory; // key → val
    }

    const result = try allocator.create(value_mod.PersistentMap);
    result.* = .{ .entries = entries.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return Value{ .map = result };
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

/// replace : コレクション内の値をマップで置換
/// (replace {:a 1 :b 2} [:a :b :c :a]) => [1 2 :c 1]
pub fn replaceFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .map) return error.TypeError;
    const smap = args[0].map;
    const items = helpers.getItems(args[1]) orelse return error.TypeError;

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
    const items = helpers.getItems(args[0]) orelse return error.TypeError;
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
    const tail_items = (try helpers.getItemsRealized(allocator, last_arg)) orelse &[_]Value{};
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
    const call = defs.call_fn orelse return error.TypeError;

    const items = (try helpers.getItemsRealized(allocator, coll)) orelse return error.TypeError;
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

    const items = (try helpers.getItemsRealized(allocator, args[0])) orelse return error.TypeError;
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

    const items = (try helpers.getItemsRealized(allocator, args[0])) orelse return error.TypeError;
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
    const call = defs.call_fn orelse return error.TypeError;

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
    const call = defs.call_fn orelse return error.TypeError;

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
    const call = defs.call_fn orelse return error.TypeError;

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
    call: defs.CallFn,
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
    const call = defs.call_fn orelse return error.TypeError;

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
    const call = defs.call_fn orelse return error.TypeError;

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
    const items = try helpers.collectToSlice(allocator, args[0]);
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
    const items = try helpers.collectToSlice(allocator, args[0]);
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

// ============================================================
// builtins 登録テーブル
// ============================================================

pub const builtins = [_]BuiltinDef{
    // コンストラクタ
    .{ .name = "list", .func = list },
    .{ .name = "list*", .func = listStar },
    .{ .name = "vector", .func = vector },
    .{ .name = "hash-map", .func = hashMap },
    .{ .name = "array-map", .func = arrayMap },
    .{ .name = "hash-set", .func = hashSet },
    // コレクション操作
    .{ .name = "first", .func = first },
    .{ .name = "rest", .func = rest },
    .{ .name = "cons", .func = cons },
    .{ .name = "conj", .func = conj },
    .{ .name = "count", .func = count },
    .{ .name = "empty?", .func = isEmpty },
    .{ .name = "nth", .func = nth },
    .{ .name = "get", .func = get },
    .{ .name = "assoc", .func = assoc },
    .{ .name = "dissoc", .func = dissoc },
    .{ .name = "keys", .func = keys },
    .{ .name = "vals", .func = vals },
    .{ .name = "contains?", .func = containsKey },
    // シーケンス操作
    .{ .name = "concat", .func = concat },
    .{ .name = "into", .func = into },
    .{ .name = "reverse", .func = reverseFn },
    .{ .name = "seq", .func = seq },
    .{ .name = "vec", .func = vecFn },
    .{ .name = "doall", .func = doall },
    // ユーティリティ（Phase 8.16）
    .{ .name = "merge", .func = merge },
    .{ .name = "get-in", .func = getIn },
    .{ .name = "assoc-in", .func = assocIn },
    .{ .name = "select-keys", .func = selectKeys },
    .{ .name = "zipmap", .func = zipmap },
    .{ .name = "not-empty", .func = notEmpty },
    // Phase 8.19: シーケンス関数
    .{ .name = "second", .func = second },
    .{ .name = "last", .func = last },
    .{ .name = "butlast", .func = butlast },
    .{ .name = "next", .func = next },
    .{ .name = "ffirst", .func = ffirst },
    .{ .name = "fnext", .func = fnext },
    .{ .name = "nfirst", .func = nfirst },
    .{ .name = "nnext", .func = nnext },
    // セット操作
    .{ .name = "set", .func = setFn },
    .{ .name = "disj", .func = disjFn },
    .{ .name = "set-union", .func = setUnion },
    .{ .name = "set-intersection", .func = setIntersection },
    .{ .name = "set-difference", .func = setDifference },
    .{ .name = "set-subset?", .func = setSubset },
    .{ .name = "set-superset?", .func = setSuperset },
    .{ .name = "set-select", .func = setSelect },
    .{ .name = "set-rename-keys", .func = setRenameKeys },
    .{ .name = "set-map-invert", .func = setMapInvert },
    .{ .name = "find", .func = findFn },
    .{ .name = "replace", .func = replaceFn },
    .{ .name = "sort", .func = sortFn },
    // キーワード・シンボル
    .{ .name = "keyword", .func = keywordFn },
    .{ .name = "symbol", .func = symbolFn },
    // ベクタ操作
    .{ .name = "subvec", .func = subvec },
    .{ .name = "peek", .func = peek },
    .{ .name = "pop", .func = pop },
    // ハッシュ
    .{ .name = "hash", .func = hashFn },
    .{ .name = "hash-combine", .func = hashCombine },
    .{ .name = "hash-ordered-coll", .func = hashOrderedColl },
    .{ .name = "hash-unordered-coll", .func = hashUnorderedColl },
    .{ .name = "mix-collection-hash", .func = mixCollectionHash },
    .{ .name = "find-keyword", .func = findKeywordFn },
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
    .{ .name = "empty", .func = emptyFn },
    .{ .name = "sequence", .func = sequenceFn },
};

// ============================================================
// テスト
// ============================================================

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
