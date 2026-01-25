//! Ops: オペコード実装
//!
//! 各オペコードの実際の処理を実装。
//! 算術演算、コレクション操作等。
//!
//! 詳細: docs/reference/architecture.md
//!
//! TODO: VM実装時に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const value = @import("../runtime/value.zig");
// const Value = value.Value;
// const vm_mod = @import("vm.zig");
// const VM = vm_mod.VM;

/// オペコード実装
/// TODO: 実装時にコメント解除
pub const Ops = struct {
    placeholder: void,

    // === 算術演算 ===
    // pub fn add(a: Value, b: Value) !Value {
    //     return switch (a) {
    //         .int => |ai| switch (b) {
    //             .int => |bi| Value{ .int = ai + bi },
    //             .float => |bf| Value{ .float = @as(f64, @floatFromInt(ai)) + bf },
    //             else => error.TypeError,
    //         },
    //         .float => |af| switch (b) {
    //             .int => |bi| Value{ .float = af + @as(f64, @floatFromInt(bi)) },
    //             .float => |bf| Value{ .float = af + bf },
    //             else => error.TypeError,
    //         },
    //         else => error.TypeError,
    //     };
    // }

    // === 比較演算 ===
    // pub fn equal(a: Value, b: Value) bool { ... }
    // pub fn lessThan(a: Value, b: Value) !bool { ... }

    // === コレクション操作 ===
    // pub fn first(coll: Value) !Value { ... }
    // pub fn rest(coll: Value) !Value { ... }
    // pub fn cons(elem: Value, coll: Value) !Value { ... }
};

// === テスト ===

test "placeholder" {
    const ops: Ops = .{ .placeholder = {} };
    _ = ops;
}
