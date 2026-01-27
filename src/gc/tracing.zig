//! Tracing: GC ルートトレース
//!
//! Mark-Sweep GC のルート走査と Value トレースを実装。
//! Env → Namespace → Var → Value のツリーを辿り、
//! 到達可能な全オブジェクトを GcAllocator に mark する。
//!
//! 再帰回避のため、明示的ワークスタック (gray_stack) を使用。

const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const GcAllocator = @import("gc_allocator.zig").GcAllocator;
const gc_mod = @import("gc.zig");
const GcGlobals = gc_mod.GcGlobals;

/// GC ルートからの到達可能性トレース
/// Env 内の全 Namespace → 全 Var → root Value をトレースし、
/// GcAllocator に mark を付ける。
pub fn markRoots(gc: *GcAllocator, env: *Env, globals: GcGlobals) void {
    // ワークスタック（再帰回避）
    // backing allocator を使う（GcAllocator 経由だと自分自身を追跡してしまう）
    var gray_stack: std.ArrayListUnmanaged(Value) = .empty;
    defer gray_stack.deinit(gc.backing);

    // 1. Env → 全 Namespace → 全 Var → root + meta
    var ns_iter = env.namespaces.iterator();
    while (ns_iter.next()) |ns_entry| {
        const ns = ns_entry.value_ptr.*;
        var var_iter = ns.mappings.iterator();
        while (var_iter.next()) |var_entry| {
            const v = var_entry.value_ptr.*;
            // Var 自体を mark
            gc.mark(@ptrCast(v));
            // root Value をキューに追加
            gray_stack.append(gc.backing, v.root) catch continue;
            // meta
            if (v.meta) |meta_ptr| {
                gc.mark(@ptrCast(@constCast(meta_ptr)));
                gray_stack.append(gc.backing, meta_ptr.*) catch continue;
            }
        }
        // refers も走査
        var ref_iter = ns.refers.iterator();
        while (ref_iter.next()) |ref_entry| {
            const v = ref_entry.value_ptr.*;
            gc.mark(@ptrCast(v));
            gray_stack.append(gc.backing, v.root) catch continue;
        }
    }

    // 2. グローバル階層
    if (globals.hierarchy) |h| {
        gray_stack.append(gc.backing, h) catch {};
    }

    // 3. グローバル taps
    if (globals.taps) |taps| {
        for (taps) |tap| {
            gray_stack.append(gc.backing, tap) catch {};
        }
    }

    // 4. 動的バインディングフレーム
    {
        const var_mod = @import("../runtime/var.zig");
        var frame = var_mod.getCurrentFrame();
        while (frame) |f| {
            for (f.entries) |entry| {
                // Var 自体は NS 経由で mark 済みなので Value のみ追加
                gray_stack.append(gc.backing, entry.value) catch {};
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
fn traceValue(gc: *GcAllocator, val: Value, gray_stack: *std.ArrayListUnmanaged(Value)) void {
    switch (val) {
        // インライン値: ヒープ参照なし
        .nil, .bool_val, .int, .float, .char_val => {},

        .string => |s| {
            gc.mark(@ptrCast(s));
            gc.markSlice(s.data.ptr, s.data.len);
        },

        .keyword => |k| {
            gc.mark(@ptrCast(k));
            gc.markSlice(k.name.ptr, k.name.len);
            if (k.namespace) |ns| gc.markSlice(ns.ptr, ns.len);
        },

        .symbol => |sym| {
            gc.mark(@ptrCast(sym));
            gc.markSlice(sym.name.ptr, sym.name.len);
            if (sym.namespace) |ns| gc.markSlice(ns.ptr, ns.len);
        },

        .list => |l| {
            gc.mark(@ptrCast(l));
            if (l.items.len > 0) {
                gc.markSlice(@ptrCast(l.items.ptr), l.items.len * @sizeOf(Value));
                for (l.items) |item| {
                    gray_stack.append(gc.backing, item) catch {};
                }
            }
            if (l.meta) |meta| {
                gc.mark(@ptrCast(@constCast(meta)));
                gray_stack.append(gc.backing, meta.*) catch {};
            }
        },

        .vector => |v| {
            gc.mark(@ptrCast(v));
            if (v.items.len > 0) {
                gc.markSlice(@ptrCast(v.items.ptr), v.items.len * @sizeOf(Value));
                for (v.items) |item| {
                    gray_stack.append(gc.backing, item) catch {};
                }
            }
            if (v.meta) |meta| {
                gc.mark(@ptrCast(@constCast(meta)));
                gray_stack.append(gc.backing, meta.*) catch {};
            }
        },

        .map => |m| {
            gc.mark(@ptrCast(m));
            if (m.entries.len > 0) {
                gc.markSlice(@ptrCast(m.entries.ptr), m.entries.len * @sizeOf(Value));
                for (m.entries) |entry| {
                    gray_stack.append(gc.backing, entry) catch {};
                }
            }
            if (m.meta) |meta| {
                gc.mark(@ptrCast(@constCast(meta)));
                gray_stack.append(gc.backing, meta.*) catch {};
            }
        },

        .set => |s| {
            gc.mark(@ptrCast(s));
            if (s.items.len > 0) {
                gc.markSlice(@ptrCast(s.items.ptr), s.items.len * @sizeOf(Value));
                for (s.items) |item| {
                    gray_stack.append(gc.backing, item) catch {};
                }
            }
            if (s.meta) |meta| {
                gc.mark(@ptrCast(@constCast(meta)));
                gray_stack.append(gc.backing, meta.*) catch {};
            }
        },

        .fn_val => |f| {
            gc.mark(@ptrCast(f));
            // arities のスライス
            if (f.arities) |arities| {
                gc.markSlice(@ptrCast(arities.ptr), arities.len * @sizeOf(value_mod.FnArityRuntime));
            }
            // クロージャバインディング
            if (f.closure_bindings) |binds| {
                gc.markSlice(@ptrCast(binds.ptr), binds.len * @sizeOf(Value));
                for (binds) |b| {
                    gray_stack.append(gc.backing, b) catch {};
                }
            }
            // meta
            if (f.meta) |meta| {
                gc.mark(@ptrCast(@constCast(meta)));
                gray_stack.append(gc.backing, meta.*) catch {};
            }
        },

        .partial_fn => |pf| {
            gc.mark(@ptrCast(pf));
            gray_stack.append(gc.backing, pf.fn_val) catch {};
            if (pf.args.len > 0) {
                gc.markSlice(@ptrCast(pf.args.ptr), pf.args.len * @sizeOf(Value));
                for (pf.args) |arg| {
                    gray_stack.append(gc.backing, arg) catch {};
                }
            }
        },

        .comp_fn => |cf| {
            gc.mark(@ptrCast(cf));
            if (cf.fns.len > 0) {
                gc.markSlice(@ptrCast(cf.fns.ptr), cf.fns.len * @sizeOf(Value));
                for (cf.fns) |f| {
                    gray_stack.append(gc.backing, f) catch {};
                }
            }
        },

        .multi_fn => |mf| {
            gc.mark(@ptrCast(mf));
            gray_stack.append(gc.backing, mf.dispatch_fn) catch {};
            // methods マップ
            gc.mark(@ptrCast(mf.methods));
            if (mf.methods.entries.len > 0) {
                gc.markSlice(@ptrCast(mf.methods.entries.ptr), mf.methods.entries.len * @sizeOf(Value));
                for (mf.methods.entries) |entry| {
                    gray_stack.append(gc.backing, entry) catch {};
                }
            }
            if (mf.default_method) |dm| {
                gray_stack.append(gc.backing, dm) catch {};
            }
        },

        .protocol => |p| {
            gc.mark(@ptrCast(p));
            // impls マップ
            gc.mark(@ptrCast(p.impls));
            if (p.impls.entries.len > 0) {
                gc.markSlice(@ptrCast(p.impls.entries.ptr), p.impls.entries.len * @sizeOf(Value));
                for (p.impls.entries) |entry| {
                    gray_stack.append(gc.backing, entry) catch {};
                }
            }
            // method_sigs
            if (p.method_sigs.len > 0) {
                gc.markSlice(@ptrCast(p.method_sigs.ptr), p.method_sigs.len * @sizeOf(value_mod.Protocol.MethodSig));
            }
        },

        .protocol_fn => |pf| {
            gc.mark(@ptrCast(pf));
            // protocol は別途 Var 経由で mark される
        },

        .lazy_seq => |ls| {
            gc.mark(@ptrCast(ls));
            if (ls.body_fn) |bf| {
                gray_stack.append(gc.backing, bf) catch {};
            }
            if (ls.realized) |r| {
                gray_stack.append(gc.backing, r) catch {};
            }
            if (ls.cons_head) |ch| {
                gray_stack.append(gc.backing, ch) catch {};
            }
            if (ls.cons_tail) |ct| {
                gray_stack.append(gc.backing, ct) catch {};
            }
            if (ls.transform) |t| {
                gray_stack.append(gc.backing, t.fn_val) catch {};
                gray_stack.append(gc.backing, t.source) catch {};
            }
            if (ls.concat_sources) |cs| {
                gc.markSlice(@ptrCast(cs.ptr), cs.len * @sizeOf(Value));
                for (cs) |src| {
                    gray_stack.append(gc.backing, src) catch {};
                }
            }
            if (ls.generator) |g| {
                if (g.fn_val) |fv| {
                    gray_stack.append(gc.backing, fv) catch {};
                }
                gray_stack.append(gc.backing, g.current) catch {};
                if (g.source) |src| {
                    gc.markSlice(@ptrCast(src.ptr), src.len * @sizeOf(Value));
                    for (src) |s| {
                        gray_stack.append(gc.backing, s) catch {};
                    }
                }
            }
        },

        .atom => |a| {
            gc.mark(@ptrCast(a));
            gray_stack.append(gc.backing, a.value) catch {};
            if (a.validator) |v| {
                gray_stack.append(gc.backing, v) catch {};
            }
            if (a.watches) |w| {
                gc.markSlice(@ptrCast(w.ptr), w.len * @sizeOf(Value));
                for (w) |watch| {
                    gray_stack.append(gc.backing, watch) catch {};
                }
            }
            if (a.meta) |m| {
                gray_stack.append(gc.backing, m) catch {};
            }
        },

        .delay_val => |d| {
            gc.mark(@ptrCast(d));
            if (d.fn_val) |fv| {
                gray_stack.append(gc.backing, fv) catch {};
            }
            if (d.cached) |c| {
                gray_stack.append(gc.backing, c) catch {};
            }
        },

        .volatile_val => |v| {
            gc.mark(@ptrCast(v));
            gray_stack.append(gc.backing, v.value) catch {};
        },

        .reduced_val => |r| {
            gc.mark(@ptrCast(r));
            gray_stack.append(gc.backing, r.value) catch {};
        },

        .transient => |t| {
            gc.mark(@ptrCast(t));
            // Transient の内部 ArrayList は GcAllocator 経由で確保されているはず
            if (t.items) |items| {
                if (items.items.len > 0) {
                    gc.markSlice(@ptrCast(items.items.ptr), items.capacity * @sizeOf(Value));
                    for (items.items) |item| {
                        gray_stack.append(gc.backing, item) catch {};
                    }
                }
            }
            if (t.entries) |entries| {
                if (entries.items.len > 0) {
                    gc.markSlice(@ptrCast(entries.items.ptr), entries.capacity * @sizeOf(Value));
                    for (entries.items) |entry| {
                        gray_stack.append(gc.backing, entry) catch {};
                    }
                }
            }
        },

        .promise => |p| {
            gc.mark(@ptrCast(p));
            if (p.value) |v| {
                gray_stack.append(gc.backing, v) catch {};
            }
        },

        // var_val は Env 経由で既にトレース済み
        .var_val => |ptr| {
            gc.mark(ptr);
        },

        // fn_proto は Compiler が管理、GC 対象外
        .fn_proto => {},

        // regex: Pattern 構造体と source 文字列を mark
        .regex => |pat| {
            gc.mark(@ptrCast(pat));
            gc.markSlice(pat.source.ptr, pat.source.len);
            // compiled は anyopaque ポインタ — mark のみ（内部は Arena で管理）
            gc.mark(@ptrCast(@constCast(pat.compiled)));
        },

        .matcher => |m| {
            gc.mark(@ptrCast(m));
            // Pattern を mark（Pattern 自体のトレースは .regex 側で行われる想定だが念のため）
            gc.mark(@ptrCast(m.pattern));
            gc.markSlice(m.pattern.source.ptr, m.pattern.source.len);
            gc.mark(@ptrCast(@constCast(m.pattern.compiled)));
            // input 文字列を mark
            gc.markSlice(m.input.ptr, m.input.len);
            // last_groups
            if (m.last_groups) |groups| {
                gc.markSlice(@ptrCast(groups.ptr), groups.len * @sizeOf(Value));
                for (groups) |g| {
                    gray_stack.append(gc.backing, g) catch {};
                }
            }
        },
    }
}

// === テスト ===

test "traceValue インライン値はno-op" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var gc = GcAllocator.init(gpa.allocator());
    defer gc.deinit();

    var gray_stack: std.ArrayListUnmanaged(Value) = .empty;
    defer gray_stack.deinit(gc.backing);

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
    defer gray_stack.deinit(gc.backing);

    // mark 前は unmarked
    traceValue(&gc, val, &gray_stack);

    // sweep しても解放されない（mark 済み）
    gc.sweep();

    // String がまだ有効
    try std.testing.expectEqualStrings("hello", s.data);
}
