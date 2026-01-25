//! Component: Wasm Component Model インターフェース
//!
//! ロード済み Wasm コンポーネントを表現。
//! エクスポート関数の呼び出し、メモリ共有等を提供。
//!
//! Clojure での使用例:
//!   (def math (wasm/load "math.wasm"))
//!   (wasm/call math "add" 1 2)  ; => 3
//!   (wasm/exports math)         ; => ["add" "sub" "mul" "div"]
//!
//! 詳細: docs/reference/architecture.md
//!
//! TODO: Wasm連携実装時に有効化

const std = @import("std");

// TODO: 実装時にコメント解除
// const types = @import("types.zig");
// const WasmValue = types.WasmValue;
// const value = @import("../runtime/value.zig");
// const Value = value.Value;

/// Wasm コンポーネント
/// TODO: 実装時にコメント解除
pub const Component = struct {
    // name: []const u8,
    // instance: WasmInstance,
    // exports: ExportMap,
    // memory: ?*WasmMemory,

    placeholder: void,

    // /// エクスポート関数を呼び出し
    // pub fn call(
    //     self: *Component,
    //     func_name: []const u8,
    //     args: []Value,
    // ) !Value {
    //     // 1. 関数を検索
    //     const func = self.exports.get(func_name) orelse
    //         return error.FunctionNotFound;
    //
    //     // 2. 引数を Wasm 型に変換
    //     const wasm_args = try types.toWasmValues(args);
    //
    //     // 3. 呼び出し
    //     const wasm_result = try func.call(wasm_args);
    //
    //     // 4. 結果を Clojure 型に変換
    //     return types.fromWasmValue(wasm_result);
    // }

    // /// エクスポート一覧を取得
    // pub fn getExports(self: *Component) []const []const u8 {
    //     return self.exports.keys();
    // }

    // /// 共有メモリにアクセス
    // pub fn getMemory(self: *Component) ?[]u8 {
    //     if (self.memory) |mem| {
    //         return mem.data;
    //     }
    //     return null;
    // }
};

/// エクスポート関数
pub const ExportFunc = struct {
    // name: []const u8,
    // signature: FuncSignature,
    // func_ptr: *anyopaque,

    placeholder: void,
};

// === テスト ===

test "placeholder" {
    const c: Component = .{ .placeholder = {} };
    _ = c;
}
