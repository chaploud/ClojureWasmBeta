//! Namespace: 名前空間
//!
//! Symbol → Var のマッピングを管理。
//! alias、refer、import も扱う。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md

const std = @import("std");
const value = @import("value.zig");
const Symbol = value.Symbol;
const var_mod = @import("var.zig");
const Var = var_mod.Var;

/// シンボル名をキーとするハッシュコンテキスト
const SymbolNameContext = struct {
    pub fn hash(_: SymbolNameContext, key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }

    pub fn eql(_: SymbolNameContext, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

/// Symbol名 → *Var のマップ
const VarMap = std.HashMapUnmanaged([]const u8, *Var, SymbolNameContext, 80);

/// Symbol名 → *Namespace のマップ
const NsAliasMap = std.HashMapUnmanaged([]const u8, *Namespace, SymbolNameContext, 80);

/// Namespace: 名前空間
pub const Namespace = struct {
    /// 名前空間名
    name: []const u8,

    /// アロケータ
    allocator: std.mem.Allocator,

    /// この NS で定義された Var (Symbol名 → *Var)
    mappings: VarMap = .empty,

    /// 他 NS へのエイリアス (alias名 → *Namespace)
    aliases: NsAliasMap = .empty,

    /// 他 NS から refer された Var (Symbol名 → *Var)
    refers: VarMap = .empty,

    // === 初期化・破棄 ===

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Namespace {
        return .{
            .name = name,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Namespace) void {
        // Var の解放
        var iter = self.mappings.iterator();
        while (iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.mappings.deinit(self.allocator);
        self.aliases.deinit(self.allocator);
        self.refers.deinit(self.allocator);
    }

    // === Var 操作 ===

    /// この NS に Var を定義（intern）
    /// 既存なら既存を返す、なければ新規作成
    pub fn intern(self: *Namespace, sym_name: []const u8) !*Var {
        if (self.mappings.get(sym_name)) |existing| {
            return existing;
        }

        const new_var = try self.allocator.create(Var);
        new_var.* = .{
            .sym = Symbol.init(sym_name),
            .ns_name = self.name,
        };
        try self.mappings.put(self.allocator, sym_name, new_var);
        return new_var;
    }

    /// 他 NS から Var を参照（refer）
    pub fn refer(self: *Namespace, sym_name: []const u8, var_ref: *Var) !void {
        try self.refers.put(self.allocator, sym_name, var_ref);
    }

    /// 別 NS へのエイリアス
    pub fn setAlias(self: *Namespace, alias_name: []const u8, ns: *Namespace) !void {
        try self.aliases.put(self.allocator, alias_name, ns);
    }

    /// エイリアスを取得
    pub fn getAlias(self: *const Namespace, alias_name: []const u8) ?*Namespace {
        return self.aliases.get(alias_name);
    }

    /// シンボルを解決（名前空間修飾なし）
    /// 優先順位: ローカル定義 > refer
    pub fn resolve(self: *const Namespace, sym_name: []const u8) ?*Var {
        // ローカル定義
        if (self.mappings.get(sym_name)) |v| {
            return v;
        }
        // refer
        if (self.refers.get(sym_name)) |v| {
            return v;
        }
        return null;
    }

    /// 名前空間修飾シンボルを解決
    /// ns_name/sym_name 形式
    pub fn resolveQualified(self: *const Namespace, ns_name: []const u8, sym_name: []const u8) ?*Var {
        // 自身の名前空間
        if (std.mem.eql(u8, ns_name, self.name)) {
            return self.mappings.get(sym_name);
        }
        // エイリアス経由
        if (self.aliases.get(ns_name)) |aliased_ns| {
            return aliased_ns.mappings.get(sym_name);
        }
        return null;
    }

    /// この NS で定義された全ての Var を取得
    pub fn getAllVars(self: *const Namespace) VarMap.Iterator {
        return self.mappings.iterator();
    }
};

// === テスト ===

test "Namespace intern" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ns = Namespace.init(allocator, "user");
    defer ns.deinit();

    const v1 = try ns.intern("foo");
    const v2 = try ns.intern("foo");

    // 同じ Var を返す
    try std.testing.expectEqual(v1, v2);
    try std.testing.expectEqualStrings("foo", v1.sym.name);
    try std.testing.expectEqualStrings("user", v1.ns_name);
}

test "Namespace resolve" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ns = Namespace.init(allocator, "user");
    defer ns.deinit();

    const v = try ns.intern("bar");
    v.bindRoot(value.intVal(42));

    const resolved = ns.resolve("bar");
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.?.deref().eql(value.intVal(42)));

    // 存在しないシンボル
    try std.testing.expect(ns.resolve("unknown") == null);
}

test "Namespace alias" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var core = Namespace.init(allocator, "clojure.core");
    defer core.deinit();

    var user = Namespace.init(allocator, "user");
    defer user.deinit();

    // clojure.core に map を定義
    const map_var = try core.intern("map");
    map_var.bindRoot(value.intVal(999)); // 仮の値

    // user で "core" をエイリアスに
    try user.setAlias("core", &core);

    // core/map を解決
    const resolved = user.resolveQualified("core", "map");
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.?.deref().eql(value.intVal(999)));
}
