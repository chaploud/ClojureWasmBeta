//! GenerationalGC: 世代別 GC 統合モジュール
//!
//! Nursery (Young) と GcAllocator (Old) を組み合わせた世代別 GC。
//!
//! アロケーション戦略:
//!   1. 新規オブジェクトは Nursery に bump allocator で高速割り当て
//!   2. Nursery 満杯時に minor GC で生存オブジェクトを Old に promotion
//!   3. Old 世代の閾値超過時に major GC (既存のセミスペース Mark-Sweep)
//!
//! 使い方:
//!   var gen_gc = GenerationalGC.init(parent_alloc);
//!   defer gen_gc.deinit();
//!   const allocator = gen_gc.allocator();
//!   // allocator は std.mem.Allocator として使える

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Nursery = @import("nursery.zig").Nursery;
const GcAllocator = @import("gc_allocator.zig").GcAllocator;
const ForwardingTable = @import("gc_allocator.zig").ForwardingTable;

/// 世代別 GC 統合
pub const GenerationalGC = struct {
    /// Young 世代 (Nursery)
    nursery: Nursery,
    /// Old 世代
    old_gen: *GcAllocator,
    /// registry 管理用アロケータ
    registry_alloc: Allocator,
    /// Remembered Set: Old→Young 参照を追跡
    /// Card marking で実装（将来の write barrier 用）
    remembered_set: RememberedSet,
    /// GC モード（世代別 or 単一世代）
    generational_enabled: bool,

    /// Remembered Set: Old オブジェクトが Young を参照する場合に記録
    const RememberedSet = std.AutoHashMapUnmanaged(*anyopaque, void);

    /// 初期化
    pub fn init(registry_alloc: Allocator) GenerationalGC {
        // GcAllocator をヒープに確保
        const old_gen = registry_alloc.create(GcAllocator) catch {
            // 失敗時は Old のみモード（nursery 無効）
            return .{
                .nursery = Nursery.init(registry_alloc, 0), // 空 nursery
                .old_gen = undefined,
                .registry_alloc = registry_alloc,
                .remembered_set = .empty,
                .generational_enabled = false,
            };
        };
        old_gen.* = GcAllocator.init(registry_alloc);

        return .{
            .nursery = Nursery.init(registry_alloc, Nursery.DEFAULT_SIZE),
            .old_gen = old_gen,
            .registry_alloc = registry_alloc,
            .remembered_set = .empty,
            .generational_enabled = true,
        };
    }

    /// 破棄
    pub fn deinit(self: *GenerationalGC) void {
        self.remembered_set.deinit(self.registry_alloc);
        self.nursery.deinit();
        if (self.generational_enabled) {
            self.old_gen.deinit();
            self.registry_alloc.destroy(self.old_gen);
        }
    }

    /// std.mem.Allocator インターフェースを返す
    pub fn allocator(self: *GenerationalGC) Allocator {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    /// Old 世代のアロケータを直接取得（互換性用）
    pub fn oldAllocator(self: *GenerationalGC) Allocator {
        return self.old_gen.allocator();
    }

    /// ポインタが Nursery 内かどうか
    pub fn isYoung(self: *const GenerationalGC, ptr: *anyopaque) bool {
        return self.nursery.contains(ptr);
    }

    /// ポインタを mark（Young or Old）
    pub fn mark(self: *GenerationalGC, ptr: *anyopaque) bool {
        if (self.generational_enabled and self.nursery.contains(ptr)) {
            return self.nursery.mark(ptr);
        }
        return self.old_gen.mark(ptr);
    }

    /// スライスポインタを mark
    pub fn markSlice(self: *GenerationalGC, ptr: ?[*]const u8, len: usize) void {
        if (ptr == null or len == 0) return;
        const raw: *anyopaque = @ptrCast(@constCast(ptr.?));
        _ = self.mark(raw);
    }

    /// 全 marked フラグをクリア
    pub fn clearMarks(self: *GenerationalGC) void {
        if (self.generational_enabled) {
            self.nursery.clearMarks();
        }
        self.old_gen.clearMarks();
    }

    /// Minor GC を実行すべきかどうか
    pub fn shouldMinorCollect(self: *const GenerationalGC) bool {
        return self.generational_enabled and self.nursery.shouldCollect();
    }

    /// Major GC を実行すべきかどうか
    pub fn shouldMajorCollect(self: *const GenerationalGC) bool {
        return self.old_gen.shouldCollect();
    }

    /// GC を実行すべきかどうか（minor or major）
    pub fn shouldCollect(self: *const GenerationalGC) bool {
        return self.shouldMinorCollect() or self.shouldMajorCollect();
    }

    /// Write barrier: Old オブジェクトが Young オブジェクトを参照した場合に呼ぶ
    /// これにより minor GC 時に Old→Young 参照を追跡できる
    pub fn writeBarrier(self: *GenerationalGC, old_ptr: *anyopaque, young_ptr: *anyopaque) void {
        if (!self.generational_enabled) return;

        // Old が Young を参照している場合のみ記録
        if (!self.nursery.contains(old_ptr) and self.nursery.contains(young_ptr)) {
            self.remembered_set.put(self.registry_alloc, old_ptr, {}) catch {};
        }
    }

    /// Minor GC 実行: Young 世代の生存オブジェクトを Old に promotion
    /// マーク済みオブジェクト (nursery.mark() 済み) を Old にコピーし、
    /// forwarding テーブルを返す
    pub fn minorCollect(self: *GenerationalGC) MinorGCResult {
        if (!self.generational_enabled) {
            return .{
                .promoted_bytes = 0,
                .promoted_count = 0,
                .freed_count = 0,
                .forwarding = .empty,
            };
        }

        const before_count = self.nursery.allocs.count();
        var promoted_bytes: usize = 0;
        var promoted_count: u32 = 0;
        var forwarding: ForwardingTable = .empty;

        // 事前確保
        var marked_count: u32 = 0;
        {
            var count_iter = self.nursery.allocs.iterator();
            while (count_iter.next()) |entry| {
                if (entry.value_ptr.marked) marked_count += 1;
            }
        }
        forwarding.ensureTotalCapacity(self.registry_alloc, marked_count) catch {};

        // マーク済みオブジェクトを Old にコピー
        const old_alloc = self.old_gen.allocator();
        var iter = self.nursery.allocs.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.marked) {
                const info = entry.value_ptr.*;
                const old_ptr: [*]u8 = @ptrCast(entry.key_ptr.*);

                // Old にコピー
                const new_ptr = old_alloc.rawAlloc(info.size, info.alignment, 0) orelse continue;
                @memcpy(new_ptr[0..info.size], old_ptr[0..info.size]);

                // forwarding テーブルに登録
                forwarding.putAssumeCapacity(entry.key_ptr.*, @ptrCast(new_ptr));

                promoted_bytes += info.size;
                promoted_count += 1;
            }
        }

        // 統計更新
        self.nursery.minor_collections += 1;
        self.nursery.total_promoted_bytes += promoted_bytes;
        self.nursery.total_promoted_count += promoted_count;

        // Nursery をリセット（全オブジェクト解放）
        self.nursery.reset();

        // Remembered Set をクリア（promotion 後は不要）
        self.remembered_set.clearRetainingCapacity();

        return .{
            .promoted_bytes = promoted_bytes,
            .promoted_count = promoted_count,
            .freed_count = before_count - promoted_count,
            .forwarding = forwarding,
        };
    }

    /// Minor GC の結果
    pub const MinorGCResult = struct {
        promoted_bytes: usize,
        promoted_count: u32,
        freed_count: u32,
        /// ポインタ転送テーブル（Nursery旧 → Old新）
        /// 呼び出し元がポインタ更新に使用した後、deinit すること
        forwarding: ForwardingTable,
    };

    /// 統計情報
    pub fn stats(self: *const GenerationalGC) Stats {
        const nursery_stats = self.nursery.stats();
        const old_stats = self.old_gen.stats();
        return .{
            .nursery = nursery_stats,
            .old = old_stats,
            .remembered_set_size = self.remembered_set.count(),
            .generational_enabled = self.generational_enabled,
        };
    }

    pub const Stats = struct {
        nursery: Nursery.Stats,
        old: GcAllocator.Stats,
        remembered_set_size: u32,
        generational_enabled: bool,
    };

    // === VTable 実装 ===

    const vtable = Allocator.VTable{
        .alloc = genAlloc,
        .resize = genResize,
        .remap = genRemap,
        .free = genFree,
    };

    fn genAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const self: *GenerationalGC = @ptrCast(@alignCast(ctx));

        // まず Nursery に割り当てを試みる
        if (self.generational_enabled) {
            if (self.nursery.alloc(len, alignment)) |ptr| {
                return ptr;
            }
            // Nursery 満杯 → Old にフォールバック（minor GC は別途トリガー）
        }

        // Old 世代に割り当て
        return self.old_gen.allocator().rawAlloc(len, alignment, 0);
    }

    fn genResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
        const self: *GenerationalGC = @ptrCast(@alignCast(ctx));

        // Nursery は bump allocator なので resize 非対応
        // Old に委譲
        return self.old_gen.allocator().rawResize(memory, alignment, new_len, 0);
    }

    fn genRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) ?[*]u8 {
        const self: *GenerationalGC = @ptrCast(@alignCast(ctx));

        // Nursery は bump allocator なので remap 非対応
        // Old に委譲
        return self.old_gen.allocator().rawRemap(memory, alignment, new_len, 0);
    }

    fn genFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
        const self: *GenerationalGC = @ptrCast(@alignCast(ctx));

        // Nursery 内の free は無視（minor GC で一括処理）
        if (self.generational_enabled and self.nursery.contains(@ptrCast(memory.ptr))) {
            return;
        }

        // Old からの free
        self.old_gen.allocator().rawFree(memory, alignment, 0);
    }
};

// === テスト ===

test "GenerationalGC 基本初期化" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gen_gc = GenerationalGC.init(gpa.allocator());
    defer gen_gc.deinit();

    try std.testing.expect(gen_gc.generational_enabled);
}

test "GenerationalGC allocator 経由で割り当て" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gen_gc = GenerationalGC.init(gpa.allocator());
    defer gen_gc.deinit();

    const a = gen_gc.allocator();

    const data = try a.alloc(u8, 100);
    try std.testing.expect(data.len == 100);

    // Nursery 内に割り当てられた
    try std.testing.expect(gen_gc.isYoung(@ptrCast(data.ptr)));

    // free は no-op (GC で回収)
    a.free(data);
}

test "GenerationalGC isYoung" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gen_gc = GenerationalGC.init(gpa.allocator());
    defer gen_gc.deinit();

    const a = gen_gc.allocator();
    const young_data = try a.alloc(u8, 100);

    try std.testing.expect(gen_gc.isYoung(@ptrCast(young_data.ptr)));

    // 外部ポインタは Young ではない
    var external: u64 = 42;
    try std.testing.expect(!gen_gc.isYoung(@ptrCast(&external)));

    a.free(young_data);
}

test "GenerationalGC mark Young/Old" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gen_gc = GenerationalGC.init(gpa.allocator());
    defer gen_gc.deinit();

    const a = gen_gc.allocator();
    const young_data = try a.alloc(u8, 100);

    // 初回 mark は false
    try std.testing.expect(!gen_gc.mark(@ptrCast(young_data.ptr)));
    // 2 回目は true
    try std.testing.expect(gen_gc.mark(@ptrCast(young_data.ptr)));

    a.free(young_data);
}

test "GenerationalGC writeBarrier" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gen_gc = GenerationalGC.init(gpa.allocator());
    defer gen_gc.deinit();

    const a = gen_gc.allocator();
    const young_data = try a.alloc(u8, 100);

    // Old ポインタ（模擬）
    var old_obj: u64 = 0;

    // write barrier を呼ぶ
    gen_gc.writeBarrier(@ptrCast(&old_obj), @ptrCast(young_data.ptr));

    // remembered set に記録された
    try std.testing.expect(gen_gc.remembered_set.contains(@ptrCast(&old_obj)));

    a.free(young_data);
}

test "GenerationalGC stats" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gen_gc = GenerationalGC.init(gpa.allocator());
    defer gen_gc.deinit();

    const s = gen_gc.stats();
    try std.testing.expect(s.generational_enabled);
    try std.testing.expect(s.nursery.capacity > 0);
}

test "GenerationalGC minorCollect" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gen_gc = GenerationalGC.init(gpa.allocator());
    defer gen_gc.deinit();

    const a = gen_gc.allocator();

    // 3 つ割り当て
    const p1 = try a.create(u64);
    const p2 = try a.create(u64);
    const p3 = try a.create(u64);
    p1.* = 1;
    p2.* = 2;
    p3.* = 3;

    // 全て Young
    try std.testing.expect(gen_gc.isYoung(@ptrCast(p1)));
    try std.testing.expect(gen_gc.isYoung(@ptrCast(p2)));
    try std.testing.expect(gen_gc.isYoung(@ptrCast(p3)));

    // p1 と p3 だけ mark
    _ = gen_gc.mark(@ptrCast(p1));
    _ = gen_gc.mark(@ptrCast(p3));

    // minor GC
    var result = gen_gc.minorCollect();
    defer result.forwarding.deinit(gpa.allocator());

    // p1 と p3 が promotion された
    try std.testing.expectEqual(@as(u32, 2), result.promoted_count);
    try std.testing.expectEqual(@as(u32, 1), result.freed_count); // p2

    // forwarding テーブルで新ポインタを取得
    const new_p1_opaque = result.forwarding.get(@ptrCast(p1)).?;
    const new_p3_opaque = result.forwarding.get(@ptrCast(p3)).?;
    const new_p1: *u64 = @ptrCast(@alignCast(new_p1_opaque));
    const new_p3: *u64 = @ptrCast(@alignCast(new_p3_opaque));

    // 値が正しくコピーされている
    try std.testing.expectEqual(@as(u64, 1), new_p1.*);
    try std.testing.expectEqual(@as(u64, 3), new_p3.*);

    // 新ポインタは Old にある（Young ではない）
    try std.testing.expect(!gen_gc.isYoung(@ptrCast(new_p1)));
    try std.testing.expect(!gen_gc.isYoung(@ptrCast(new_p3)));
}

test "GenerationalGC minorCollect 後の Nursery リセット" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gen_gc = GenerationalGC.init(gpa.allocator());
    defer gen_gc.deinit();

    const a = gen_gc.allocator();

    // 割り当て
    _ = try a.create(u64);
    const before_offset = gen_gc.nursery.offset;
    try std.testing.expect(before_offset > 0);

    // minor GC (何も mark しない → 全て解放)
    var result = gen_gc.minorCollect();
    result.forwarding.deinit(gpa.allocator());

    // Nursery がリセットされた
    try std.testing.expectEqual(@as(usize, 0), gen_gc.nursery.offset);
    try std.testing.expectEqual(@as(u32, 0), gen_gc.nursery.allocs.count());
}
