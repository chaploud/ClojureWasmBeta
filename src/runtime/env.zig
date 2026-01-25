//! Env: グローバル環境
//!
//! 全ての Namespace を管理するグローバルな環境。
//! data readers、features なども保持。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md

const std = @import("std");
const value = @import("value.zig");
const Symbol = value.Symbol;
const namespace_mod = @import("namespace.zig");
const Namespace = namespace_mod.Namespace;
const var_mod = @import("var.zig");
const Var = var_mod.Var;

/// 名前空間名をキーとするハッシュコンテキスト
const NsNameContext = struct {
    pub fn hash(_: NsNameContext, key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }

    pub fn eql(_: NsNameContext, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

/// 名前空間名 → *Namespace のマップ
const NsMap = std.HashMapUnmanaged([]const u8, *Namespace, NsNameContext, 80);

/// Env: グローバル環境
/// 全ての Namespace と設定を管理
pub const Env = struct {
    /// アロケータ
    allocator: std.mem.Allocator,

    /// 全 Namespace (名前 → *Namespace)
    namespaces: NsMap = .empty,

    /// 現在の名前空間
    current_ns: ?*Namespace = null,

    // === Reader 設定（将来）===
    // features: FeatureSet,      // :clj, :cljs, etc. (#? 用)
    // data_readers: TagReaderMap, // #uuid, #inst, etc.

    // === 初期化・破棄 ===

    pub fn init(allocator: std.mem.Allocator) Env {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Env) void {
        var iter = self.namespaces.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.namespaces.deinit(self.allocator);
    }

    // === Namespace 操作 ===

    /// Namespace を取得（なければ作成）
    pub fn findOrCreateNs(self: *Env, name: []const u8) !*Namespace {
        if (self.namespaces.get(name)) |ns| {
            return ns;
        }

        const new_ns = try self.allocator.create(Namespace);
        new_ns.* = Namespace.init(self.allocator, name);
        try self.namespaces.put(self.allocator, name, new_ns);
        return new_ns;
    }

    /// Namespace を取得（なければ null）
    pub fn findNs(self: *const Env, name: []const u8) ?*Namespace {
        return self.namespaces.get(name);
    }

    /// 現在の Namespace を設定
    pub fn setCurrentNs(self: *Env, ns: *Namespace) void {
        self.current_ns = ns;
    }

    /// 現在の Namespace を取得
    pub fn getCurrentNs(self: *const Env) ?*Namespace {
        return self.current_ns;
    }

    /// シンボルを解決（現在の NS から）
    pub fn resolve(self: *const Env, sym: Symbol) ?*Var {
        const ns = self.current_ns orelse return null;

        // 名前空間修飾されている場合
        if (sym.namespace) |sym_ns| {
            // 完全修飾名（他の NS を直接参照）
            if (self.namespaces.get(sym_ns)) |target_ns| {
                return target_ns.resolve(sym.name);
            }
            // エイリアス経由
            return ns.resolveQualified(sym_ns, sym.name);
        }

        // 名前空間修飾なし
        return ns.resolve(sym.name);
    }

    /// clojure.core の Var を取得
    pub fn getCoreVar(self: *const Env, name: []const u8) ?*Var {
        const core = self.namespaces.get("clojure.core") orelse return null;
        return core.resolve(name);
    }

    // === 初期化ヘルパー ===

    /// 基本環境を構築（clojure.core, user 等）
    pub fn setupBasic(self: *Env) !void {
        // clojure.core を作成
        _ = try self.findOrCreateNs("clojure.core");

        // user を作成し、現在の NS に設定
        const user = try self.findOrCreateNs("user");
        self.setCurrentNs(user);
    }
};

// === テスト ===

test "Env 基本操作" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    // Namespace 作成
    const ns1 = try env.findOrCreateNs("user");
    const ns2 = try env.findOrCreateNs("user");

    // 同じ Namespace を返す
    try std.testing.expectEqual(ns1, ns2);
    try std.testing.expectEqualStrings("user", ns1.name);
}

test "Env resolve" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    // user NS を作成し、現在の NS に設定
    const user = try env.findOrCreateNs("user");
    env.setCurrentNs(user);

    // user に foo を定義
    const v = try user.intern("foo");
    v.bindRoot(value.intVal(42));

    // 解決
    const resolved = env.resolve(Symbol.init("foo"));
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.?.deref().eql(value.intVal(42)));
}

test "Env setupBasic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    try env.setupBasic();

    // clojure.core が存在
    try std.testing.expect(env.findNs("clojure.core") != null);

    // user が現在の NS
    const current = env.getCurrentNs();
    try std.testing.expect(current != null);
    try std.testing.expectEqualStrings("user", current.?.name);
}
