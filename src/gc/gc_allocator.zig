//! GcAllocator: トラッキングアロケータ（Arena セミスペース方式）
//!
//! std.mem.Allocator をラップし、全 alloc/free を registry に記録する。
//! Mark-Sweep GC のための mark/sweep 機能を提供。
//!
//! 設計:
//!   - ArenaAllocator をバッキングストアとして使用（高速割り当て）
//!   - alloc 時に registry (HashMap) に登録
//!   - mark(): ポインタを marked に設定
//!   - sweep(): 生存オブジェクトを新 Arena にコピーし、旧 Arena を一括解放
//!     → 個別 rawFree を排除し、O(survivors) でコンパクション
//!   - 戻り値の SweepResult に forwarding テーブルを含む（呼び出し元がポインタ更新）
//!
//! 使い方:
//!   var gc_alloc = GcAllocator.init(gpa.allocator());
//!   const allocator = gc_alloc.allocator();
//!   // allocator は std.mem.Allocator として使える

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// アロケーション情報
const AllocInfo = struct {
    /// バイトサイズ
    size: usize,
    /// アライメント
    alignment: Alignment,
    /// GC mark フラグ
    marked: bool,
};

/// ポインタ → AllocInfo のマップ
const AllocMap = std.AutoHashMapUnmanaged(*anyopaque, AllocInfo);

/// ポインタ転送テーブル（旧 → 新）
pub const ForwardingTable = std.AutoHashMapUnmanaged(*anyopaque, *anyopaque);

/// GC トラッキングアロケータ
pub const GcAllocator = struct {
    /// Arena（オブジェクト割り当て用）
    arena: std.heap.ArenaAllocator,
    /// registry 管理用アロケータ（HashMap 自体の管理に使用）
    registry_alloc: Allocator,
    /// ptr → AllocInfo のマップ（追跡 registry）
    allocs: AllocMap,
    /// 現在の確保バイト数
    bytes_allocated: usize,
    /// GC トリガー閾値
    gc_threshold: usize,

    // === GC 統計 ===
    /// 累計 GC 実行回数
    total_collections: u64,
    /// 累計回収バイト数
    total_freed_bytes: u64,
    /// 累計回収オブジェクト数
    total_freed_count: u64,
    /// 累計アロケーション数（alloc 呼び出し回数）
    total_alloc_count: u64,
    /// 累計 GC 一時停止時間（ナノ秒）
    total_pause_ns: u64,

    /// 初期閾値: 1MB
    const INITIAL_THRESHOLD: usize = 1024 * 1024;
    /// 閾値の成長係数（sweep 後に bytes_allocated * GROWTH_FACTOR に更新）
    const GROWTH_FACTOR: usize = 2;
    /// 最小閾値（成長後も下回らない）
    const MIN_THRESHOLD: usize = 256 * 1024;

    /// 初期化
    /// registry_alloc: HashMap/配列管理用（GPA 等）
    pub fn init(registry_alloc: Allocator) GcAllocator {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .registry_alloc = registry_alloc,
            .allocs = .empty,
            .bytes_allocated = 0,
            .gc_threshold = INITIAL_THRESHOLD,
            .total_collections = 0,
            .total_freed_bytes = 0,
            .total_freed_count = 0,
            .total_alloc_count = 0,
            .total_pause_ns = 0,
        };
    }

    /// 破棄
    pub fn deinit(self: *GcAllocator) void {
        self.allocs.deinit(self.registry_alloc);
        self.arena.deinit();
    }

    /// std.mem.Allocator インターフェースを返す
    pub fn allocator(self: *GcAllocator) Allocator {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// backing allocator を返す（GC 対象外の割り当て用 — テスト等）
    pub fn backing(self: *GcAllocator) Allocator {
        return self.registry_alloc;
    }

    /// ポインタを mark（到達可能としてマーク）
    /// 戻り値: true = 既にマーク済み（再トレース不要）、false = 初回マーク
    pub fn mark(self: *GcAllocator, ptr: *anyopaque) bool {
        if (self.allocs.getPtr(ptr)) |info| {
            const was_marked = info.marked;
            info.marked = true;
            return was_marked;
        }
        return false;
    }

    /// スライスポインタを mark（[]T の .ptr を渡す）
    pub fn markSlice(self: *GcAllocator, ptr: ?[*]const u8, len: usize) void {
        if (ptr == null or len == 0) return;
        const raw: *anyopaque = @ptrCast(@constCast(ptr.?));
        _ = self.mark(raw);
    }

    /// 全 marked フラグをクリア
    pub fn clearMarks(self: *GcAllocator) void {
        var iter = self.allocs.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.marked = false;
        }
    }

    /// Sweep: セミスペース方式
    /// 1. 生存オブジェクトを新 Arena にコピー
    /// 2. 旧 Arena を一括解放
    /// 3. ForwardingTable を返す（呼び出し元がポインタ更新に使用）
    ///
    /// 注意: 呼び出し元は返却された forwarding テーブルを使って
    ///       全ルートのポインタを更新した後、forwarding.deinit() すること。
    pub fn sweep(self: *GcAllocator) SweepResult {
        const before_bytes = self.bytes_allocated;
        const before_count = self.allocs.count();

        // 新 Arena を作成
        var new_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const new_alloc = new_arena.allocator();

        // 新 registry と forwarding テーブルを事前確保
        var new_allocs: AllocMap = .empty;
        var forwarding: ForwardingTable = .empty;
        var survived_bytes: usize = 0;
        var survived_count: u32 = 0;

        // 生存数を事前カウント（ensureTotalCapacity 用）
        var survive_estimate: u32 = 0;
        {
            var count_iter = self.allocs.iterator();
            while (count_iter.next()) |entry| {
                if (entry.value_ptr.marked) survive_estimate += 1;
            }
        }

        new_allocs.ensureTotalCapacity(self.registry_alloc, survive_estimate) catch {};
        forwarding.ensureTotalCapacity(self.registry_alloc, survive_estimate) catch {};

        // 生存オブジェクトを新 Arena にコピー
        var iter = self.allocs.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.marked) {
                const info = entry.value_ptr.*;
                const old_ptr: [*]u8 = @ptrCast(entry.key_ptr.*);
                const new_ptr = new_alloc.rawAlloc(info.size, info.alignment, 0) orelse continue;
                @memcpy(new_ptr[0..info.size], old_ptr[0..info.size]);
                const new_opaque: *anyopaque = @ptrCast(new_ptr);
                new_allocs.putAssumeCapacity(new_opaque, .{
                    .size = info.size,
                    .alignment = info.alignment,
                    .marked = false,
                });
                forwarding.putAssumeCapacity(entry.key_ptr.*, new_opaque);
                survived_bytes += info.size;
                survived_count += 1;
            }
        }

        // 旧 Arena を一括解放（全デッドオブジェクトを O(1) で回収）
        self.arena.deinit();

        // 旧 registry を解放して新 registry にスワップ
        self.allocs.deinit(self.registry_alloc);
        self.allocs = new_allocs;
        self.arena = new_arena;
        self.bytes_allocated = survived_bytes;

        // 閾値を動的調整
        const new_threshold = self.bytes_allocated * GROWTH_FACTOR;
        self.gc_threshold = @max(new_threshold, MIN_THRESHOLD);

        // 統計更新
        const freed_bytes = before_bytes - survived_bytes;
        const freed_count = before_count - survived_count;
        self.total_collections += 1;
        self.total_freed_bytes += freed_bytes;
        self.total_freed_count += freed_count;

        return .{
            .freed_bytes = freed_bytes,
            .freed_count = freed_count,
            .before_bytes = before_bytes,
            .after_bytes = survived_bytes,
            .new_threshold = self.gc_threshold,
            .forwarding = forwarding,
        };
    }

    /// sweep() の結果
    pub const SweepResult = struct {
        freed_bytes: usize,
        freed_count: u32,
        before_bytes: usize,
        after_bytes: usize,
        new_threshold: usize,
        /// ポインタ転送テーブル（旧 → 新）
        /// 呼び出し元が全ルートのポインタ更新に使用した後、deinit すること
        forwarding: ForwardingTable,
    };

    /// GC を実行すべきかどうか
    pub fn shouldCollect(self: *const GcAllocator) bool {
        return self.bytes_allocated > self.gc_threshold;
    }

    /// 統計情報
    pub fn stats(self: *const GcAllocator) Stats {
        return .{
            .bytes_allocated = self.bytes_allocated,
            .num_allocations = self.allocs.count(),
            .gc_threshold = self.gc_threshold,
            .total_collections = self.total_collections,
            .total_freed_bytes = self.total_freed_bytes,
            .total_freed_count = self.total_freed_count,
            .total_alloc_count = self.total_alloc_count,
            .total_pause_ns = self.total_pause_ns,
        };
    }

    /// 累計一時停止時間を加算
    pub fn addPauseTime(self: *GcAllocator, ns: u64) void {
        self.total_pause_ns += ns;
    }

    pub const Stats = struct {
        bytes_allocated: usize,
        num_allocations: u32,
        gc_threshold: usize,
        total_collections: u64,
        total_freed_bytes: u64,
        total_freed_count: u64,
        total_alloc_count: u64,
        total_pause_ns: u64,
    };

    // === VTable 実装 ===

    const vtable = Allocator.VTable{
        .alloc = gcAlloc,
        .resize = gcResize,
        .remap = gcRemap,
        .free = gcFree,
    };

    fn gcAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const self: *GcAllocator = @ptrCast(@alignCast(ctx));
        // Arena から割り当て
        const ptr = self.arena.allocator().rawAlloc(len, alignment, 0) orelse return null;

        // registry に登録
        self.allocs.put(self.registry_alloc, @ptrCast(ptr), .{
            .size = len,
            .alignment = alignment,
            .marked = false,
        }) catch return null;

        self.bytes_allocated += len;
        self.total_alloc_count += 1;
        return ptr;
    }

    fn gcResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
        const self: *GcAllocator = @ptrCast(@alignCast(ctx));
        const old_len = memory.len;

        if (!self.arena.allocator().rawResize(memory, alignment, new_len, 0)) {
            return false;
        }

        // registry を更新（アドレスは変わらない）
        const key: *anyopaque = @ptrCast(memory.ptr);
        if (self.allocs.getPtr(key)) |info| {
            info.size = new_len;
        }

        // バイトカウント更新
        if (new_len > old_len) {
            self.bytes_allocated += (new_len - old_len);
        } else {
            self.bytes_allocated -= (old_len - new_len);
        }

        return true;
    }

    fn gcRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) ?[*]u8 {
        const self: *GcAllocator = @ptrCast(@alignCast(ctx));
        const old_len = memory.len;
        const old_key: *anyopaque = @ptrCast(memory.ptr);

        const new_ptr = self.arena.allocator().rawRemap(memory, alignment, new_len, 0) orelse return null;

        // 旧エントリの marked 状態を保持
        const was_marked = if (self.allocs.get(old_key)) |info| info.marked else false;

        // 旧エントリを削除
        _ = self.allocs.remove(old_key);

        // 新エントリを登録
        self.allocs.put(self.registry_alloc, @ptrCast(new_ptr), .{
            .size = new_len,
            .alignment = alignment,
            .marked = was_marked,
        }) catch {
            // put 失敗しても remap 自体は成功しているので ptr を返す
        };

        // バイトカウント更新
        if (new_len > old_len) {
            self.bytes_allocated += (new_len - old_len);
        } else {
            self.bytes_allocated -= (old_len - new_len);
        }

        return new_ptr;
    }

    fn gcFree(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
        const self: *GcAllocator = @ptrCast(@alignCast(ctx));
        const key: *anyopaque = @ptrCast(memory.ptr);

        // registry から削除（Arena は個別 free 不要）
        if (self.allocs.fetchRemove(key)) |kv| {
            self.bytes_allocated -= kv.value.size;
        }
        // Arena は個別解放しない（sweep で一括解放）
    }
};

// === テスト ===

test "GcAllocator 基本 alloc/free" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gc = GcAllocator.init(gpa.allocator());
    defer gc.deinit();

    const a = gc.allocator();

    // alloc
    const data = try a.alloc(u8, 100);
    try std.testing.expect(gc.bytes_allocated >= 100);
    try std.testing.expect(gc.allocs.count() > 0);

    // free（registry から除去のみ、Arena は個別解放しない）
    a.free(data);
    try std.testing.expectEqual(@as(usize, 0), gc.bytes_allocated);
}

test "GcAllocator create/destroy" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gc = GcAllocator.init(gpa.allocator());
    defer gc.deinit();

    const a = gc.allocator();

    const p = try a.create(u64);
    p.* = 42;
    try std.testing.expect(gc.bytes_allocated > 0);

    a.destroy(p);
    try std.testing.expectEqual(@as(usize, 0), gc.bytes_allocated);
}

test "GcAllocator mark と sweep" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gc = GcAllocator.init(gpa.allocator());
    defer gc.deinit();

    const a = gc.allocator();

    // 3つ確保
    const p1 = try a.create(u64);
    const p2 = try a.create(u64);
    const p3 = try a.create(u64);
    p1.* = 1;
    p2.* = 2;
    p3.* = 3;

    const before_bytes = gc.bytes_allocated;
    try std.testing.expect(before_bytes > 0);

    // p1 と p3 だけ mark
    _ = gc.mark(@ptrCast(p1));
    _ = gc.mark(@ptrCast(p3));

    // sweep → p2 が解放される、p1/p3 は新 Arena にコピー
    var result = gc.sweep();
    defer result.forwarding.deinit(gpa.allocator());

    // p2 分のメモリが減少
    try std.testing.expect(gc.bytes_allocated < before_bytes);

    // forwarding テーブルで新ポインタを取得
    const new_p1_opaque = result.forwarding.get(@ptrCast(p1)).?;
    const new_p3_opaque = result.forwarding.get(@ptrCast(p3)).?;
    const new_p1: *u64 = @ptrCast(@alignCast(new_p1_opaque));
    const new_p3: *u64 = @ptrCast(@alignCast(new_p3_opaque));

    // コピーされた値が正しい
    try std.testing.expectEqual(@as(u64, 1), new_p1.*);
    try std.testing.expectEqual(@as(u64, 3), new_p3.*);
}

test "GcAllocator shouldCollect" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gc = GcAllocator.init(gpa.allocator());
    defer gc.deinit();

    // 初期状態では GC 不要
    try std.testing.expect(!gc.shouldCollect());

    // 閾値を小さく設定してテスト
    gc.gc_threshold = 100;

    const a = gc.allocator();
    const data = try a.alloc(u8, 200);
    try std.testing.expect(gc.shouldCollect());

    a.free(data);
}

test "GcAllocator sweep 後の閾値調整" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gc = GcAllocator.init(gpa.allocator());
    defer gc.deinit();

    const a = gc.allocator();

    // 確保して mark してから sweep
    const p1 = try a.create(u64);
    _ = gc.mark(@ptrCast(p1));
    var result = gc.sweep();
    result.forwarding.deinit(gpa.allocator());

    // 閾値が MIN_THRESHOLD 以上であること
    try std.testing.expect(gc.gc_threshold >= GcAllocator.MIN_THRESHOLD);
}
