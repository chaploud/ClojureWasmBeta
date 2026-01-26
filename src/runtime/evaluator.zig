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
    UserException,
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
        .throw_node => |n| runThrow(n, ctx),
        .try_node => |n| runTry(n, ctx),
        .apply_node => |n| runApply(n, ctx),
        .partial_node => |n| runPartial(n, ctx),
        .comp_node => |n| runComp(n, ctx),
        .reduce_node => |n| runReduce(n, ctx),
        .map_node => |n| runMap(n, ctx),
        .filter_node => |n| runFilter(n, ctx),
        .swap_node => |n| runSwap(n, ctx),
        .defmulti_node => |n| runDefmulti(n, ctx),
        .defmethod_node => |n| runDefmethod(n, ctx),
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
/// バインディングは順次評価・バインド（後続のバインディングが前のバインディングを参照可能）
fn runLet(node: *const node_mod.LetNode, ctx: *Context) EvalError!Value {
    var current_ctx = ctx.*;

    // 各バインディングを順次評価してコンテキストに追加
    for (node.bindings) |binding| {
        const val = try run(binding.init, &current_ctx);
        current_ctx = current_ctx.withBinding(val) catch return error.OutOfMemory;
    }

    // 新しいコンテキストでボディを評価
    const result = try run(node.body, &current_ctx);

    // recur フラグを伝搬（loop 内の let で recur が発生した場合）
    if (current_ctx.hasRecur()) {
        ctx.recur_values = current_ctx.recur_values;
    }

    return result;
}

/// loop 評価
/// バインディングは順次評価・バインド（後続のバインディングが前のバインディングを参照可能）
fn runLoop(node: *const node_mod.LoopNode, ctx: *Context) EvalError!Value {
    // 各バインディングを順次評価してコンテキストに追加
    var current_ctx = ctx.*;
    for (node.bindings) |binding| {
        const val = try run(binding.init, &current_ctx);
        current_ctx = current_ctx.withBinding(val) catch return error.OutOfMemory;
    }

    const start_idx = ctx.bindings.len;
    var loop_ctx = current_ctx;

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
    // body を永続アロケータに深コピー（scratch arena 解放後も安全にするため）
    const runtime_arities = ctx.allocator.alloc(value_mod.FnArityRuntime, node.arities.len) catch return error.OutOfMemory;
    for (node.arities, 0..) |arity, i| {
        const cloned_body = arity.body.deepClone(ctx.allocator) catch return error.OutOfMemory;
        runtime_arities[i] = .{
            .params = arity.params,
            .variadic = arity.variadic,
            .body = @ptrCast(cloned_body),
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
                break :blk builtin(ctx.allocator, args) catch |e| {
                    return switch (e) {
                        error.ArityError => error.ArityError,
                        error.DivisionByZero => error.DivisionByZero,
                        error.OutOfMemory => error.OutOfMemory,
                        error.UserException => error.UserException,
                        else => error.TypeError,
                    };
                };
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
        .multi_fn => |mf| blk: {
            // マルチメソッド呼び出し: dispatch_fn で値を取得 → methods からメソッドを検索
            const dispatch_result = try callWithArgs(mf.dispatch_fn, args, ctx);

            // ディスパッチ値でメソッドを検索
            if (mf.methods.get(dispatch_result)) |method| {
                break :blk callWithArgs(method, args, ctx);
            }

            // :default メソッドを試す
            if (mf.default_method) |default| {
                break :blk callWithArgs(default, args, ctx);
            }

            // メソッドが見つからない
            break :blk error.TypeError;
        },
        .keyword => |k| blk: {
            // キーワードを関数として使用: (:key map) or (:key map default)
            if (args.len < 1 or args.len > 2) return error.ArityError;
            const not_found = if (args.len == 2) args[1] else value_mod.nil;
            break :blk switch (args[0]) {
                .map => |m| m.get(Value{ .keyword = k }) orelse not_found,
                .set => |s| blk2: {
                    const kv = Value{ .keyword = k };
                    for (s.items) |item| {
                        if (kv.eql(item)) break :blk2 kv;
                    }
                    break :blk2 not_found;
                },
                else => not_found,
            };
        },
        else => error.TypeError,
    };
}

/// throw 評価
fn runThrow(node: *const node_mod.ThrowNode, ctx: *Context) EvalError!Value {
    // 式を評価
    const val = try run(node.expr, ctx);

    // アリーナに Value を確保して threadlocal に格納
    const val_ptr = ctx.allocator.create(Value) catch return error.OutOfMemory;
    val_ptr.* = val;
    err.thrown_value = @ptrCast(val_ptr);
    return error.UserException;
}

/// try/catch/finally 評価
fn runTry(node: *const node_mod.TryNode, ctx: *Context) EvalError!Value {
    // body を実行
    var result: Value = undefined;
    var body_err: ?EvalError = null;

    if (run(node.body, ctx)) |val| {
        result = val;
    } else |e| {
        body_err = e;
    }

    if (body_err) |the_err| {
        // エラー発生: catch 節をチェック
        if (node.catch_clause) |clause| {
            // 例外値を取得
            var exception_val: Value = value_mod.nil;
            if (the_err == error.UserException) {
                // ユーザー throw
                if (err.getThrownValue()) |thrown_ptr| {
                    exception_val = @as(*const Value, @ptrCast(@alignCast(thrown_ptr))).*;
                }
            } else {
                // 内部エラーをマップに変換
                exception_val = internalErrorToValue(the_err, ctx);
            }

            // catch バインディングでハンドラ実行
            var catch_ctx = ctx.withBinding(exception_val) catch return error.OutOfMemory;
            result = try runFinally(node.finally_body, ctx, run(clause.body, &catch_ctx));
            return result;
        } else {
            // catch なし: finally だけ実行してエラーを再 throw
            try runFinallyIgnoreResult(node.finally_body, ctx);
            return the_err;
        }
    }

    // 成功: finally を実行して結果を返す
    try runFinallyIgnoreResult(node.finally_body, ctx);
    return result;
}

/// finally 実行（結果を透過）
fn runFinally(finally_body: ?*const Node, ctx: *Context, inner_result: EvalError!Value) EvalError!Value {
    try runFinallyIgnoreResult(finally_body, ctx);
    return inner_result;
}

/// finally 実行（結果を無視、エラーは伝搬）
fn runFinallyIgnoreResult(finally_body: ?*const Node, ctx: *Context) EvalError!void {
    if (finally_body) |finally_n| {
        _ = try run(finally_n, ctx);
    }
}

/// 内部エラーを Value マップに変換
/// {:type :type-error, :message "..."} 形式
fn internalErrorToValue(e: EvalError, ctx: *Context) Value {
    const type_str: []const u8 = switch (e) {
        error.TypeError => "type-error",
        error.ArityError => "arity-error",
        error.UndefinedSymbol => "undefined-symbol",
        error.DivisionByZero => "division-by-zero",
        error.RecurOutsideLoop => "recur-outside-loop",
        error.OutOfMemory => "out-of-memory",
        error.UserException => "user-exception",
    };

    // {:type :type-error, :message "..."} マップを作成
    // フラットな [k1, v1, k2, v2, ...] 形式
    const map_ptr = ctx.allocator.create(value_mod.PersistentMap) catch return value_mod.nil;

    // エントリ配列: [:type, :error-type, :message, "error-type"]
    const entries = ctx.allocator.alloc(Value, 4) catch return value_mod.nil;

    // :type キー
    const type_kw = ctx.allocator.create(value_mod.Keyword) catch return value_mod.nil;
    type_kw.* = value_mod.Keyword.init("type");
    entries[0] = Value{ .keyword = type_kw };

    // :type 値（キーワード）
    const err_type_kw = ctx.allocator.create(value_mod.Keyword) catch return value_mod.nil;
    err_type_kw.* = value_mod.Keyword.init(type_str);
    entries[1] = Value{ .keyword = err_type_kw };

    // :message キー
    const msg_kw = ctx.allocator.create(value_mod.Keyword) catch return value_mod.nil;
    msg_kw.* = value_mod.Keyword.init("message");
    entries[2] = Value{ .keyword = msg_kw };

    // :message 値（文字列）
    const msg_str = ctx.allocator.create(value_mod.String) catch return value_mod.nil;
    msg_str.* = value_mod.String.init(type_str);
    entries[3] = Value{ .string = msg_str };

    map_ptr.* = .{ .entries = entries };
    return Value{ .map = map_ptr };
}

/// def 評価
fn runDef(node: *const node_mod.DefNode, ctx: *Context) EvalError!Value {
    const ns = ctx.env.getCurrentNs() orelse return error.UndefinedSymbol;
    const v = ns.intern(node.sym_name) catch return error.OutOfMemory;

    if (node.init) |init_node| {
        const val = try run(init_node, ctx);
        // scratch アロケータ上の参照を排除するため persistent にディープクローン
        const cloned = val.deepClone(ctx.allocator) catch return error.OutOfMemory;
        v.bindRoot(cloned);
    }

    // マクロフラグを設定
    if (node.is_macro) {
        v.setMacro(true);
    }

    // Var を返す（#'var 形式）
    // TODO: Var を Value に含める
    return value_mod.nil;
}

/// defmulti 評価
/// (defmulti name dispatch-fn)
fn runDefmulti(node: *const node_mod.DefmultiNode, ctx: *Context) EvalError!Value {
    const ns = ctx.env.getCurrentNs() orelse return error.UndefinedSymbol;
    const v = ns.intern(node.name) catch return error.OutOfMemory;

    // ディスパッチ関数を評価
    const dispatch_fn = try run(node.dispatch_fn, ctx);

    // MultiFn を作成
    const empty_map = ctx.allocator.create(value_mod.PersistentMap) catch return error.OutOfMemory;
    empty_map.* = value_mod.PersistentMap.empty();

    const mf = ctx.allocator.create(value_mod.MultiFn) catch return error.OutOfMemory;
    mf.* = .{
        .name = value_mod.Symbol.init(node.name),
        .dispatch_fn = dispatch_fn,
        .methods = empty_map,
        .default_method = null,
    };

    v.bindRoot(Value{ .multi_fn = mf });
    return value_mod.nil;
}

/// defmethod 評価
/// (defmethod name dispatch-val [params] body...)
fn runDefmethod(node: *const node_mod.DefmethodNode, ctx: *Context) EvalError!Value {
    const ns = ctx.env.getCurrentNs() orelse return error.UndefinedSymbol;
    const v = ns.intern(node.multi_name) catch return error.OutOfMemory;

    // Var から MultiFn を取得
    const mf_val = v.deref();
    if (mf_val != .multi_fn) return error.TypeError;
    const mf = mf_val.multi_fn;

    // ディスパッチ値を評価
    const dispatch_val = try run(node.dispatch_val, ctx);

    // メソッド関数を評価
    const method_fn = try run(node.method_fn, ctx);
    const cloned_method = method_fn.deepClone(ctx.allocator) catch return error.OutOfMemory;

    // :default キーワードかチェック
    const is_default = switch (dispatch_val) {
        .keyword => |k| std.mem.eql(u8, k.name, "default"),
        else => false,
    };

    if (is_default) {
        mf.default_method = cloned_method;
    } else {
        // methods マップに追加
        const cloned_key = dispatch_val.deepClone(ctx.allocator) catch return error.OutOfMemory;
        const new_map = ctx.allocator.create(value_mod.PersistentMap) catch return error.OutOfMemory;
        new_map.* = mf.methods.assoc(ctx.allocator, cloned_key, cloned_method) catch return error.OutOfMemory;
        mf.methods = new_map;
    }

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
        const sym = value_mod.Symbol.init("identity");
        if (ctx.env.resolve(sym)) |v| {
            return v.deref();
        }
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

/// map 評価
/// (map f coll)
fn runMap(node: *const node_mod.MapNode, ctx: *Context) EvalError!Value {
    const fn_val = try run(node.fn_node, ctx);
    const coll_val = try run(node.coll_node, ctx);

    const items: []const Value = switch (coll_val) {
        .list => |l| l.items,
        .vector => |v| v.items,
        .nil => &[_]Value{},
        else => return error.TypeError,
    };

    // 各要素に関数を適用
    var result_items = ctx.allocator.alloc(Value, items.len) catch return error.OutOfMemory;
    for (items, 0..) |item, i| {
        const args = ctx.allocator.alloc(Value, 1) catch return error.OutOfMemory;
        args[0] = item;
        result_items[i] = try callWithArgs(fn_val, args, ctx);
    }

    const result_list = ctx.allocator.create(value_mod.PersistentList) catch return error.OutOfMemory;
    result_list.* = .{ .items = result_items };
    return Value{ .list = result_list };
}

/// filter 評価
/// (filter pred coll)
fn runFilter(node: *const node_mod.FilterNode, ctx: *Context) EvalError!Value {
    const fn_val = try run(node.fn_node, ctx);
    const coll_val = try run(node.coll_node, ctx);

    const items: []const Value = switch (coll_val) {
        .list => |l| l.items,
        .vector => |v| v.items,
        .nil => &[_]Value{},
        else => return error.TypeError,
    };

    // 述語が真の要素だけ集める
    var result_buf: std.ArrayListUnmanaged(Value) = .empty;
    for (items) |item| {
        const args = ctx.allocator.alloc(Value, 1) catch return error.OutOfMemory;
        args[0] = item;
        const pred_result = try callWithArgs(fn_val, args, ctx);
        if (pred_result.isTruthy()) {
            result_buf.append(ctx.allocator, item) catch return error.OutOfMemory;
        }
    }

    const result_list = ctx.allocator.create(value_mod.PersistentList) catch return error.OutOfMemory;
    result_list.* = .{ .items = result_buf.toOwnedSlice(ctx.allocator) catch return error.OutOfMemory };
    return Value{ .list = result_list };
}

/// (swap! atom f) または (swap! atom f x y ...)
fn runSwap(node: *const node_mod.SwapNode, ctx: *Context) EvalError!Value {
    const atom_val = try run(node.atom_node, ctx);
    const fn_val = try run(node.fn_node, ctx);

    // Atom チェック
    const atom_ptr = switch (atom_val) {
        .atom => |a| a,
        else => return error.TypeError,
    };

    // 追加引数を評価
    var extra_args = ctx.allocator.alloc(Value, node.args.len) catch return error.OutOfMemory;
    for (node.args, 0..) |arg, i| {
        extra_args[i] = try run(arg, ctx);
    }

    // (f current-val extra-args...) の引数を構築
    const total_args = 1 + extra_args.len;
    var all_args = ctx.allocator.alloc(Value, total_args) catch return error.OutOfMemory;
    all_args[0] = atom_ptr.value; // 現在の値
    @memcpy(all_args[1..], extra_args);

    // 関数を適用
    const new_val = try callWithArgs(fn_val, all_args, ctx);

    // scratch 参照を排除するためディープクローン
    const cloned = new_val.deepClone(ctx.allocator) catch return error.OutOfMemory;

    // Atom を更新
    atom_ptr.value = cloned;
    return cloned;
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
