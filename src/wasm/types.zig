//! Wasm 型変換ユーティリティ
//!
//! Clojure Value ↔ Wasm u64 の相互変換。
//! zware は全パラメータを u64 配列で受け渡しするため、
//! ビットキャストで変換する。

const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;

/// Clojure Value → Wasm u64 変換
/// int → i64 → @bitCast(u64)
/// float → f64 → @bitCast(u64)
/// bool → 1/0
/// nil → 0
pub fn valueToWasmU64(v: Value) !u64 {
    return switch (v) {
        .int => |n| @bitCast(n),
        .float => |f| @bitCast(f),
        .bool_val => |b| if (b) @as(u64, 1) else @as(u64, 0),
        .nil => 0,
        else => error.TypeError,
    };
}

/// Wasm i32 結果 → Clojure Value
/// u64 の下位32ビットを i32 として取り出し、i64 に拡張
pub fn wasmI32ToValue(raw: u64) Value {
    const i: i32 = @bitCast(@as(u32, @truncate(raw)));
    return .{ .int = @as(i64, i) };
}

/// Wasm i64 結果 → Clojure Value
pub fn wasmI64ToValue(raw: u64) Value {
    const i: i64 = @bitCast(raw);
    return .{ .int = i };
}

/// Wasm f32 結果 → Clojure Value
pub fn wasmF32ToValue(raw: u64) Value {
    const f: f32 = @bitCast(@as(u32, @truncate(raw)));
    return .{ .float = @as(f64, f) };
}

/// Wasm f64 結果 → Clojure Value
pub fn wasmF64ToValue(raw: u64) Value {
    const f: f64 = @bitCast(raw);
    return .{ .float = f };
}

pub const TypeError = error{TypeError};

// === テスト ===

test "valueToWasmU64 int" {
    const v: Value = .{ .int = 42 };
    const raw = try valueToWasmU64(v);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, 42))), raw);
}

test "wasmI32ToValue" {
    const v = wasmI32ToValue(7);
    try std.testing.expectEqual(@as(i64, 7), v.int);
}
