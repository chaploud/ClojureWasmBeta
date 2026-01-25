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
};

/// スタックサイズ
const STACK_MAX: usize = 256 * 64;

/// コールフレームの最大数
const FRAMES_MAX: usize = 64;

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

    /// 初期化
    pub fn init(allocator: std.mem.Allocator, env: *Env) VM {
        return .{
            .allocator = allocator,
            .stack = undefined,
            .sp = 0,
            .frames = undefined,
            .frame_count = 0,
            .env = env,
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
                    try self.callValue(@intCast(arg_count));
                },
                .call_0 => try self.callValue(0),
                .call_1 => try self.callValue(1),
                .call_2 => try self.callValue(2),
                .call_3 => try self.callValue(3),
                .tail_call => {
                    // TODO: 末尾呼び出し最適化
                    const arg_count = instr.operand;
                    try self.callValue(@intCast(arg_count));
                },
                .apply => {
                    // TODO: apply 実装
                    return error.InvalidInstruction;
                },
                .ret => {
                    const result = self.pop();

                    // フレームを戻す
                    self.frame_count -= 1;
                    if (self.frame_count == 0) {
                        return result;
                    }

                    // スタックをフレームベースまで戻す
                    const prev_frame = &self.frames[self.frame_count - 1];
                    self.sp = frame.base;

                    // 結果を push
                    try self.push(result);

                    // 前のフレームの命令に戻る
                    _ = prev_frame;
                },
                .closure => {
                    const proto_val = constants[instr.operand];
                    // FnProto から Fn を作成
                    try self.createClosure(proto_val);
                },

                // ═══════════════════════════════════════════════════════
                // [H] loop/recur
                // ═══════════════════════════════════════════════════════
                .loop_start => {
                    // マーカーのみ、何もしない
                },
                .recur => {
                    // recur は loop 内で処理されるので、ここでは何もしない
                    // 実際の処理は emitLoop で生成された jump で行われる
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
                // [K] 例外処理（未実装）
                // ═══════════════════════════════════════════════════════
                .try_begin, .catch_begin, .finally_begin, .try_end, .throw_ex => {
                    // TODO: Phase 9 で実装
                    return error.InvalidInstruction;
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

                // 新しいフレームを作成
                self.frames[self.frame_count] = .{
                    .proto = null, // Tree-walk スタイルの関数
                    .ip = 0,
                    .base = fn_idx + 1,
                    .closure = f.closure_bindings,
                };
                self.frame_count += 1;

                // TODO: ユーザー定義関数の実行
                _ = arity;
                return error.InvalidInstruction;
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
        runtime_arities[0] = .{
            .params = &[_][]const u8{}, // TODO: パラメータ名
            .variadic = proto.variadic,
            .body = @ptrCast(@constCast(proto)),
        };

        fn_obj.* = .{
            .name = if (proto.name) |n| value_mod.Symbol.init(n) else null,
            .arities = runtime_arities,
            .closure_bindings = null, // TODO: キャプチャ
        };

        try self.push(Value{ .fn_val = fn_obj });
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
