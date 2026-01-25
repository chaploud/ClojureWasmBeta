//! Stack: VMの値スタック
//!
//! スタックベースVMの値スタックとコールフレームを管理。
//!
//! 詳細: docs/reference/architecture.md
//!
//! TODO: VM実装時に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const value = @import("../runtime/value.zig");
// const Value = value.Value;

/// 値スタック
/// TODO: 実装時にコメント解除
pub const Stack = struct {
    // values: [STACK_MAX]Value,
    // top: [*]Value,

    // pub const STACK_MAX = 256 * 64;  // 最大スタックサイズ

    placeholder: void,

    // pub fn push(self: *Stack, v: Value) void {
    //     self.top[0] = v;
    //     self.top += 1;
    // }

    // pub fn pop(self: *Stack) Value {
    //     self.top -= 1;
    //     return self.top[0];
    // }

    // pub fn peek(self: *Stack, distance: usize) Value {
    //     return (self.top - 1 - distance)[0];
    // }
};

/// コールフレーム
/// TODO: 実装時にコメント解除
pub const CallFrame = struct {
    // closure: *Closure,
    // ip: [*]u8,
    // slots: [*]Value,  // このフレームのスタックベース

    placeholder: void,
};

/// コールフレームスタック
pub const CallFrames = struct {
    // frames: [FRAMES_MAX]CallFrame,
    // count: usize,

    // pub const FRAMES_MAX = 64;

    placeholder: void,
};

// === テスト ===

test "placeholder" {
    const s: Stack = .{ .placeholder = {} };
    _ = s;
}
