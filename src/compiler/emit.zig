//! Emit: コード生成
//!
//! Node からバイトコードを生成する。
//!
//! 処理フロー:
//!   Form (Reader) → Node (Analyzer) → Bytecode (Compiler) → Value (VM)

const std = @import("std");
const bytecode = @import("bytecode.zig");
const Chunk = bytecode.Chunk;
const OpCode = bytecode.OpCode;
const FnProto = bytecode.FnProto;
const node_mod = @import("../analyzer/node.zig");
const Node = node_mod.Node;
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../runtime/var.zig");
const Var = var_mod.Var;

/// コンパイルエラー
pub const CompileError = error{
    OutOfMemory,
    TooManyConstants,
    TooManyLocals,
    InvalidNode,
};

/// ローカル変数情報
const Local = struct {
    name: []const u8,
    depth: u32,
};

/// コンパイラ状態
pub const Compiler = struct {
    allocator: std.mem.Allocator,
    chunk: Chunk,
    /// ローカル変数テーブル
    locals: std.ArrayListUnmanaged(Local),
    /// スコープ深度
    scope_depth: u32,
    /// loop 開始位置（recur 用）
    loop_start: ?usize,

    /// 初期化
    pub fn init(allocator: std.mem.Allocator) Compiler {
        return .{
            .allocator = allocator,
            .chunk = Chunk.init(allocator),
            .locals = .empty,
            .scope_depth = 0,
            .loop_start = null,
        };
    }

    /// 解放
    pub fn deinit(self: *Compiler) void {
        self.chunk.deinit();
        self.locals.deinit(self.allocator);
    }

    /// 結果の Chunk を取得（所有権移動）
    pub fn takeChunk(self: *Compiler) Chunk {
        const result = self.chunk;
        self.chunk = Chunk.init(self.allocator);
        return result;
    }

    /// Node をコンパイル
    pub fn compile(self: *Compiler, n: *const Node) CompileError!void {
        switch (n.*) {
            .constant => |val| try self.emitConstant(val),
            .var_ref => |ref| try self.emitVarRef(ref),
            .local_ref => |ref| try self.emitLocalRef(ref),
            .if_node => |node| try self.emitIf(node),
            .do_node => |node| try self.emitDo(node),
            .let_node => |node| try self.emitLet(node),
            .loop_node => |node| try self.emitLoop(node),
            .recur_node => |node| try self.emitRecur(node),
            .fn_node => |node| try self.emitFn(node),
            .call_node => |node| try self.emitCall(node),
            .def_node => |node| try self.emitDef(node),
            .quote_node => |node| try self.emitQuote(node),
            .throw_node => return error.InvalidNode, // TODO
            .apply_node => |node| try self.emitApply(node),
        }
    }

    // === 各ノードのコンパイル ===

    /// 定数をプッシュ
    fn emitConstant(self: *Compiler, val: Value) CompileError!void {
        // 特殊値の最適化
        if (val.isNil()) {
            try self.chunk.emitOp(.nil);
            return;
        }
        switch (val) {
            .bool_val => |b| {
                if (b) {
                    try self.chunk.emitOp(.true_val);
                } else {
                    try self.chunk.emitOp(.false_val);
                }
                return;
            },
            else => {},
        }

        // 一般の定数
        const idx = self.chunk.addConstant(val) catch return error.TooManyConstants;
        try self.chunk.emit(.const_load, idx);
    }

    /// Var 参照
    fn emitVarRef(self: *Compiler, ref: node_mod.VarRefNode) CompileError!void {
        // Var ポインタを定数として格納
        const var_val = Value{ .var_val = ref.var_ref };
        const idx = self.chunk.addConstant(var_val) catch return error.TooManyConstants;
        try self.chunk.emit(.var_load, idx);
    }

    /// ローカル変数参照
    fn emitLocalRef(self: *Compiler, ref: node_mod.LocalRefNode) CompileError!void {
        try self.chunk.emit(.local_load, @intCast(ref.idx));
    }

    /// if
    fn emitIf(self: *Compiler, node: *const node_mod.IfNode) CompileError!void {
        // test をコンパイル
        try self.compile(node.test_node);

        // false ならジャンプ（then をスキップ）
        const jump_if_false = self.chunk.emitJump(.jump_if_false) catch return error.OutOfMemory;

        // then をコンパイル
        try self.compile(node.then_node);

        // else をスキップするジャンプ
        const jump_over_else = self.chunk.emitJump(.jump) catch return error.OutOfMemory;

        // false ジャンプ先をパッチ
        self.chunk.patchJump(jump_if_false);

        // else をコンパイル
        if (node.else_node) |else_n| {
            try self.compile(else_n);
        } else {
            try self.chunk.emitOp(.nil);
        }

        // else スキップジャンプ先をパッチ
        self.chunk.patchJump(jump_over_else);
    }

    /// do
    fn emitDo(self: *Compiler, node: *const node_mod.DoNode) CompileError!void {
        if (node.statements.len == 0) {
            try self.chunk.emitOp(.nil);
            return;
        }

        for (node.statements, 0..) |stmt, i| {
            try self.compile(stmt);
            // 最後以外は pop
            if (i < node.statements.len - 1) {
                try self.chunk.emitOp(.pop);
            }
        }
    }

    /// let
    fn emitLet(self: *Compiler, node: *const node_mod.LetNode) CompileError!void {
        // スコープ開始
        self.scope_depth += 1;
        const base_locals = self.locals.items.len;

        // バインディングをコンパイル
        for (node.bindings) |binding| {
            try self.compile(binding.init);
            // ローカル変数を追加
            try self.addLocal(binding.name);
        }

        // ボディをコンパイル
        try self.compile(node.body);

        // スコープ終了、ローカルを pop
        const locals_to_pop = self.locals.items.len - base_locals;
        // ボディの結果を保存するため、結果を残して他を pop
        if (locals_to_pop > 0) {
            // 結果をスタックトップに持ち上げるため、
            // locals_to_pop 個の値を除去する必要がある
            // 簡易実装: 各ローカルを pop してから結果を戻す
            // より効率的な方法は swap + pop だが、ここでは簡易実装
            for (0..locals_to_pop) |_| {
                // 結果とローカルを入れ替えて pop
                // TODO: 効率化（swap命令追加）
            }
        }

        // ローカルを削除
        self.locals.shrinkRetainingCapacity(base_locals);
        self.scope_depth -= 1;
    }

    /// loop
    fn emitLoop(self: *Compiler, node: *const node_mod.LoopNode) CompileError!void {
        // スコープ開始
        self.scope_depth += 1;
        const base_locals = self.locals.items.len;

        // 初期バインディングをコンパイル
        for (node.bindings) |binding| {
            try self.compile(binding.init);
            try self.addLocal(binding.name);
        }

        // ループ開始位置を記録
        const loop_start_pos = self.chunk.currentOffset();
        const prev_loop_start = self.loop_start;
        self.loop_start = loop_start_pos;

        // ボディをコンパイル
        try self.compile(node.body);

        // ループ開始位置を復元
        self.loop_start = prev_loop_start;

        // ローカルを削除
        self.locals.shrinkRetainingCapacity(base_locals);
        self.scope_depth -= 1;
    }

    /// recur
    fn emitRecur(self: *Compiler, node: *const node_mod.RecurNode) CompileError!void {
        // 引数をコンパイル
        for (node.args) |arg| {
            try self.compile(arg);
        }

        // recur 命令を発行
        try self.chunk.emit(.recur, @intCast(node.args.len));

        // ループ先頭へジャンプ
        if (self.loop_start) |start| {
            try self.chunk.emitLoop(start);
        }
    }

    /// fn（クロージャ作成）
    fn emitFn(self: *Compiler, node: *const node_mod.FnNode) CompileError!void {
        // 関数本体を別の Compiler でコンパイル
        // 各アリティ毎に FnProto を作成

        if (node.arities.len == 0) {
            try self.chunk.emitOp(.nil);
            return;
        }

        // 単一アリティの場合は最適化パス
        if (node.arities.len == 1) {
            const proto = try self.compileArity(node.name, node.arities[0]);
            const proto_val = Value{ .fn_proto = proto };
            const idx = self.chunk.addConstant(proto_val) catch return error.TooManyConstants;
            try self.chunk.emit(.closure, idx);
            return;
        }

        // 複数アリティ: 各アリティの FnProto をスタックにプッシュ
        for (node.arities) |arity| {
            const proto = try self.compileArity(node.name, arity);
            const proto_val = Value{ .fn_proto = proto };
            const idx = self.chunk.addConstant(proto_val) catch return error.TooManyConstants;
            try self.chunk.emit(.const_load, idx);
        }

        // closure_multi 命令で結合
        try self.chunk.emit(.closure_multi, @intCast(node.arities.len));
    }

    /// 単一アリティをコンパイルして FnProto を返す
    fn compileArity(self: *Compiler, name: ?[]const u8, arity: node_mod.FnArity) CompileError!*FnProto {
        // 関数本体用のコンパイラ
        var fn_compiler = Compiler.init(self.allocator);
        defer fn_compiler.deinit();

        // 引数をローカルとして追加
        fn_compiler.scope_depth = 1;
        for (arity.params) |param| {
            try fn_compiler.addLocal(param);
        }

        // ボディをコンパイル
        try fn_compiler.compile(arity.body);
        try fn_compiler.chunk.emitOp(.ret);

        // FnProto を作成
        const proto = self.allocator.create(FnProto) catch return error.OutOfMemory;
        var fn_chunk = fn_compiler.takeChunk();
        proto.* = .{
            .name = name,
            .arity = @intCast(arity.params.len),
            .variadic = arity.variadic,
            .local_count = @intCast(fn_compiler.locals.items.len),
            .code = fn_chunk.code.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .constants = fn_chunk.constants.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
        };

        return proto;
    }

    /// call
    fn emitCall(self: *Compiler, node: *const node_mod.CallNode) CompileError!void {
        // 関数をコンパイル
        try self.compile(node.fn_node);

        // 引数をコンパイル
        for (node.args) |arg| {
            try self.compile(arg);
        }

        // call 命令
        try self.chunk.emit(.call, @intCast(node.args.len));
    }

    /// def
    fn emitDef(self: *Compiler, node: *const node_mod.DefNode) CompileError!void {
        // 初期値をコンパイル
        if (node.init) |init_node| {
            try self.compile(init_node);
        } else {
            try self.chunk.emitOp(.nil);
        }

        // シンボル名をシンボル Value として追加
        const sym = self.allocator.create(value_mod.Symbol) catch return error.OutOfMemory;
        sym.* = value_mod.Symbol.init(node.sym_name);
        const name_val = Value{ .symbol = sym };
        const idx = self.chunk.addConstant(name_val) catch return error.TooManyConstants;

        // def/defmacro 命令
        if (node.is_macro) {
            try self.chunk.emit(.def_macro, idx);
        } else {
            try self.chunk.emit(.def, idx);
        }
    }

    /// quote
    fn emitQuote(self: *Compiler, node: *const node_mod.QuoteNode) CompileError!void {
        try self.emitConstant(node.form);
    }

    /// apply
    /// (apply f args) または (apply f x y z args)
    fn emitApply(self: *Compiler, node: *const node_mod.ApplyNode) CompileError!void {
        // 関数をコンパイル
        try self.compile(node.fn_node);

        // 中間引数をコンパイル
        for (node.args) |arg| {
            try self.compile(arg);
        }

        // シーケンス引数をコンパイル
        try self.compile(node.seq_node);

        // apply 命令（オペランド: 中間引数の数）
        try self.chunk.emit(.apply, @intCast(node.args.len));
    }

    // === ヘルパー ===

    /// ローカル変数を追加
    fn addLocal(self: *Compiler, name: []const u8) CompileError!void {
        if (self.locals.items.len >= std.math.maxInt(u16)) {
            return error.TooManyLocals;
        }
        self.locals.append(self.allocator, .{
            .name = name,
            .depth = self.scope_depth,
        }) catch return error.OutOfMemory;
    }
};

// === テスト ===

test "compile constant" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    var constant_node = Node{ .constant = value_mod.intVal(42) };
    try compiler.compile(&constant_node);

    try std.testing.expectEqual(@as(usize, 1), compiler.chunk.code.items.len);
    try std.testing.expectEqual(OpCode.const_load, compiler.chunk.code.items[0].op);
}

test "compile nil" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    var nil_node = Node{ .constant = value_mod.nil };
    try compiler.compile(&nil_node);

    try std.testing.expectEqual(@as(usize, 1), compiler.chunk.code.items.len);
    try std.testing.expectEqual(OpCode.nil, compiler.chunk.code.items[0].op);
}

test "compile if" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    // (if true 1 2)
    var test_node = Node{ .constant = value_mod.true_val };
    var then_node = Node{ .constant = value_mod.intVal(1) };
    var else_node = Node{ .constant = value_mod.intVal(2) };

    const if_data = try allocator.create(node_mod.IfNode);
    if_data.* = .{
        .test_node = &test_node,
        .then_node = &then_node,
        .else_node = &else_node,
        .stack = .{},
    };

    var if_node = Node{ .if_node = if_data };
    try compiler.compile(&if_node);

    // true_val, jump_if_false, const_load(1), jump, const_load(2)
    try std.testing.expectEqual(@as(usize, 5), compiler.chunk.code.items.len);
}
