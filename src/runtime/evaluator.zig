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
            fn_ctx = fn_ctx.withBindings(args) catch return error.OutOfMemory;

            // ボディを評価
            const body: *const Node = @ptrCast(@alignCast(arity.body));
            break :blk run(body, &fn_ctx);
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
