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
/// 初期実装: 配列ベース（キー値ペア）、将来はHAMTに
pub const PersistentMap = struct {
    /// キー値ペアのフラットな配列 [k1, v1, k2, v2, ...]
    entries: []const Value,
    meta: ?*const Value = null,

    pub fn empty() PersistentMap {
        return .{ .entries = &[_]Value{} };
    }

    pub fn count(self: PersistentMap) usize {
        return self.entries.len / 2;
    }

    pub fn get(self: PersistentMap, key: Value) ?Value {
        var i: usize = 0;
        while (i < self.entries.len) : (i += 2) {
            if (key.eql(self.entries[i])) {
                return self.entries[i + 1];
            }
        }
        return null;
    }

    pub fn assoc(self: PersistentMap, allocator: std.mem.Allocator, key: Value, val: Value) !PersistentMap {
        // 既存キーを探す
        var i: usize = 0;
        while (i < self.entries.len) : (i += 2) {
            if (key.eql(self.entries[i])) {
                // 既存キーを更新
                var new_entries = try allocator.dupe(Value, self.entries);
                new_entries[i + 1] = val;
                return .{ .entries = new_entries };
            }
        }
        // 新規キーを追加
        var new_entries = try allocator.alloc(Value, self.entries.len + 2);
        @memcpy(new_entries[0..self.entries.len], self.entries);
        new_entries[self.entries.len] = key;
        new_entries[self.entries.len + 1] = val;
        return .{ .entries = new_entries };
    }

    pub fn dissoc(self: PersistentMap, allocator: std.mem.Allocator, key: Value) !PersistentMap {
        // キーを探す
        var i: usize = 0;
        while (i < self.entries.len) : (i += 2) {
            if (key.eql(self.entries[i])) {
                // キーを削除
                if (self.entries.len == 2) {
                    return .{ .entries = &[_]Value{} };
                }
                var new_entries = try allocator.alloc(Value, self.entries.len - 2);
                @memcpy(new_entries[0..i], self.entries[0..i]);
                @memcpy(new_entries[i..], self.entries[i + 2 ..]);
                return .{ .entries = new_entries };
            }
        }
        // キーが見つからなければそのまま返す
        return self;
    }
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
