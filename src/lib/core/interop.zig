//! 階層・型操作
//!
//! hierarchy, type, class, instance?, derive, isa?

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const var_mod = defs.var_mod;
const BuiltinDef = defs.BuiltinDef;

const helpers = @import("helpers.zig");

// ============================================================
// 型関数
// ============================================================

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
        .wasm_module => "wasm-module",
    };

    const str = try allocator.create(value_mod.String);
    str.* = value_mod.String.init(type_name);
    return Value{ .string = str };
}

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
        .wasm_module => "WasmModule",
    };
    const s = try allocator.create(value_mod.String);
    s.* = .{ .data = name };
    return Value{ .string = s };
}

// ============================================================
// Phase 17: 階層システム
// ============================================================

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
        if (defs.global_hierarchy == null) {
            defs.global_hierarchy = try emptyHierarchy(allocator);
        }
        h = defs.global_hierarchy.?;
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
        defs.global_hierarchy = new_h;
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
        if (defs.global_hierarchy == null) return value_mod.nil;
        h = defs.global_hierarchy.?;
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
        defs.global_hierarchy = new_h;
        return value_mod.nil;
    }
    return new_h;
}

/// parents : タグの直接の親のセットを返す
/// (parents tag) or (parents h tag)
pub fn parentsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1 or args.len > 2) return error.ArityError;
    const h = if (args.len == 2) args[0] else (defs.global_hierarchy orelse return value_mod.nil);
    const tag = if (args.len == 2) args[1] else args[0];
    const parents_map = getHierarchyMap(h, "parents") orelse return value_mod.nil;
    return parents_map.get(tag) orelse value_mod.nil;
}

/// ancestors : タグの全祖先のセットを返す（parents から再帰計算）
/// (ancestors tag) or (ancestors h tag)
pub fn ancestorsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;
    const h = if (args.len == 2) args[0] else (defs.global_hierarchy orelse return value_mod.nil);
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
    const h = if (args.len == 2) args[0] else (defs.global_hierarchy orelse return value_mod.nil);
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
    const h = if (args.len == 3) args[0] else defs.global_hierarchy;
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
        if (try isaCheck(allocator, defs.global_hierarchy, dispatch_value, method_key)) {
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
// builtins
// ============================================================

pub const builtins = [_]BuiltinDef{
    // 型
    .{ .name = "type", .func = typeFn },
    .{ .name = "class", .func = classFn },
    // マルチメソッド拡張
    .{ .name = "get-method", .func = getMethod },
    .{ .name = "methods", .func = methodsFn },
    .{ .name = "remove-method", .func = removeMethod },
    .{ .name = "remove-all-methods", .func = removeAllMethods },
    .{ .name = "prefer-method", .func = preferMethod },
    .{ .name = "prefers", .func = prefersFn },
    // 階層システム
    .{ .name = "make-hierarchy", .func = makeHierarchyFn },
    .{ .name = "derive", .func = deriveFn },
    .{ .name = "underive", .func = underiveFn },
    .{ .name = "parents", .func = parentsFn },
    .{ .name = "ancestors", .func = ancestorsFn },
    .{ .name = "descendants", .func = descendantsFn },
    .{ .name = "isa?", .func = isaPred },
};
