//! アロケータ管理
//!
//! オブジェクトの寿命に応じたアロケータを提供する。
//!
//! 寿命の分類:
//!   - persistent: 永続（Var, Namespace, 組み込み関数、def された値）
//!     → GcAllocator でラップし、mark-sweep GC で回収可能
//!   - scratch: 一時（Reader/Analyzer の中間構造、評価中のバインディング）
//!
//! 使用パターン:
//!   ```zig
//!   // Env 初期化時
//!   var allocs = Allocators.init(gpa.allocator());
//!   var env = Env.init(allocs.persistent());
//!
//!   // 評価時（式ごとに scratch をリセット）
//!   allocs.resetScratch();
//!   var reader = Reader.init(allocs.scratch(), source);
//!   // ... 評価 ...
//!   // 評価完了後、scratch 内の Form/Node は無効になる
//!
//!   // GC（式境界で閾値超過時）
//!   allocs.collectGarbage(&env, globals);
//!   ```

const std = @import("std");
const gc_mod = @import("../gc/gc.zig");
const GcAllocator = gc_mod.GcAllocator;
const GcGlobals = gc_mod.GcGlobals;
const tracing = @import("../gc/tracing.zig");
const env_mod = @import("env.zig");
const Env = env_mod.Env;

/// 寿命別アロケータ
pub const Allocators = struct {
    /// GC 追跡用アロケータ（null なら GC 無効）
    gc: ?*GcAllocator,

    /// 永続オブジェクト用（GcAllocator 経由 or 直接親アロケータ）
    /// Var, Namespace, def された関数、クロージャ環境など
    persistent_allocator: std.mem.Allocator,

    /// 親アロケータ（GcAllocator の backing / deinit 用）
    parent_allocator: std.mem.Allocator,

    /// 一時オブジェクト用 Arena
    /// Reader の Form、Analyzer の Node、評価中のバインディング
    scratch_arena: std.heap.ArenaAllocator,

    /// 初期化
    /// parent は GcAllocator の backing として使用され、scratch の親にもなる
    pub fn init(parent: std.mem.Allocator) Allocators {
        // GcAllocator を parent 上に確保
        const gc_alloc = parent.create(GcAllocator) catch {
            // GcAllocator 確保失敗時は GC 無効で動作
            return .{
                .gc = null,
                .persistent_allocator = parent,
                .parent_allocator = parent,
                .scratch_arena = std.heap.ArenaAllocator.init(parent),
            };
        };
        gc_alloc.* = GcAllocator.init(parent);
        return .{
            .gc = gc_alloc,
            .persistent_allocator = gc_alloc.allocator(),
            .parent_allocator = parent,
            .scratch_arena = std.heap.ArenaAllocator.init(parent),
        };
    }

    /// 解放
    pub fn deinit(self: *Allocators) void {
        self.scratch_arena.deinit();
        if (self.gc) |gc_alloc| {
            gc_alloc.deinit();
            self.parent_allocator.destroy(gc_alloc);
        }
    }

    /// 永続アロケータを取得
    /// Var, Namespace, def された値など長寿命オブジェクト用
    pub fn persistent(self: *Allocators) std.mem.Allocator {
        return self.persistent_allocator;
    }

    /// 一時アロケータを取得
    /// Reader の Form、Analyzer の Node など短寿命オブジェクト用
    pub fn scratch(self: *Allocators) std.mem.Allocator {
        return self.scratch_arena.allocator();
    }

    /// scratch Arena をリセット（評価完了後に呼ぶ）
    /// 次の評価で再利用可能
    pub fn resetScratch(self: *Allocators) void {
        // retain_capacity: メモリを保持し、再割り当てを減らす
        _ = self.scratch_arena.reset(.retain_capacity);
    }

    /// scratch Arena を完全解放
    pub fn freeScratch(self: *Allocators) void {
        _ = self.scratch_arena.reset(.free_all);
    }

    /// GC 実行（閾値超過時のみ）
    /// 式境界で呼び出す
    pub fn collectGarbage(self: *Allocators, env: *Env, globals: GcGlobals) void {
        if (self.gc) |gc_alloc| {
            if (gc_alloc.shouldCollect()) {
                tracing.markRoots(gc_alloc, env, globals);
                gc_alloc.sweep();
            }
        }
    }

    /// GC 強制実行（閾値チェックなし）
    pub fn forceGC(self: *Allocators, env: *Env, globals: GcGlobals) void {
        if (self.gc) |gc_alloc| {
            tracing.markRoots(gc_alloc, env, globals);
            gc_alloc.sweep();
        }
    }
};

// === テスト ===

test "Allocators basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocs = Allocators.init(gpa.allocator());
    defer allocs.deinit();

    // persistent で確保
    const p = try allocs.persistent().create(u64);
    defer allocs.persistent().destroy(p);
    p.* = 42;

    // scratch で確保
    const s = try allocs.scratch().alloc(u8, 100);
    _ = s;

    // scratch リセット（s は無効になる）
    allocs.resetScratch();

    // 再度 scratch で確保可能
    const s2 = try allocs.scratch().alloc(u8, 100);
    _ = s2;
}

test "Allocators scratch isolation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocs = Allocators.init(gpa.allocator());
    defer allocs.deinit();

    // 複数回の評価サイクルをシミュレート
    for (0..3) |_| {
        // 評価開始
        const data = try allocs.scratch().alloc(u8, 1024);
        @memset(data, 0xAA);

        // 評価完了、scratch リセット
        allocs.resetScratch();
    }

    // GPA がリークを検出しないことを確認
}

test "Allocators GC 有効化" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocs = Allocators.init(gpa.allocator());
    defer allocs.deinit();

    // GC が有効
    try std.testing.expect(allocs.gc != null);

    // persistent は GcAllocator 経由
    const p = try allocs.persistent().create(u64);
    p.* = 42;
    try std.testing.expect(allocs.gc.?.bytes_allocated > 0);

    allocs.persistent().destroy(p);
}
