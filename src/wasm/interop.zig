//! Wasm メモリ操作 + 文字列マーシャリング
//!
//! Clojure ↔ Wasm 線形メモリ間のデータ転送。
//! Instance.getMemory(0) で線形メモリにアクセスし、
//! バイト列/文字列の読み書きを行う。

const std = @import("std");
const zware = @import("zware");
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const WasmModule = value_mod.WasmModule;

/// Instance から線形メモリを取得
fn getMemory(wm: *WasmModule) !*zware.Memory {
    if (wm.closed) return error.WasmModuleClosed;
    const instance: *zware.Instance = @ptrCast(@alignCast(wm.instance));
    return instance.getMemory(0) catch {
        return error.WasmMemoryError;
    };
}

/// メモリから文字列 (UTF-8) を読み出す
/// (wasm/memory-read module offset len) → string
pub fn readString(wm: *WasmModule, offset: u32, len: u32, allocator: std.mem.Allocator) !Value {
    const memory = try getMemory(wm);
    const data = memory.memory();

    const end = @as(u64, offset) + @as(u64, len);
    if (end > data.len) return error.WasmMemoryOutOfBounds;

    const slice = data[offset .. offset + len];
    const copied = try allocator.dupe(u8, slice);

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = copied };
    return Value{ .string = str_obj };
}

/// メモリにバイト列を書き込む
/// (wasm/memory-write module offset data) → nil
pub fn writeBytes(wm: *WasmModule, offset: u32, data: []const u8) !void {
    const memory = try getMemory(wm);
    const mem_data = memory.memory();

    const end = @as(u64, offset) + @as(u64, data.len);
    if (end > mem_data.len) return error.WasmMemoryOutOfBounds;

    @memcpy(mem_data[offset .. offset + data.len], data);
}

/// メモリサイズ (ページ数) を返す
pub fn memorySize(wm: *WasmModule) !u32 {
    const memory = try getMemory(wm);
    return memory.size();
}

/// メモリサイズ (バイト数) を返す
pub fn memorySizeBytes(wm: *WasmModule) !u64 {
    const memory = try getMemory(wm);
    return @as(u64, memory.size()) * 65536;
}

pub const WasmInteropError = error{
    WasmModuleClosed,
    WasmMemoryError,
    WasmMemoryOutOfBounds,
    OutOfMemory,
};
