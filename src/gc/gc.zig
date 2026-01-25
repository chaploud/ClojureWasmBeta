//! GC: ガベージコレクションインターフェース
//!
//! ランタイム値のメモリ管理を行う。
//! 初期は Arena ベース、将来は Mark-Sweep 等に拡張。
//!
//! 戦略:
//!   1. Arena (現状): フェーズ単位で一括解放
//!   2. Mark-Sweep: 到達可能性ベースのGC
//!   3. Generational: 世代別GC（将来）
//!
//! 詳細: docs/reference/architecture.md
//!
//! TODO: GC実装時に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const value = @import("../runtime/value.zig");
// const Value = value.Value;

/// GC戦略
pub const Strategy = enum {
    arena,       // Arena ベース（現状）
    mark_sweep,  // Mark-Sweep
    // generational, // 世代別（将来）
};

/// GCインターフェース
/// TODO: 実装時にコメント解除
pub const GC = struct {
    // allocator: std.mem.Allocator,
    // strategy: Strategy,
    // bytes_allocated: usize,
    // next_gc: usize,  // 次のGCトリガー

    // === オブジェクト追跡 ===
    // objects: ?*Object,  // 全オブジェクトのリンクリスト
    // gray_stack: std.ArrayList(*Object),  // Mark フェーズ用

    placeholder: void,

    // /// オブジェクトを割り当て
    // pub fn alloc(self: *GC, comptime T: type) !*T {
    //     self.bytes_allocated += @sizeOf(T);
    //     if (self.bytes_allocated > self.next_gc) {
    //         try self.collectGarbage();
    //     }
    //     // ...
    // }

    // /// GC実行
    // pub fn collectGarbage(self: *GC) !void {
    //     switch (self.strategy) {
    //         .arena => {}, // Arenaは手動解放
    //         .mark_sweep => try self.markSweep(),
    //     }
    // }

    // fn markSweep(self: *GC) !void {
    //     // Mark: ルートから到達可能なオブジェクトをマーク
    //     // Sweep: マークされていないオブジェクトを解放
    // }
};

// === テスト ===

test "placeholder" {
    const g: GC = .{ .placeholder = {} };
    _ = g;
}
