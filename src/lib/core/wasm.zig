//! Wasm 関数
//!
//! wasm/load-module, wasm/invoke, wasm/exports, wasm/memory-*, wasm/close 等

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const wasm_loader = defs.wasm_loader;
const wasm_runtime = defs.wasm_runtime;
const wasm_interop = defs.wasm_interop;
const wasm_wasi = defs.wasm_wasi;
const BuiltinDef = defs.BuiltinDef;

const helpers = @import("helpers.zig");

/// wasm/load-module: .wasm ファイルをロードして WasmModule を返す
pub fn wasmLoadModule(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;
    const path = switch (args[0]) {
        .string => |s| s.data,
        else => return error.TypeError,
    };
    // 第2引数: オプションのインポートマップ {:imports {"env" {"func" clj-fn}}}
    if (args.len == 2) {
        const opts = args[1];
        const opts_map = switch (opts) {
            .map => |m| m,
            else => return error.TypeError,
        };
        // :imports キーを検索
        const imports_val = helpers.lookupKeywordInMap(opts_map, "imports");
        if (imports_val) |imp| {
            const wm = wasm_loader.loadModuleWithImports(allocator, path, imp) catch {
                return error.WasmLoadError;
            };
            return Value{ .wasm_module = wm };
        }
    }
    const wm = wasm_loader.loadModule(allocator, path) catch {
        return error.WasmLoadError;
    };
    return Value{ .wasm_module = wm };
}

/// wasm/invoke: WasmModule のエクスポート関数を呼び出す
pub fn wasmInvoke(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // (wasm/invoke module "func-name" arg1 arg2 ...)
    if (args.len < 2) return error.ArityError;
    const wm = switch (args[0]) {
        .wasm_module => |m| m,
        else => return error.TypeError,
    };
    const func_name = switch (args[1]) {
        .string => |s| s.data,
        else => return error.TypeError,
    };
    const func_args = args[2..];
    return wasm_runtime.invoke(wm, func_name, func_args, allocator) catch {
        return error.WasmInvokeError;
    };
}

/// wasm/exports: WasmModule のエクスポート一覧をマップで返す
pub fn wasmExports(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const wm = switch (args[0]) {
        .wasm_module => |m| m,
        else => return error.TypeError,
    };
    return wasm_runtime.getExports(wm, allocator) catch {
        return error.WasmInvokeError;
    };
}

/// wasm/module?: WasmModule かどうかを判定
pub fn isWasmModule(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .wasm_module => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// wasm/memory-read: メモリから文字列を読み出す
/// (wasm/memory-read module offset len) → string
pub fn wasmMemoryRead(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const wm = switch (args[0]) {
        .wasm_module => |m| m,
        else => return error.TypeError,
    };
    const offset: u32 = switch (args[1]) {
        .int => |n| if (n >= 0) @intCast(n) else return error.TypeError,
        else => return error.TypeError,
    };
    const len: u32 = switch (args[2]) {
        .int => |n| if (n >= 0) @intCast(n) else return error.TypeError,
        else => return error.TypeError,
    };
    return wasm_interop.readString(wm, offset, len, allocator) catch {
        return error.WasmMemoryError;
    };
}

/// wasm/memory-write: メモリに文字列/バイト列を書き込む
/// (wasm/memory-write module offset data) → nil
pub fn wasmMemoryWrite(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const wm = switch (args[0]) {
        .wasm_module => |m| m,
        else => return error.TypeError,
    };
    const offset: u32 = switch (args[1]) {
        .int => |n| if (n >= 0) @intCast(n) else return error.TypeError,
        else => return error.TypeError,
    };
    const data: []const u8 = switch (args[2]) {
        .string => |s| s.data,
        else => return error.TypeError,
    };
    wasm_interop.writeBytes(wm, offset, data) catch {
        return error.WasmMemoryError;
    };
    return value_mod.nil;
}

/// wasm/memory-size: メモリサイズ (バイト数) を返す
/// (wasm/memory-size module) → int
pub fn wasmMemorySize(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const wm = switch (args[0]) {
        .wasm_module => |m| m,
        else => return error.TypeError,
    };
    const size_bytes = wasm_interop.memorySizeBytes(wm) catch {
        return error.WasmMemoryError;
    };
    return Value{ .int = @intCast(size_bytes) };
}

/// wasm/load-wasi: WASI モジュールをロード
pub fn wasmLoadWasi(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const path = switch (args[0]) {
        .string => |s| s.data,
        else => return error.TypeError,
    };
    const wm = wasm_wasi.loadWasiModule(allocator, path) catch {
        return error.WasmLoadError;
    };
    return Value{ .wasm_module = wm };
}

/// wasm/close: モジュールを閉じる（明示的クリーンアップ）
pub fn wasmClose(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const wm = switch (args[0]) {
        .wasm_module => |m| m,
        else => return error.TypeError,
    };
    wm.closed = true;
    return value_mod.nil;
}

/// wasm/closed?: モジュールが閉じられたか確認
pub fn wasmClosed(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const wm = switch (args[0]) {
        .wasm_module => |m| m,
        else => return error.TypeError,
    };
    return if (wm.closed) value_mod.true_val else value_mod.false_val;
}

pub const builtins = [_]BuiltinDef{
    // Phase La
    .{ .name = "load-module", .func = wasmLoadModule },
    .{ .name = "invoke", .func = wasmInvoke },
    .{ .name = "exports", .func = wasmExports },
    .{ .name = "module?", .func = isWasmModule },
    // Phase Lb
    .{ .name = "memory-read", .func = wasmMemoryRead },
    .{ .name = "memory-write", .func = wasmMemoryWrite },
    .{ .name = "memory-size", .func = wasmMemorySize },
    // Phase Ld
    .{ .name = "load-wasi", .func = wasmLoadWasi },
    // Phase Le
    .{ .name = "close", .func = wasmClose },
    .{ .name = "closed?", .func = wasmClosed },
};
