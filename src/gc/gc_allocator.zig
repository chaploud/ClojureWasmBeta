//! GcAllocator: トラッキングアロケータ
//!
//! std.mem.Allocator をラップし、全 alloc/free を registry に記録する。
//! Mark-Sweep GC のための mark/sweep 機能を提供。
//!
//! 設計:
//!   - backing allocator（GPA等）を透過的にラップ
//!   - alloc 時に registry (HashMap) に登録
//!   - free 時に registry から削除
//!   - mark(): ポインタを marked に設定
//!   - sweep(): marked=false のエントリを backing.rawFree で解放
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

/// GC トラッキングアロケータ
pub const GcAllocator = struct {
    /// 実際のメモリ確保先
    backing: Allocator,
    /// ptr → AllocInfo のマップ（追跡 registry）
    allocs: AllocMap,
    /// 現在の確保バイト数
    bytes_allocated: usize,
    /// GC トリガー閾値
    gc_threshold: usize,

    /// 初期閾値: 1MB
    const INITIAL_THRESHOLD: usize = 1024 * 1024;
    /// 閾値の成長係数（sweep 後に bytes_allocated * GROWTH_FACTOR に更新）
    const GROWTH_FACTOR: usize = 2;
    /// 最小閾値（成長後も下回らない）
    const MIN_THRESHOLD: usize = 256 * 1024;

    /// 初期化
    pub fn init(backing: Allocator) GcAllocator {
        return .{
            .backing = backing,
            .allocs = .empty,
            .bytes_allocated = 0,
            .gc_threshold = INITIAL_THRESHOLD,
        };
    }

    /// 破棄
    /// 残存する全アロケーションを backing allocator に返却し、
    /// registry HashMap を解放する。
    pub fn deinit(self: *GcAllocator) void {
        var iter = self.allocs.iterator();
        while (iter.next()) |entry| {
            const raw_ptr: [*]u8 = @ptrCast(entry.key_ptr.*);
            const info = entry.value_ptr.*;
            self.backing.rawFree(raw_ptr[0..info.size], info.alignment, 0);
        }
        self.allocs.deinit(self.backing);
    }

    /// std.mem.Allocator インターフェースを返す
    pub fn allocator(self: *GcAllocator) Allocator {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
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

    /// Sweep: marked=false のアロケーションを解放
    pub fn sweep(self: *GcAllocator) void {
        var iter = self.allocs.iterator();
        while (iter.next()) |entry| {
            if (!entry.value_ptr.marked) {
                // 未到達 → 解放
                const raw_ptr: [*]u8 = @ptrCast(entry.key_ptr.*);
                const info = entry.value_ptr.*;
                self.backing.rawFree(raw_ptr[0..info.size], info.alignment, 0);
                self.bytes_allocated -= info.size;
                // iterator から安全に削除
                self.allocs.removeByPtr(entry.key_ptr);
            } else {
                // 次回用にリセット
                entry.value_ptr.marked = false;
            }
        }

        // 閾値を動的調整
        const new_threshold = self.bytes_allocated * GROWTH_FACTOR;
        self.gc_threshold = @max(new_threshold, MIN_THRESHOLD);
    }

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
        };
    }

    pub const Stats = struct {
        bytes_allocated: usize,
        num_allocations: u32,
        gc_threshold: usize,
    };

    // === VTable 実装 ===

    const vtable = Allocator.VTable{
        .alloc = gcAlloc,
        .resize = gcResize,
        .remap = gcRemap,
        .free = gcFree,
    };

    fn gcAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *GcAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;

        // registry に登録
        self.allocs.put(self.backing, @ptrCast(ptr), .{
            .size = len,
            .alignment = alignment,
            .marked = false,
        }) catch return null; // HashMap の put が失敗した場合、メモリリークを許容する代わりに null を返す

        self.bytes_allocated += len;
        return ptr;
    }

    fn gcResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *GcAllocator = @ptrCast(@alignCast(ctx));
        const old_len = memory.len;

        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) {
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

    fn gcRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *GcAllocator = @ptrCast(@alignCast(ctx));
        const old_len = memory.len;
        const old_key: *anyopaque = @ptrCast(memory.ptr);

        const new_ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;

        // 旧エントリの marked 状態を保持
        const was_marked = if (self.allocs.get(old_key)) |info| info.marked else false;

        // 旧エントリを削除
        _ = self.allocs.remove(old_key);

        // 新エントリを登録
        self.allocs.put(self.backing, @ptrCast(new_ptr), .{
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

    fn gcFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *GcAllocator = @ptrCast(@alignCast(ctx));
        const key: *anyopaque = @ptrCast(memory.ptr);

        // registry から削除
        if (self.allocs.fetchRemove(key)) |kv| {
            self.bytes_allocated -= kv.value.size;
        }

        // backing から解放
        self.backing.rawFree(memory, alignment, ret_addr);
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

    // free
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

    // sweep → p2 が解放される
    gc.sweep();

    // p2 分のメモリが減少
    try std.testing.expect(gc.bytes_allocated < before_bytes);

    // p1, p3 はまだ使える（marked がリセットされている）
    try std.testing.expectEqual(@as(u64, 1), p1.*);
    try std.testing.expectEqual(@as(u64, 3), p3.*);

    // クリーンアップ: 残りを手動解放
    a.destroy(p1);
    a.destroy(p3);
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
    gc.sweep();

    // 閾値が MIN_THRESHOLD 以上であること
    try std.testing.expect(gc.gc_threshold >= GcAllocator.MIN_THRESHOLD);

    a.destroy(p1);
}
