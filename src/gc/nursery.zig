//! Nursery: Young 世代 bump allocator
//!
//! 世代別 GC の Young 世代を実装。
//! - 固定サイズのメモリ領域に bump pointer で高速割り当て
//! - 満杯時に minor GC で生存オブジェクトを Old 世代に promotion
//! - Write barrier (card marking) で Old→Young 参照を追跡
//!
//! 使い方:
//!   var nursery = Nursery.init(parent_alloc, 4 * 1024 * 1024);  // 4MB nursery
//!   defer nursery.deinit();
//!   const ptr = nursery.alloc(size, alignment) orelse {
//!       // nursery 満杯、minor GC が必要
//!   };

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// アロケーション情報（minor GC 用）
const AllocInfo = struct {
    /// バイトサイズ
    size: usize,
    /// アライメント
    alignment: Alignment,
    /// GC mark フラグ
    marked: bool,
    /// 生存回数（promotion 判定用）
    age: u8,
};

/// ポインタ → AllocInfo のマップ
const AllocMap = std.AutoHashMapUnmanaged(*anyopaque, AllocInfo);

/// Young 世代 bump allocator
pub const Nursery = struct {
    /// メモリ領域
    buffer: []u8,
    /// 次の割り当て位置
    offset: usize,
    /// registry 管理用アロケータ
    registry_alloc: Allocator,
    /// ptr → AllocInfo のマップ（追跡 registry）
    allocs: AllocMap,
    /// 現在の確保バイト数
    bytes_allocated: usize,
    /// nursery 容量
    capacity: usize,

    // === 統計 ===
    /// 累計 minor GC 実行回数
    minor_collections: u64,
    /// 累計 promotion バイト数
    total_promoted_bytes: u64,
    /// 累計 promotion オブジェクト数
    total_promoted_count: u64,
    /// 累計アロケーション数
    total_alloc_count: u64,
    /// 累計一時停止時間（ナノ秒）
    total_pause_ns: u64,

    /// デフォルト nursery サイズ: 4MB
    pub const DEFAULT_SIZE: usize = 4 * 1024 * 1024;
    /// promotion するまでの生存回数
    pub const PROMOTION_THRESHOLD: u8 = 2;

    /// 初期化
    pub fn init(registry_alloc: Allocator, size: usize) Nursery {
        const buffer = registry_alloc.alloc(u8, size) catch &.{};
        return .{
            .buffer = @constCast(buffer),
            .offset = 0,
            .registry_alloc = registry_alloc,
            .allocs = .empty,
            .bytes_allocated = 0,
            .capacity = buffer.len,
            .minor_collections = 0,
            .total_promoted_bytes = 0,
            .total_promoted_count = 0,
            .total_alloc_count = 0,
            .total_pause_ns = 0,
        };
    }

    /// 破棄
    pub fn deinit(self: *Nursery) void {
        self.allocs.deinit(self.registry_alloc);
        if (self.buffer.len > 0) {
            self.registry_alloc.free(self.buffer);
        }
    }

    /// メモリ割り当て（bump pointer 方式）
    /// nursery が満杯なら null を返す
    pub fn alloc(self: *Nursery, size: usize, alignment: Alignment) ?[*]u8 {
        // アラインメント調整
        const aligned_offset = alignment.forward(self.offset);

        // 容量チェック
        if (aligned_offset + size > self.capacity) {
            return null; // 満杯
        }

        const ptr = self.buffer[aligned_offset..].ptr;
        self.offset = aligned_offset + size;

        // registry に登録
        self.allocs.put(self.registry_alloc, @ptrCast(ptr), .{
            .size = size,
            .alignment = alignment,
            .marked = false,
            .age = 0,
        }) catch return null;

        self.bytes_allocated += size;
        self.total_alloc_count += 1;
        return ptr;
    }

    /// アドレスが nursery 内かどうか判定
    pub fn contains(self: *const Nursery, ptr: *anyopaque) bool {
        const addr = @intFromPtr(ptr);
        const base = @intFromPtr(self.buffer.ptr);
        return addr >= base and addr < base + self.capacity;
    }

    /// ポインタを mark
    pub fn mark(self: *Nursery, ptr: *anyopaque) bool {
        if (self.allocs.getPtr(ptr)) |info| {
            const was_marked = info.marked;
            info.marked = true;
            return was_marked;
        }
        return false;
    }

    /// 全 marked フラグをクリア
    pub fn clearMarks(self: *Nursery) void {
        var iter = self.allocs.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.marked = false;
        }
    }

    /// nursery が閾値を超えたか
    pub fn shouldCollect(self: *const Nursery) bool {
        // 80% 使用率で GC トリガー
        return self.offset > (self.capacity * 8 / 10);
    }

    /// nursery をリセット（全解放）
    pub fn reset(self: *Nursery) void {
        self.offset = 0;
        self.allocs.clearRetainingCapacity();
        self.bytes_allocated = 0;
    }

    /// 統計情報
    pub fn stats(self: *const Nursery) Stats {
        return .{
            .bytes_allocated = self.bytes_allocated,
            .num_allocations = self.allocs.count(),
            .capacity = self.capacity,
            .minor_collections = self.minor_collections,
            .total_promoted_bytes = self.total_promoted_bytes,
            .total_promoted_count = self.total_promoted_count,
            .total_alloc_count = self.total_alloc_count,
            .total_pause_ns = self.total_pause_ns,
        };
    }

    /// 一時停止時間を加算
    pub fn addPauseTime(self: *Nursery, ns: u64) void {
        self.total_pause_ns += ns;
    }

    pub const Stats = struct {
        bytes_allocated: usize,
        num_allocations: u32,
        capacity: usize,
        minor_collections: u64,
        total_promoted_bytes: u64,
        total_promoted_count: u64,
        total_alloc_count: u64,
        total_pause_ns: u64,
    };
};

// === テスト ===

test "Nursery 基本 alloc" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var nursery = Nursery.init(gpa.allocator(), 1024);
    defer nursery.deinit();

    // 割り当て
    const ptr = nursery.alloc(100, .@"8");
    try std.testing.expect(ptr != null);
    try std.testing.expect(nursery.bytes_allocated >= 100);
    try std.testing.expectEqual(@as(u64, 1), nursery.total_alloc_count);
}

test "Nursery 満杯で null" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var nursery = Nursery.init(gpa.allocator(), 128);
    defer nursery.deinit();

    // 64 bytes を 2 回で満杯
    _ = nursery.alloc(64, .@"1");
    _ = nursery.alloc(64, .@"1");

    // 3 回目は null
    const ptr = nursery.alloc(64, .@"1");
    try std.testing.expect(ptr == null);
}

test "Nursery contains" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var nursery = Nursery.init(gpa.allocator(), 1024);
    defer nursery.deinit();

    const ptr = nursery.alloc(100, .@"8").?;
    try std.testing.expect(nursery.contains(@ptrCast(ptr)));

    // 外部ポインタ
    var external: u64 = 42;
    try std.testing.expect(!nursery.contains(@ptrCast(&external)));
}

test "Nursery mark" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var nursery = Nursery.init(gpa.allocator(), 1024);
    defer nursery.deinit();

    const ptr = nursery.alloc(100, .@"8").?;

    // 初回 mark は false
    try std.testing.expect(!nursery.mark(@ptrCast(ptr)));
    // 2 回目は true (既にマーク済み)
    try std.testing.expect(nursery.mark(@ptrCast(ptr)));
}

test "Nursery reset" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var nursery = Nursery.init(gpa.allocator(), 1024);
    defer nursery.deinit();

    _ = nursery.alloc(500, .@"8");
    try std.testing.expect(nursery.bytes_allocated >= 500);

    nursery.reset();

    try std.testing.expectEqual(@as(usize, 0), nursery.bytes_allocated);
    try std.testing.expectEqual(@as(usize, 0), nursery.offset);
    try std.testing.expectEqual(@as(u32, 0), nursery.allocs.count());
}

test "Nursery shouldCollect" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var nursery = Nursery.init(gpa.allocator(), 1000);
    defer nursery.deinit();

    // 初期状態では GC 不要
    try std.testing.expect(!nursery.shouldCollect());

    // 80% 超えたら GC 必要
    _ = nursery.alloc(850, .@"1");
    try std.testing.expect(nursery.shouldCollect());
}
