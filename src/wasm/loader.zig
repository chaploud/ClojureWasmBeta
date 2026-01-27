//! Wasm モジュールローダー
//!
//! .wasm ファイルを読み込み、zware でインスタンス化。
//! WasmModule 構造体を返す。

const std = @import("std");
const zware = @import("zware");
const value_mod = @import("../runtime/value.zig");
const WasmModule = value_mod.WasmModule;

/// 最大ファイルサイズ (10MB)
const MAX_FILE_SIZE = 10 * 1024 * 1024;

/// .wasm ファイルをロードしてインスタンス化
pub fn loadModule(allocator: std.mem.Allocator, path: []const u8) !*WasmModule {
    // 1. ファイル読み込み
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return error.WasmFileNotFound;
    };
    defer file.close();

    const bytes = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        return error.WasmFileReadError;
    };

    // 2. Store をヒープに確保
    const store = try allocator.create(zware.Store);
    store.* = zware.Store.init(allocator);

    // 3. Module をヒープに確保してデコード
    const module = try allocator.create(zware.Module);
    module.* = zware.Module.init(allocator, bytes);
    module.decode() catch {
        return error.WasmDecodeError;
    };

    // 4. Instance をヒープに確保してインスタンス化
    const instance = try allocator.create(zware.Instance);
    instance.* = zware.Instance.init(allocator, store, module.*);
    instance.instantiate() catch {
        return error.WasmInstantiateError;
    };

    // 5. WasmModule 構造体を作成
    const wm = try allocator.create(WasmModule);
    const path_copy = try allocator.dupe(u8, path);
    wm.* = .{
        .path = path_copy,
        .store = @ptrCast(store),
        .instance = @ptrCast(instance),
        .module_ptr = @ptrCast(module),
        .closed = false,
    };

    return wm;
}

pub const WasmLoadError = error{
    WasmFileNotFound,
    WasmFileReadError,
    WasmDecodeError,
    WasmInstantiateError,
    OutOfMemory,
};
