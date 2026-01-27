//! WASI Preview 1 サポート
//!
//! zware 内蔵の WASI 関数を Store に登録し、
//! WASI モジュールのロード・実行を可能にする。

const std = @import("std");
const zware = @import("zware");
const value_mod = @import("../runtime/value.zig");
const WasmModule = value_mod.WasmModule;

/// 最大ファイルサイズ (10MB)
const MAX_FILE_SIZE = 10 * 1024 * 1024;

/// WASI 関数名 → zware 実装のマッピング
const WasiEntry = struct {
    name: []const u8,
    func: *const fn (*zware.VirtualMachine) zware.WasmError!void,
};

const wasi_functions = [_]WasiEntry{
    .{ .name = "args_get", .func = &zware.wasi.args_get },
    .{ .name = "args_sizes_get", .func = &zware.wasi.args_sizes_get },
    .{ .name = "environ_get", .func = &zware.wasi.environ_get },
    .{ .name = "environ_sizes_get", .func = &zware.wasi.environ_sizes_get },
    .{ .name = "clock_time_get", .func = &zware.wasi.clock_time_get },
    .{ .name = "fd_close", .func = &zware.wasi.fd_close },
    .{ .name = "fd_fdstat_get", .func = &zware.wasi.fd_fdstat_get },
    .{ .name = "fd_filestat_get", .func = &zware.wasi.fd_filestat_get },
    .{ .name = "fd_prestat_get", .func = &zware.wasi.fd_prestat_get },
    .{ .name = "fd_prestat_dir_name", .func = &zware.wasi.fd_prestat_dir_name },
    .{ .name = "fd_read", .func = &zware.wasi.fd_read },
    .{ .name = "fd_seek", .func = &zware.wasi.fd_seek },
    .{ .name = "fd_write", .func = &zware.wasi.fd_write },
    .{ .name = "fd_tell", .func = &zware.wasi.fd_tell },
    .{ .name = "fd_readdir", .func = &zware.wasi.fd_readdir },
    .{ .name = "path_filestat_get", .func = &zware.wasi.path_filestat_get },
    .{ .name = "path_open", .func = &zware.wasi.path_open },
    .{ .name = "proc_exit", .func = &zware.wasi.proc_exit },
    .{ .name = "random_get", .func = &zware.wasi.random_get },
};

/// WASI 関数名から zware 実装を検索
fn lookupWasiFunc(name: []const u8) ?*const fn (*zware.VirtualMachine) zware.WasmError!void {
    for (wasi_functions) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.func;
    }
    return null;
}

/// モジュールのインポートを走査し、WASI 関数を Store に登録
fn registerWasiFunctions(store: *zware.Store, module: *zware.Module) !void {
    for (module.imports.list.items, 0..) |imp, import_idx| {
        if (imp.desc_tag != .Func) continue;
        if (!std.mem.eql(u8, imp.module, "wasi_snapshot_preview1")) continue;

        const wasi_fn = lookupWasiFunc(imp.name) orelse {
            return error.WasmWasiUnsupported;
        };

        // 型情報を取得
        const func_entry = module.functions.lookup(import_idx) catch {
            return error.WasmDecodeError;
        };
        const functype = module.types.lookup(func_entry.typeidx) catch {
            return error.WasmDecodeError;
        };

        // zware.wasi 関数は *const fn(*VM) WasmError!void 型だが、
        // exposeHostFunction は *const fn(*VM, usize) WasmError!void を要求する。
        // @ptrCast で変換（zware 内部では context 引数を無視する形で動作）
        store.exposeHostFunction(
            imp.module,
            imp.name,
            @ptrCast(wasi_fn),
            0,
            functype.params,
            functype.results,
        ) catch {
            return error.WasmInstantiateError;
        };
    }
}

/// WASI モジュールをロードしてインスタンス化
pub fn loadWasiModule(allocator: std.mem.Allocator, path: []const u8) !*WasmModule {
    // 1. ファイル読み込み
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return error.WasmFileNotFound;
    };
    defer file.close();

    const bytes = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch {
        return error.WasmFileReadError;
    };

    // 2. Store
    const store = try allocator.create(zware.Store);
    store.* = zware.Store.init(allocator);

    // 3. Module デコード
    const module = try allocator.create(zware.Module);
    module.* = zware.Module.init(allocator, bytes);
    module.decode() catch {
        return error.WasmDecodeError;
    };

    // 4. WASI 関数を登録
    try registerWasiFunctions(store, module);

    // 5. Instance
    const instance = try allocator.create(zware.Instance);
    instance.* = zware.Instance.init(allocator, store, module.*);
    instance.instantiate() catch {
        return error.WasmInstantiateError;
    };

    // 6. WasmModule 構造体
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

pub const WasiError = error{
    WasmFileNotFound,
    WasmFileReadError,
    WasmDecodeError,
    WasmInstantiateError,
    WasmWasiUnsupported,
    OutOfMemory,
};
