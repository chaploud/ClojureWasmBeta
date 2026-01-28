//! Wasm ホスト関数ブリッジ
//!
//! Clojure 関数を zware ホスト関数として登録する。
//! グローバルコンテキストテーブルでコールバック情報を管理し、
//! 汎用トランポリン関数で Clojure ↔ Wasm 間の呼び出しを仲介する。

const std = @import("std");
const zware = @import("zware");
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const core = @import("../lib/core.zig");
const wasm_types = @import("types.zig");

/// ホスト関数コンテキスト
const HostContext = struct {
    clj_fn: Value,
    param_count: u32,
    result_count: u32,
    allocator: std.mem.Allocator,
};

/// グローバルコンテキストテーブル (最大 256 ホスト関数)
const MAX_CONTEXTS = 256;
var host_contexts: [MAX_CONTEXTS]?HostContext = [_]?HostContext{null} ** MAX_CONTEXTS;
var next_context_id: usize = 0;

/// コンテキストスロットを割り当て
fn allocContext(ctx: HostContext) !usize {
    // 空きスロットを探す
    var id = next_context_id;
    var tried: usize = 0;
    while (tried < MAX_CONTEXTS) : ({
        id = (id + 1) % MAX_CONTEXTS;
        tried += 1;
    }) {
        if (host_contexts[id] == null) {
            host_contexts[id] = ctx;
            next_context_id = (id + 1) % MAX_CONTEXTS;
            return id;
        }
    }
    return error.WasmHostContextFull;
}

/// 汎用トランポリン: zware から呼ばれ、Clojure 関数を実行
fn hostTrampoline(vm: *zware.VirtualMachine, context_id: usize) zware.WasmError!void {
    const ctx = host_contexts[context_id] orelse return zware.WasmError.Trap;

    const call = core.getCallFn() orelse return zware.WasmError.Trap;

    // VM スタックから引数を pop（逆順で取り出されるので反転が必要）
    var args_buf: [16]Value = undefined;
    const param_count = ctx.param_count;
    if (param_count > 16) return zware.WasmError.Trap;

    // pop は後ろの引数から取り出す
    var i: u32 = param_count;
    while (i > 0) {
        i -= 1;
        const raw = vm.popAnyOperand();
        args_buf[i] = wasm_types.wasmI32ToValue(raw);
    }

    // Clojure 関数を呼び出し
    const result = call(ctx.clj_fn, args_buf[0..param_count], ctx.allocator) catch {
        return zware.WasmError.Trap;
    };

    // 結果をスタックに push
    if (ctx.result_count > 0) {
        const raw = wasm_types.valueToWasmU64(result) catch {
            return zware.WasmError.Trap;
        };
        vm.pushOperand(u64, raw) catch {
            return zware.WasmError.Trap;
        };
    }
}

/// Wasm モジュールのインポートに対して Clojure 関数を登録
/// imports_map: Clojure マップ {module_name {func_name clj_fn}}
pub fn registerImports(
    store: *zware.Store,
    module: *zware.Module,
    imports_map: Value,
    allocator: std.mem.Allocator,
) !void {
    // imports_map は PersistentMap: {"env" {"print_i32" (fn [n] ...)}}
    const map = switch (imports_map) {
        .map => |m| m,
        else => return error.TypeError,
    };

    // モジュールのインポートセクションを走査
    for (module.imports.list.items, 0..) |imp, import_idx| {
        if (imp.desc_tag != .Func) continue;

        // インポートの型情報を取得
        const func_entry = module.functions.lookup(import_idx) catch continue;
        const functype = module.types.lookup(func_entry.typeidx) catch continue;

        // imports_map からモジュール名→関数名で Clojure 関数を検索
        const clj_fn = lookupImportFn(map, imp.module, imp.name) orelse continue;

        // コンテキストを割り当て
        const ctx_id = try allocContext(.{
            .clj_fn = clj_fn,
            .param_count = @intCast(functype.params.len),
            .result_count = @intCast(functype.results.len),
            .allocator = allocator,
        });

        // zware にホスト関数を登録
        store.exposeHostFunction(
            imp.module,
            imp.name,
            &hostTrampoline,
            ctx_id,
            functype.params,
            functype.results,
        ) catch {
            // スロットを解放
            host_contexts[ctx_id] = null;
            return error.WasmHostRegisterError;
        };
    }
}

/// imports マップから Clojure 関数を検索
/// map: {"env" {"print_i32" (fn ...)}}
fn lookupImportFn(map: *const value_mod.PersistentMap, module_name: []const u8, func_name: []const u8) ?Value {
    // 外側マップからモジュール名でサブマップを検索
    const entries = map.entries;
    var idx: usize = 0;
    while (idx + 1 < entries.len) : (idx += 2) {
        const key = entries[idx];
        const val = entries[idx + 1];

        // キーは文字列
        const key_str = switch (key) {
            .string => |s| s.data,
            else => continue,
        };

        if (!std.mem.eql(u8, key_str, module_name)) continue;

        // val はサブマップ {"func_name" clj_fn}
        const sub_map = switch (val) {
            .map => |m| m,
            else => return null,
        };

        // サブマップから関数名で検索
        const sub_entries = sub_map.entries;
        var j: usize = 0;
        while (j + 1 < sub_entries.len) : (j += 2) {
            const fkey = sub_entries[j];
            const fval = sub_entries[j + 1];

            const fkey_str = switch (fkey) {
                .string => |s| s.data,
                else => continue,
            };

            if (std.mem.eql(u8, fkey_str, func_name)) {
                return fval;
            }
        }
        return null;
    }
    return null;
}

pub const HostFunctionError = error{
    WasmHostContextFull,
    WasmHostRegisterError,
    TypeError,
    OutOfMemory,
};
