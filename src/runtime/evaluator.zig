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
    // TreeWalk 用 LazySeq コールバックを設定
    core.setForceCallback(&treeWalkForce);
    core.setCallFn(&treeWalkCall);
    core.setCurrentEnv(ctx.env);
    current_env = ctx.env;

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
        .letfn_node => |n| runLetfn(n, ctx),
        .call_node => |n| runCall(n, ctx),
        .def_node => |n| runDef(n, ctx),
        .quote_node => |n| n.form,
        .throw_node => |n| runThrow(n, ctx),
        .try_node => |n| runTry(n, ctx),
        .defmulti_node => |n| runDefmulti(n, ctx),
        .defmethod_node => |n| runDefmethod(n, ctx),
        .defprotocol_node => |n| runDefprotocol(n, ctx),
        .extend_type_node => |n| runExtendType(n, ctx),
        .lazy_seq_node => |n| runLazySeq(n, ctx),
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

    // recur 用バッファを事前割り当て（毎反復の alloc を回避）
    const num_loop_bindings = node.bindings.len;
    const recur_buf = ctx.allocator.alloc(Value, num_loop_bindings) catch return error.OutOfMemory;
    loop_ctx.recur_buffer = recur_buf;

    // loop 本体を繰り返し評価
    while (true) {
        loop_ctx.clearRecur();
        const result = try run(node.body, &loop_ctx);

        if (loop_ctx.hasRecur()) {
            // recur の値でバインディングをインプレース更新（新規割り当てを回避）
            const recur_vals = loop_ctx.recur_values.?.values;
            for (recur_vals, 0..) |val, i| {
                loop_ctx.bindings[start_idx + i] = val;
            }
            continue;
        }

        return result;
    }
}

/// recur 評価
fn runRecur(node: *const node_mod.RecurNode, ctx: *Context) EvalError!Value {
    // 事前割り当てバッファがあれば再利用、なければ新規割り当て
    const vals = if (ctx.recur_buffer) |buf|
        buf[0..node.args.len]
    else
        ctx.allocator.alloc(Value, node.args.len) catch return error.OutOfMemory;

    // 引数を評価
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
    // 名前付き fn の場合、自己参照用のスロットを1つ追加
    const is_named = node.name != null;
    const closure_bindings = if (is_named) blk: {
        // 自己参照用に1スロット追加
        const binds = ctx.allocator.alloc(Value, ctx.bindings.len + 1) catch return error.OutOfMemory;
        @memcpy(binds[0..ctx.bindings.len], ctx.bindings);
        binds[ctx.bindings.len] = value_mod.nil; // 後で自己参照をセット
        break :blk binds;
    } else if (ctx.bindings.len > 0)
        ctx.allocator.dupe(Value, ctx.bindings) catch return error.OutOfMemory
    else
        null;

    // Fn オブジェクトを作成
    const fn_obj = ctx.allocator.create(value_mod.Fn) catch return error.OutOfMemory;
    fn_obj.* = value_mod.Fn.initUser(node.name, runtime_arities, closure_bindings);

    const fn_val = Value{ .fn_val = fn_obj };

    // 名前付き fn: 自己参照をクロージャ環境に設定
    if (is_named) {
        if (closure_bindings) |binds| {
            @constCast(binds)[ctx.bindings.len] = fn_val;
        }
    }

    return fn_val;
}

/// letfn 評価（相互再帰ローカル関数）
/// 1. 全関数を作成（closure_bindings なし）
/// 2. コンテキストに追加
/// 3. 各関数の closure_bindings を更新（全関数を含むコンテキスト）
fn runLetfn(node: *const node_mod.LetfnNode, ctx: *Context) EvalError!Value {
    // Phase 1: 全関数を仮作成してコンテキストに追加
    var current_ctx = ctx.*;
    var fn_objects = ctx.allocator.alloc(*value_mod.Fn, node.bindings.len) catch return error.OutOfMemory;

    for (node.bindings, 0..) |binding, i| {
        // fn ノードを評価して関数値を取得
        // (注: letfn では fn を名前なしで解析し、ここで名前を付与する)
        const fn_val = try runFn(binding.fn_node.fn_node, &current_ctx);
        fn_objects[i] = fn_val.fn_val;
        fn_objects[i].name = value_mod.Symbol.init(binding.name); // デバッグ表示用
        // コンテキストに追加（後続の関数は先行する関数を参照可能）
        current_ctx = current_ctx.withBinding(fn_val) catch return error.OutOfMemory;
    }

    // Phase 2: 全関数の closure_bindings を更新
    // 全関数がスコープ内にある状態の bindings でクロージャを更新
    const full_bindings = ctx.allocator.dupe(Value, current_ctx.bindings) catch return error.OutOfMemory;
    for (fn_objects) |fn_obj| {
        fn_obj.closure_bindings = full_bindings;
    }

    // Phase 3: ボディを評価
    return run(node.body, &current_ctx);
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

/// TreeWalk 用 LazySeq force コールバック
/// threadlocal に保存された env を使用
threadlocal var current_env: ?*Env = null;

fn treeWalkForce(fn_val: Value, allocator: std.mem.Allocator) anyerror!Value {
    // fn を引数なしで呼び出す
    const env = current_env orelse return error.TypeError;
    var ctx = Context.init(allocator, env);
    return callWithArgs(fn_val, &[_]Value{}, &ctx);
}

fn treeWalkCall(fn_val: Value, args: []const Value, allocator: std.mem.Allocator) anyerror!Value {
    // fn を引数付きで呼び出す
    const env = current_env orelse return error.TypeError;
    var ctx = Context.init(allocator, env);
    return callWithArgs(fn_val, args, &ctx);
}

/// 関数を引数付きで呼び出し（partial_fn サポート付き）
/// isa? ベースでマルチメソッドのメソッドを検索（core に委譲）
fn findIsaMethod(allocator: std.mem.Allocator, mf: *const value_mod.MultiFn, dispatch_value: Value) !?Value {
    return core.findIsaMethodFromMultiFn(allocator, mf, dispatch_value);
}

fn callWithArgs(fn_val: Value, args: []const Value, ctx: *Context) EvalError!Value {
    // LazySeq コールバックを設定
    core.setForceCallback(&treeWalkForce);
    core.setCallFn(&treeWalkCall);
    core.setCurrentEnv(ctx.env);
    current_env = ctx.env;

    return switch (fn_val) {
        .fn_val => |f| blk: {
            // 組み込み関数
            if (f.builtin) |builtin_ptr| {
                // anyopaque から BuiltinFn にキャスト
                const builtin: core.BuiltinFn = @ptrCast(@alignCast(builtin_ptr));
                break :blk builtin(ctx.allocator, args) catch |e| {
                    @branchHint(.cold);
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
            const arity = f.findArity(args.len) orelse {
                @branchHint(.cold);
                const fn_name = if (f.name) |n| n.name else "<anonymous>";
                err.setArityError(args.len, fn_name);
                return error.ArityError;
            };

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

            // ボディを評価 (fn-level recur 対応)
            const body: *const Node = @ptrCast(@alignCast(arity.body));
            const param_count = arity.params.len;
            const start_idx = fn_ctx.bindings.len - param_count;

            // recur 用バッファを事前割り当て
            const recur_buf = ctx.allocator.alloc(Value, param_count) catch return error.OutOfMemory;
            fn_ctx.recur_buffer = recur_buf;

            while (true) {
                fn_ctx.clearRecur();
                const result = try run(body, &fn_ctx);

                if (fn_ctx.hasRecur()) {
                    // recur の値でパラメータバインディングをインプレース更新
                    const recur_vals = fn_ctx.recur_values.?.values;
                    for (recur_vals, 0..) |val, i| {
                        fn_ctx.bindings[start_idx + i] = val;
                    }
                    continue;
                }

                break :blk result;
            }
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

            // 1. 完全一致
            if (mf.methods.get(dispatch_result)) |method| {
                break :blk callWithArgs(method, args, ctx);
            }

            // 2. isa? ベースの階層的ディスパッチ
            if (findIsaMethod(ctx.allocator, mf, dispatch_result) catch null) |method| {
                break :blk callWithArgs(method, args, ctx);
            }

            // 3. :default メソッドを試す
            if (mf.default_method) |default| {
                break :blk callWithArgs(default, args, ctx);
            }

            // メソッドが見つからない
            err.setEvalErrorFmt(.type_error, "No method in multimethod for dispatch value", .{});
            return error.TypeError;
        },
        .protocol_fn => |pf| blk: {
            // プロトコル関数呼び出し: 第1引数の型で実装を検索
            if (args.len < 1) {
                err.setArityError(args.len, pf.method_name);
                return error.ArityError;
            }
            const type_key_str = args[0].typeKeyword();

            // type_key を文字列 Value として作成
            const type_key_s = ctx.allocator.create(value_mod.String) catch return error.OutOfMemory;
            type_key_s.* = value_mod.String.init(type_key_str);
            const type_key = Value{ .string = type_key_s };

            // プロトコルの impls から型のメソッドマップを検索
            const methods_val = pf.protocol.impls.get(type_key) orelse
                return error.TypeError;

            // メソッドマップから関数を検索
            if (methods_val != .map) return error.TypeError;
            const method_name_s = ctx.allocator.create(value_mod.String) catch return error.OutOfMemory;
            method_name_s.* = value_mod.String.init(pf.method_name);
            const method_key = Value{ .string = method_name_s };

            const method_fn = methods_val.map.get(method_key) orelse
                return error.TypeError;

            break :blk callWithArgs(method_fn, args, ctx);
        },
        .keyword => |k| blk: {
            // キーワードを関数として使用: (:key map) or (:key map default)
            if (args.len < 1 or args.len > 2) {
                err.setArityError(args.len, k.name);
                return error.ArityError;
            }
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
        .var_val => |vp| {
            // Var を関数として呼び出し: (#'foo args...) → deref して再帰呼び出し
            const v: *var_mod.Var = @ptrCast(@alignCast(vp));
            return callWithArgs(v.deref(), args, ctx);
        },
        else => {
            @branchHint(.cold);
            err.setTypeError("function", fn_val.typeName());
            return error.TypeError;
        },
    };
}

/// throw 評価
fn runThrow(node: *const node_mod.ThrowNode, ctx: *Context) EvalError!Value {
    @branchHint(.cold);
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
    @branchHint(.cold);
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

    // dynamic フラグを設定
    if (node.is_dynamic) {
        v.dynamic = true;
    }

    // Var を返す（#'ns/name 形式）
    return Value{ .var_val = @ptrCast(v) };
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
        .prefer_table = null,
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

/// defprotocol 評価
/// (defprotocol Name (method1 [this]) (method2 [this arg]))
fn runDefprotocol(node: *const node_mod.DefprotocolNode, ctx: *Context) EvalError!Value {
    const ns = ctx.env.getCurrentNs() orelse return error.UndefinedSymbol;

    // Protocol 構造体を作成（空の impls マップ）
    const empty_impls = ctx.allocator.create(value_mod.PersistentMap) catch return error.OutOfMemory;
    empty_impls.* = value_mod.PersistentMap.empty();

    const proto = ctx.allocator.create(value_mod.Protocol) catch return error.OutOfMemory;
    proto.* = .{
        .name = value_mod.Symbol.init(node.name),
        .method_sigs = blk: {
            const sigs = ctx.allocator.alloc(value_mod.Protocol.MethodSig, node.method_sigs.len) catch return error.OutOfMemory;
            for (node.method_sigs, 0..) |sig, i| {
                sigs[i] = .{ .name = sig.name, .arity = sig.arity };
            }
            break :blk sigs;
        },
        .impls = empty_impls,
    };

    // プロトコル名の Var にバインド
    const proto_var = ns.intern(node.name) catch return error.OutOfMemory;
    proto_var.bindRoot(Value{ .protocol = proto });

    // 各メソッドについて ProtocolFn を作成し、メソッド名の Var にバインド
    for (node.method_sigs) |sig| {
        const pf = ctx.allocator.create(value_mod.ProtocolFn) catch return error.OutOfMemory;
        pf.* = .{
            .protocol = proto,
            .method_name = sig.name,
        };

        const method_var = ns.intern(sig.name) catch return error.OutOfMemory;
        method_var.bindRoot(Value{ .protocol_fn = pf });
    }

    return value_mod.nil;
}

/// extend-type 評価
/// (extend-type TypeName ProtoName (m1 [this] body) ...)
fn runExtendType(node: *const node_mod.ExtendTypeNode, ctx: *Context) EvalError!Value {
    const ns = ctx.env.getCurrentNs() orelse return error.UndefinedSymbol;

    // 型名を内部 typeKeyword に変換
    const type_key_str = mapUserTypeName(node.type_name);

    for (node.extensions) |ext| {
        // プロトコルの Var から Protocol を取得
        const proto_var = ns.intern(ext.protocol_name) catch return error.OutOfMemory;
        const proto_val = proto_var.deref();
        if (proto_val != .protocol) return error.TypeError;
        const proto = proto_val.protocol;

        // 各メソッドの fn を評価し、メソッドマップを構築
        // メソッドマップ: {method_name_string → fn Value}
        var method_map = value_mod.PersistentMap.empty();
        for (ext.methods) |method| {
            const method_fn = try run(method.fn_node, ctx);
            const cloned_fn = method_fn.deepClone(ctx.allocator) catch return error.OutOfMemory;

            const name_s = ctx.allocator.create(value_mod.String) catch return error.OutOfMemory;
            name_s.* = value_mod.String.init(method.name);
            const name_key = Value{ .string = name_s };

            method_map = method_map.assoc(ctx.allocator, name_key, cloned_fn) catch return error.OutOfMemory;
        }

        // impls に追加: type_key_string → メソッドマップ
        const type_key_s = ctx.allocator.create(value_mod.String) catch return error.OutOfMemory;
        type_key_s.* = value_mod.String.init(type_key_str);
        const type_key = Value{ .string = type_key_s };

        const method_map_ptr = ctx.allocator.create(value_mod.PersistentMap) catch return error.OutOfMemory;
        method_map_ptr.* = method_map;
        const method_map_val = Value{ .map = method_map_ptr };

        const new_impls = ctx.allocator.create(value_mod.PersistentMap) catch return error.OutOfMemory;
        new_impls.* = proto.impls.assoc(ctx.allocator, type_key, method_map_val) catch return error.OutOfMemory;
        proto.impls = new_impls;
    }

    return value_mod.nil;
}

/// ユーザー指定の型名を内部 typeKeyword 文字列に変換
fn mapUserTypeName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "nil")) return "nil";
    if (std.mem.eql(u8, name, "Boolean")) return "boolean";
    if (std.mem.eql(u8, name, "Integer")) return "integer";
    if (std.mem.eql(u8, name, "Float")) return "float";
    if (std.mem.eql(u8, name, "String")) return "string";
    if (std.mem.eql(u8, name, "Keyword")) return "keyword";
    if (std.mem.eql(u8, name, "Symbol")) return "symbol";
    if (std.mem.eql(u8, name, "List")) return "list";
    if (std.mem.eql(u8, name, "Vector")) return "vector";
    if (std.mem.eql(u8, name, "Map")) return "map";
    if (std.mem.eql(u8, name, "Set")) return "set";
    if (std.mem.eql(u8, name, "Function")) return "function";
    if (std.mem.eql(u8, name, "Atom")) return "atom";
    // 未知の型名はそのまま返す
    return name;
}

/// lazy-seq 評価
/// body をサンク（fn body として包み）、LazySeq 値を返す
/// body は実際に first/rest 等が呼ばれた時点で評価される
fn runLazySeq(node: *const node_mod.LazySeqNode, ctx: *Context) EvalError!Value {
    // body ノードを (fn [] body) としてクロージャ化し、LazySeq に格納
    // body ノードを deepClone して永続化
    const persistent_body = node.body.deepClone(ctx.allocator) catch return error.OutOfMemory;

    // 引数なしのアリティを作成
    const arity = ctx.allocator.create(value_mod.FnArityRuntime) catch return error.OutOfMemory;
    arity.* = .{
        .params = &[_][]const u8{},
        .variadic = false,
        .body = @ptrCast(persistent_body),
    };
    const arities = ctx.allocator.alloc(value_mod.FnArityRuntime, 1) catch return error.OutOfMemory;
    arities[0] = arity.*;

    // クロージャバインディングをキャプチャ
    const bindings = if (ctx.bindings.len > 0) blk: {
        const b = ctx.allocator.dupe(Value, ctx.bindings) catch return error.OutOfMemory;
        break :blk b;
    } else null;

    // Fn オブジェクト作成
    const fn_obj = ctx.allocator.create(value_mod.Fn) catch return error.OutOfMemory;
    fn_obj.* = value_mod.Fn.initUser(null, arities, bindings);

    // LazySeq 作成
    const ls = ctx.allocator.create(value_mod.LazySeq) catch return error.OutOfMemory;
    ls.* = value_mod.LazySeq.init(.{ .fn_val = fn_obj });

    return Value{ .lazy_seq = ls };
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
