//! Evaluator: ツリーウォーク評価器
//!
//! Node を実行して Value を返す。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md

const std = @import("std");
const node_mod = @import("../analyzer/node.zig");
const Node = node_mod.Node;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const context_mod = @import("context.zig");
const Context = context_mod.Context;
const env_mod = @import("env.zig");
const Env = env_mod.Env;
const var_mod = @import("var.zig");
const Var = var_mod.Var;
const err = @import("../base/error.zig");
const core = @import("../lib/core.zig");

/// 評価エラー
pub const EvalError = error{
    TypeError,
    ArityError,
    UndefinedSymbol,
    DivisionByZero,
    RecurOutsideLoop,
    OutOfMemory,
};

/// Node を評価
pub fn run(node: *const Node, ctx: *Context) EvalError!Value {
    return switch (node.*) {
        .constant => |val| val,
        .var_ref => |ref| ref.var_ref.deref(),
        .local_ref => |ref| ctx.getLocal(ref.idx) orelse return error.UndefinedSymbol,
        .if_node => |n| runIf(n, ctx),
        .do_node => |n| runDo(n, ctx),
        .let_node => |n| runLet(n, ctx),
        .loop_node => |n| runLoop(n, ctx),
        .recur_node => |n| runRecur(n, ctx),
        .fn_node => |n| runFn(n, ctx),
        .call_node => |n| runCall(n, ctx),
        .def_node => |n| runDef(n, ctx),
        .quote_node => |n| n.form,
        .throw_node => return error.TypeError, // TODO: 例外処理
        .apply_node => |n| runApply(n, ctx),
        .partial_node => |n| runPartial(n, ctx),
        .comp_node => |n| runComp(n, ctx),
        .reduce_node => |n| runReduce(n, ctx),
    };
}

/// if 評価
fn runIf(node: *const node_mod.IfNode, ctx: *Context) EvalError!Value {
    const test_val = try run(node.test_node, ctx);
    if (test_val.isTruthy()) {
        return run(node.then_node, ctx);
    } else if (node.else_node) |else_n| {
        return run(else_n, ctx);
    } else {
        return value_mod.nil;
    }
}

/// do 評価
fn runDo(node: *const node_mod.DoNode, ctx: *Context) EvalError!Value {
    var result: Value = value_mod.nil;
    for (node.statements) |stmt| {
        result = try run(stmt, ctx);
        // recur が発生したら即座に返す
        if (ctx.hasRecur()) return result;
    }
    return result;
}

/// let 評価
fn runLet(node: *const node_mod.LetNode, ctx: *Context) EvalError!Value {
    // バインディングの値を評価
    var binding_vals = ctx.allocator.alloc(Value, node.bindings.len) catch return error.OutOfMemory;
    for (node.bindings, 0..) |binding, i| {
        binding_vals[i] = try run(binding.init, ctx);
    }

    // 新しいコンテキストでボディを評価
    var new_ctx = ctx.withBindings(binding_vals) catch return error.OutOfMemory;
    return run(node.body, &new_ctx);
}

/// loop 評価
fn runLoop(node: *const node_mod.LoopNode, ctx: *Context) EvalError!Value {
    // 初期バインディングの値を評価
    var binding_vals = ctx.allocator.alloc(Value, node.bindings.len) catch return error.OutOfMemory;
    for (node.bindings, 0..) |binding, i| {
        binding_vals[i] = try run(binding.init, ctx);
    }

    const start_idx = ctx.bindings.len;
    var loop_ctx = ctx.withBindings(binding_vals) catch return error.OutOfMemory;

    // loop 本体を繰り返し評価
    while (true) {
        loop_ctx.clearRecur();
        const result = try run(node.body, &loop_ctx);

        if (loop_ctx.hasRecur()) {
            // recur の値で再バインド
            const recur_vals = loop_ctx.recur_values.?.values;
            loop_ctx = loop_ctx.replaceBindings(start_idx, recur_vals) catch return error.OutOfMemory;
            continue;
        }

        return result;
    }
}

/// recur 評価
fn runRecur(node: *const node_mod.RecurNode, ctx: *Context) EvalError!Value {
    // 引数を評価
    var vals = ctx.allocator.alloc(Value, node.args.len) catch return error.OutOfMemory;
    for (node.args, 0..) |arg, i| {
        vals[i] = try run(arg, ctx);
    }

    // recur フラグを設定
    ctx.setRecur(vals);
    return value_mod.nil;
}

/// fn 評価（クロージャ作成）
fn runFn(node: *const node_mod.FnNode, ctx: *Context) EvalError!Value {
    // FnNode の arities を FnArityRuntime に変換
    const runtime_arities = ctx.allocator.alloc(value_mod.FnArityRuntime, node.arities.len) catch return error.OutOfMemory;
    for (node.arities, 0..) |arity, i| {
        runtime_arities[i] = .{
            .params = arity.params,
            .variadic = arity.variadic,
            .body = @ptrCast(@constCast(arity.body)),
        };
    }

    // クロージャ環境をキャプチャ
    const closure_bindings = if (ctx.bindings.len > 0)
        ctx.allocator.dupe(Value, ctx.bindings) catch return error.OutOfMemory
    else
        null;

    // Fn オブジェクトを作成
    const fn_obj = ctx.allocator.create(value_mod.Fn) catch return error.OutOfMemory;
    fn_obj.* = value_mod.Fn.initUser(node.name, runtime_arities, closure_bindings);

    return Value{ .fn_val = fn_obj };
}

/// call 評価
fn runCall(node: *const node_mod.CallNode, ctx: *Context) EvalError!Value {
    // 関数を評価
    const fn_val = try run(node.fn_node, ctx);

    // 引数を評価
    const args = ctx.allocator.alloc(Value, node.args.len) catch return error.OutOfMemory;
    for (node.args, 0..) |arg, i| {
        args[i] = try run(arg, ctx);
    }

    // 関数を呼び出し
    return callWithArgs(fn_val, args, ctx);
}

/// 関数を引数付きで呼び出し（partial_fn サポート付き）
fn callWithArgs(fn_val: Value, args: []const Value, ctx: *Context) EvalError!Value {
    return switch (fn_val) {
        .fn_val => |f| blk: {
            // 組み込み関数
            if (f.builtin) |builtin_ptr| {
                // anyopaque から BuiltinFn にキャスト
                const builtin: core.BuiltinFn = @ptrCast(@alignCast(builtin_ptr));
                break :blk builtin(ctx.allocator, args) catch return error.TypeError;
            }

            // ユーザー定義関数
            const arity = f.findArity(args.len) orelse return error.ArityError;

            // 新しいコンテキストを作成
            var fn_ctx = Context.init(ctx.allocator, ctx.env);

            // クロージャ環境をバインド
            if (f.closure_bindings) |bindings| {
                fn_ctx = fn_ctx.withBindings(bindings) catch return error.OutOfMemory;
            }

            // 引数をバインド
            if (arity.variadic) {
                // 可変長: 固定引数 + rest リスト
                const fixed_count = arity.params.len - 1; // rest パラメータを除く

                // 固定引数 + rest リスト用に params.len 個のバインディングを作成
                var bindings_arr = ctx.allocator.alloc(Value, arity.params.len) catch return error.OutOfMemory;

                // 固定引数をコピー
                @memcpy(bindings_arr[0..fixed_count], args[0..fixed_count]);

                // 残りの引数をリストにまとめる
                const rest_list = value_mod.PersistentList.fromSlice(ctx.allocator, args[fixed_count..]) catch return error.OutOfMemory;
                bindings_arr[fixed_count] = Value{ .list = rest_list };

                fn_ctx = fn_ctx.withBindings(bindings_arr) catch return error.OutOfMemory;
            } else {
                // 固定アリティ: 引数をそのままバインド
                fn_ctx = fn_ctx.withBindings(args) catch return error.OutOfMemory;
            }

            // ボディを評価
            const body: *const Node = @ptrCast(@alignCast(arity.body));
            break :blk run(body, &fn_ctx);
        },
        .partial_fn => |p| blk: {
            // partial_fn: 部分適用された引数と新しい引数を結合
            const total_len = p.args.len + args.len;
            var all_args = ctx.allocator.alloc(Value, total_len) catch return error.OutOfMemory;
            @memcpy(all_args[0..p.args.len], p.args);
            @memcpy(all_args[p.args.len..], args);

            // 元の関数を呼び出し（再帰的にpartial_fnもサポート）
            break :blk callWithArgs(p.fn_val, all_args, ctx);
        },
        .comp_fn => |c| blk: {
            // comp_fn: 右から左へ関数を適用
            // ((comp f g h) x) => (f (g (h x)))
            if (c.fns.len == 0) {
                // (comp) は identity、最初の引数を返す
                if (args.len > 0) break :blk args[0];
                break :blk value_mod.nil;
            }

            // 最後の関数に引数を適用
            var result = try callWithArgs(c.fns[c.fns.len - 1], args, ctx);

            // 残りの関数を右から左へ適用（1引数で呼び出し）
            var i = c.fns.len - 1;
            while (i > 0) {
                i -= 1;
                const single_arg = ctx.allocator.alloc(Value, 1) catch return error.OutOfMemory;
                single_arg[0] = result;
                result = try callWithArgs(c.fns[i], single_arg, ctx);
            }

            break :blk result;
        },
        else => error.TypeError,
    };
}

/// def 評価
fn runDef(node: *const node_mod.DefNode, ctx: *Context) EvalError!Value {
    const ns = ctx.env.getCurrentNs() orelse return error.UndefinedSymbol;
    const v = ns.intern(node.sym_name) catch return error.OutOfMemory;

    if (node.init) |init_node| {
        const val = try run(init_node, ctx);
        v.bindRoot(val);
    }

    // マクロフラグを設定
    if (node.is_macro) {
        v.setMacro(true);
    }

    // Var を返す（#'var 形式）
    // TODO: Var を Value に含める
    return value_mod.nil;
}

/// apply 評価
/// (apply f args) または (apply f x y z args)
fn runApply(node: *const node_mod.ApplyNode, ctx: *Context) EvalError!Value {
    // 関数を評価
    const fn_val = try run(node.fn_node, ctx);

    // 中間引数を評価
    var middle_vals = ctx.allocator.alloc(Value, node.args.len) catch return error.OutOfMemory;
    for (node.args, 0..) |arg, i| {
        middle_vals[i] = try run(arg, ctx);
    }

    // シーケンス引数を評価
    const seq_val = try run(node.seq_node, ctx);

    // シーケンスから要素を抽出
    const seq_items: []const Value = switch (seq_val) {
        .list => |l| l.items,
        .vector => |v| v.items,
        .nil => &[_]Value{}, // nil は空シーケンス
        else => return error.TypeError,
    };

    // 全引数を結合
    const total_len = middle_vals.len + seq_items.len;
    var all_args = ctx.allocator.alloc(Value, total_len) catch return error.OutOfMemory;
    @memcpy(all_args[0..middle_vals.len], middle_vals);
    @memcpy(all_args[middle_vals.len..], seq_items);

    // 関数を呼び出し（partial_fn もサポート）
    return callWithArgs(fn_val, all_args, ctx);
}

/// partial 評価
fn runPartial(node: *const node_mod.PartialNode, ctx: *Context) EvalError!Value {
    // 関数を評価
    const fn_val = try run(node.fn_node, ctx);

    // 引数を評価
    var partial_args = ctx.allocator.alloc(Value, node.args.len) catch return error.OutOfMemory;
    for (node.args, 0..) |arg, i| {
        partial_args[i] = try run(arg, ctx);
    }

    // PartialFn を作成
    const partial_fn = ctx.allocator.create(value_mod.PartialFn) catch return error.OutOfMemory;
    partial_fn.* = .{
        .fn_val = fn_val,
        .args = partial_args,
    };

    return Value{ .partial_fn = partial_fn };
}

/// comp 評価
fn runComp(node: *const node_mod.CompNode, ctx: *Context) EvalError!Value {
    // (comp) => identity を返す
    // (comp f) => f を返す
    // (comp f g h ...) => CompFn を作成

    // 0引数の場合は identity を返す
    if (node.fns.len == 0) {
        // identity 関数をビルトインから取得（なければエラー）
        // 簡易実装: identity 相当の fn を作成する代わりに nil を返す
        // TODO: 実際の identity 実装
        return value_mod.nil;
    }

    // 1引数の場合はその関数を返す
    if (node.fns.len == 1) {
        return try run(node.fns[0], ctx);
    }

    // 関数を評価
    var fns = ctx.allocator.alloc(Value, node.fns.len) catch return error.OutOfMemory;
    for (node.fns, 0..) |fn_node, i| {
        fns[i] = try run(fn_node, ctx);
    }

    // CompFn を作成
    const comp_fn = ctx.allocator.create(value_mod.CompFn) catch return error.OutOfMemory;
    comp_fn.* = .{
        .fns = fns,
    };

    return Value{ .comp_fn = comp_fn };
}

/// reduce 評価
/// (reduce f coll) または (reduce f init coll)
fn runReduce(node: *const node_mod.ReduceNode, ctx: *Context) EvalError!Value {
    // 関数を評価
    const fn_val = try run(node.fn_node, ctx);

    // コレクションを評価
    const coll_val = try run(node.coll_node, ctx);

    // コレクションから要素を取得
    const items: []const Value = switch (coll_val) {
        .list => |l| l.items,
        .vector => |v| v.items,
        .nil => &[_]Value{}, // nil は空シーケンス
        else => return error.TypeError,
    };

    // 初期値を決定
    var acc: Value = undefined;
    var start_idx: usize = 0;

    if (node.init_node) |init_n| {
        // (reduce f init coll) - 初期値あり
        acc = try run(init_n, ctx);
    } else {
        // (reduce f coll) - 初期値なし、最初の要素を使用
        if (items.len == 0) {
            // 空コレクションで初期値なしは (f) を呼び出す
            const empty_args = ctx.allocator.alloc(Value, 0) catch return error.OutOfMemory;
            return callWithArgs(fn_val, empty_args, ctx);
        }
        acc = items[0];
        start_idx = 1;
    }

    // 畳み込みを実行
    for (items[start_idx..]) |item| {
        const args = ctx.allocator.alloc(Value, 2) catch return error.OutOfMemory;
        args[0] = acc;
        args[1] = item;
        acc = try callWithArgs(fn_val, args, ctx);
    }

    return acc;
}

// === テスト ===

test "run constant" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    var ctx = Context.init(allocator, &env);

    var node = Node{ .constant = value_mod.intVal(42) };
    const result = try run(&node, &ctx);
    try std.testing.expect(result.eql(value_mod.intVal(42)));
}

test "run if true" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    var ctx = Context.init(allocator, &env);

    var test_node = Node{ .constant = value_mod.true_val };
    var then_node = Node{ .constant = value_mod.intVal(1) };
    var else_node = Node{ .constant = value_mod.intVal(2) };

    var if_data = node_mod.IfNode{
        .test_node = &test_node,
        .then_node = &then_node,
        .else_node = &else_node,
        .stack = .{},
    };

    var node = Node{ .if_node = &if_data };
    const result = try run(&node, &ctx);
    try std.testing.expect(result.eql(value_mod.intVal(1)));
}

test "run if false" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    var ctx = Context.init(allocator, &env);

    var test_node = Node{ .constant = value_mod.false_val };
    var then_node = Node{ .constant = value_mod.intVal(1) };
    var else_node = Node{ .constant = value_mod.intVal(2) };

    var if_data = node_mod.IfNode{
        .test_node = &test_node,
        .then_node = &then_node,
        .else_node = &else_node,
        .stack = .{},
    };

    var node = Node{ .if_node = &if_data };
    const result = try run(&node, &ctx);
    try std.testing.expect(result.eql(value_mod.intVal(2)));
}

test "run do" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    var ctx = Context.init(allocator, &env);

    var stmt1 = Node{ .constant = value_mod.intVal(1) };
    var stmt2 = Node{ .constant = value_mod.intVal(2) };
    var stmt3 = Node{ .constant = value_mod.intVal(3) };

    const stmts = [_]*Node{ &stmt1, &stmt2, &stmt3 };

    var do_data = node_mod.DoNode{
        .statements = &stmts,
        .stack = .{},
    };

    var node = Node{ .do_node = &do_data };
    const result = try run(&node, &ctx);
    try std.testing.expect(result.eql(value_mod.intVal(3)));
}

test "run let" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    var ctx = Context.init(allocator, &env);

    // (let [x 42] x)
    var init_node = Node{ .constant = value_mod.intVal(42) };
    var body_node = Node{ .local_ref = .{ .name = "x", .idx = 0, .stack = .{} } };

    const bindings = [_]node_mod.LetBinding{
        .{ .name = "x", .init = &init_node },
    };

    var let_data = node_mod.LetNode{
        .bindings = &bindings,
        .body = &body_node,
        .stack = .{},
    };

    var node = Node{ .let_node = &let_data };
    const result = try run(&node, &ctx);
    try std.testing.expect(result.eql(value_mod.intVal(42)));
}
