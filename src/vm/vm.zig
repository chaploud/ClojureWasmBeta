//! VM: バイトコード仮想マシン
//!
//! コンパイル済みバイトコードを実行する。
//! スタックベースの仮想マシン。
//!
//! 処理フロー:
//!   Form (Reader) → Node (Analyzer) → Bytecode (Compiler) → Value (VM)

const std = @import("std");
const bytecode = @import("../compiler/bytecode.zig");
const Chunk = bytecode.Chunk;
const OpCode = bytecode.OpCode;
const Instruction = bytecode.Instruction;
const FnProto = bytecode.FnProto;
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const var_mod = @import("../runtime/var.zig");
const Var = var_mod.Var;
const core = @import("../lib/core.zig");

/// VM エラー
pub const VMError = error{
    StackOverflow,
    StackUnderflow,
    TypeError,
    ArityError,
    UndefinedVar,
    OutOfMemory,
    InvalidInstruction,
    UserException,
};

/// スタックサイズ
const STACK_MAX: usize = 256 * 64;

/// コールフレームの最大数
const FRAMES_MAX: usize = 64;

/// 例外ハンドラの最大数
const HANDLERS_MAX: usize = 32;

/// 例外ハンドラ（try ブロックの状態保存）
const ExceptionHandler = struct {
    /// catch 節の IP
    catch_ip: usize,
    /// try 開始時のスタックポインタ
    saved_sp: usize,
    /// try 開始時のフレーム数
    saved_frame_count: usize,
    /// try ブロックのコードポインタ
    code_ptr: []const Instruction,
    /// try ブロックの定数テーブル
    constants_ptr: []const Value,
};

/// コールフレーム
const CallFrame = struct {
    /// 関数プロトタイプ
    proto: ?*const FnProto,
    /// 命令ポインタ（コード配列内のインデックス）
    ip: usize,
    /// このフレームのスタックベース
    base: usize,
    /// クロージャ環境
    closure: ?[]const Value,
};

/// 仮想マシン
pub const VM = struct {
    allocator: std.mem.Allocator,
    /// 値スタック
    stack: [STACK_MAX]Value,
    /// スタックトップ（次に push する位置）
    sp: usize,
    /// コールフレーム
    frames: [FRAMES_MAX]CallFrame,
    /// フレーム数
    frame_count: usize,
    /// グローバル環境
    env: *Env,
    /// 例外ハンドラスタック
    handlers: [HANDLERS_MAX]ExceptionHandler,
    /// アクティブなハンドラ数
    handler_count: usize,
    /// 例外伝搬用フラグ（ネストした execute 間の伝搬）
    pending_exception: bool,
    /// 伝搬中の例外値
    pending_exception_value: Value,

    /// 初期化
    pub fn init(allocator: std.mem.Allocator, env: *Env) VM {
        return .{
            .allocator = allocator,
            .stack = undefined,
            .sp = 0,
            .frames = undefined,
            .frame_count = 0,
            .env = env,
            .handlers = undefined,
            .handler_count = 0,
            .pending_exception = false,
            .pending_exception_value = value_mod.nil,
        };
    }

    /// Chunk を実行
    pub fn run(self: *VM, chunk: *const Chunk) VMError!Value {
        // トップレベルフレームを作成
        self.frames[0] = .{
            .proto = null,
            .ip = 0,
            .base = 0,
            .closure = null,
        };
        self.frame_count = 1;

        return self.execute(chunk.code.items, chunk.constants.items);
    }

    /// 命令を実行
    fn execute(self: *VM, code: []const Instruction, constants: []const Value) VMError!Value {
        // この execute が開始した時点の frame_count を記録
        // ret でこのレベルに戻ったら、この execute から return する
        const entry_frame_count = self.frame_count;

        while (true) {
            const frame = &self.frames[self.frame_count - 1];
            if (frame.ip >= code.len) {
                // コード終端
                return if (self.sp > 0) self.pop() else value_mod.nil;
            }

            const instr = code[frame.ip];
            frame.ip += 1;

            switch (instr.op) {
                // ═══════════════════════════════════════════════════════
                // [A] 定数・リテラル
                // ═══════════════════════════════════════════════════════
                .const_load => {
                    const val = constants[instr.operand];
                    try self.push(val);
                },
                .nil => try self.push(value_mod.nil),
                .true_val => try self.push(value_mod.true_val),
                .false_val => try self.push(value_mod.false_val),
                .int_0 => try self.push(value_mod.intVal(0)),
                .int_1 => try self.push(value_mod.intVal(1)),
                .int_neg1 => try self.push(value_mod.intVal(-1)),

                // ═══════════════════════════════════════════════════════
                // [B] スタック操作
                // ═══════════════════════════════════════════════════════
                .pop => {
                    _ = self.pop();
                },
                .dup => {
                    const val = try self.peek(0);
                    try self.push(val);
                },
                .swap => {
                    if (self.sp < 2) return error.StackUnderflow;
                    const tmp = self.stack[self.sp - 1];
                    self.stack[self.sp - 1] = self.stack[self.sp - 2];
                    self.stack[self.sp - 2] = tmp;
                },
                .scope_exit => {
                    // スコープ終了: N個のローカルを除去し、結果（スタックトップ）を保持
                    const n: usize = instr.operand;
                    if (n > 0) {
                        const result = self.stack[self.sp - 1];
                        self.sp -= n;
                        self.stack[self.sp - 1] = result;
                    }
                },

                // ═══════════════════════════════════════════════════════
                // [C] ローカル変数
                // ═══════════════════════════════════════════════════════
                .local_load => {
                    const idx = frame.base + instr.operand;
                    if (idx >= self.sp) return error.StackUnderflow;
                    try self.push(self.stack[idx]);
                },
                .local_store => {
                    const idx = frame.base + instr.operand;
                    const val = self.pop();
                    self.stack[idx] = val;
                },
                .local_load_0 => {
                    if (frame.base >= self.sp) return error.StackUnderflow;
                    try self.push(self.stack[frame.base]);
                },
                .local_load_1 => {
                    if (frame.base + 1 >= self.sp) return error.StackUnderflow;
                    try self.push(self.stack[frame.base + 1]);
                },
                .local_load_2 => {
                    if (frame.base + 2 >= self.sp) return error.StackUnderflow;
                    try self.push(self.stack[frame.base + 2]);
                },
                .local_load_3 => {
                    if (frame.base + 3 >= self.sp) return error.StackUnderflow;
                    try self.push(self.stack[frame.base + 3]);
                },

                // ═══════════════════════════════════════════════════════
                // [D] クロージャ変数（未実装）
                // ═══════════════════════════════════════════════════════
                .upvalue_load, .upvalue_store => {
                    // TODO: Phase 8.1 で実装
                    return error.InvalidInstruction;
                },

                // ═══════════════════════════════════════════════════════
                // [E] Var 操作
                // ═══════════════════════════════════════════════════════
                .var_load => {
                    const var_val = constants[instr.operand];
                    if (var_val != .var_val) return error.InvalidInstruction;
                    const v: *Var = @ptrCast(@alignCast(var_val.var_val));
                    try self.push(v.deref());
                },
                .var_load_dynamic => {
                    // TODO: 動的バインディング対応
                    // 現時点では var_load と同じ
                    const var_val = constants[instr.operand];
                    if (var_val != .var_val) return error.InvalidInstruction;
                    const v: *Var = @ptrCast(@alignCast(var_val.var_val));
                    try self.push(v.deref());
                },
                .def => {
                    try self.runDef(constants[instr.operand], false);
                },
                .def_macro => {
                    try self.runDef(constants[instr.operand], true);
                },

                // ═══════════════════════════════════════════════════════
                // [F] 制御フロー
                // ═══════════════════════════════════════════════════════
                .jump => {
                    const offset = instr.signedOperand();
                    if (offset < 0) {
                        frame.ip -= @intCast(-offset);
                    } else {
                        frame.ip += @intCast(offset);
                    }
                },
                .jump_if_false => {
                    const val = self.pop();
                    if (!val.isTruthy()) {
                        frame.ip += instr.operand;
                    }
                },
                .jump_if_true => {
                    const val = self.pop();
                    if (val.isTruthy()) {
                        frame.ip += instr.operand;
                    }
                },
                .jump_if_nil => {
                    const val = self.pop();
                    if (val.isNil()) {
                        frame.ip += instr.operand;
                    }
                },
                .jump_back => {
                    // 後方ジャンプ（loop 用）
                    frame.ip -= instr.operand;
                },

                // ═══════════════════════════════════════════════════════
                // [G] 関数
                // ═══════════════════════════════════════════════════════
                .call => {
                    const arg_count = instr.operand;
                    try self.callValueWithExceptionHandling(@intCast(arg_count));
                },
                .call_0 => try self.callValueWithExceptionHandling(0),
                .call_1 => try self.callValueWithExceptionHandling(1),
                .call_2 => try self.callValueWithExceptionHandling(2),
                .call_3 => try self.callValueWithExceptionHandling(3),
                .tail_call => {
                    // TODO: 末尾呼び出し最適化
                    const arg_count = instr.operand;
                    try self.callValueWithExceptionHandling(@intCast(arg_count));
                },
                .apply => {
                    // apply: (apply f x y z seq)
                    // スタック: [... fn, arg0, arg1, ..., seq]
                    // オペランド: 中間引数の数
                    const middle_count = instr.operand;
                    try self.applyValueWithExceptionHandling(@intCast(middle_count));
                },
                .ret => {
                    const result = self.pop();

                    // フレームを戻す
                    self.frame_count -= 1;

                    // この execute の開始レベルまで戻ったら return
                    // （または frame_count が 0 になったら）
                    if (self.frame_count < entry_frame_count) {
                        return result;
                    }

                    // スタックをフレームベースまで戻す
                    self.sp = frame.base;

                    // 結果を push
                    try self.push(result);
                },
                .closure => {
                    const proto_val = constants[instr.operand];
                    // FnProto から Fn を作成
                    try self.createClosure(proto_val);
                },
                .closure_multi => {
                    // 複数アリティのクロージャを作成
                    const arity_count = instr.operand;
                    try self.createMultiClosure(@intCast(arity_count));
                },
                .partial => {
                    // partial 関数を作成
                    const arg_count = instr.operand;
                    try self.createPartialFn(@intCast(arg_count));
                },
                .comp => {
                    // comp 関数を作成
                    const fn_count = instr.operand;
                    try self.createCompFn(@intCast(fn_count));
                },
                .reduce => {
                    // reduce を実行
                    const has_init = instr.operand != 0;
                    try self.executeReduceWithExceptionHandling(has_init);
                },
                .map_seq => {
                    try self.executeMapWithExceptionHandling();
                },
                .filter_seq => {
                    try self.executeFilterWithExceptionHandling();
                },

                // ═══════════════════════════════════════════════════════
                // [H] loop/recur
                // ═══════════════════════════════════════════════════════
                .loop_start => {
                    // マーカーのみ、何もしない
                },
                .recur => {
                    // recur: ループ変数を新しい値で更新
                    // オペランド: 上位8bit = loop開始オフセット、下位8bit = 引数数
                    const arg_count = instr.operand & 0xFF;
                    const base_offset = (instr.operand >> 8) & 0xFF;

                    // 引数をスタックから取り出して一時保存
                    const temp_values = self.allocator.alloc(Value, arg_count) catch return error.OutOfMemory;
                    defer self.allocator.free(temp_values);

                    // 後ろから取り出す
                    var i: usize = arg_count;
                    while (i > 0) {
                        i -= 1;
                        temp_values[i] = self.pop();
                    }

                    // ループバインディングを更新（let 等のバインディングをスキップ）
                    for (temp_values, 0..) |val, idx| {
                        self.stack[frame.base + base_offset + idx] = val;
                    }

                    // SP をループバインディング直後にリセット
                    // （loop body 内の let 等で追加されたローカルを破棄）
                    self.sp = frame.base + base_offset + arg_count;

                    // 次の命令（jump）がループ先頭に戻る
                },

                // ═══════════════════════════════════════════════════════
                // [I] コレクション生成（未実装）
                // ═══════════════════════════════════════════════════════
                .list_new, .vec_new, .map_new, .set_new => {
                    // TODO: Phase 8.2 で実装
                    return error.InvalidInstruction;
                },

                // ═══════════════════════════════════════════════════════
                // [J] コレクション操作（未実装）
                // ═══════════════════════════════════════════════════════
                .nth, .get, .first, .rest, .conj, .assoc, .count => {
                    // TODO: 将来最適化で実装
                    return error.InvalidInstruction;
                },

                // ═══════════════════════════════════════════════════════
                // [K] 例外処理
                // ═══════════════════════════════════════════════════════
                .try_begin => {
                    // ハンドラを登録
                    if (self.handler_count >= HANDLERS_MAX) return error.StackOverflow;
                    const catch_ip = frame.ip + instr.operand; // catch 節の位置
                    self.handlers[self.handler_count] = .{
                        .catch_ip = catch_ip,
                        .saved_sp = self.sp,
                        .saved_frame_count = self.frame_count,
                        .code_ptr = code,
                        .constants_ptr = constants,
                    };
                    self.handler_count += 1;
                },
                .catch_begin => {
                    // ハンドラを解除（try body が正常終了した場合ここに来る）
                    if (self.handler_count > 0) {
                        self.handler_count -= 1;
                    }
                },
                .finally_begin => {
                    // マーカーのみ
                },
                .try_end => {
                    // マーカーのみ
                },
                .throw_ex => {
                    // スタックトップを例外として投げる
                    const thrown = self.pop();
                    if (!self.handleThrow(thrown)) {
                        // ハンドラなし: エラーとして伝搬
                        const err_mod = @import("../base/error.zig");
                        const val_ptr = self.allocator.create(Value) catch return error.OutOfMemory;
                        val_ptr.* = thrown;
                        err_mod.thrown_value = @ptrCast(val_ptr);
                        return error.UserException;
                    }
                    // ハンドラが IP を調整済み — ループ続行
                },

                // ═══════════════════════════════════════════════════════
                // [K2] Atom 操作
                // ═══════════════════════════════════════════════════════
                .swap_atom => {
                    try self.executeSwapAtomWithExceptionHandling(instr.operand);
                },

                // ═══════════════════════════════════════════════════════
                // [L] メタデータ（未実装）
                // ═══════════════════════════════════════════════════════
                .with_meta, .meta => {
                    // TODO: Phase 10 で実装
                    return error.InvalidInstruction;
                },

                // ═══════════════════════════════════════════════════════
                // [Z] 予約・デバッグ
                // ═══════════════════════════════════════════════════════
                .nop => {},
                .debug_print => {
                    // デバッグ用: スタックトップを表示（現時点では何もしない）
                    // TODO: デバッグ出力の実装
                },
            }
        }
    }

    /// 関数呼び出し
    fn callValue(self: *VM, arg_count: usize) VMError!void {
        // スタックから関数と引数を取得
        const fn_idx = self.sp - arg_count - 1;
        const fn_val = self.stack[fn_idx];

        switch (fn_val) {
            .fn_val => |f| {
                // 組み込み関数
                if (f.builtin) |builtin_ptr| {
                    const builtin: core.BuiltinFn = @ptrCast(@alignCast(builtin_ptr));
                    const args = self.stack[fn_idx + 1 .. self.sp];
                    const result = builtin(self.allocator, args) catch return error.TypeError;

                    // スタックを巻き戻し
                    self.sp = fn_idx;
                    try self.push(result);
                    return;
                }

                // ユーザー定義関数
                const arity = f.findArity(arg_count) orelse return error.ArityError;
                if (self.frame_count >= FRAMES_MAX) return error.StackOverflow;

                // body から FnProto を取得（VM では body は FnProto へのポインタ）
                const proto: *const FnProto = @ptrCast(@alignCast(arity.body));

                // クロージャ環境がある場合、引数の前に配置
                // これにより local_load でクロージャ変数にアクセス可能
                if (f.closure_bindings) |closure_vals| {
                    // 引数を一時保存
                    const args_start = fn_idx + 1;
                    const args_end = self.sp;
                    const args_count_actual = args_end - args_start;

                    // クロージャ値を引数の前に挿入
                    // スタック: [fn, arg0, arg1, ...] -> [fn, closure0, closure1, ..., arg0, arg1, ...]
                    // 引数を後ろにシフト
                    if (args_count_actual > 0 and closure_vals.len > 0) {
                        // 新しいスタック位置を計算
                        const new_sp = args_start + closure_vals.len + args_count_actual;
                        if (new_sp >= STACK_MAX) return error.StackOverflow;

                        // 引数を後ろに移動（後ろから前に向かってコピー）
                        var i = args_count_actual;
                        while (i > 0) {
                            i -= 1;
                            self.stack[args_start + closure_vals.len + i] = self.stack[args_start + i];
                        }

                        // クロージャ値を挿入
                        for (closure_vals, 0..) |cv, ci| {
                            self.stack[args_start + ci] = cv;
                        }

                        self.sp = new_sp;
                    } else if (closure_vals.len > 0) {
                        // 引数がない場合、単にクロージャ値を追加
                        for (closure_vals) |cv| {
                            try self.push(cv);
                        }
                    }
                }

                // 可変長引数の処理
                // [x y & rest] の場合、余剰引数をリストにまとめる
                if (arity.variadic) {
                    const closure_len = if (f.closure_bindings) |cb| cb.len else 0;
                    const args_start = fn_idx + 1 + closure_len;
                    const fixed_count = arity.params.len - 1; // rest パラメータを除く

                    // 余剰引数をリストに変換
                    const rest_args = self.stack[args_start + fixed_count .. self.sp];
                    const rest_list = value_mod.PersistentList.fromSlice(self.allocator, rest_args) catch return error.OutOfMemory;

                    // スタックを調整: [固定引数, rest_list]
                    self.stack[args_start + fixed_count] = Value{ .list = rest_list };
                    self.sp = args_start + fixed_count + 1;
                }

                // 新しいフレームを作成
                self.frames[self.frame_count] = .{
                    .proto = proto,
                    .ip = 0,
                    .base = fn_idx + 1,
                    .closure = f.closure_bindings,
                };
                self.frame_count += 1;

                // proto のコードを実行
                const result = try self.execute(proto.code, proto.constants);

                // 結果を push
                self.sp = fn_idx;
                try self.push(result);
            },
            .fn_proto => |proto_ptr| {
                const proto: *const FnProto = @ptrCast(@alignCast(proto_ptr));
                if (arg_count != proto.arity) return error.ArityError;
                if (self.frame_count >= FRAMES_MAX) return error.StackOverflow;

                // 新しいフレームを作成
                self.frames[self.frame_count] = .{
                    .proto = proto,
                    .ip = 0,
                    .base = fn_idx + 1,
                    .closure = null,
                };
                self.frame_count += 1;

                // proto のコードを実行
                const result = try self.execute(proto.code, proto.constants);

                // 結果を push
                self.sp = fn_idx;
                try self.push(result);
            },
            .partial_fn => |p| {
                // partial_fn: 部分適用された引数と新しい引数を結合して呼び出し
                const partial_args = p.args;
                const new_args = self.stack[fn_idx + 1 .. self.sp];
                const total_args = partial_args.len + new_args.len;

                // 引数を一時保存
                var combined_args = self.allocator.alloc(Value, total_args) catch return error.OutOfMemory;
                defer self.allocator.free(combined_args);

                @memcpy(combined_args[0..partial_args.len], partial_args);
                @memcpy(combined_args[partial_args.len..], new_args);

                // スタックを巻き戻して新しい引数をプッシュ
                self.sp = fn_idx;
                try self.push(p.fn_val);
                for (combined_args) |arg| {
                    try self.push(arg);
                }

                // 元の関数を呼び出し（再帰的にpartial_fnもサポート）
                try self.callValue(total_args);
            },
            .comp_fn => |c| {
                // comp_fn: 右から左へ関数を適用
                // ((comp f g h) x) => (f (g (h x)))
                if (c.fns.len == 0) {
                    // (comp) は identity、最初の引数を返す
                    self.sp = fn_idx;
                    if (arg_count > 0) {
                        const args = self.stack[fn_idx + 1 .. fn_idx + 1 + arg_count];
                        try self.push(args[0]);
                    } else {
                        try self.push(value_mod.nil);
                    }
                    return;
                }

                // 引数を取り出す
                const args = self.stack[fn_idx + 1 .. fn_idx + 1 + arg_count];
                const args_copy = self.allocator.alloc(Value, arg_count) catch return error.OutOfMemory;
                defer self.allocator.free(args_copy);
                @memcpy(args_copy, args);

                // スタックを巻き戻し
                self.sp = fn_idx;

                // 最後の関数に引数を適用
                try self.push(c.fns[c.fns.len - 1]);
                for (args_copy) |arg| {
                    try self.push(arg);
                }
                try self.callValue(arg_count);

                // 残りの関数を右から左へ適用（1引数で呼び出し）
                var i = c.fns.len - 1;
                while (i > 0) {
                    i -= 1;
                    const result = self.pop();
                    try self.push(c.fns[i]);
                    try self.push(result);
                    try self.callValue(1);
                }
            },
            .keyword => |k| {
                // キーワードを関数として使用: (:key map) or (:key map default)
                if (arg_count < 1 or arg_count > 2) return error.ArityError;
                const args = self.stack[fn_idx + 1 .. self.sp];
                const not_found = if (arg_count == 2) args[1] else value_mod.nil;
                const result = switch (args[0]) {
                    .map => |m| m.get(Value{ .keyword = k }) orelse not_found,
                    .set => |s| blk: {
                        const kv = Value{ .keyword = k };
                        for (s.items) |item| {
                            if (kv.eql(item)) break :blk kv;
                        }
                        break :blk not_found;
                    },
                    else => not_found,
                };
                self.sp = fn_idx;
                try self.push(result);
            },
            else => return error.TypeError,
        }
    }

    /// クロージャを作成
    fn createClosure(self: *VM, proto_val: Value) VMError!void {
        if (proto_val != .fn_proto) return error.InvalidInstruction;

        // FnProto から Fn オブジェクトを作成
        const proto: *const FnProto = @ptrCast(@alignCast(proto_val.fn_proto));

        const fn_obj = self.allocator.create(value_mod.Fn) catch return error.OutOfMemory;
        const runtime_arities = self.allocator.alloc(value_mod.FnArityRuntime, 1) catch return error.OutOfMemory;

        // パラメータ名のダミー配列を作成（アリティチェック用に正しい長さが必要）
        const dummy_params = self.allocator.alloc([]const u8, proto.arity) catch return error.OutOfMemory;
        for (0..proto.arity) |i| {
            dummy_params[i] = ""; // ダミー名
        }

        runtime_arities[0] = .{
            .params = dummy_params,
            .variadic = proto.variadic,
            .body = @ptrCast(@constCast(proto)),
        };

        // 現在のフレームのローカル変数をキャプチャ
        // 注: frame.base > 0 の場合のみキャプチャ（ネストされたスコープ内）
        // frame.base == 0 はトップレベルなのでキャプチャ不要
        const frame = &self.frames[self.frame_count - 1];
        const closure_bindings: ?[]const Value = if (frame.base > 0) blk: {
            const locals_count = self.sp - frame.base;
            if (locals_count > 0) {
                const bindings = self.allocator.alloc(Value, locals_count) catch return error.OutOfMemory;
                for (0..locals_count) |i| {
                    bindings[i] = self.stack[frame.base + i];
                }
                break :blk bindings;
            }
            break :blk null;
        } else null;

        fn_obj.* = .{
            .name = if (proto.name) |n| value_mod.Symbol.init(n) else null,
            .arities = runtime_arities,
            .closure_bindings = closure_bindings,
        };

        try self.push(Value{ .fn_val = fn_obj });
    }

    /// 複数アリティのクロージャを作成
    /// スタック上に arity_count 個の FnProto があることを期待
    fn createMultiClosure(self: *VM, arity_count: usize) VMError!void {
        // FnProtos をスタックから取り出す（逆順で）
        var protos = self.allocator.alloc(*const FnProto, arity_count) catch return error.OutOfMemory;
        defer self.allocator.free(protos);

        var i = arity_count;
        while (i > 0) {
            i -= 1;
            const val = self.pop();
            if (val != .fn_proto) return error.InvalidInstruction;
            protos[i] = @ptrCast(@alignCast(val.fn_proto));
        }

        // Fn オブジェクトを作成
        const fn_obj = self.allocator.create(value_mod.Fn) catch return error.OutOfMemory;
        const runtime_arities = self.allocator.alloc(value_mod.FnArityRuntime, arity_count) catch return error.OutOfMemory;

        for (protos, 0..) |proto, idx| {
            // パラメータ名のダミー配列を作成
            const dummy_params = self.allocator.alloc([]const u8, proto.arity) catch return error.OutOfMemory;
            for (0..proto.arity) |j| {
                dummy_params[j] = "";
            }

            runtime_arities[idx] = .{
                .params = dummy_params,
                .variadic = proto.variadic,
                .body = @ptrCast(@constCast(proto)),
            };
        }

        // クロージャバインディングをキャプチャ
        const closure_bindings: ?[]const Value = if (self.frame_count > 0) blk: {
            const frame = &self.frames[self.frame_count - 1];
            const locals_count = self.sp - frame.base;
            if (locals_count > 0) {
                const bindings = self.allocator.alloc(Value, locals_count) catch return error.OutOfMemory;
                for (0..locals_count) |j| {
                    bindings[j] = self.stack[frame.base + j];
                }
                break :blk bindings;
            }
            break :blk null;
        } else null;

        // 関数名（最初の proto から取得）
        const name: ?value_mod.Symbol = if (protos.len > 0 and protos[0].name != null)
            value_mod.Symbol.init(protos[0].name.?)
        else
            null;

        fn_obj.* = .{
            .name = name,
            .arities = runtime_arities,
            .closure_bindings = closure_bindings,
        };

        try self.push(Value{ .fn_val = fn_obj });
    }

    /// partial 関数を作成
    fn createPartialFn(self: *VM, arg_count: usize) VMError!void {
        // スタック: [fn, arg1, arg2, ..., argN] (argN がトップ)
        // 引数を取り出す（逆順で）
        var args = self.allocator.alloc(Value, arg_count) catch return error.OutOfMemory;
        var i = arg_count;
        while (i > 0) {
            i -= 1;
            args[i] = self.pop();
        }

        // 関数を取り出す
        const fn_val = self.pop();

        // PartialFn を作成
        const partial = self.allocator.create(value_mod.PartialFn) catch return error.OutOfMemory;
        partial.* = .{
            .fn_val = fn_val,
            .args = args,
        };

        try self.push(Value{ .partial_fn = partial });
    }

    /// comp 関数を作成
    fn createCompFn(self: *VM, fn_count: usize) VMError!void {
        // スタック: [f1, f2, f3, ...] (最後の関数がトップ)
        // 0個の場合は identity を返す（nil として代用）
        if (fn_count == 0) {
            try self.push(value_mod.nil);
            return;
        }

        // 1個の場合はその関数をそのまま返す
        if (fn_count == 1) {
            // スタックにすでに関数があるので何もしない
            return;
        }

        // 関数を取り出す（逆順で）
        var fns = self.allocator.alloc(Value, fn_count) catch return error.OutOfMemory;
        var i = fn_count;
        while (i > 0) {
            i -= 1;
            fns[i] = self.pop();
        }

        // CompFn を作成
        const comp = self.allocator.create(value_mod.CompFn) catch return error.OutOfMemory;
        comp.* = .{
            .fns = fns,
        };

        try self.push(Value{ .comp_fn = comp });
    }

    /// reduce を実行
    fn executeReduce(self: *VM, has_init: bool) VMError!void {
        // スタック:
        //   初期値あり: [関数, 初期値, コレクション] (コレクションがトップ)
        //   初期値なし: [関数, コレクション] (コレクションがトップ)

        // コレクションを取り出し
        const coll_val = self.pop();
        const items: []const Value = switch (coll_val) {
            .list => |l| l.items,
            .vector => |v| v.items,
            .nil => &[_]Value{},
            else => return error.TypeError,
        };

        // 初期値とスタート位置を決定
        var acc: Value = undefined;
        var start_idx: usize = 0;

        if (has_init) {
            // 初期値あり
            acc = self.pop();
        } else {
            // 初期値なし - 最初の要素を使用
            if (items.len == 0) {
                // 空コレクションで初期値なし - 関数を 0 引数で呼び出す
                // 関数はスタックにある
                try self.callValue(0);
                return;
            }
            acc = items[0];
            start_idx = 1;
        }

        // 関数を取り出し
        const fn_val = self.pop();

        // 畳み込みを実行
        for (items[start_idx..]) |item| {
            // スタックに [関数, acc, item] をプッシュして呼び出し
            try self.push(fn_val);
            try self.push(acc);
            try self.push(item);
            try self.callValue(2);

            // 結果を取得
            acc = self.pop();
        }

        // 結果をプッシュ
        try self.push(acc);
    }

    /// map を実行
    /// スタック: [関数, コレクション] (コレクションがトップ)
    fn executeMap(self: *VM) VMError!void {
        const coll_val = self.pop();
        const fn_val = self.pop();

        const items: []const Value = switch (coll_val) {
            .list => |l| l.items,
            .vector => |v| v.items,
            .nil => &[_]Value{},
            else => return error.TypeError,
        };

        // 各要素に関数を適用
        var result_items = self.allocator.alloc(Value, items.len) catch return error.OutOfMemory;
        for (items, 0..) |item, i| {
            try self.push(fn_val);
            try self.push(item);
            try self.callValue(1);
            result_items[i] = self.pop();
        }

        const result_list = self.allocator.create(value_mod.PersistentList) catch return error.OutOfMemory;
        result_list.* = .{ .items = result_items };
        try self.push(Value{ .list = result_list });
    }

    /// filter を実行
    /// スタック: [関数, コレクション] (コレクションがトップ)
    fn executeFilter(self: *VM) VMError!void {
        const coll_val = self.pop();
        const fn_val = self.pop();

        const items: []const Value = switch (coll_val) {
            .list => |l| l.items,
            .vector => |v| v.items,
            .nil => &[_]Value{},
            else => return error.TypeError,
        };

        // 述語が真の要素だけ集める
        var result_buf: std.ArrayListUnmanaged(Value) = .empty;
        for (items) |item| {
            try self.push(fn_val);
            try self.push(item);
            try self.callValue(1);
            const pred_result = self.pop();
            if (pred_result.isTruthy()) {
                result_buf.append(self.allocator, item) catch return error.OutOfMemory;
            }
        }

        const result_list = self.allocator.create(value_mod.PersistentList) catch return error.OutOfMemory;
        result_list.* = .{ .items = result_buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
        try self.push(Value{ .list = result_list });
    }

    /// def を実行
    fn runDef(self: *VM, name_val: Value, is_macro: bool) VMError!void {
        const val = self.pop();

        // シンボル名を取得
        const name = switch (name_val) {
            .symbol => |s| s.name,
            else => return error.InvalidInstruction,
        };

        // Var を作成
        const ns = self.env.getCurrentNs() orelse return error.UndefinedVar;
        const v = ns.intern(name) catch return error.OutOfMemory;
        v.bindRoot(val);
        if (is_macro) {
            v.setMacro(true);
        }

        // nil を push（戻り値）
        try self.push(value_mod.nil);
    }

    /// apply を実行
    /// スタック: [... fn, arg0, arg1, ..., seq]
    fn applyValue(self: *VM, middle_count: usize) VMError!void {
        // シーケンスを取り出す（スタックトップ）
        const seq_val = self.pop();

        // シーケンスから要素を抽出
        const seq_items: []const Value = switch (seq_val) {
            .list => |l| l.items,
            .vector => |v| v.items,
            .nil => &[_]Value{},
            else => return error.TypeError,
        };

        // 中間引数を取り出す
        var middle_args = self.allocator.alloc(Value, middle_count) catch return error.OutOfMemory;
        defer self.allocator.free(middle_args);
        var i = middle_count;
        while (i > 0) {
            i -= 1;
            middle_args[i] = self.pop();
        }

        // 全引数を結合してスタックに戻す
        const total_args = middle_count + seq_items.len;
        for (middle_args) |arg| {
            try self.push(arg);
        }
        for (seq_items) |item| {
            try self.push(item);
        }

        // callValue を呼び出す
        try self.callValue(total_args);
    }

    // === 例外ハンドリング ===

    /// 例外を処理: ハンドラを検索して catch 節にジャンプ
    /// ハンドラがあれば true を返し、なければ false を返す
    fn handleThrow(self: *VM, thrown: Value) bool {
        if (self.handler_count == 0) {
            // ハンドラなし: pending に設定して呼び出し元に伝搬
            self.pending_exception = true;
            self.pending_exception_value = thrown;
            return false;
        }

        // ハンドラをポップ
        self.handler_count -= 1;
        const handler = self.handlers[self.handler_count];

        // スタックを巻き戻し
        self.sp = handler.saved_sp;

        // フレームを巻き戻し
        self.frame_count = handler.saved_frame_count;

        // 例外値をスタックにプッシュ（catch バインディング用）
        self.push(thrown) catch {
            self.pending_exception = true;
            self.pending_exception_value = thrown;
            return false;
        };

        // catch 節の IP にジャンプ
        self.frames[self.frame_count - 1].ip = handler.catch_ip;
        return true;
    }

    /// callValue のラッパー: UserException をハンドラに転送
    fn callValueWithExceptionHandling(self: *VM, arg_count: usize) VMError!void {
        self.callValue(arg_count) catch |e| {
            if (e == error.UserException and self.handleThrowFromError()) return;
            return e;
        };
    }

    /// applyValue のラッパー: UserException をハンドラに転送
    fn applyValueWithExceptionHandling(self: *VM, middle_count: usize) VMError!void {
        self.applyValue(middle_count) catch |e| {
            if (e == error.UserException and self.handleThrowFromError()) return;
            return e;
        };
    }

    /// executeReduce のラッパー: UserException をハンドラに転送
    fn executeReduceWithExceptionHandling(self: *VM, has_init: bool) VMError!void {
        self.executeReduce(has_init) catch |e| {
            if (e == error.UserException and self.handleThrowFromError()) return;
            return e;
        };
    }

    /// executeMap のラッパー: UserException をハンドラに転送
    fn executeMapWithExceptionHandling(self: *VM) VMError!void {
        self.executeMap() catch |e| {
            if (e == error.UserException and self.handleThrowFromError()) return;
            return e;
        };
    }

    /// executeFilter のラッパー: UserException をハンドラに転送
    fn executeFilterWithExceptionHandling(self: *VM) VMError!void {
        self.executeFilter() catch |e| {
            if (e == error.UserException and self.handleThrowFromError()) return;
            return e;
        };
    }

    /// UserException エラーから例外値を取得してハンドラに転送
    /// ハンドラで処理できた場合 true を返す
    fn handleThrowFromError(self: *VM) bool {
        // pending_exception が設定されていればそれを使う
        if (self.pending_exception) {
            const thrown = self.pending_exception_value;
            self.pending_exception = false;
            self.pending_exception_value = value_mod.nil;
            return self.handleThrow(thrown);
        }

        // threadlocal から取得
        const err_mod = @import("../base/error.zig");
        if (err_mod.getThrownValue()) |thrown_ptr| {
            const thrown = @as(*const Value, @ptrCast(@alignCast(thrown_ptr))).*;
            return self.handleThrow(thrown);
        }

        return false;
    }

    // === Atom 操作 ===

    /// swap! を実行
    /// スタック: [atom, fn, arg1, ..., argN] (argN がトップ)
    fn executeSwapAtom(self: *VM, extra_arg_count: u16) VMError!void {
        // 追加引数を取り出し
        var extra_args = self.allocator.alloc(Value, extra_arg_count) catch return error.OutOfMemory;
        var i: usize = extra_arg_count;
        while (i > 0) {
            i -= 1;
            extra_args[i] = self.pop();
        }

        // 関数を取り出し
        const fn_val = self.pop();

        // Atom を取り出し
        const atom_val = self.pop();
        const atom_ptr = switch (atom_val) {
            .atom => |a| a,
            else => return error.TypeError,
        };

        // (f current-val extra-args...) を呼び出し
        try self.push(fn_val);
        try self.push(atom_ptr.value); // 現在の値
        for (extra_args) |arg| {
            try self.push(arg);
        }
        try self.callValue(1 + extra_arg_count);

        // 結果を取得して Atom を更新
        const new_val = self.pop();
        atom_ptr.value = new_val;
        try self.push(new_val);
    }

    /// executeSwapAtom のラッパー: UserException をハンドラに転送
    fn executeSwapAtomWithExceptionHandling(self: *VM, extra_arg_count: u16) VMError!void {
        self.executeSwapAtom(extra_arg_count) catch |e| {
            if (e == error.UserException and self.handleThrowFromError()) return;
            return e;
        };
    }

    // === スタック操作 ===

    fn push(self: *VM, val: Value) VMError!void {
        if (self.sp >= STACK_MAX) return error.StackOverflow;
        self.stack[self.sp] = val;
        self.sp += 1;
    }

    fn pop(self: *VM) Value {
        if (self.sp == 0) return value_mod.nil;
        self.sp -= 1;
        return self.stack[self.sp];
    }

    fn peek(self: *VM, distance: usize) VMError!Value {
        if (self.sp <= distance) return error.StackUnderflow;
        return self.stack[self.sp - 1 - distance];
    }
};

// === テスト ===

test "VM basic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    var vm = VM.init(allocator, &env);

    // 簡単なチャンク: nil を返す
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    try chunk.emitOp(.nil);
    try chunk.emitOp(.ret);

    const result = try vm.run(&chunk);
    try std.testing.expect(result.isNil());
}

test "VM constant" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    var vm = VM.init(allocator, &env);

    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    const idx = try chunk.addConstant(value_mod.intVal(42));
    try chunk.emit(.const_load, idx);
    try chunk.emitOp(.ret);

    const result = try vm.run(&chunk);
    try std.testing.expect(result.eql(value_mod.intVal(42)));
}
