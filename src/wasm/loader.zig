//! Wasm モジュールローダー
//!
//! .wasm ファイルを読み込み、zware でインスタンス化。
//! WasmModule 構造体を返す。

const std = @import("std");
const zware = @import("zware");
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const WasmModule = value_mod.WasmModule;
const host_functions = @import("host_functions.zig");

/// 最大ファイルサイズ (10MB)
const MAX_FILE_SIZE = 10 * 1024 * 1024;

/// インスタンス化前のフック関数型
/// Store と Module を受け取り、インポート登録等の前処理を行う
const PreInstantiateFn = *const fn (*zware.Store, *zware.Module) anyerror!void;

/// 共通ローダー: ファイル読み込み → デコード → (フック) → インスタンス化 → WasmModule 生成
pub fn loadModuleCore(
    allocator: std.mem.Allocator,
    path: []const u8,
    pre_instantiate: ?PreInstantiateFn,
) !*WasmModule {
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

    // 4. インスタンス化前のフック (ホスト関数登録、WASI 登録等)
    if (pre_instantiate) |hook| {
        hook(store, module) catch {
            return error.WasmInstantiateError;
        };
    }

    // 5. Instance をヒープに確保してインスタンス化
    const instance = try allocator.create(zware.Instance);
    instance.* = zware.Instance.init(allocator, store, module.*);
    instance.instantiate() catch {
        return error.WasmInstantiateError;
    };

    // 6. WasmModule 構造体を作成
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

/// .wasm ファイルをロードしてインスタンス化
pub fn loadModule(allocator: std.mem.Allocator, path: []const u8) !*WasmModule {
    return loadModuleCore(allocator, path, null);
}

/// .wasm ファイルをロードし、ホスト関数を登録してインスタンス化
pub fn loadModuleWithImports(allocator: std.mem.Allocator, path: []const u8, imports_map: Value) !*WasmModule {
    // imports_map をクロージャとして渡すため、threadlocal を使用
    pending_imports = .{ .map = imports_map, .allocator = allocator };
    defer pending_imports = null;
    return loadModuleCore(allocator, path, &registerImportsHook);
}

/// ホスト関数登録フック (threadlocal 経由で imports_map を受け取る)
const PendingImports = struct { map: Value, allocator: std.mem.Allocator };
threadlocal var pending_imports: ?PendingImports = null;

fn registerImportsHook(store: *zware.Store, module: *zware.Module) anyerror!void {
    const pi = pending_imports orelse return error.WasmInstantiateError;
    try host_functions.registerImports(store, module, pi.map, pi.allocator);
}

pub const WasmLoadError = error{
    WasmFileNotFound,
    WasmFileReadError,
    WasmDecodeError,
    WasmInstantiateError,
    OutOfMemory,
};
