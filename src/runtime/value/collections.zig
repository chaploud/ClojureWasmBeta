//! 永続コレクション — PersistentList, PersistentVector, PersistentMap, PersistentSet
//!
//! value.zig (facade) から re-export される。

const std = @import("std");
const Value = @import("../value.zig").Value;

// === コレクション ===

/// 永続リスト（Cons cell ベース）
/// 初期実装: スライスベース、将来は真の永続リストに
pub const PersistentList = struct {
    items: []const Value,
    meta: ?*const Value = null,

    /// 空のリストを返す（値）
    pub fn emptyVal() PersistentList {
        return .{ .items = &[_]Value{} };
    }

    /// 空のリストを作成してポインタを返す
    pub fn empty(allocator: std.mem.Allocator) !*PersistentList {
        const list = try allocator.create(PersistentList);
        list.* = .{ .items = &[_]Value{} };
        return list;
    }

    /// スライスから作成
    pub fn fromSlice(allocator: std.mem.Allocator, items: []const Value) !*PersistentList {
        const list = try allocator.create(PersistentList);
        const new_items = try allocator.dupe(Value, items);
        list.* = .{ .items = new_items };
        return list;
    }

    pub fn count(self: PersistentList) usize {
        return self.items.len;
    }

    pub fn first(self: PersistentList) ?Value {
        if (self.items.len == 0) return null;
        return self.items[0];
    }

    pub fn rest(self: PersistentList, allocator: std.mem.Allocator) !PersistentList {
        if (self.items.len <= 1) return emptyVal();
        const new_items = try allocator.dupe(Value, self.items[1..]);
        return .{ .items = new_items };
    }
};

/// 永続ベクター
/// 初期実装: スライスベース、将来は32分木に
pub const PersistentVector = struct {
    items: []const Value,
    meta: ?*const Value = null,

    pub fn empty() PersistentVector {
        return .{ .items = &[_]Value{} };
    }

    pub fn count(self: PersistentVector) usize {
        return self.items.len;
    }

    pub fn nth(self: PersistentVector, index: usize) ?Value {
        if (index >= self.items.len) return null;
        return self.items[index];
    }

    pub fn conj(self: PersistentVector, allocator: std.mem.Allocator, val: Value) !PersistentVector {
        var new_items = try allocator.alloc(Value, self.items.len + 1);
        @memcpy(new_items[0..self.items.len], self.items);
        new_items[self.items.len] = val;
        return .{ .items = new_items };
    }
};

/// 永続マップ
/// ハッシュインデックス + バイナリサーチによる O(log n) ルックアップ
/// entries は挿入順を保持 (イテレーション互換性のため)
pub const PersistentMap = struct {
    /// キー値ペアのフラットな配列 [k1, v1, k2, v2, ...] — 挿入順
    entries: []const Value,
    /// ハッシュ値 (ソート済み、hash_index と並行)
    hash_values: []const u32 = &[_]u32{},
    /// entries 内のペアインデックス (hash_values 順にソート済み)
    /// entries[hash_index[i] * 2] が hash_values[i] に対応するキー
    hash_index: []const u32 = &[_]u32{},
    meta: ?*const Value = null,

    pub fn empty() PersistentMap {
        return .{ .entries = &[_]Value{} };
    }

    pub fn count(self: PersistentMap) usize {
        return self.entries.len / 2;
    }

    /// ハッシュインデックスが構築済みかどうか
    fn hasIndex(self: PersistentMap) bool {
        return self.hash_values.len > 0;
    }

    /// ハッシュ値でバイナリサーチし、該当するインデックス範囲を返す
    fn findHashRange(self: PersistentMap, target_hash: u32) struct { start: usize, end: usize } {
        const n = self.hash_values.len;
        if (n == 0) return .{ .start = 0, .end = 0 };

        // lower_bound: target_hash の最初の出現を探す
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.hash_values[mid] < target_hash) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        const start = lo;
        if (start >= n or self.hash_values[start] != target_hash) {
            return .{ .start = start, .end = start };
        }

        // 同一ハッシュの末尾を探す
        var end = start + 1;
        while (end < n and self.hash_values[end] == target_hash) {
            end += 1;
        }
        return .{ .start = start, .end = end };
    }

    pub fn get(self: PersistentMap, key: Value) ?Value {
        if (self.entries.len == 0) return null;

        // ハッシュインデックスがない場合はリニアスキャン
        if (!self.hasIndex()) {
            var i: usize = 0;
            while (i < self.entries.len) : (i += 2) {
                if (key.eql(self.entries[i])) {
                    return self.entries[i + 1];
                }
            }
            return null;
        }

        const target_hash = key.valueHash();
        const range = self.findHashRange(target_hash);

        for (range.start..range.end) |i| {
            const entry_idx = self.hash_index[i];
            if (key.eql(self.entries[entry_idx * 2])) {
                return self.entries[entry_idx * 2 + 1];
            }
        }
        return null;
    }

    pub fn assoc(self: PersistentMap, allocator: std.mem.Allocator, key: Value, val: Value) !PersistentMap {
        const pair_count = self.entries.len / 2;
        const target_hash = key.valueHash();

        if (pair_count == 0) {
            // 空マップへの追加
            const new_entries = try allocator.alloc(Value, 2);
            new_entries[0] = key;
            new_entries[1] = val;
            const new_hv = try allocator.alloc(u32, 1);
            new_hv[0] = target_hash;
            const new_hi = try allocator.alloc(u32, 1);
            new_hi[0] = 0;
            return .{ .entries = new_entries, .hash_values = new_hv, .hash_index = new_hi };
        }

        // ハッシュインデックスがない場合: 構築して再実行
        if (!self.hasIndex()) {
            const indexed = try buildIndex(allocator, self.entries);
            return indexed.assoc(allocator, key, val);
        }

        const n = self.hash_values.len;
        const range = self.findHashRange(target_hash);

        // 既存キーを探す
        for (range.start..range.end) |i| {
            const entry_idx = self.hash_index[i];
            if (key.eql(self.entries[entry_idx * 2])) {
                // 既存キーを更新 (entries の位置は変わらない)
                var new_entries = try allocator.dupe(Value, self.entries);
                new_entries[entry_idx * 2 + 1] = val;
                return .{ .entries = new_entries, .hash_values = self.hash_values, .hash_index = self.hash_index };
            }
        }

        // 新規キーを追加 (entries の末尾に追加、hash_index にソート挿入)
        const new_pair_idx: u32 = @intCast(pair_count);
        var new_entries = try allocator.alloc(Value, self.entries.len + 2);
        @memcpy(new_entries[0..self.entries.len], self.entries);
        new_entries[self.entries.len] = key;
        new_entries[self.entries.len + 1] = val;

        // hash_index にソート位置で挿入
        const insert_pos = range.start; // ソート位置 (同一ハッシュの先頭)
        var new_hv = try allocator.alloc(u32, n + 1);
        var new_hi = try allocator.alloc(u32, n + 1);

        @memcpy(new_hv[0..insert_pos], self.hash_values[0..insert_pos]);
        @memcpy(new_hi[0..insert_pos], self.hash_index[0..insert_pos]);

        new_hv[insert_pos] = target_hash;
        new_hi[insert_pos] = new_pair_idx;

        @memcpy(new_hv[insert_pos + 1 ..], self.hash_values[insert_pos..]);
        @memcpy(new_hi[insert_pos + 1 ..], self.hash_index[insert_pos..]);

        return .{ .entries = new_entries, .hash_values = new_hv, .hash_index = new_hi };
    }

    pub fn dissoc(self: PersistentMap, allocator: std.mem.Allocator, key: Value) !PersistentMap {
        if (self.entries.len == 0) return self;

        // ハッシュインデックスがない場合: リニアスキャン
        if (!self.hasIndex()) {
            var i: usize = 0;
            while (i < self.entries.len) : (i += 2) {
                if (key.eql(self.entries[i])) {
                    if (self.entries.len == 2) {
                        return .{ .entries = &[_]Value{} };
                    }
                    var new_entries = try allocator.alloc(Value, self.entries.len - 2);
                    @memcpy(new_entries[0..i], self.entries[0..i]);
                    @memcpy(new_entries[i..], self.entries[i + 2 ..]);
                    return .{ .entries = new_entries };
                }
            }
            return self;
        }

        const n = self.hash_values.len;
        const target_hash = key.valueHash();
        const range = self.findHashRange(target_hash);

        for (range.start..range.end) |i| {
            const entry_idx = self.hash_index[i];
            if (key.eql(self.entries[entry_idx * 2])) {
                if (n == 1) {
                    return .{ .entries = &[_]Value{} };
                }

                // entries から該当ペアを削除
                const del_pos = entry_idx * 2;
                var new_entries = try allocator.alloc(Value, self.entries.len - 2);
                @memcpy(new_entries[0..del_pos], self.entries[0..del_pos]);
                @memcpy(new_entries[del_pos..], self.entries[del_pos + 2 ..]);

                // hash_index から削除 + インデックス調整
                var new_hv = try allocator.alloc(u32, n - 1);
                var new_hi = try allocator.alloc(u32, n - 1);
                var dst: usize = 0;
                for (0..n) |j| {
                    if (j == i) continue;
                    new_hv[dst] = self.hash_values[j];
                    // entry_idx より後のインデックスは 1 減らす
                    new_hi[dst] = if (self.hash_index[j] > entry_idx)
                        self.hash_index[j] - 1
                    else
                        self.hash_index[j];
                    dst += 1;
                }

                return .{ .entries = new_entries, .hash_values = new_hv, .hash_index = new_hi };
            }
        }
        return self;
    }

    /// entries 配列からハッシュインデックスを構築
    pub fn buildIndex(allocator: std.mem.Allocator, entries: []const Value) !PersistentMap {
        const n = entries.len / 2;
        if (n == 0) return empty();

        // ハッシュ計算
        var hashes = try allocator.alloc(u32, n);
        var indices = try allocator.alloc(u32, n);
        for (0..n) |i| {
            hashes[i] = entries[i * 2].valueHash();
            indices[i] = @intCast(i);
        }

        // インデックスをハッシュ値でソート
        std.mem.sortUnstable(u32, indices, SortCtx{ .hashes = hashes }, struct {
            fn lessThan(ctx: SortCtx, a: u32, b: u32) bool {
                return ctx.hashes[a] < ctx.hashes[b];
            }
        }.lessThan);

        // ソート済み hash_values と hash_index を構築
        var sorted_hv = try allocator.alloc(u32, n);
        for (0..n) |i| {
            sorted_hv[i] = hashes[indices[i]];
        }
        allocator.free(hashes);

        return .{ .entries = entries, .hash_values = sorted_hv, .hash_index = indices };
    }

    /// ソートなしのエントリ配列から PersistentMap を構築
    pub fn fromUnsortedEntries(allocator: std.mem.Allocator, raw_entries: []const Value) !PersistentMap {
        const duped = try allocator.dupe(Value, raw_entries);
        return buildIndex(allocator, duped);
    }

    const SortCtx = struct {
        hashes: []const u32,
    };
};

/// 永続セット
/// 初期実装: 配列ベース、将来はHAMTに
pub const PersistentSet = struct {
    items: []const Value,
    meta: ?*const Value = null,

    pub fn empty() PersistentSet {
        return .{ .items = &[_]Value{} };
    }

    pub fn count(self: PersistentSet) usize {
        return self.items.len;
    }

    pub fn contains(self: PersistentSet, val: Value) bool {
        for (self.items) |item| {
            if (val.eql(item)) return true;
        }
        return false;
    }

    pub fn conj(self: PersistentSet, allocator: std.mem.Allocator, val: Value) !PersistentSet {
        // 重複チェック
        if (self.contains(val)) return self;
        var new_items = try allocator.alloc(Value, self.items.len + 1);
        @memcpy(new_items[0..self.items.len], self.items);
        new_items[self.items.len] = val;
        return .{ .items = new_items };
    }
};
