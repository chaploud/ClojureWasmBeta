//! アロケータ管理
//!
//! オブジェクトの寿命に応じたアロケータを提供する。
//!
//! 寿命の分類:
//!   - persistent: 永続（Var, Namespace, 組み込み関数、def された値）
//!   - scratch: 一時（Reader/Analyzer の中間構造、評価中のバインディング）
//!
//! 使用パターン:
//!   ```zig
//!   // Env 初期化時
//!   var allocs = Allocators.init(gpa.allocator());
//!   var env = Env.initWithAllocators(&allocs);
//!
//!   // 評価時（式ごとに scratch をリセット）
//!   allocs.resetScratch();
//!   var reader = Reader.init(allocs.scratch(), source);
//!   // ... 評価 ...
//!   // 評価完了後、scratch 内の Form/Node は無効になる
//!   ```

const std = @import("std");

/// 寿命別アロケータ
pub const Allocators = struct {
    /// 永続オブジェクト用（親アロケータ）
    /// Var, Namespace, def された関数、クロージャ環境など
    persistent_allocator: std.mem.Allocator,

    /// 一時オブジェクト用 Arena
    /// Reader の Form、Analyzer の Node、評価中のバインディング
    scratch_arena: std.heap.ArenaAllocator,

    /// 初期化
    /// parent は永続アロケータとして使用され、scratch の親にもなる
    pub fn init(parent: std.mem.Allocator) Allocators {
        return .{
            .persistent_allocator = parent,
            .scratch_arena = std.heap.ArenaAllocator.init(parent),
        };
    }

    /// 解放
    pub fn deinit(self: *Allocators) void {
        self.scratch_arena.deinit();
        // persistent_allocator は外部管理なので解放しない
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
