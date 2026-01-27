//! Wasm 実行エンジン
//!
//! invoke: エクスポート関数を呼び出す
//! getExports: エクスポート一覧を取得

const std = @import("std");
const zware = @import("zware");
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const WasmModule = value_mod.WasmModule;
const wasm_types = @import("types.zig");

/// Wasm エクスポート関数を呼び出す
pub fn invoke(
    wm: *WasmModule,
    func_name: []const u8,
    args: []const Value,
    allocator: std.mem.Allocator,
) !Value {
    if (wm.closed) return error.WasmModuleClosed;

    const instance: *zware.Instance = @ptrCast(@alignCast(wm.instance));

    // 引数を u64 配列に変換
    const in_vals = try allocator.alloc(u64, args.len);
    defer allocator.free(in_vals);
    for (args, 0..) |arg, i| {
        in_vals[i] = wasm_types.valueToWasmU64(arg) catch {
            return error.WasmTypeError;
        };
    }

    // 結果バッファ（最大1つ — MVP では単一戻り値のみ）
    var out_vals: [1]u64 = .{0};

    // 呼び出し
    instance.invoke(func_name, in_vals, out_vals[0..], .{}) catch {
        return error.WasmInvokeError;
    };

    // 結果を Value に変換（i32 がデフォルト）
    return wasm_types.wasmI32ToValue(out_vals[0]);
}

/// エクスポート一覧をマップとして返す
/// {:name {:type :func/:memory/:table/:global}}
pub fn getExports(wm: *WasmModule, allocator: std.mem.Allocator) !Value {
    if (wm.closed) return error.WasmModuleClosed;

    const module: *zware.Module = @ptrCast(@alignCast(wm.module_ptr));

    // exports セクションを走査
    const exports = module.exports.list.items;
    if (exports.len == 0) {
        const empty = try allocator.create(value_mod.PersistentMap);
        empty.* = .{ .entries = &[_]Value{} };
        return Value{ .map = empty };
    }

    // エントリを構築: [name, {type_kw, type_val}, name2, ...]
    var entries: std.ArrayListUnmanaged(Value) = .empty;
    defer entries.deinit(allocator);

    for (exports) |exp| {
        // キー: export 名 (keyword)
        const name_kw = try allocator.create(value_mod.Keyword);
        name_kw.* = .{ .name = exp.name, .namespace = null };
        try entries.append(allocator, Value{ .keyword = name_kw });

        // 値: {:type :func/:memory/:table/:global}
        const type_str: []const u8 = switch (exp.tag) {
            .Func => "func",
            .Table => "table",
            .Mem => "memory",
            .Global => "global",
        };

        const type_kw = try allocator.create(value_mod.Keyword);
        type_kw.* = .{ .name = "type", .namespace = null };
        const type_val_kw = try allocator.create(value_mod.Keyword);
        type_val_kw.* = .{ .name = type_str, .namespace = null };

        const inner_entries = try allocator.alloc(Value, 2);
        inner_entries[0] = Value{ .keyword = type_kw };
        inner_entries[1] = Value{ .keyword = type_val_kw };

        const inner_map = try allocator.create(value_mod.PersistentMap);
        inner_map.* = .{ .entries = inner_entries };
        try entries.append(allocator, Value{ .map = inner_map });
    }

    const result_entries = try allocator.dupe(Value, entries.items);
    const result_map = try allocator.create(value_mod.PersistentMap);
    result_map.* = .{ .entries = result_entries };
    return Value{ .map = result_map };
}

pub const WasmRuntimeError = error{
    WasmModuleClosed,
    WasmTypeError,
    WasmInvokeError,
    OutOfMemory,
};
