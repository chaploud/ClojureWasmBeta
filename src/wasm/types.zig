//! Types: Clojure ↔ Wasm 型マッピング
//!
//! Clojure の Value と Wasm の型を相互変換。
//! Component Model の型システムに準拠。
//!
//! マッピング:
//!   Clojure       Wasm Component Model
//!   ─────────────────────────────────
//!   nil           option<T> の none
//!   bool          bool
//!   int (i64)     s64
//!   float (f64)   float64
//!   string        string
//!   vector        list<T>
//!   map           record / variant
//!   keyword       enum
//!
//! 詳細: docs/reference/architecture.md
//!
//! TODO: Wasm連携実装時に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const value = @import("../runtime/value.zig");
// const Value = value.Value;

/// Wasm 値型
/// TODO: 実装時にコメント解除
pub const WasmValue = union(enum) {
    // i32_val: i32,
    // i64_val: i64,
    // f32_val: f32,
    // f64_val: f64,
    // string_val: []const u8,
    // list_val: []WasmValue,
    // record_val: *Record,

    placeholder: void,
};

/// Wasm 関数シグネチャ
pub const FuncSignature = struct {
    // params: []WasmType,
    // results: []WasmType,

    placeholder: void,
};

/// 型変換
/// TODO: 実装時にコメント解除
pub const TypeConverter = struct {
    placeholder: void,

    // /// Clojure Value → Wasm Value
    // pub fn toWasm(v: Value) !WasmValue {
    //     return switch (v) {
    //         .nil => .{ .i32_val = 0 },  // option none
    //         .bool_val => |b| .{ .i32_val = if (b) 1 else 0 },
    //         .int => |i| .{ .i64_val = i },
    //         .float => |f| .{ .f64_val = f },
    //         .string => |s| .{ .string_val = s.data },
    //         // ...
    //     };
    // }

    // /// Wasm Value → Clojure Value
    // pub fn fromWasm(w: WasmValue) !Value {
    //     return switch (w) {
    //         .i64_val => |i| Value{ .int = i },
    //         .f64_val => |f| Value{ .float = f },
    //         .string_val => |s| Value{ .string = ... },
    //         // ...
    //     };
    // }
};

// === テスト ===

test "placeholder" {
    const w: WasmValue = .{ .placeholder = {} };
    _ = w;
}
