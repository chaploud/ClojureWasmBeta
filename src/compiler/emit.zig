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
    slot: u16, // frame.base からの実際のスタック位置
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
    /// loop バインディングの開始インデックス（recur が正しいスロットに書き込むために必要）
    loop_locals_base: usize,
    /// コンパイル時スタック深度（frame.base からの相対位置）
    sp_depth: u16,
    /// Analyzer のグローバルローカルインデックスにおける、
    /// このコンパイラの locals[0] の開始位置。
    /// fn_compiler が親スコープ変数と自スコープ変数を区別するために使用。
    locals_offset: u32,

    /// 初期化
    pub fn init(allocator: std.mem.Allocator) Compiler {
        return .{
            .allocator = allocator,
            .chunk = Chunk.init(allocator),
            .locals = .empty,
            .scope_depth = 0,
            .loop_start = null,
            .loop_locals_base = 0,
            .sp_depth = 0,
            .locals_offset = 0,
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
            .letfn_node => |node| try self.emitLetfn(node),
            .call_node => |node| try self.emitCall(node),
            .def_node => |node| try self.emitDef(node),
            .quote_node => |node| try self.emitQuote(node),
            .throw_node => |node| try self.emitThrow(node),
            .try_node => |node| try self.emitTry(node),
            .apply_node => |node| try self.emitApply(node),
            .partial_node => |node| try self.emitPartial(node),
            .comp_node => |node| try self.emitComp(node),
            .reduce_node => |node| try self.emitReduce(node),
            .map_node => |node| try self.emitMap(node),
            .filter_node => |node| try self.emitFilter(node),
            .swap_node => |node| try self.emitSwap(node),
            .take_while_node => |node| try self.emitTakeWhile(node),
            .drop_while_node => |node| try self.emitDropWhile(node),
            .map_indexed_node => |node| try self.emitMapIndexed(node),
            .sort_by_node => |node| try self.emitSortBy(node),
            .group_by_node => |node| try self.emitGroupBy(node),
            .defmulti_node => |node| try self.emitDefmulti(node),
            .defmethod_node => |node| try self.emitDefmethod(node),
            .defprotocol_node => |node| try self.emitDefprotocol(node),
            .extend_type_node => |node| try self.emitExtendType(node),
            .lazy_seq_node => |node| try self.emitLazySeq(node),
        }
    }

    // === 各ノードのコンパイル ===

    /// 定数をプッシュ
    fn emitConstant(self: *Compiler, val: Value) CompileError!void {
        // 特殊値の最適化
        if (val.isNil()) {
            try self.chunk.emitOp(.nil);
            self.sp_depth += 1;
            return;
        }
        switch (val) {
            .bool_val => |b| {
                if (b) {
                    try self.chunk.emitOp(.true_val);
                } else {
                    try self.chunk.emitOp(.false_val);
                }
                self.sp_depth += 1;
                return;
            },
            else => {},
        }

        // 一般の定数
        const idx = self.chunk.addConstant(val) catch return error.TooManyConstants;
        try self.chunk.emit(.const_load, idx);
        self.sp_depth += 1;
    }

    /// Var 参照
    fn emitVarRef(self: *Compiler, ref: node_mod.VarRefNode) CompileError!void {
        // Var ポインタを定数として格納
        const var_val = Value{ .var_val = ref.var_ref };
        const idx = self.chunk.addConstant(var_val) catch return error.TooManyConstants;
        // dynamic Var は var_load_dynamic を使い、deref() で動的バインディングを参照
        const v: *Var = @ptrCast(@alignCast(ref.var_ref));
        if (v.isDynamic()) {
            try self.chunk.emit(.var_load_dynamic, idx);
        } else {
            try self.chunk.emit(.var_load, idx);
        }
        self.sp_depth += 1;
    }

    /// ローカル変数参照
    fn emitLocalRef(self: *Compiler, ref: node_mod.LocalRefNode) CompileError!void {
        // コンパイラの locals テーブルから実際のスロット位置を取得
        // ref.idx は Analyzer のグローバルローカルインデックス。
        // locals_offset を使って自スコープ内の変数かどうかを判定:
        //   ref.idx >= locals_offset → 自スコープ内 → locals テーブルの slot を使用
        //   ref.idx < locals_offset → 親スコープ → idx をそのまま slot として使用
        //     （closure_bindings がフレーム先頭に配置されるため、
        //      親スコープ変数の idx がそのまま正しい slot になる）
        const slot = if (ref.idx >= self.locals_offset and
            ref.idx - self.locals_offset < self.locals.items.len)
            self.locals.items[ref.idx - self.locals_offset].slot
        else
            @as(u16, @intCast(ref.idx));
        try self.chunk.emit(.local_load, slot);
        self.sp_depth += 1;
    }

    /// if
    fn emitIf(self: *Compiler, node: *const node_mod.IfNode) CompileError!void {
        // test をコンパイル（sp_depth += 1 は子が処理）
        try self.compile(node.test_node);

        // jump_if_false は test をポップ
        self.sp_depth -= 1;
        const jump_if_false = self.chunk.emitJump(.jump_if_false) catch return error.OutOfMemory;

        // then をコンパイル（sp_depth += 1 は子が処理）
        try self.compile(node.then_node);

        // else をスキップするジャンプ
        const jump_over_else = self.chunk.emitJump(.jump) catch return error.OutOfMemory;

        // false ジャンプ先をパッチ
        self.chunk.patchJump(jump_if_false);

        // else ブランチは then の結果がない状態から始まる
        self.sp_depth -= 1;

        // else をコンパイル
        if (node.else_node) |else_n| {
            try self.compile(else_n);
        } else {
            try self.chunk.emitOp(.nil);
            self.sp_depth += 1;
        }

        // else スキップジャンプ先をパッチ
        // 両ブランチとも結果1つ分（+1）で終了
        self.chunk.patchJump(jump_over_else);
    }

    /// do
    fn emitDo(self: *Compiler, node: *const node_mod.DoNode) CompileError!void {
        if (node.statements.len == 0) {
            try self.chunk.emitOp(.nil);
            self.sp_depth += 1;
            return;
        }

        for (node.statements, 0..) |stmt, i| {
            try self.compile(stmt);
            // 最後以外は pop
            if (i < node.statements.len - 1) {
                try self.chunk.emitOp(.pop);
                self.sp_depth -= 1;
            }
        }
    }

    /// let
    fn emitLet(self: *Compiler, node: *const node_mod.LetNode) CompileError!void {
        // スコープ開始
        self.scope_depth += 1;
        const base_locals = self.locals.items.len;

        // バインディングをコンパイル（compile が sp_depth += 1 を処理）
        for (node.bindings) |binding| {
            try self.compile(binding.init);
            // addLocal は sp_depth - 1 をスロットとして記録
            try self.addLocal(binding.name);
        }

        // ボディをコンパイル（sp_depth += 1 は子が処理）
        try self.compile(node.body);

        // スコープ終了: ローカルをスタックから除去し、結果を保持
        const locals_to_pop = self.locals.items.len - base_locals;
        if (locals_to_pop > 0) {
            try self.chunk.emit(.scope_exit, @intCast(locals_to_pop));
            self.sp_depth -= @intCast(locals_to_pop);
        }

        // ローカルを削除
        self.locals.shrinkRetainingCapacity(base_locals);
        self.scope_depth -= 1;
    }

    /// letfn（相互再帰ローカル関数）
    /// Analyzer と同じ順序でスロットを確保:
    /// 1. 全関数名のプレースホルダを push & addLocal
    /// 2. 各関数の fn をコンパイルして上書き
    /// 3. letfn_fixup で相互参照を設定
    /// 4. ボディをコンパイル
    /// 5. scope_exit でクリーンアップ
    fn emitLetfn(self: *Compiler, node: *const node_mod.LetfnNode) CompileError!void {
        self.scope_depth += 1;
        const base_locals = self.locals.items.len;
        const fn_count = node.bindings.len;

        // Phase 1: 全関数名のスロットを確保（nil プレースホルダ）
        // Analyzer が全名前を登録してから fn body を解析するのと同じ順序
        for (node.bindings) |binding| {
            try self.chunk.emitOp(.nil);
            self.sp_depth += 1;
            try self.addLocal(binding.name);
        }

        // Phase 2: 各関数をコンパイルし、対応するスロットに上書き
        for (node.bindings, 0..) |binding, i| {
            // fn ノードをコンパイル（closure opcode を生成 → スタックトップに push）
            try self.compile(binding.fn_node);
            // 結果をローカルスロットに書き込み（上書き）
            const local = self.locals.items[base_locals + i];
            try self.chunk.emit(.local_store, local.slot);
            self.sp_depth -= 1; // local_store はスタックから消費
        }

        // Phase 3: letfn_fixup で相互参照を設定
        // operand: 上位8bit = 先頭関数のスロット位置, 下位8bit = 関数の数
        if (fn_count > 0) {
            const first_slot = self.locals.items[base_locals].slot;
            const operand: u16 = (@as(u16, first_slot) << 8) | @as(u16, @intCast(fn_count));
            try self.chunk.emit(.letfn_fixup, operand);
        }

        // Phase 4: ボディをコンパイル
        try self.compile(node.body);

        // Phase 5: スコープ終了
        const locals_to_pop = self.locals.items.len - base_locals;
        if (locals_to_pop > 0) {
            try self.chunk.emit(.scope_exit, @intCast(locals_to_pop));
            self.sp_depth -= @intCast(locals_to_pop);
        }

        self.locals.shrinkRetainingCapacity(base_locals);
        self.scope_depth -= 1;
    }

    /// loop
    fn emitLoop(self: *Compiler, node: *const node_mod.LoopNode) CompileError!void {
        // スコープ開始
        self.scope_depth += 1;
        const base_locals = self.locals.items.len;
        const loop_sp_base = self.sp_depth; // バインディング前のスタック位置

        // 初期バインディングをコンパイル（compile が sp_depth += 1 を処理）
        for (node.bindings) |binding| {
            try self.compile(binding.init);
            try self.addLocal(binding.name);
        }

        // ループ開始位置と loop バインディング開始位置を記録
        // loop_locals_base はスタック上の実際のオフセット（sp_depth ベース）
        const loop_start_pos = self.chunk.currentOffset();
        const prev_loop_start = self.loop_start;
        const prev_loop_locals_base = self.loop_locals_base;
        self.loop_start = loop_start_pos;
        self.loop_locals_base = loop_sp_base;

        // ボディをコンパイル（sp_depth += 1 は子が処理）
        try self.compile(node.body);

        // ループ開始位置を復元
        self.loop_start = prev_loop_start;
        self.loop_locals_base = prev_loop_locals_base;

        // スコープ終了: ループバインディングを除去し結果を保持
        const locals_to_pop = self.locals.items.len - base_locals;
        if (locals_to_pop > 0) {
            try self.chunk.emit(.scope_exit, @intCast(locals_to_pop));
            self.sp_depth -= @intCast(locals_to_pop);
        }

        // ローカルを削除
        self.locals.shrinkRetainingCapacity(base_locals);
        self.scope_depth -= 1;
    }

    /// recur
    fn emitRecur(self: *Compiler, node: *const node_mod.RecurNode) CompileError!void {
        const sp_before = self.sp_depth;

        // 引数をコンパイル（各 compile が sp_depth += 1 を処理）
        for (node.args) |arg| {
            try self.compile(arg);
        }

        // recur 命令を発行（上位8bit: loop開始オフセット、下位8bit: 引数数）
        const base_offset: u16 = @intCast(self.loop_locals_base);
        const arg_count: u16 = @intCast(node.args.len);
        try self.chunk.emit(.recur, (base_offset << 8) | arg_count);

        // ループ先頭へジャンプ
        if (self.loop_start) |start| {
            try self.chunk.emitLoop(start);
        }

        // recur はジャンプするので到達しないが、
        // コンパイル時のsp_depth整合性のために結果1つ分を設定
        self.sp_depth = sp_before + 1;
    }

    /// fn（クロージャ作成）
    fn emitFn(self: *Compiler, node: *const node_mod.FnNode) CompileError!void {
        // 関数本体を別の Compiler でコンパイル
        // 各アリティ毎に FnProto を作成

        if (node.arities.len == 0) {
            try self.chunk.emitOp(.nil);
            self.sp_depth += 1;
            return;
        }

        // 単一アリティの場合は最適化パス
        if (node.arities.len == 1) {
            const proto = try self.compileArity(node.name, node.arities[0]);
            const proto_val = Value{ .fn_proto = proto };
            const idx = self.chunk.addConstant(proto_val) catch return error.TooManyConstants;
            try self.chunk.emit(.closure, idx);
            self.sp_depth += 1;
            return;
        }

        // 複数アリティ: 各アリティの FnProto をスタックにプッシュ
        for (node.arities) |arity| {
            const proto = try self.compileArity(node.name, arity);
            const proto_val = Value{ .fn_proto = proto };
            const idx = self.chunk.addConstant(proto_val) catch return error.TooManyConstants;
            try self.chunk.emit(.const_load, idx);
            self.sp_depth += 1;
        }

        // closure_multi 命令で結合（N個ポップ、1個プッシュ）
        try self.chunk.emit(.closure_multi, @intCast(node.arities.len));
        self.sp_depth -= @as(u16, @intCast(node.arities.len)) - 1;
    }

    /// 単一アリティをコンパイルして FnProto を返す
    fn compileArity(self: *Compiler, name: ?[]const u8, arity: node_mod.FnArity) CompileError!*FnProto {
        // 関数本体用のコンパイラ
        var fn_compiler = Compiler.init(self.allocator);
        defer fn_compiler.deinit();

        // fn_compiler の locals_offset を設定
        // Analyzer のグローバルインデックスにおいて、この関数のパラメータは
        // 親の locals_offset + 親の locals 数 から始まる
        fn_compiler.locals_offset = self.locals_offset + @as(u32, @intCast(self.locals.items.len));

        // 引数をローカルとして追加
        // クロージャバインディングがスタック先頭に配置されるため、
        // パラメータの sp_depth は capture_count 分オフセット
        fn_compiler.scope_depth = 1;
        const capture_count = self.locals.items.len;
        fn_compiler.sp_depth = @intCast(capture_count); // クロージャバインディング分
        for (arity.params) |param| {
            fn_compiler.sp_depth += 1; // パラメータがスタック上に存在
            try fn_compiler.addLocal(param);
        }

        // ボディをコンパイル
        try fn_compiler.compile(arity.body);
        try fn_compiler.chunk.emitOp(.ret);

        // FnProto を作成
        const proto = self.allocator.create(FnProto) catch return error.OutOfMemory;
        var fn_chunk = fn_compiler.takeChunk();
        // 親スコープのローカル変数情報を記録
        // capture_count: キャプチャするローカル数
        // capture_offset: 最初のローカルのスロット位置（スタック上の先行値をスキップ）
        const cap_count: u16 = @intCast(self.locals.items.len);
        const cap_offset: u16 = if (cap_count > 0)
            self.locals.items[0].slot
        else
            0;
        proto.* = .{
            .name = name,
            .arity = @intCast(arity.params.len),
            .variadic = arity.variadic,
            .local_count = @intCast(fn_compiler.locals.items.len),
            .capture_count = cap_count,
            .capture_offset = cap_offset,
            .code = fn_chunk.code.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .constants = fn_chunk.constants.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
        };

        return proto;
    }

    /// call
    fn emitCall(self: *Compiler, node: *const node_mod.CallNode) CompileError!void {
        // 関数をコンパイル（sp_depth += 1 は子が処理）
        try self.compile(node.fn_node);

        // 引数をコンパイル（各 sp_depth += 1 は子が処理）
        for (node.args) |arg| {
            try self.compile(arg);
        }

        // call 命令（fn + N引数をポップ、結果1つプッシュ → net -N）
        try self.chunk.emit(.call, @intCast(node.args.len));
        self.sp_depth -= @intCast(node.args.len);
    }

    /// def
    fn emitDef(self: *Compiler, node: *const node_mod.DefNode) CompileError!void {
        // 初期値をコンパイル
        if (node.init) |init_node| {
            try self.compile(init_node);
        } else {
            try self.chunk.emitOp(.nil);
            self.sp_depth += 1;
        }

        // シンボル名をシンボル Value として追加
        const sym = self.allocator.create(value_mod.Symbol) catch return error.OutOfMemory;
        sym.* = value_mod.Symbol.init(node.sym_name);
        const name_val = Value{ .symbol = sym };
        const idx = self.chunk.addConstant(name_val) catch return error.TooManyConstants;

        // def/defmacro 命令（値をポップして Var をプッシュ → sp_depth 変化なし）
        if (node.is_macro) {
            try self.chunk.emit(.def_macro, idx);
        } else {
            try self.chunk.emit(.def, idx);
        }
    }

    /// defmulti
    /// (defmulti name dispatch-fn) → dispatch_fn をコンパイル → defmulti 命令
    fn emitDefmulti(self: *Compiler, node: *const node_mod.DefmultiNode) CompileError!void {
        // ディスパッチ関数をコンパイル
        try self.compile(node.dispatch_fn);

        // シンボル名を定数に追加
        const sym = self.allocator.create(value_mod.Symbol) catch return error.OutOfMemory;
        sym.* = value_mod.Symbol.init(node.name);
        const name_val = Value{ .symbol = sym };
        const idx = self.chunk.addConstant(name_val) catch return error.TooManyConstants;

        // defmulti 命令（dispatch_fn をポップ → nil をプッシュ → sp_depth 変化なし）
        try self.chunk.emit(.defmulti, idx);
    }

    /// defmethod
    /// (defmethod name dispatch-val method-fn)
    fn emitDefmethod(self: *Compiler, node: *const node_mod.DefmethodNode) CompileError!void {
        // ディスパッチ値をコンパイル
        try self.compile(node.dispatch_val);
        // メソッド関数をコンパイル
        try self.compile(node.method_fn);

        // シンボル名を定数に追加
        const sym = self.allocator.create(value_mod.Symbol) catch return error.OutOfMemory;
        sym.* = value_mod.Symbol.init(node.multi_name);
        const name_val = Value{ .symbol = sym };
        const idx = self.chunk.addConstant(name_val) catch return error.TooManyConstants;

        // defmethod 命令（dispatch_val, method_fn をポップ → nil をプッシュ → sp_depth -1）
        try self.chunk.emit(.defmethod, idx);
        self.sp_depth -= 1; // 2つポップして1つプッシュ = net -1
    }

    /// defprotocol
    /// プロトコル名とメソッドシグネチャ情報を定数に格納
    fn emitDefprotocol(self: *Compiler, node: *const node_mod.DefprotocolNode) CompileError!void {
        // プロトコル名を定数に追加
        const sym = self.allocator.create(value_mod.Symbol) catch return error.OutOfMemory;
        sym.* = value_mod.Symbol.init(node.name);
        const name_val = Value{ .symbol = sym };
        const idx = self.chunk.addConstant(name_val) catch return error.TooManyConstants;

        // メソッドシグネチャ情報をベクターとして定数に追加
        // [method_name_1, arity_1, method_name_2, arity_2, ...]
        const sig_items = self.allocator.alloc(Value, node.method_sigs.len * 2) catch return error.OutOfMemory;
        for (node.method_sigs, 0..) |sig, i| {
            const ms = self.allocator.create(value_mod.String) catch return error.OutOfMemory;
            ms.* = value_mod.String.init(sig.name);
            sig_items[i * 2] = Value{ .string = ms };
            sig_items[i * 2 + 1] = value_mod.intVal(@intCast(sig.arity));
        }
        const vec = self.allocator.create(value_mod.PersistentVector) catch return error.OutOfMemory;
        vec.* = .{ .items = sig_items };
        const sigs_idx = self.chunk.addConstant(Value{ .vector = vec }) catch return error.TooManyConstants;
        _ = sigs_idx;

        // defprotocol 命令（[] → [nil]）
        try self.chunk.emit(.defprotocol, idx);
        self.sp_depth += 1;
    }

    /// extend-type
    /// 各メソッド fn をコンパイルし、extend_type_method 命令を emit
    fn emitExtendType(self: *Compiler, node: *const node_mod.ExtendTypeNode) CompileError!void {
        for (node.extensions) |ext| {
            for (ext.methods) |method| {
                // メソッド fn をコンパイル（スタックに push）
                try self.compile(method.fn_node);

                // メタデータ: [type_name, protocol_name, method_name] をベクターとして定数に格納
                const meta_items = self.allocator.alloc(Value, 3) catch return error.OutOfMemory;
                const ts = self.allocator.create(value_mod.String) catch return error.OutOfMemory;
                ts.* = value_mod.String.init(node.type_name);
                meta_items[0] = Value{ .string = ts };
                const ps = self.allocator.create(value_mod.String) catch return error.OutOfMemory;
                ps.* = value_mod.String.init(ext.protocol_name);
                meta_items[1] = Value{ .string = ps };
                const ms = self.allocator.create(value_mod.String) catch return error.OutOfMemory;
                ms.* = value_mod.String.init(method.name);
                meta_items[2] = Value{ .string = ms };

                const meta_vec = self.allocator.create(value_mod.PersistentVector) catch return error.OutOfMemory;
                meta_vec.* = .{ .items = meta_items };
                const meta_idx = self.chunk.addConstant(Value{ .vector = meta_vec }) catch return error.TooManyConstants;

                // extend_type_method 命令（[method_fn] → [nil]）
                try self.chunk.emit(.extend_type_method, meta_idx);
                // sp_depth: method_fn を pop して nil を push = 変化なし
            }
        }

        // 最終結果として nil をプッシュ（extend-type 全体の戻り値）
        // もしメソッドがある場合、最後の extend_type_method が nil を残すので
        // 余分な nil は不要（メソッドが0個のケースのみ nil が必要）
        if (node.extensions.len == 0) {
            try self.chunk.emitOp(.nil);
            self.sp_depth += 1;
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

        // apply 命令（fn + N中間引数 + seq をポップ、結果プッシュ → net -(N+1)）
        try self.chunk.emit(.apply, @intCast(node.args.len));
        self.sp_depth -= @as(u16, @intCast(node.args.len)) + 1;
    }

    fn emitPartial(self: *Compiler, node: *const node_mod.PartialNode) CompileError!void {
        // 関数をコンパイル
        try self.compile(node.fn_node);

        // 部分適用する引数をコンパイル
        for (node.args) |arg| {
            try self.compile(arg);
        }

        // partial 命令（fn + N引数をポップ、結果プッシュ → net -N）
        try self.chunk.emit(.partial, @intCast(node.args.len));
        self.sp_depth -= @intCast(node.args.len);
    }

    fn emitComp(self: *Compiler, node: *const node_mod.CompNode) CompileError!void {
        // 関数をコンパイル（左から右の順）
        for (node.fns) |fn_node| {
            try self.compile(fn_node);
        }

        // comp 命令（N個ポップ、1個プッシュ → net -(N-1)）
        try self.chunk.emit(.comp, @intCast(node.fns.len));
        if (node.fns.len > 1) {
            self.sp_depth -= @as(u16, @intCast(node.fns.len)) - 1;
        }
    }

    fn emitReduce(self: *Compiler, node: *const node_mod.ReduceNode) CompileError!void {
        // 関数をコンパイル
        try self.compile(node.fn_node);

        // 初期値がある場合はコンパイル
        const has_init: u16 = if (node.init_node) |init_n| blk: {
            try self.compile(init_n);
            break :blk 1;
        } else 0;

        // コレクションをコンパイル
        try self.compile(node.coll_node);

        // reduce 命令（fn + init? + coll をポップ、結果プッシュ → net -(1+has_init)）
        try self.chunk.emit(.reduce, has_init);
        self.sp_depth -= 1 + has_init;
    }

    /// map コンパイル: (map f coll)
    fn emitMap(self: *Compiler, node: *const node_mod.MapNode) CompileError!void {
        try self.compile(node.fn_node);
        try self.compile(node.coll_node);
        // fn + coll をポップ、結果プッシュ → net -1
        try self.chunk.emit(.map_seq, 0);
        self.sp_depth -= 1;
    }

    /// filter コンパイル: (filter pred coll)
    fn emitFilter(self: *Compiler, node: *const node_mod.FilterNode) CompileError!void {
        try self.compile(node.fn_node);
        try self.compile(node.coll_node);
        // fn + coll をポップ、結果プッシュ → net -1
        try self.chunk.emit(.filter_seq, 0);
        self.sp_depth -= 1;
    }

    /// take-while コンパイル: (take-while pred coll)
    fn emitTakeWhile(self: *Compiler, node: *const node_mod.TakeWhileNode) CompileError!void {
        try self.compile(node.fn_node);
        try self.compile(node.coll_node);
        try self.chunk.emit(.take_while_seq, 0);
        self.sp_depth -= 1;
    }

    /// drop-while コンパイル: (drop-while pred coll)
    fn emitDropWhile(self: *Compiler, node: *const node_mod.DropWhileNode) CompileError!void {
        try self.compile(node.fn_node);
        try self.compile(node.coll_node);
        try self.chunk.emit(.drop_while_seq, 0);
        self.sp_depth -= 1;
    }

    /// map-indexed コンパイル: (map-indexed f coll)
    fn emitMapIndexed(self: *Compiler, node: *const node_mod.MapIndexedNode) CompileError!void {
        try self.compile(node.fn_node);
        try self.compile(node.coll_node);
        try self.chunk.emit(.map_indexed_seq, 0);
        self.sp_depth -= 1;
    }

    /// sort-by コンパイル: (sort-by f coll)
    fn emitSortBy(self: *Compiler, node: *const node_mod.SortByNode) CompileError!void {
        try self.compile(node.fn_node);
        try self.compile(node.coll_node);
        try self.chunk.emit(.sort_by_seq, 0);
        self.sp_depth -= 1;
    }

    /// group-by コンパイル: (group-by f coll)
    fn emitGroupBy(self: *Compiler, node: *const node_mod.GroupByNode) CompileError!void {
        try self.compile(node.fn_node);
        try self.compile(node.coll_node);
        try self.chunk.emit(.group_by_seq, 0);
        self.sp_depth -= 1;
    }

    // === 遅延シーケンス ===

    /// lazy-seq コンパイル: (lazy-seq body)
    /// body を引数なし fn としてコンパイルし、lazy_seq オペコードで LazySeq を生成
    fn emitLazySeq(self: *Compiler, node: *const node_mod.LazySeqNode) CompileError!void {
        // body を (fn [] body) として扱い、FnProto を生成
        const arity = node_mod.FnArity{
            .params = &[_][]const u8{},
            .variadic = false,
            .body = node.body,
        };
        const proto = try self.compileArity(null, arity);
        const proto_val = Value{ .fn_proto = proto };
        const idx = self.chunk.addConstant(proto_val) catch return error.TooManyConstants;
        // closure 命令でサンク関数を作成
        try self.chunk.emit(.closure, idx);
        self.sp_depth += 1;
        // lazy_seq 命令でサンクから LazySeq を作成
        try self.chunk.emitOp(.lazy_seq);
        // スタック効果: fn をポップして lazy_seq をプッシュ（差引0）
    }

    // === Atom 操作 ===

    /// swap! コンパイル: (swap! atom f arg1 arg2 ...)
    fn emitSwap(self: *Compiler, node: *const node_mod.SwapNode) CompileError!void {
        // atom 式をコンパイル
        try self.compile(node.atom_node);
        // 関数をコンパイル
        try self.compile(node.fn_node);
        // 追加引数をコンパイル
        for (node.args) |arg| {
            try self.compile(arg);
        }
        // swap_atom 命令（atom + fn + N引数をポップ、結果プッシュ → net -(N+1)）
        try self.chunk.emit(.swap_atom, @intCast(node.args.len));
        self.sp_depth -= @as(u16, @intCast(node.args.len)) + 1;
    }

    // === 例外処理 ===

    /// throw コンパイル: (throw expr)
    fn emitThrow(self: *Compiler, node: *const node_mod.ThrowNode) CompileError!void {
        // 式をコンパイル（スタックに値をプッシュ）
        try self.compile(node.expr);
        // throw_ex 命令
        try self.chunk.emitOp(.throw_ex);
    }

    /// try/catch/finally コンパイル
    /// try_begin [catch_offset]
    /// ... body ...
    /// jump [end_offset]      ; 成功時は catch/finally をスキップ
    /// catch_begin             ; catch 節開始
    /// ... catch handler ...
    /// finally_begin           ; finally 開始
    /// ... finally ...
    /// try_end
    fn emitTry(self: *Compiler, node: *const node_mod.TryNode) CompileError!void {
        const sp_before = self.sp_depth;

        // try_begin: catch 節へのオフセット（後でパッチ）
        const try_begin_idx = self.chunk.emitJump(.try_begin) catch return error.OutOfMemory;

        // body をコンパイル（sp_depth += 1 は子が処理）
        try self.compile(node.body);

        // 成功時: catch をスキップして finally/end へジャンプ
        const jump_to_finally = self.chunk.emitJump(.jump) catch return error.OutOfMemory;

        // catch 節開始位置をパッチ
        self.chunk.patchJump(try_begin_idx);

        // catch パスでは body の結果はなく、例外が VM によりプッシュされる
        self.sp_depth = sp_before;

        // catch 節
        if (node.catch_clause) |clause| {
            try self.chunk.emitOp(.catch_begin);
            self.sp_depth += 1; // VM が例外値をプッシュ

            // catch バインディング用のスコープ
            self.scope_depth += 1;
            const base_locals = self.locals.items.len;

            // 例外値はスタックトップに置かれる（VM がプッシュ）
            try self.addLocal(clause.binding_name);

            // catch ハンドラ本体をコンパイル
            try self.compile(clause.body);

            // catch スコープのローカルを削除
            const locals_to_pop = self.locals.items.len - base_locals;
            if (locals_to_pop > 0) {
                try self.chunk.emit(.scope_exit, @intCast(locals_to_pop));
                self.sp_depth -= @intCast(locals_to_pop);
            }

            self.locals.shrinkRetainingCapacity(base_locals);
            self.scope_depth -= 1;
        } else {
            // catch なし: nil をプッシュ（catch_begin マーカー）
            try self.chunk.emitOp(.catch_begin);
            try self.chunk.emitOp(.nil);
            self.sp_depth += 1;
        }

        // finally/end へのジャンプをパッチ
        self.chunk.patchJump(jump_to_finally);

        // sp_depth を body/catch の結果分に統一
        self.sp_depth = sp_before + 1;

        // finally 節
        if (node.finally_body) |finally_n| {
            try self.chunk.emitOp(.finally_begin);
            try self.compile(finally_n);
            // finally の結果は捨てる（try/catch の結果を維持）
            try self.chunk.emitOp(.pop);
            self.sp_depth -= 1;
        }

        // try_end マーカー
        try self.chunk.emitOp(.try_end);
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
            .slot = self.sp_depth - 1, // 直前に push された値の位置
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
