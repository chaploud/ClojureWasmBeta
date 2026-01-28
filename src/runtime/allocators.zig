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
const value_mod = @import("value.zig");
const Value = value_mod.Value;

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

    /// GC 統計ログを有効にするか (--gc-stats)
    gc_stats_enabled: bool,

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
                .gc_stats_enabled = false,
            };
        };
        gc_alloc.* = GcAllocator.init(parent);
        return .{
            .gc = gc_alloc,
            .persistent_allocator = gc_alloc.allocator(),
            .parent_allocator = parent,
            .scratch_arena = std.heap.ArenaAllocator.init(parent),
            .gc_stats_enabled = false,
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
                self.runGc(gc_alloc, env, globals);
            }
        }
    }

    /// GC 強制実行（閾値チェックなし）
    pub fn forceGC(self: *Allocators, env: *Env, globals: GcGlobals) void {
        if (self.gc) |gc_alloc| {
            self.runGc(gc_alloc, env, globals);
        }
    }

    /// Safe Point GC: VM スタックもルートとして GC を実行
    /// 式実行中 (recur/call 後) に呼び出す
    /// 閾値超過時のみ実行
    pub fn safePointCollect(self: *Allocators, env: *Env, globals: GcGlobals, vm_stack: []Value) void {
        if (self.gc) |gc_alloc| {
            if (gc_alloc.shouldCollect()) {
                self.runSafePointGc(gc_alloc, env, globals, vm_stack);
            }
        }
    }

    /// Safe Point GC 実行（mark + sweep + fixup + VM スタック修正 + 計測）
    fn runSafePointGc(self: *Allocators, gc_alloc: *GcAllocator, env: *Env, globals: GcGlobals, vm_stack: []Value) void {
        var timer = std.time.Timer.start() catch {
            // タイマー取得失敗時は計測なしで実行
            tracing.markRoots(gc_alloc, env, globals);
            tracing.markVmStack(gc_alloc, vm_stack);
            var result = gc_alloc.sweep();
            if (result.forwarding.count() > 0) {
                tracing.fixupRoots(&result.forwarding, gc_alloc.registry_alloc, env, globals);
                tracing.fixupVmStack(&result.forwarding, gc_alloc.registry_alloc, vm_stack);
            }
            result.forwarding.deinit(gc_alloc.registry_alloc);
            if (self.gc_stats_enabled) {
                logSweepResult(result, gc_alloc.total_collections, null, null);
            }
            return;
        };

        // Mark phase (通常ルート + VM スタック)
        tracing.markRoots(gc_alloc, env, globals);
        tracing.markVmStack(gc_alloc, vm_stack);
        const mark_ns = timer.read();

        // Sweep phase
        var result = gc_alloc.sweep();
        const sweep_ns = timer.read() - mark_ns;

        // Fixup phase (通常ルート + VM スタック)
        if (result.forwarding.count() > 0) {
            tracing.fixupRoots(&result.forwarding, gc_alloc.registry_alloc, env, globals);
            tracing.fixupVmStack(&result.forwarding, gc_alloc.registry_alloc, vm_stack);
        }
        result.forwarding.deinit(gc_alloc.registry_alloc);
        const total_ns = timer.read();

        gc_alloc.addPauseTime(total_ns);

        if (self.gc_stats_enabled) {
            logSweepResult(result, gc_alloc.total_collections, mark_ns, sweep_ns);
        }
    }

    /// GC 実行（mark + sweep + fixup + 計測）
    fn runGc(self: *Allocators, gc_alloc: *GcAllocator, env: *Env, globals: GcGlobals) void {
        var timer = std.time.Timer.start() catch {
            // タイマー取得失敗時は計測なしで実行
            tracing.markRoots(gc_alloc, env, globals);
            var result = gc_alloc.sweep();
            // ポインタ修正
            if (result.forwarding.count() > 0) {
                tracing.fixupRoots(&result.forwarding, gc_alloc.registry_alloc, env, globals);
            }
            result.forwarding.deinit(gc_alloc.registry_alloc);
            if (self.gc_stats_enabled) {
                logSweepResult(result, gc_alloc.total_collections, null, null);
            }
            return;
        };

        // Mark phase
        tracing.markRoots(gc_alloc, env, globals);
        const mark_ns = timer.read();

        // Sweep phase（セミスペース: 生存オブジェクトを新 Arena にコピー）
        var result = gc_alloc.sweep();
        const sweep_ns = timer.read() - mark_ns;

        // Fixup phase（全ルートのポインタを更新）
        if (result.forwarding.count() > 0) {
            tracing.fixupRoots(&result.forwarding, gc_alloc.registry_alloc, env, globals);
        }
        result.forwarding.deinit(gc_alloc.registry_alloc);
        const total_ns = timer.read();

        gc_alloc.addPauseTime(total_ns);

        if (self.gc_stats_enabled) {
            logSweepResult(result, gc_alloc.total_collections, mark_ns, sweep_ns);
        }
    }

    /// GC 統計サマリを stderr に出力
    pub fn printGcSummary(self: *const Allocators) void {
        if (self.gc) |gc_alloc| {
            const s = gc_alloc.stats();
            const stderr_file = std.fs.File.stderr();
            var buf: [4096]u8 = undefined;
            var w = stderr_file.writer(&buf);
            const writer = &w.interface;
            writer.writeAll("\n[GC Summary]\n") catch {};
            writer.print("  total collections : {d}\n", .{s.total_collections}) catch {};
            writer.print("  total freed       : {d} bytes, {d} objects\n", .{ s.total_freed_bytes, s.total_freed_count }) catch {};
            writer.print("  total allocated   : {d} alloc calls\n", .{s.total_alloc_count}) catch {};
            writer.print("  total pause time  : {d:.3} ms\n", .{nsToMs(s.total_pause_ns)}) catch {};
            writer.print("  final heap        : {d} bytes, {d} objects\n", .{ s.bytes_allocated, s.num_allocations }) catch {};
            writer.print("  final threshold   : {d} bytes\n", .{s.gc_threshold}) catch {};
            writer.flush() catch {};
        }
    }

    /// sweep 結果を stderr にログ出力
    fn logSweepResult(result: GcAllocator.SweepResult, collection_num: u64, mark_ns: ?u64, sweep_ns: ?u64) void {
        const stderr_file = std.fs.File.stderr();
        var buf: [512]u8 = undefined;
        var w = stderr_file.writer(&buf);
        const writer = &w.interface;
        writer.print("[GC #{d}] freed {d} bytes, {d} objects | heap {d} -> {d} bytes | threshold {d} bytes", .{
            collection_num,
            result.freed_bytes,
            result.freed_count,
            result.before_bytes,
            result.after_bytes,
            result.new_threshold,
        }) catch {};
        if (mark_ns) |m| {
            if (sweep_ns) |s| {
                writer.print(" | mark {d:.3} ms, sweep {d:.3} ms", .{ nsToMs(m), nsToMs(s) }) catch {};
            }
        }
        writer.writeByte('\n') catch {};
        writer.flush() catch {};
    }

    /// ナノ秒 → ミリ秒変換
    fn nsToMs(ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
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
