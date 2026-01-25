//! Arena: Arenaアロケータ
//!
//! フェーズ単位でメモリを一括解放する簡易GC。
//! 初期実装で使用。
//!
//! 利点:
//!   - シンプル
//!   - フラグメンテーションなし
//!   - 高速な割り当て
//!
//! 欠点:
//!   - 細かい解放ができない
//!   - 長時間実行には不向き
//!
//! 詳細: docs/reference/architecture.md
//!
//! TODO: 基本実装時に有効化

const std = @import("std");

/// Arenaラッパー
/// TODO: 実装時にコメント解除
pub const Arena = struct {
    // arena: std.heap.ArenaAllocator,

    placeholder: void,

    // pub fn init(child_allocator: std.mem.Allocator) Arena {
    //     return .{
    //         .arena = std.heap.ArenaAllocator.init(child_allocator),
    //     };
    // }

    // pub fn allocator(self: *Arena) std.mem.Allocator {
    //     return self.arena.allocator();
    // }

    // /// 全メモリを解放
    // pub fn reset(self: *Arena) void {
    //     _ = self.arena.reset(.retain_capacity);
    // }

    // pub fn deinit(self: *Arena) void {
    //     self.arena.deinit();
    // }
};

// === テスト ===

test "placeholder" {
    const a: Arena = .{ .placeholder = {} };
    _ = a;
}
