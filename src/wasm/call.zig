//! Call: Wasm 関数呼び出しブリッジ
//!
//! Clojure から Wasm 関数を呼び出すためのブリッジ。
//! 引数/戻り値の変換、エラーハンドリングを行う。
//!
//! 双方向呼び出し:
//!   - Clojure → Wasm: wasm/call
//!   - Wasm → Clojure: インポート関数として提供
//!
//! 詳細: docs/reference/architecture.md
//!
//! TODO: Wasm連携実装時に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const component = @import("component.zig");
// const Component = component.Component;
// const types = @import("types.zig");
// const WasmValue = types.WasmValue;
// const value = @import("../runtime/value.zig");
// const Value = value.Value;

/// 呼び出しコンテキスト
/// TODO: 実装時にコメント解除
pub const CallContext = struct {
    // component: *Component,
    // allocator: std.mem.Allocator,

    placeholder: void,
};

/// Wasm 関数呼び出し
/// TODO: 実装時にコメント解除
pub const Caller = struct {
    placeholder: void,

    // /// 関数を呼び出し（可変長引数）
    // pub fn call(
    //     ctx: *CallContext,
    //     func_name: []const u8,
    //     args: []Value,
    // ) !Value {
    //     const func = ctx.component.exports.get(func_name) orelse
    //         return error.FunctionNotFound;
    //
    //     // 引数を変換
    //     var wasm_args = try ctx.allocator.alloc(WasmValue, args.len);
    //     defer ctx.allocator.free(wasm_args);
    //     for (args, 0..) |arg, i| {
    //         wasm_args[i] = try types.TypeConverter.toWasm(arg);
    //     }
    //
    //     // 呼び出し
    //     const result = try invokeWasm(func, wasm_args);
    //
    //     // 結果を変換
    //     return types.TypeConverter.fromWasm(result);
    // }

    // /// Clojure 関数を Wasm インポートとして公開
    // pub fn exportToWasm(
    //     name: []const u8,
    //     clj_fn: *Fn,
    // ) WasmImport {
    //     // Clojure 関数をラップして Wasm から呼び出せるようにする
    // }
};

/// エラー型
pub const CallError = error{
    FunctionNotFound,
    TypeMismatch,
    TooManyArguments,
    WasmTrap,
    OutOfMemory,
};

// === テスト ===

test "placeholder" {
    const c: Caller = .{ .placeholder = {} };
    _ = c;
}
