//! Tracing: トレーシングGC
//!
//! Mark-Sweep ベースのガベージコレクション。
//! ルートから到達可能なオブジェクトを追跡。
//!
//! アルゴリズム:
//!   1. Mark: ルートから到達可能なオブジェクトをマーク
//!   2. Sweep: マークされていないオブジェクトを解放
//!
//! ルート:
//!   - VMスタック
//!   - グローバル変数
//!   - コールフレーム
//!   - Open upvalues
//!
//! 詳細: docs/reference/architecture.md
//!
//! TODO: 本格GC実装時に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const value = @import("../runtime/value.zig");
// const Value = value.Value;

/// オブジェクトヘッダ（GC管理用）
/// TODO: 実装時にコメント解除
pub const ObjectHeader = struct {
    // marked: bool,
    // next: ?*ObjectHeader,  // 全オブジェクトリスト

    placeholder: void,
};

/// Mark-Sweep GC
/// TODO: 実装時にコメント解除
pub const TracingGC = struct {
    // objects: ?*ObjectHeader,
    // gray_stack: std.ArrayList(*ObjectHeader),
    // bytes_allocated: usize,
    // next_gc: usize,

    placeholder: void,

    // /// Mark フェーズ
    // pub fn mark(self: *TracingGC, roots: []Value) void {
    //     // ルートからグレースタックに追加
    //     for (roots) |root| {
    //         self.markValue(root);
    //     }
    //     // グレースタックを処理
    //     while (self.gray_stack.popOrNull()) |obj| {
    //         self.blackenObject(obj);
    //     }
    // }

    // /// Sweep フェーズ
    // pub fn sweep(self: *TracingGC) void {
    //     var prev: ?*ObjectHeader = null;
    //     var obj = self.objects;
    //     while (obj) |o| {
    //         if (!o.marked) {
    //             // 解放
    //             const unreached = o;
    //             obj = o.next;
    //             if (prev) |p| {
    //                 p.next = obj;
    //             } else {
    //                 self.objects = obj;
    //             }
    //             self.freeObject(unreached);
    //         } else {
    //             o.marked = false;  // 次回用にリセット
    //             prev = o;
    //             obj = o.next;
    //         }
    //     }
    // }
};

// === テスト ===

test "placeholder" {
    const gc: TracingGC = .{ .placeholder = {} };
    _ = gc;
}
