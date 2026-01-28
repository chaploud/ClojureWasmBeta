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
    DivisionByZero,
};

/// VM 用 LazySeq force コールバック（threadlocal 経由で VM にアクセス）
threadlocal var current_vm: ?*VM = null;

fn vmForce(fn_val: Value, allocator: std.mem.Allocator) anyerror!Value {
    _ = allocator;
    const vm = current_vm orelse return error.TypeError;
    // スタックに関数をプッシュして callValue(0)
    try vm.push(fn_val);
    try vm.callValue(0);
    // 結果をポップ
    return vm.pop();
}

fn vmCall(fn_val: Value, args: []const Value, allocator: std.mem.Allocator) anyerror!Value {
    _ = allocator;
    const vm = current_vm orelse return error.TypeError;
    // スタックに関数と引数をプッシュ
    try vm.push(fn_val);
    for (args) |arg| {
        try vm.push(arg);
    }
    try vm.callValue(args.len);
    return vm.pop();
}

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
        // VM 用 LazySeq コールバックを設定
        current_vm = self;
        core.setForceCallback(&vmForce);
        core.setCallFn(&vmCall);
        core.setCurrentEnv(self.env);

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
                    // Var.deref() が動的バインディングフレームを参照する
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
                .defmulti => {
                    try self.runDefmulti(constants[instr.operand]);
                },
                .defmethod => {
                    try self.runDefmethod(constants[instr.operand]);
                },
                .defprotocol => {
                    try self.runDefprotocol(constants[instr.operand], constants);
                },
                .extend_type_method => {
                    try self.runExtendTypeMethod(constants[instr.operand]);
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
                .lazy_seq => {
                    // スタックからサンク関数をポップして LazySeq を作成
                    try self.executeLazySeq();
                },

                // ═══════════════════════════════════════════════════════
                // [H] loop/recur
                // ═══════════════════════════════════════════════════════
                .loop_start => {
                    // マーカーのみ、何もしない
                },
                .letfn_fixup => {
                    // letfn: ローカルスロット上の N 個のクロージャの closure_bindings を相互参照に更新
                    try self.letfnFixup(instr.operand);
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
                    const result = builtin(self.allocator, args) catch |e| {
                        return switch (e) {
                            error.ArityError => error.ArityError,
                            error.DivisionByZero => error.DivisionByZero,
                            error.OutOfMemory => error.OutOfMemory,
                            error.UserException => error.UserException,
                            else => error.TypeError,
                        };
                    };

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
            .protocol_fn => |pf| {
                // プロトコル関数呼び出し
                if (arg_count < 1) return error.ArityError;
                const args = self.stack[fn_idx + 1 .. self.sp];
                const args_copy = self.allocator.alloc(Value, arg_count) catch return error.OutOfMemory;
                defer self.allocator.free(args_copy);
                @memcpy(args_copy, args);

                // 第1引数の型キーワード
                const type_key_str = args[0].typeKeyword();

                // type_key を文字列 Value として作成
                const type_key_s = self.allocator.create(value_mod.String) catch return error.OutOfMemory;
                type_key_s.* = value_mod.String.init(type_key_str);
                const type_key = Value{ .string = type_key_s };

                // プロトコルの impls から型のメソッドマップを検索
                const methods_val = pf.protocol.impls.get(type_key) orelse
                    return error.TypeError;
                if (methods_val != .map) return error.TypeError;

                // メソッドマップから関数を検索
                const method_name_s = self.allocator.create(value_mod.String) catch return error.OutOfMemory;
                method_name_s.* = value_mod.String.init(pf.method_name);
                const method_key = Value{ .string = method_name_s };

                const method_fn = methods_val.map.get(method_key) orelse
                    return error.TypeError;

                // スタックを巻き戻して新しい関数と引数を配置
                self.sp = fn_idx;
                try self.push(method_fn);
                for (args_copy) |arg| {
                    try self.push(arg);
                }
                try self.callValue(arg_count);
            },
            .multi_fn => |mf| {
                // マルチメソッド呼び出し
                // 引数をローカルコピー
                const args = self.stack[fn_idx + 1 .. self.sp];
                const args_copy = self.allocator.alloc(Value, arg_count) catch return error.OutOfMemory;
                defer self.allocator.free(args_copy);
                @memcpy(args_copy, args);

                // スタックを巻き戻し
                self.sp = fn_idx;

                // ディスパッチ関数を呼び出し
                try self.push(mf.dispatch_fn);
                for (args_copy) |arg| {
                    try self.push(arg);
                }
                try self.callValue(arg_count);

                // ディスパッチ結果を取得
                const dispatch_result = self.pop();

                // メソッドを検索: 完全一致 → isa? → :default
                const method = mf.methods.get(dispatch_result) orelse
                    (core.findIsaMethodFromMultiFn(self.allocator, mf, dispatch_result) catch null) orelse
                    mf.default_method orelse return error.TypeError;

                // メソッドを呼び出し
                try self.push(method);
                for (args_copy) |arg| {
                    try self.push(arg);
                }
                try self.callValue(arg_count);
            },
            .var_val => |vp| {
                // Var を関数として呼び出し: (#'foo args...) → deref して再帰呼び出し
                const v: *var_mod.Var = @ptrCast(@alignCast(vp));
                const derefed = v.deref();
                self.stack[fn_idx] = derefed;
                try self.callValue(arg_count);
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
        // frame.base > 0: 関数内なので全ローカルをキャプチャ
        // frame.base == 0: トップレベルでは capture_count で指定された数だけキャプチャ
        //   （let スコープ内の fn の場合、コンパイラが capture_count を設定）
        const frame = &self.frames[self.frame_count - 1];
        const closure_bindings: ?[]const Value = blk: {
            if (frame.base > 0) {
                // 関数内: 全ローカルをキャプチャ
                const locals_count = self.sp - frame.base;
                if (locals_count > 0) {
                    const bindings = self.allocator.alloc(Value, locals_count) catch return error.OutOfMemory;
                    for (0..locals_count) |i| {
                        bindings[i] = self.stack[frame.base + i];
                    }
                    break :blk bindings;
                }
                break :blk null;
            } else if (proto.capture_count > 0) {
                // トップレベル let 内の fn: capture_offset から capture_count 分キャプチャ
                const cap_count = proto.capture_count;
                const cap_start = frame.base + proto.capture_offset;
                const bindings = self.allocator.alloc(Value, cap_count) catch return error.OutOfMemory;
                for (0..cap_count) |i| {
                    bindings[i] = self.stack[cap_start + i];
                }
                break :blk bindings;
            } else break :blk null;
        };

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
        // capture_count は全アリティ共通（同じ親スコープから生成されるため）
        const capture_count = if (protos.len > 0) protos[0].capture_count else 0;
        const closure_bindings: ?[]const Value = if (self.frame_count > 0) blk: {
            const frame = &self.frames[self.frame_count - 1];
            if (frame.base > 0) {
                // 関数内: 全ローカルをキャプチャ
                const locals_count = self.sp - frame.base;
                if (locals_count > 0) {
                    const bindings = self.allocator.alloc(Value, locals_count) catch return error.OutOfMemory;
                    for (0..locals_count) |j| {
                        bindings[j] = self.stack[frame.base + j];
                    }
                    break :blk bindings;
                }
                break :blk null;
            } else if (capture_count > 0) {
                // トップレベル let 内: capture_offset から capture_count 分キャプチャ
                const cap_offset = if (protos.len > 0) protos[0].capture_offset else 0;
                const cap_start = frame.base + cap_offset;
                const bindings = self.allocator.alloc(Value, capture_count) catch return error.OutOfMemory;
                for (0..capture_count) |j| {
                    bindings[j] = self.stack[cap_start + j];
                }
                break :blk bindings;
            } else break :blk null;
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

    /// letfn fixup: ローカルスロット上の N 個のクロージャの closure_bindings を相互参照に更新
    /// operand: 上位8bit = 先頭関数のスロット位置, 下位8bit = 関数の数
    /// 各クロージャの既存 closure_bindings 内の対応スロットを実際の関数値で更新
    fn letfnFixup(self: *VM, operand: u16) VMError!void {
        const base_slot: usize = operand >> 8;
        const fn_count: usize = operand & 0xFF;
        if (fn_count == 0) return;

        const frame = &self.frames[self.frame_count - 1];
        const fn_start = frame.base + base_slot;

        // 各クロージャの closure_bindings を更新
        for (0..fn_count) |i| {
            const fn_val = self.stack[fn_start + i];
            if (fn_val == .fn_val) {
                if (fn_val.fn_val.closure_bindings) |cb| {
                    // 既存の closure_bindings 内の letfn スロットを実際の関数値で更新
                    const mutable_cb: []Value = @constCast(cb);
                    for (0..fn_count) |j| {
                        if (base_slot + j < mutable_cb.len) {
                            mutable_cb[base_slot + j] = self.stack[fn_start + j];
                        }
                    }
                } else {
                    // closure_bindings がない場合（トップレベル letfn）: 新規作成
                    const bindings = self.allocator.alloc(Value, fn_count) catch return error.OutOfMemory;
                    for (0..fn_count) |j| {
                        bindings[j] = self.stack[fn_start + j];
                    }
                    fn_val.fn_val.closure_bindings = bindings;
                }
            }
        }
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

        // Var を push（戻り値 — #'ns/name 形式）
        try self.push(Value{ .var_val = @ptrCast(v) });
    }

    /// defmulti を実行
    /// スタック: [dispatch_fn] → [nil]
    fn runDefmulti(self: *VM, name_val: Value) VMError!void {
        const dispatch_fn = self.pop();

        const name = switch (name_val) {
            .symbol => |s| s.name,
            else => return error.InvalidInstruction,
        };

        // MultiFn を作成
        const empty_map = self.allocator.create(value_mod.PersistentMap) catch return error.OutOfMemory;
        empty_map.* = value_mod.PersistentMap.empty();

        const mf = self.allocator.create(value_mod.MultiFn) catch return error.OutOfMemory;
        mf.* = .{
            .name = value_mod.Symbol.init(name),
            .dispatch_fn = dispatch_fn,
            .methods = empty_map,
            .default_method = null,
            .prefer_table = null,
        };

        // Var にバインド
        const ns = self.env.getCurrentNs() orelse return error.UndefinedVar;
        const v = ns.intern(name) catch return error.OutOfMemory;
        v.bindRoot(Value{ .multi_fn = mf });

        try self.push(value_mod.nil);
    }

    /// defmethod を実行
    /// スタック: [dispatch_val, method_fn] → [nil]
    fn runDefmethod(self: *VM, name_val: Value) VMError!void {
        const method_fn = self.pop();
        const dispatch_val = self.pop();

        const name = switch (name_val) {
            .symbol => |s| s.name,
            else => return error.InvalidInstruction,
        };

        // Var から MultiFn を取得
        const ns = self.env.getCurrentNs() orelse return error.UndefinedVar;
        const v = ns.intern(name) catch return error.OutOfMemory;
        const mf_val = v.deref();
        if (mf_val != .multi_fn) return error.InvalidInstruction;
        const mf = mf_val.multi_fn;

        // :default キーワードかチェック
        const is_default = switch (dispatch_val) {
            .keyword => |k| std.mem.eql(u8, k.name, "default"),
            else => false,
        };

        if (is_default) {
            mf.default_method = method_fn;
        } else {
            // methods マップに追加
            const new_map = self.allocator.create(value_mod.PersistentMap) catch return error.OutOfMemory;
            new_map.* = mf.methods.assoc(self.allocator, dispatch_val, method_fn) catch return error.OutOfMemory;
            mf.methods = new_map;
        }

        try self.push(value_mod.nil);
    }

    /// defprotocol を実行
    /// オペランド定数[idx] = プロトコル名シンボル、定数[idx+1] = メソッドシグネチャベクター
    fn runDefprotocol(self: *VM, name_val: Value, constants: []const Value) VMError!void {
        const name = switch (name_val) {
            .symbol => |s| s.name,
            else => return error.InvalidInstruction,
        };

        // 定数テーブルからメソッドシグネチャ情報を取得
        // name_val の次の定数がシグネチャベクター [name1, arity1, name2, arity2, ...]
        // name_val のインデックスを探す
        var name_idx: usize = 0;
        for (constants, 0..) |c, i| {
            if (c == .symbol and c.symbol == name_val.symbol) {
                name_idx = i;
                break;
            }
        }
        const sigs_vec = constants[name_idx + 1];
        if (sigs_vec != .vector) return error.InvalidInstruction;

        // Protocol 構造体を作成
        const empty_impls = self.allocator.create(value_mod.PersistentMap) catch return error.OutOfMemory;
        empty_impls.* = value_mod.PersistentMap.empty();

        const sig_count = sigs_vec.vector.items.len / 2;
        const method_sigs = self.allocator.alloc(value_mod.Protocol.MethodSig, sig_count) catch return error.OutOfMemory;
        var si: usize = 0;
        while (si < sig_count) : (si += 1) {
            const name_v = sigs_vec.vector.items[si * 2];
            const arity_v = sigs_vec.vector.items[si * 2 + 1];
            method_sigs[si] = .{
                .name = if (name_v == .string) name_v.string.data else return error.InvalidInstruction,
                .arity = if (arity_v == .int) @intCast(arity_v.int) else return error.InvalidInstruction,
            };
        }

        const proto = self.allocator.create(value_mod.Protocol) catch return error.OutOfMemory;
        proto.* = .{
            .name = value_mod.Symbol.init(name),
            .method_sigs = method_sigs,
            .impls = empty_impls,
        };

        // Var にバインド
        const ns = self.env.getCurrentNs() orelse return error.UndefinedVar;
        const v = ns.intern(name) catch return error.OutOfMemory;
        v.bindRoot(Value{ .protocol = proto });

        // 各メソッドについて ProtocolFn を作成
        for (method_sigs) |sig| {
            const pf = self.allocator.create(value_mod.ProtocolFn) catch return error.OutOfMemory;
            pf.* = .{
                .protocol = proto,
                .method_name = sig.name,
            };
            const mv = ns.intern(sig.name) catch return error.OutOfMemory;
            mv.bindRoot(Value{ .protocol_fn = pf });
        }

        try self.push(value_mod.nil);
    }

    /// extend-type メソッドを登録
    /// オペランド定数 = ベクター [type_name, protocol_name, method_name]
    /// スタック: [method_fn] → [nil]
    fn runExtendTypeMethod(self: *VM, meta_val: Value) VMError!void {
        const method_fn = self.pop();

        if (meta_val != .vector) return error.InvalidInstruction;
        const meta = meta_val.vector;
        if (meta.items.len != 3) return error.InvalidInstruction;

        const type_name_str = if (meta.items[0] == .string) meta.items[0].string.data else return error.InvalidInstruction;
        const proto_name_str = if (meta.items[1] == .string) meta.items[1].string.data else return error.InvalidInstruction;
        const method_name_str = if (meta.items[2] == .string) meta.items[2].string.data else return error.InvalidInstruction;

        // 型名を内部キーワードに変換
        const type_key_str = mapUserTypeName(type_name_str);

        // プロトコルの Var から Protocol を取得
        const ns = self.env.getCurrentNs() orelse return error.UndefinedVar;
        const proto_var = ns.intern(proto_name_str) catch return error.OutOfMemory;
        const proto_val = proto_var.deref();
        if (proto_val != .protocol) return error.InvalidInstruction;
        const proto = proto_val.protocol;

        // 型キーを作成
        const type_key_s = self.allocator.create(value_mod.String) catch return error.OutOfMemory;
        type_key_s.* = value_mod.String.init(type_key_str);
        const type_key = Value{ .string = type_key_s };

        // 既存のメソッドマップを取得（なければ空）
        var method_map = if (proto.impls.get(type_key)) |existing|
            if (existing == .map) existing.map.* else value_mod.PersistentMap.empty()
        else
            value_mod.PersistentMap.empty();

        // メソッドを追加
        const method_name_s = self.allocator.create(value_mod.String) catch return error.OutOfMemory;
        method_name_s.* = value_mod.String.init(method_name_str);
        const method_key = Value{ .string = method_name_s };
        method_map = method_map.assoc(self.allocator, method_key, method_fn) catch return error.OutOfMemory;

        // impls を更新
        const method_map_ptr = self.allocator.create(value_mod.PersistentMap) catch return error.OutOfMemory;
        method_map_ptr.* = method_map;
        const method_map_val = Value{ .map = method_map_ptr };

        const new_impls = self.allocator.create(value_mod.PersistentMap) catch return error.OutOfMemory;
        new_impls.* = proto.impls.assoc(self.allocator, type_key, method_map_val) catch return error.OutOfMemory;
        proto.impls = new_impls;

        try self.push(value_mod.nil);
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
        return name;
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

    /// callValue のラッパー: 例外をハンドラに転送
    fn callValueWithExceptionHandling(self: *VM, arg_count: usize) VMError!void {
        self.callValue(arg_count) catch |e| {
            if (self.handler_count > 0) {
                if (e == error.UserException) {
                    if (self.handleThrowFromError()) return;
                    return e;
                }
                // 内部エラーを Value に変換して catch ハンドラに転送
                const exception_val = self.internalErrorToValue(e);
                if (self.handleThrow(exception_val)) return;
            }
            return e;
        };
    }

    /// lazy-seq 実行: スタックからサンク関数をポップして LazySeq を作成
    fn executeLazySeq(self: *VM) VMError!void {
        const fn_val = self.pop();
        const ls = self.allocator.create(value_mod.LazySeq) catch return error.OutOfMemory;
        ls.* = value_mod.LazySeq.init(fn_val);
        try self.push(Value{ .lazy_seq = ls });
    }

    /// 内部エラーを Value マップに変換（TreeWalk の internalErrorToValue と同等）
    /// {:type :type-error, :message "..."} 形式
    fn internalErrorToValue(self: *VM, e: VMError) Value {
        const type_str: []const u8 = switch (e) {
            error.TypeError => "type-error",
            error.ArityError => "arity-error",
            error.UndefinedVar => "undefined-symbol",
            error.DivisionByZero => "division-by-zero",
            error.StackOverflow => "stack-overflow",
            error.StackUnderflow => "stack-underflow",
            error.OutOfMemory => "out-of-memory",
            error.InvalidInstruction => "invalid-instruction",
            error.UserException => "user-exception",
        };

        // {:type :type-error, :message "..."} マップを作成
        const map_ptr = self.allocator.create(value_mod.PersistentMap) catch return value_mod.nil;
        const entries = self.allocator.alloc(Value, 4) catch return value_mod.nil;

        // :type キー
        const type_kw = self.allocator.create(value_mod.Keyword) catch return value_mod.nil;
        type_kw.* = value_mod.Keyword.init("type");
        entries[0] = Value{ .keyword = type_kw };

        // :type 値（キーワード）
        const err_type_kw = self.allocator.create(value_mod.Keyword) catch return value_mod.nil;
        err_type_kw.* = value_mod.Keyword.init(type_str);
        entries[1] = Value{ .keyword = err_type_kw };

        // :message キー
        const msg_kw = self.allocator.create(value_mod.Keyword) catch return value_mod.nil;
        msg_kw.* = value_mod.Keyword.init("message");
        entries[2] = Value{ .keyword = msg_kw };

        // :message 値（文字列）
        const msg_str = self.allocator.create(value_mod.String) catch return value_mod.nil;
        msg_str.* = value_mod.String.init(type_str);
        entries[3] = Value{ .string = msg_str };

        map_ptr.* = .{ .entries = entries };
        return Value{ .map = map_ptr };
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
