//! Tracing: GC ルートトレース
//!
//! Mark-Sweep GC のルート走査と Value トレースを実装。
//! Env → Namespace → Var → Value のツリーを辿り、
//! 到達可能な全オブジェクトを GcAllocator に mark する。
//!
//! 再帰回避のため、明示的ワークスタック (gray_stack) を使用。
//! サイクル検出: gc.mark() が true を返したら既にトレース済み → スキップ。

const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const gc_alloc_mod = @import("gc_allocator.zig");
const GcAllocator = gc_alloc_mod.GcAllocator;
const ForwardingTable = gc_alloc_mod.ForwardingTable;
const gc_mod = @import("gc.zig");
const GcGlobals = gc_mod.GcGlobals;

/// GC ルートからの到達可能性トレース
/// Env 内の全 Namespace → 全 Var → root Value をトレースし、
/// GcAllocator に mark を付ける。
pub fn markRoots(gc: *GcAllocator, env: *Env, globals: GcGlobals) void {
    // ワークスタック（再帰回避）
    // backing allocator を使う（GcAllocator 経由だと自分自身を追跡してしまう）
    var gray_stack: std.ArrayListUnmanaged(Value) = .empty;
    defer gray_stack.deinit(gc.registry_alloc);

    // 1. Env → 全 Namespace → 全 Var → root + meta
    var ns_iter = env.namespaces.iterator();
    while (ns_iter.next()) |ns_entry| {
        const ns = ns_entry.value_ptr.*;
        var var_iter = ns.mappings.iterator();
        while (var_iter.next()) |var_entry| {
            const v = var_entry.value_ptr.*;
            // Var 自体を mark
            _ = gc.mark(@ptrCast(v));
            // root Value をキューに追加
            gray_stack.append(gc.registry_alloc, v.root) catch continue;
            // meta
            if (v.meta) |meta_ptr| {
                _ = gc.mark(@ptrCast(@constCast(meta_ptr)));
                gray_stack.append(gc.registry_alloc, meta_ptr.*) catch continue;
            }
            // watches
            if (v.watches) |ws| {
                for (ws) |w| gray_stack.append(gc.registry_alloc, w) catch continue;
            }
        }
        // refers も走査
        var ref_iter = ns.refers.iterator();
        while (ref_iter.next()) |ref_entry| {
            const v = ref_entry.value_ptr.*;
            _ = gc.mark(@ptrCast(v));
            gray_stack.append(gc.registry_alloc, v.root) catch continue;
            // watches (refers)
            if (v.watches) |ws| {
                for (ws) |w| gray_stack.append(gc.registry_alloc, w) catch continue;
            }
        }
    }

    // 2. グローバル階層
    if (globals.hierarchy.*) |h| {
        gray_stack.append(gc.registry_alloc, h) catch {};
    }

    // 3. グローバル taps
    if (globals.taps) |taps| {
        for (taps) |tap| {
            gray_stack.append(gc.registry_alloc, tap) catch {};
        }
    }

    // 4. 動的バインディングフレーム
    {
        const var_mod = @import("../runtime/var.zig");
        var frame = var_mod.getCurrentFrame();
        while (frame) |f| {
            for (f.entries) |entry| {
                // Var 自体は NS 経由で mark 済みなので Value のみ追加
                gray_stack.append(gc.registry_alloc, entry.value) catch {};
            }
            frame = f.prev;
        }
    }

    // ワークスタックを処理（幅優先トレース）
    while (gray_stack.items.len > 0) {
        const val = gray_stack.pop().?;
        traceValue(gc, val, &gray_stack);
    }
}

/// 単一 Value をトレースし、内部のヒープポインタを mark する。
/// 子 Value はワークスタックに追加（再帰しない）。
/// サイクル検出: gc.mark() が true を返したら既にトレース済み → スキップ。
fn traceValue(gc: *GcAllocator, val: Value, gray_stack: *std.ArrayListUnmanaged(Value)) void {
    switch (val) {
        // インライン値: ヒープ参照なし
        .nil, .bool_val, .int, .float, .char_val => {},

        .string => |s| {
            if (gc.mark(@ptrCast(s))) return;
            gc.markSlice(s.data.ptr, s.data.len);
        },

        .keyword => |k| {
            if (gc.mark(@ptrCast(k))) return;
            gc.markSlice(k.name.ptr, k.name.len);
            if (k.namespace) |ns| gc.markSlice(ns.ptr, ns.len);
        },

        .symbol => |sym| {
            if (gc.mark(@ptrCast(sym))) return;
            gc.markSlice(sym.name.ptr, sym.name.len);
            if (sym.namespace) |ns| gc.markSlice(ns.ptr, ns.len);
        },

        .list => |l| {
            if (gc.mark(@ptrCast(l))) return;
            if (l.items.len > 0) {
                gc.markSlice(@ptrCast(l.items.ptr), l.items.len * @sizeOf(Value));
                for (l.items) |item| {
                    gray_stack.append(gc.registry_alloc, item) catch {};
                }
            }
            if (l.meta) |meta| {
                _ = gc.mark(@ptrCast(@constCast(meta)));
                gray_stack.append(gc.registry_alloc, meta.*) catch {};
            }
        },

        .vector => |v| {
            if (gc.mark(@ptrCast(v))) return;
            if (v.items.len > 0) {
                gc.markSlice(@ptrCast(v.items.ptr), v.items.len * @sizeOf(Value));
                for (v.items) |item| {
                    gray_stack.append(gc.registry_alloc, item) catch {};
                }
            }
            if (v.meta) |meta| {
                _ = gc.mark(@ptrCast(@constCast(meta)));
                gray_stack.append(gc.registry_alloc, meta.*) catch {};
            }
        },

        .map => |m| {
            if (gc.mark(@ptrCast(m))) return;
            if (m.entries.len > 0) {
                gc.markSlice(@ptrCast(m.entries.ptr), m.entries.len * @sizeOf(Value));
                for (m.entries) |entry| {
                    gray_stack.append(gc.registry_alloc, entry) catch {};
                }
            }
            if (m.meta) |meta| {
                _ = gc.mark(@ptrCast(@constCast(meta)));
                gray_stack.append(gc.registry_alloc, meta.*) catch {};
            }
        },

        .set => |s| {
            if (gc.mark(@ptrCast(s))) return;
            if (s.items.len > 0) {
                gc.markSlice(@ptrCast(s.items.ptr), s.items.len * @sizeOf(Value));
                for (s.items) |item| {
                    gray_stack.append(gc.registry_alloc, item) catch {};
                }
            }
            if (s.meta) |meta| {
                _ = gc.mark(@ptrCast(@constCast(meta)));
                gray_stack.append(gc.registry_alloc, meta.*) catch {};
            }
        },

        .fn_val => |f| {
            if (gc.mark(@ptrCast(f))) return;
            // arities のスライス
            if (f.arities) |arities| {
                gc.markSlice(@ptrCast(arities.ptr), arities.len * @sizeOf(value_mod.FnArityRuntime));
            }
            // クロージャバインディング
            if (f.closure_bindings) |binds| {
                gc.markSlice(@ptrCast(binds.ptr), binds.len * @sizeOf(Value));
                for (binds) |b| {
                    gray_stack.append(gc.registry_alloc, b) catch {};
                }
            }
            // meta
            if (f.meta) |meta| {
                _ = gc.mark(@ptrCast(@constCast(meta)));
                gray_stack.append(gc.registry_alloc, meta.*) catch {};
            }
        },

        .partial_fn => |pf| {
            if (gc.mark(@ptrCast(pf))) return;
            gray_stack.append(gc.registry_alloc, pf.fn_val) catch {};
            if (pf.args.len > 0) {
                gc.markSlice(@ptrCast(pf.args.ptr), pf.args.len * @sizeOf(Value));
                for (pf.args) |arg| {
                    gray_stack.append(gc.registry_alloc, arg) catch {};
                }
            }
        },

        .comp_fn => |cf| {
            if (gc.mark(@ptrCast(cf))) return;
            if (cf.fns.len > 0) {
                gc.markSlice(@ptrCast(cf.fns.ptr), cf.fns.len * @sizeOf(Value));
                for (cf.fns) |f| {
                    gray_stack.append(gc.registry_alloc, f) catch {};
                }
            }
        },

        .multi_fn => |mf| {
            if (gc.mark(@ptrCast(mf))) return;
            gray_stack.append(gc.registry_alloc, mf.dispatch_fn) catch {};
            // methods マップ
            _ = gc.mark(@ptrCast(mf.methods));
            if (mf.methods.entries.len > 0) {
                gc.markSlice(@ptrCast(mf.methods.entries.ptr), mf.methods.entries.len * @sizeOf(Value));
                for (mf.methods.entries) |entry| {
                    gray_stack.append(gc.registry_alloc, entry) catch {};
                }
            }
            if (mf.default_method) |dm| {
                gray_stack.append(gc.registry_alloc, dm) catch {};
            }
        },

        .protocol => |p| {
            if (gc.mark(@ptrCast(p))) return;
            // impls マップ
            _ = gc.mark(@ptrCast(p.impls));
            if (p.impls.entries.len > 0) {
                gc.markSlice(@ptrCast(p.impls.entries.ptr), p.impls.entries.len * @sizeOf(Value));
                for (p.impls.entries) |entry| {
                    gray_stack.append(gc.registry_alloc, entry) catch {};
                }
            }
            // method_sigs
            if (p.method_sigs.len > 0) {
                gc.markSlice(@ptrCast(p.method_sigs.ptr), p.method_sigs.len * @sizeOf(value_mod.Protocol.MethodSig));
            }
        },

        .protocol_fn => |pf| {
            _ = gc.mark(@ptrCast(pf));
            // protocol は別途 Var 経由で mark される
        },

        .lazy_seq => |ls| {
            if (gc.mark(@ptrCast(ls))) return;
            if (ls.body_fn) |bf| {
                gray_stack.append(gc.registry_alloc, bf) catch {};
            }
            if (ls.realized) |r| {
                gray_stack.append(gc.registry_alloc, r) catch {};
            }
            if (ls.cons_head) |ch| {
                gray_stack.append(gc.registry_alloc, ch) catch {};
            }
            if (ls.cons_tail) |ct| {
                gray_stack.append(gc.registry_alloc, ct) catch {};
            }
            if (ls.transform) |t| {
                gray_stack.append(gc.registry_alloc, t.fn_val) catch {};
                gray_stack.append(gc.registry_alloc, t.source) catch {};
            }
            if (ls.concat_sources) |cs| {
                gc.markSlice(@ptrCast(cs.ptr), cs.len * @sizeOf(Value));
                for (cs) |src| {
                    gray_stack.append(gc.registry_alloc, src) catch {};
                }
            }
            if (ls.generator) |g| {
                if (g.fn_val) |fv| {
                    gray_stack.append(gc.registry_alloc, fv) catch {};
                }
                gray_stack.append(gc.registry_alloc, g.current) catch {};
                if (g.source) |src| {
                    gc.markSlice(@ptrCast(src.ptr), src.len * @sizeOf(Value));
                    for (src) |s| {
                        gray_stack.append(gc.registry_alloc, s) catch {};
                    }
                }
            }
        },

        .atom => |a| {
            if (gc.mark(@ptrCast(a))) return;
            gray_stack.append(gc.registry_alloc, a.value) catch {};
            if (a.validator) |v| {
                gray_stack.append(gc.registry_alloc, v) catch {};
            }
            if (a.watches) |w| {
                gc.markSlice(@ptrCast(w.ptr), w.len * @sizeOf(Value));
                for (w) |watch| {
                    gray_stack.append(gc.registry_alloc, watch) catch {};
                }
            }
            if (a.meta) |m| {
                gray_stack.append(gc.registry_alloc, m) catch {};
            }
        },

        .delay_val => |d| {
            if (gc.mark(@ptrCast(d))) return;
            if (d.fn_val) |fv| {
                gray_stack.append(gc.registry_alloc, fv) catch {};
            }
            if (d.cached) |c| {
                gray_stack.append(gc.registry_alloc, c) catch {};
            }
        },

        .volatile_val => |v| {
            if (gc.mark(@ptrCast(v))) return;
            gray_stack.append(gc.registry_alloc, v.value) catch {};
        },

        .reduced_val => |r| {
            if (gc.mark(@ptrCast(r))) return;
            gray_stack.append(gc.registry_alloc, r.value) catch {};
        },

        .transient => |t| {
            if (gc.mark(@ptrCast(t))) return;
            // Transient の内部 ArrayList は GcAllocator 経由で確保されているはず
            if (t.items) |items| {
                if (items.items.len > 0) {
                    gc.markSlice(@ptrCast(items.items.ptr), items.capacity * @sizeOf(Value));
                    for (items.items) |item| {
                        gray_stack.append(gc.registry_alloc, item) catch {};
                    }
                }
            }
            if (t.entries) |entries| {
                if (entries.items.len > 0) {
                    gc.markSlice(@ptrCast(entries.items.ptr), entries.capacity * @sizeOf(Value));
                    for (entries.items) |entry| {
                        gray_stack.append(gc.registry_alloc, entry) catch {};
                    }
                }
            }
        },

        .promise => |p| {
            if (gc.mark(@ptrCast(p))) return;
            if (p.value) |v| {
                gray_stack.append(gc.registry_alloc, v) catch {};
            }
        },

        // var_val は Env 経由で既にトレース済み
        .var_val => |ptr| {
            _ = gc.mark(ptr);
        },

        // fn_proto は Compiler が管理、GC 対象外
        .fn_proto => {},

        // regex: Pattern 構造体と source 文字列を mark
        .regex => |pat| {
            if (gc.mark(@ptrCast(pat))) return;
            gc.markSlice(pat.source.ptr, pat.source.len);
            // compiled は anyopaque ポインタ — mark のみ（内部は Arena で管理）
            _ = gc.mark(@ptrCast(@constCast(pat.compiled)));
        },

        .matcher => |m| {
            if (gc.mark(@ptrCast(m))) return;
            // Pattern を mark（Pattern 自体のトレースは .regex 側で行われる想定だが念のため）
            _ = gc.mark(@ptrCast(m.pattern));
            gc.markSlice(m.pattern.source.ptr, m.pattern.source.len);
            _ = gc.mark(@ptrCast(@constCast(m.pattern.compiled)));
            // input 文字列を mark
            gc.markSlice(m.input.ptr, m.input.len);
            // last_groups
            if (m.last_groups) |groups| {
                gc.markSlice(@ptrCast(groups.ptr), groups.len * @sizeOf(Value));
                for (groups) |g| {
                    gray_stack.append(gc.registry_alloc, g) catch {};
                }
            }
        },

        // wasm_module: ポインタのみ mark（内部は zware 管理）
        .wasm_module => |wm| {
            _ = gc.mark(@ptrCast(wm));
        },
    }
}

/// セミスペース GC 後のポインタ修正
/// sweep() が返した forwarding テーブルを使い、全ルートのポインタを更新する。
/// markRoots と同じルートを走査するが、mark の代わりにポインタを置換する。
pub fn fixupRoots(fwd: *ForwardingTable, alloc: std.mem.Allocator, env: *Env, globals: GcGlobals) void {
    // 処理済みポインタの記録（サイクル防止）
    var visited: std.AutoHashMapUnmanaged(*anyopaque, void) = .empty;
    defer visited.deinit(alloc);

    // 1. Env → 全 Namespace → 全 Var → root + meta
    var ns_iter = env.namespaces.iterator();
    while (ns_iter.next()) |ns_entry| {
        const ns = ns_entry.value_ptr.*;
        var var_iter = ns.mappings.iterator();
        while (var_iter.next()) |var_entry| {
            const v = var_entry.value_ptr.*;
            fixupVar(fwd, v, &visited, alloc);
        }
        var ref_iter = ns.refers.iterator();
        while (ref_iter.next()) |ref_entry| {
            const v = ref_entry.value_ptr.*;
            fixupVar(fwd, v, &visited, alloc);
        }
    }

    // 2. グローバル階層（ポインタ経由で直接書き換え）
    if (globals.hierarchy.*) |_| {
        fixupValue(fwd, &(globals.hierarchy.*).?, &visited, alloc);
    }

    // 3. グローバル taps
    if (globals.taps) |taps| {
        for (taps) |*tap| {
            fixupValue(fwd, @constCast(tap), &visited, alloc);
        }
    }

    // 4. 動的バインディングフレーム
    {
        const var_mod = @import("../runtime/var.zig");
        var frame = var_mod.getCurrentFrame();
        while (frame) |f| {
            for (f.entries) |*entry| {
                fixupValue(fwd, &entry.value, &visited, alloc);
            }
            frame = f.prev;
        }
    }
}

/// Var のポインタを修正
fn fixupVar(
    fwd: *ForwardingTable,
    v: *@import("../runtime/var.zig").Var,
    visited: *std.AutoHashMapUnmanaged(*anyopaque, void),
    alloc: std.mem.Allocator,
) void {
    fixupValue(fwd, &v.root, visited, alloc);
    if (v.meta) |meta_ptr| {
        // meta のポインタ自体を更新
        if (fwd.get(@ptrCast(@constCast(meta_ptr)))) |new_ptr| {
            v.meta = @ptrCast(@alignCast(new_ptr));
        }
        // meta の内容（Value）も更新
        if (v.meta) |new_meta| {
            fixupValue(fwd, @constCast(new_meta), visited, alloc);
        }
    }
    // watches
    if (v.watches) |_| {
        fixupOptSlice(Value, fwd, &v.watches);
        if (v.watches) |new_ws| {
            for (new_ws) |*w| {
                fixupValue(fwd, @constCast(w), visited, alloc);
            }
        }
    }
}

/// Value 内のポインタを forwarding テーブルで置換
/// val は Value のミュータブルな参照（直接書き換え）
fn fixupValue(
    fwd: *ForwardingTable,
    val: *Value,
    visited: *std.AutoHashMapUnmanaged(*anyopaque, void),
    alloc: std.mem.Allocator,
) void {
    switch (val.*) {
        .nil, .bool_val, .int, .float, .char_val => {},

        .string => |s| {
            // String 構造体のポインタを更新
            if (fwd.get(@ptrCast(s))) |new_ptr| {
                val.* = .{ .string = @ptrCast(@alignCast(new_ptr)) };
            }
            // String 内の data スライスポインタを更新
            const cur_s = val.string;
            if (visited.contains(@ptrCast(cur_s))) return;
            visited.put(alloc, @ptrCast(cur_s), {}) catch {};
            fixupSlice(u8, fwd, &cur_s.data);
        },

        .keyword => |k| {
            if (fwd.get(@ptrCast(k))) |new_ptr| {
                val.* = .{ .keyword = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.keyword;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            fixupSlice(u8, fwd, &cur.name);
            if (cur.namespace) |_| {
                fixupOptSlice(u8, fwd, &cur.namespace);
            }
        },

        .symbol => |sym| {
            if (fwd.get(@ptrCast(sym))) |new_ptr| {
                val.* = .{ .symbol = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.symbol;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            fixupSlice(u8, fwd, &cur.name);
            if (cur.namespace) |_| {
                fixupOptSlice(u8, fwd, &cur.namespace);
            }
        },

        .list => |l| {
            if (fwd.get(@ptrCast(l))) |new_ptr| {
                val.* = .{ .list = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.list;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            fixupSlice(Value, fwd, &cur.items);
            fixupValueSlice(fwd, cur.items, visited, alloc);
            fixupMetaPtr(fwd, &cur.meta, visited, alloc);
        },

        .vector => |v| {
            if (fwd.get(@ptrCast(v))) |new_ptr| {
                val.* = .{ .vector = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.vector;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            fixupSlice(Value, fwd, &cur.items);
            fixupValueSlice(fwd, cur.items, visited, alloc);
            fixupMetaPtr(fwd, &cur.meta, visited, alloc);
        },

        .map => |m| {
            if (fwd.get(@ptrCast(m))) |new_ptr| {
                val.* = .{ .map = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.map;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            fixupSlice(Value, fwd, &cur.entries);
            fixupValueSlice(fwd, cur.entries, visited, alloc);
            // hash_values / hash_index スライスも更新
            fixupSlice(u32, fwd, &cur.hash_values);
            fixupSlice(u32, fwd, &cur.hash_index);
            fixupMetaPtr(fwd, &cur.meta, visited, alloc);
        },

        .set => |s| {
            if (fwd.get(@ptrCast(s))) |new_ptr| {
                val.* = .{ .set = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.set;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            fixupSlice(Value, fwd, &cur.items);
            fixupValueSlice(fwd, cur.items, visited, alloc);
            fixupMetaPtr(fwd, &cur.meta, visited, alloc);
        },

        .fn_val => |f| {
            if (fwd.get(@ptrCast(f))) |new_ptr| {
                val.* = .{ .fn_val = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.fn_val;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            if (cur.arities) |_| {
                fixupOptSlice(value_mod.FnArityRuntime, fwd, &cur.arities);
            }
            if (cur.closure_bindings) |_| {
                fixupOptSlice(Value, fwd, &cur.closure_bindings);
                if (cur.closure_bindings) |binds| {
                    fixupValueSlice(fwd, binds, visited, alloc);
                }
            }
            if (cur.meta) |meta| {
                if (fwd.get(@ptrCast(@constCast(meta)))) |new_meta| {
                    cur.meta = @ptrCast(@alignCast(new_meta));
                }
                if (cur.meta) |new_meta| {
                    fixupValue(fwd, @constCast(new_meta), visited, alloc);
                }
            }
        },

        .partial_fn => |pf| {
            if (fwd.get(@ptrCast(pf))) |new_ptr| {
                val.* = .{ .partial_fn = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.partial_fn;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            fixupValue(fwd, &cur.fn_val, visited, alloc);
            fixupSlice(Value, fwd, &cur.args);
            fixupValueSlice(fwd, cur.args, visited, alloc);
        },

        .comp_fn => |cf| {
            if (fwd.get(@ptrCast(cf))) |new_ptr| {
                val.* = .{ .comp_fn = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.comp_fn;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            fixupSlice(Value, fwd, &cur.fns);
            fixupValueSlice(fwd, cur.fns, visited, alloc);
        },

        .multi_fn => |mf| {
            if (fwd.get(@ptrCast(mf))) |new_ptr| {
                val.* = .{ .multi_fn = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.multi_fn;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            fixupValue(fwd, &cur.dispatch_fn, visited, alloc);
            // methods マップ
            if (fwd.get(@ptrCast(cur.methods))) |new_methods| {
                cur.methods = @ptrCast(@alignCast(new_methods));
            }
            fixupSlice(Value, fwd, &cur.methods.entries);
            fixupValueSlice(fwd, cur.methods.entries, visited, alloc);
            if (cur.default_method) |_| {
                var dm = cur.default_method.?;
                fixupValue(fwd, &dm, visited, alloc);
                cur.default_method = dm;
            }
        },

        .protocol => |p| {
            if (fwd.get(@ptrCast(p))) |new_ptr| {
                val.* = .{ .protocol = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.protocol;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            if (fwd.get(@ptrCast(cur.impls))) |new_impls| {
                cur.impls = @ptrCast(@alignCast(new_impls));
            }
            fixupSlice(Value, fwd, &cur.impls.entries);
            fixupValueSlice(fwd, cur.impls.entries, visited, alloc);
            if (cur.method_sigs.len > 0) {
                fixupSlice(value_mod.Protocol.MethodSig, fwd, &cur.method_sigs);
            }
        },

        .protocol_fn => |pf| {
            if (fwd.get(@ptrCast(pf))) |new_ptr| {
                val.* = .{ .protocol_fn = @ptrCast(@alignCast(new_ptr)) };
            }
        },

        .lazy_seq => |ls| {
            if (fwd.get(@ptrCast(ls))) |new_ptr| {
                val.* = .{ .lazy_seq = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.lazy_seq;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            if (cur.body_fn) |_| fixupValue(fwd, &(cur.body_fn.?), visited, alloc);
            if (cur.realized) |_| fixupValue(fwd, &(cur.realized.?), visited, alloc);
            if (cur.cons_head) |_| fixupValue(fwd, &(cur.cons_head.?), visited, alloc);
            if (cur.cons_tail) |_| fixupValue(fwd, &(cur.cons_tail.?), visited, alloc);
            if (cur.transform) |*t| {
                fixupValue(fwd, &t.fn_val, visited, alloc);
                fixupValue(fwd, &t.source, visited, alloc);
            }
            if (cur.concat_sources) |_| {
                fixupOptSlice(Value, fwd, &cur.concat_sources);
                if (cur.concat_sources) |cs| {
                    for (cs) |*src| {
                        fixupValue(fwd, @constCast(src), visited, alloc);
                    }
                }
            }
            if (cur.generator) |*g| {
                if (g.fn_val) |_| fixupValue(fwd, &(g.fn_val.?), visited, alloc);
                fixupValue(fwd, &g.current, visited, alloc);
                if (g.source) |_| {
                    fixupOptSlice(Value, fwd, &g.source);
                    if (g.source) |src| {
                        for (src) |*s| {
                            fixupValue(fwd, @constCast(s), visited, alloc);
                        }
                    }
                }
            }
        },

        .atom => |a| {
            if (fwd.get(@ptrCast(a))) |new_ptr| {
                val.* = .{ .atom = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.atom;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            fixupValue(fwd, &cur.value, visited, alloc);
            if (cur.validator) |_| fixupValue(fwd, &(cur.validator.?), visited, alloc);
            if (cur.watches) |_| {
                fixupOptSlice(Value, fwd, &cur.watches);
                if (cur.watches) |watches| {
                    for (watches) |*w| {
                        fixupValue(fwd, @constCast(w), visited, alloc);
                    }
                }
            }
            if (cur.meta) |_| fixupValue(fwd, &(cur.meta.?), visited, alloc);
        },

        .delay_val => |d| {
            if (fwd.get(@ptrCast(d))) |new_ptr| {
                val.* = .{ .delay_val = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.delay_val;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            if (cur.fn_val) |_| fixupValue(fwd, &(cur.fn_val.?), visited, alloc);
            if (cur.cached) |_| fixupValue(fwd, &(cur.cached.?), visited, alloc);
        },

        .volatile_val => |v| {
            if (fwd.get(@ptrCast(v))) |new_ptr| {
                val.* = .{ .volatile_val = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.volatile_val;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            fixupValue(fwd, &cur.value, visited, alloc);
        },

        .reduced_val => |r| {
            if (fwd.get(@ptrCast(r))) |new_ptr| {
                val.* = .{ .reduced_val = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.reduced_val;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            fixupValue(fwd, &cur.value, visited, alloc);
        },

        .transient => |t| {
            if (fwd.get(@ptrCast(t))) |new_ptr| {
                val.* = .{ .transient = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.transient;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            // Transient 内の ArrayList バッファも fixup
            if (cur.items) |*items| {
                fixupArrayListBuf(Value, fwd, items);
                for (items.items) |*item| {
                    fixupValue(fwd, item, visited, alloc);
                }
            }
            if (cur.entries) |*entries| {
                fixupArrayListBuf(Value, fwd, entries);
                for (entries.items) |*entry| {
                    fixupValue(fwd, entry, visited, alloc);
                }
            }
        },

        .promise => |p| {
            if (fwd.get(@ptrCast(p))) |new_ptr| {
                val.* = .{ .promise = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.promise;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            if (cur.value) |_| fixupValue(fwd, &(cur.value.?), visited, alloc);
        },

        .var_val => |ptr| {
            // Var は Env (GPA) が管理するため forwarding 不要
            _ = ptr;
        },

        .fn_proto => {},

        .regex => |pat| {
            if (fwd.get(@ptrCast(pat))) |new_ptr| {
                val.* = .{ .regex = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.regex;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            fixupSlice(u8, fwd, @constCast(&cur.source));
            if (fwd.get(@ptrCast(@constCast(cur.compiled)))) |new_c| {
                cur.compiled = @ptrCast(@alignCast(new_c));
            }
        },

        .matcher => |m| {
            if (fwd.get(@ptrCast(m))) |new_ptr| {
                val.* = .{ .matcher = @ptrCast(@alignCast(new_ptr)) };
            }
            const cur = val.matcher;
            if (visited.contains(@ptrCast(cur))) return;
            visited.put(alloc, @ptrCast(cur), {}) catch {};
            // pattern ポインタ
            if (fwd.get(@ptrCast(cur.pattern))) |new_pat| {
                cur.pattern = @ptrCast(@alignCast(new_pat));
            }
            fixupSlice(u8, fwd, @constCast(&cur.input));
            if (cur.last_groups) |_| {
                fixupOptSlice(Value, fwd, &cur.last_groups);
                if (cur.last_groups) |groups| {
                    for (groups) |*g| {
                        fixupValue(fwd, @constCast(g), visited, alloc);
                    }
                }
            }
        },

        .wasm_module => |wm| {
            if (fwd.get(@ptrCast(wm))) |new_ptr| {
                val.* = .{ .wasm_module = @ptrCast(@alignCast(new_ptr)) };
            }
        },
    }
}

/// スライスの .ptr を forwarding テーブルで更新
fn fixupSlice(comptime T: type, fwd: *ForwardingTable, slice: anytype) void {
    const s = slice.*;
    if (s.len == 0) return;
    if (fwd.get(@ptrCast(@constCast(s.ptr)))) |new_ptr| {
        const new_typed: [*]const T = @ptrCast(@alignCast(new_ptr));
        slice.* = new_typed[0..s.len];
    }
}

/// optional スライスの .ptr を forwarding テーブルで更新
fn fixupOptSlice(comptime T: type, fwd: *ForwardingTable, opt_slice: anytype) void {
    if (opt_slice.*) |s| {
        if (s.len == 0) return;
        if (fwd.get(@ptrCast(@constCast(s.ptr)))) |new_ptr| {
            const new_typed: [*]const T = @ptrCast(@alignCast(new_ptr));
            opt_slice.* = new_typed[0..s.len];
        }
    }
}

/// []const Value スライスの各要素を fixup（const → mutable キャスト）
fn fixupValueSlice(
    fwd: *ForwardingTable,
    items: []const Value,
    visited: *std.AutoHashMapUnmanaged(*anyopaque, void),
    alloc: std.mem.Allocator,
) void {
    const mutable_items: []Value = @constCast(items);
    for (mutable_items) |*item| {
        fixupValue(fwd, item, visited, alloc);
    }
}

/// メタデータポインタ (?*const Value) を更新
fn fixupMetaPtr(
    fwd: *ForwardingTable,
    meta: *?*const Value,
    visited: *std.AutoHashMapUnmanaged(*anyopaque, void),
    alloc: std.mem.Allocator,
) void {
    if (meta.*) |m| {
        if (fwd.get(@ptrCast(@constCast(m)))) |new_m| {
            meta.* = @ptrCast(@alignCast(new_m));
        }
        if (meta.*) |new_m| {
            fixupValue(fwd, @constCast(new_m), visited, alloc);
        }
    }
}

/// ArrayListUnmanaged のバッファポインタを更新
fn fixupArrayListBuf(comptime T: type, fwd: *ForwardingTable, list: *std.ArrayListUnmanaged(T)) void {
    if (list.items.len == 0) return;
    if (fwd.get(@ptrCast(list.items.ptr))) |new_ptr| {
        const new_typed: [*]T = @ptrCast(@alignCast(new_ptr));
        // capacity 分のバッファとして items を再構成
        list.items.ptr = new_typed;
    }
}

// === テスト ===

test "traceValue インライン値はno-op" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gc = GcAllocator.init(gpa.allocator());
    defer gc.deinit();

    var gray_stack: std.ArrayListUnmanaged(Value) = .empty;
    defer gray_stack.deinit(gc.registry_alloc);

    // インライン値はトレースしても何も起きない
    traceValue(&gc, .nil, &gray_stack);
    traceValue(&gc, .{ .bool_val = true }, &gray_stack);
    traceValue(&gc, .{ .int = 42 }, &gray_stack);
    traceValue(&gc, .{ .float = 3.14 }, &gray_stack);
    traceValue(&gc, .{ .char_val = 'A' }, &gray_stack);

    try std.testing.expectEqual(@as(usize, 0), gray_stack.items.len);
}

test "traceValue string を mark" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gc = GcAllocator.init(gpa.allocator());
    defer gc.deinit();

    const a = gc.allocator();

    // GcAllocator 経由で String を作成
    const s = try a.create(value_mod.String);
    const data = try a.dupe(u8, "hello");
    s.* = .{ .data = data };

    const val: Value = .{ .string = s };

    var gray_stack: std.ArrayListUnmanaged(Value) = .empty;
    defer gray_stack.deinit(gc.registry_alloc);

    // mark 前は unmarked
    traceValue(&gc, val, &gray_stack);

    // sweep しても解放されない（mark 済み）
    var result = gc.sweep();
    defer result.forwarding.deinit(gpa.allocator());

    // forwarding テーブルで新ポインタを取得
    const new_s_opaque = result.forwarding.get(@ptrCast(s)).?;
    const new_s: *value_mod.String = @ptrCast(@alignCast(new_s_opaque));

    // data スライスも forwarding で更新が必要
    if (result.forwarding.get(@ptrCast(@constCast(new_s.data.ptr)))) |new_data_ptr| {
        const new_typed: [*]const u8 = @ptrCast(@alignCast(new_data_ptr));
        new_s.data = new_typed[0..new_s.data.len];
    }

    // String がまだ有効
    try std.testing.expectEqualStrings("hello", new_s.data);
}
