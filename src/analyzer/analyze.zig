//! Analyzer: Form → Node 変換
//!
//! Reader が生成した Form を実行可能な Node に変換する。
//! - special forms の解析 (if, do, let, fn, def, quote, defmacro)
//! - シンボル解決（ローカル変数 vs Var）
//! - マクロ展開
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)

const std = @import("std");
const form_mod = @import("../reader/form.zig");
const Form = form_mod.Form;
const FormSymbol = form_mod.Symbol;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const SourceInfo = node_mod.SourceInfo;
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const Fn = value_mod.Fn;
const RuntimeSymbol = value_mod.Symbol;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;
const var_mod = @import("../runtime/var.zig");
const Var = var_mod.Var;
const err = @import("../base/error.zig");
const context_mod = @import("../runtime/context.zig");
const Context = context_mod.Context;
const evaluator = @import("../runtime/evaluator.zig");
const core = @import("../lib/core.zig");

/// ローカルバインディング情報
const LocalBinding = struct {
    name: []const u8,
    idx: u32,
};

/// Analyzer
/// Form を Node に変換
pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    env: *Env,

    /// ローカル変数のスタック（let, fn のバインディング）
    locals: std.ArrayListUnmanaged(LocalBinding) = .empty,

    /// 初期化
    pub fn init(allocator: std.mem.Allocator, env: *Env) Analyzer {
        return .{
            .allocator = allocator,
            .env = env,
        };
    }

    /// 解放
    pub fn deinit(self: *Analyzer) void {
        self.locals.deinit(self.allocator);
    }

    /// Form を Node に変換
    pub fn analyze(self: *Analyzer, form: Form) err.Error!*Node {
        return switch (form) {
            // リテラル
            .nil => self.makeConstant(value_mod.nil),
            .bool_true => self.makeConstant(value_mod.true_val),
            .bool_false => self.makeConstant(value_mod.false_val),
            .int => |n| self.makeConstant(value_mod.intVal(n)),
            .float => |n| self.makeConstant(value_mod.floatVal(n)),
            .string => |s| self.analyzeString(s),
            .keyword => |sym| self.analyzeKeyword(sym),
            .symbol => |sym| self.analyzeSymbol(sym),

            // コレクション
            .list => |items| self.analyzeList(items),
            .vector => |items| self.analyzeVector(items),
        };
    }

    // === リテラル解析 ===

    fn analyzeString(self: *Analyzer, s: []const u8) err.Error!*Node {
        const str = self.allocator.create(value_mod.String) catch return error.OutOfMemory;
        str.* = value_mod.String.init(s);
        return self.makeConstant(.{ .string = str });
    }

    fn analyzeKeyword(self: *Analyzer, sym: FormSymbol) err.Error!*Node {
        const kw = self.allocator.create(value_mod.Keyword) catch return error.OutOfMemory;
        kw.* = if (sym.namespace) |ns|
            value_mod.Keyword.initNs(ns, sym.name)
        else
            value_mod.Keyword.init(sym.name);
        return self.makeConstant(.{ .keyword = kw });
    }

    fn analyzeSymbol(self: *Analyzer, sym: FormSymbol) err.Error!*Node {
        // ローカル変数を検索
        if (sym.namespace == null) {
            if (self.findLocal(sym.name)) |local| {
                return self.makeLocalRef(local.name, local.idx);
            }
        }

        // Var を検索
        const runtime_sym = if (sym.namespace) |ns|
            RuntimeSymbol.initNs(ns, sym.name)
        else
            RuntimeSymbol.init(sym.name);

        if (self.env.resolve(runtime_sym)) |v| {
            return self.makeVarRef(v);
        }

        // 未定義シンボル
        return err.parseError(.undefined_symbol, "Unable to resolve symbol", .{});
    }

    // === コレクション解析 ===

    fn analyzeList(self: *Analyzer, items: []const Form) err.Error!*Node {
        if (items.len == 0) {
            // 空リスト () は nil ではなく空リスト
            return self.makeEmptyList();
        }

        // 先頭要素をチェック
        const first = items[0];
        if (first == .symbol) {
            const sym_name = first.symbol.name;

            // special forms
            if (std.mem.eql(u8, sym_name, "if")) {
                return self.analyzeIf(items);
            } else if (std.mem.eql(u8, sym_name, "do")) {
                return self.analyzeDo(items);
            } else if (std.mem.eql(u8, sym_name, "let") or std.mem.eql(u8, sym_name, "let*")) {
                return self.analyzeLet(items);
            } else if (std.mem.eql(u8, sym_name, "fn") or std.mem.eql(u8, sym_name, "fn*")) {
                return self.analyzeFn(items);
            } else if (std.mem.eql(u8, sym_name, "def")) {
                return self.analyzeDef(items);
            } else if (std.mem.eql(u8, sym_name, "quote")) {
                return self.analyzeQuote(items);
            } else if (std.mem.eql(u8, sym_name, "loop") or std.mem.eql(u8, sym_name, "loop*")) {
                return self.analyzeLoop(items);
            } else if (std.mem.eql(u8, sym_name, "recur")) {
                return self.analyzeRecur(items);
            } else if (std.mem.eql(u8, sym_name, "defmacro")) {
                return self.analyzeDefmacro(items);
            } else if (std.mem.eql(u8, sym_name, "apply")) {
                return self.analyzeApply(items);
            } else if (std.mem.eql(u8, sym_name, "partial")) {
                return self.analyzePartial(items);
            } else if (std.mem.eql(u8, sym_name, "comp")) {
                return self.analyzeComp(items);
            } else if (std.mem.eql(u8, sym_name, "reduce")) {
                return self.analyzeReduce(items);
            }
        }

        // マクロ展開をチェック
        if (try self.tryMacroExpand(items)) |expanded_node| {
            return expanded_node;
        }

        // 関数呼び出し
        return self.analyzeCall(items);
    }

    fn analyzeVector(self: *Analyzer, items: []const Form) err.Error!*Node {
        // ベクターリテラル
        var analyzed = self.allocator.alloc(Value, items.len) catch return error.OutOfMemory;
        for (items, 0..) |item, i| {
            const node = try self.analyze(item);
            // 定数のみサポート（現時点）
            switch (node.*) {
                .constant => |val| analyzed[i] = val,
                else => return err.parseError(.invalid_token, "Vector literal must contain constants", .{}),
            }
        }

        const vec = self.allocator.create(value_mod.PersistentVector) catch return error.OutOfMemory;
        vec.* = .{ .items = analyzed };
        return self.makeConstant(.{ .vector = vec });
    }

    // === special forms ===

    fn analyzeIf(self: *Analyzer, items: []const Form) err.Error!*Node {
        // (if test then) または (if test then else)
        if (items.len < 3 or items.len > 4) {
            return err.parseError(.invalid_arity, "if requires 2 or 3 arguments", .{});
        }

        const test_node = try self.analyze(items[1]);
        const then_node = try self.analyze(items[2]);
        const else_node = if (items.len == 4)
            try self.analyze(items[3])
        else
            try self.makeConstant(value_mod.nil);

        const if_data = self.allocator.create(node_mod.IfNode) catch return error.OutOfMemory;
        if_data.* = .{
            .test_node = test_node,
            .then_node = then_node,
            .else_node = else_node,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .if_node = if_data };
        return node;
    }

    fn analyzeDo(self: *Analyzer, items: []const Form) err.Error!*Node {
        // (do expr1 expr2 ...)
        if (items.len == 1) {
            return self.makeConstant(value_mod.nil);
        }

        var statements = self.allocator.alloc(*Node, items.len - 1) catch return error.OutOfMemory;
        for (items[1..], 0..) |item, i| {
            statements[i] = try self.analyze(item);
        }

        const do_data = self.allocator.create(node_mod.DoNode) catch return error.OutOfMemory;
        do_data.* = .{
            .statements = statements,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .do_node = do_data };
        return node;
    }

    fn analyzeLet(self: *Analyzer, items: []const Form) err.Error!*Node {
        // (let [binding1 val1 binding2 val2 ...] body...)
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "let requires binding vector", .{});
        }

        // バインディングベクター
        const bindings_form = items[1];
        if (bindings_form != .vector) {
            return err.parseError(.invalid_binding, "let bindings must be a vector", .{});
        }

        const binding_pairs = bindings_form.vector;
        if (binding_pairs.len % 2 != 0) {
            return err.parseError(.invalid_binding, "let bindings must have even number of forms", .{});
        }

        // ローカルバインディングをスタックに追加
        const start_locals = self.locals.items.len;
        var bindings = self.allocator.alloc(node_mod.LetBinding, binding_pairs.len / 2) catch return error.OutOfMemory;

        var i: usize = 0;
        while (i < binding_pairs.len) : (i += 2) {
            const sym_form = binding_pairs[i];
            if (sym_form != .symbol) {
                return err.parseError(.invalid_binding, "let binding name must be a symbol", .{});
            }

            const name = sym_form.symbol.name;
            const init_node = try self.analyze(binding_pairs[i + 1]);

            // ローカルに追加
            const idx: u32 = @intCast(self.locals.items.len);
            self.locals.append(self.allocator, .{ .name = name, .idx = idx }) catch return error.OutOfMemory;

            bindings[i / 2] = .{ .name = name, .init = init_node };
        }

        // ボディを解析
        const body = if (items.len == 2)
            try self.makeConstant(value_mod.nil)
        else if (items.len == 3)
            try self.analyze(items[2])
        else blk: {
            // 複数のボディ式を do でラップ
            var statements = self.allocator.alloc(*Node, items.len - 2) catch return error.OutOfMemory;
            for (items[2..], 0..) |item, j| {
                statements[j] = try self.analyze(item);
            }
            const do_data = self.allocator.create(node_mod.DoNode) catch return error.OutOfMemory;
            do_data.* = .{ .statements = statements, .stack = .{} };
            const do_node = self.allocator.create(Node) catch return error.OutOfMemory;
            do_node.* = .{ .do_node = do_data };
            break :blk do_node;
        };

        // ローカルをポップ
        self.locals.shrinkRetainingCapacity(start_locals);

        const let_data = self.allocator.create(node_mod.LetNode) catch return error.OutOfMemory;
        let_data.* = .{
            .bindings = bindings,
            .body = body,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .let_node = let_data };
        return node;
    }

    fn analyzeFn(self: *Analyzer, items: []const Form) err.Error!*Node {
        // (fn name? [params] body...) または (fn name? ([params] body...) ...)
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "fn requires parameter vector", .{});
        }

        var idx: usize = 1;
        var name: ?[]const u8 = null;

        // オプションの名前
        if (items[idx] == .symbol) {
            name = items[idx].symbol.name;
            idx += 1;
        }

        if (idx >= items.len) {
            return err.parseError(.invalid_arity, "fn requires parameter vector", .{});
        }

        // 単一アリティ: [params] body...
        if (items[idx] == .vector) {
            const arity = try self.analyzeFnArity(items[idx].vector, items[idx + 1 ..]);
            const arities = self.allocator.alloc(node_mod.FnArity, 1) catch return error.OutOfMemory;
            arities[0] = arity;

            const fn_data = self.allocator.create(node_mod.FnNode) catch return error.OutOfMemory;
            fn_data.* = .{
                .name = name,
                .arities = arities,
                .stack = .{},
            };

            const node = self.allocator.create(Node) catch return error.OutOfMemory;
            node.* = .{ .fn_node = fn_data };
            return node;
        }

        // 複数アリティ: ([params] body...) ...
        // 各アリティは (params-vector body...) 形式のリスト
        var arities_list = std.ArrayListUnmanaged(node_mod.FnArity).empty;

        while (idx < items.len) {
            const arity_form = items[idx];
            if (arity_form != .list) {
                return err.parseError(.invalid_token, "fn arity must be a list: ([params] body...)", .{});
            }

            const arity_items = arity_form.list;
            if (arity_items.len == 0 or arity_items[0] != .vector) {
                return err.parseError(.invalid_token, "fn arity must start with parameter vector", .{});
            }

            const arity = try self.analyzeFnArity(arity_items[0].vector, arity_items[1..]);
            arities_list.append(self.allocator, arity) catch return error.OutOfMemory;

            idx += 1;
        }

        if (arities_list.items.len == 0) {
            return err.parseError(.invalid_arity, "fn requires at least one arity", .{});
        }

        const fn_data = self.allocator.create(node_mod.FnNode) catch return error.OutOfMemory;
        fn_data.* = .{
            .name = name,
            .arities = arities_list.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .fn_node = fn_data };
        return node;
    }

    fn analyzeFnArity(self: *Analyzer, params_form: []const Form, body_forms: []const Form) err.Error!node_mod.FnArity {
        // パラメータを解析
        var params = std.ArrayListUnmanaged([]const u8).empty;
        var variadic = false;

        // fn 本体では新しいスコープを開始
        // クロージャ環境は現在のローカル数を保存して評価時に復元
        const closure_size = self.locals.items.len;
        const start_locals = self.locals.items.len;

        for (params_form) |p| {
            if (p != .symbol) {
                return err.parseError(.invalid_binding, "fn parameter must be a symbol", .{});
            }

            const param_name = p.symbol.name;

            if (std.mem.eql(u8, param_name, "&")) {
                variadic = true;
                continue;
            }

            params.append(self.allocator, param_name) catch return error.OutOfMemory;

            // ローカルに追加
            // パラメータのインデックスはクロージャ環境のサイズから開始
            const idx: u32 = @intCast(self.locals.items.len);
            self.locals.append(self.allocator, .{ .name = param_name, .idx = idx }) catch return error.OutOfMemory;
        }
        _ = closure_size;

        // ボディを解析
        const body = if (body_forms.len == 0)
            try self.makeConstant(value_mod.nil)
        else if (body_forms.len == 1)
            try self.analyze(body_forms[0])
        else blk: {
            var statements = self.allocator.alloc(*Node, body_forms.len) catch return error.OutOfMemory;
            for (body_forms, 0..) |item, i| {
                statements[i] = try self.analyze(item);
            }
            const do_data = self.allocator.create(node_mod.DoNode) catch return error.OutOfMemory;
            do_data.* = .{ .statements = statements, .stack = .{} };
            const do_node = self.allocator.create(Node) catch return error.OutOfMemory;
            do_node.* = .{ .do_node = do_data };
            break :blk do_node;
        };

        // ローカルをポップ
        self.locals.shrinkRetainingCapacity(start_locals);

        return .{
            .params = params.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .variadic = variadic,
            .body = body,
        };
    }

    fn analyzeDef(self: *Analyzer, items: []const Form) err.Error!*Node {
        // (def name) または (def name value)
        if (items.len < 2 or items.len > 3) {
            return err.parseError(.invalid_arity, "def requires 1 or 2 arguments", .{});
        }

        if (items[1] != .symbol) {
            return err.parseError(.invalid_binding, "def name must be a symbol", .{});
        }

        const sym_name = items[1].symbol.name;
        const init_node = if (items.len == 3)
            try self.analyze(items[2])
        else
            null;

        const def_data = self.allocator.create(node_mod.DefNode) catch return error.OutOfMemory;
        def_data.* = .{
            .sym_name = sym_name,
            .init = init_node,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .def_node = def_data };
        return node;
    }

    fn analyzeQuote(self: *Analyzer, items: []const Form) err.Error!*Node {
        // (quote form)
        if (items.len != 2) {
            return err.parseError(.invalid_arity, "quote requires exactly 1 argument", .{});
        }

        // Form を Value に変換
        const val = try self.formToValue(items[1]);

        const quote_data = self.allocator.create(node_mod.QuoteNode) catch return error.OutOfMemory;
        quote_data.* = .{
            .form = val,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .quote_node = quote_data };
        return node;
    }

    fn analyzeLoop(self: *Analyzer, items: []const Form) err.Error!*Node {
        // (loop [binding1 val1 ...] body...)
        // let と同じ構造だが、recur のターゲットになる
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "loop requires binding vector", .{});
        }

        const bindings_form = items[1];
        if (bindings_form != .vector) {
            return err.parseError(.invalid_binding, "loop bindings must be a vector", .{});
        }

        const binding_pairs = bindings_form.vector;
        if (binding_pairs.len % 2 != 0) {
            return err.parseError(.invalid_binding, "loop bindings must have even number of forms", .{});
        }

        const start_locals = self.locals.items.len;
        var bindings = self.allocator.alloc(node_mod.LetBinding, binding_pairs.len / 2) catch return error.OutOfMemory;

        var i: usize = 0;
        while (i < binding_pairs.len) : (i += 2) {
            const sym_form = binding_pairs[i];
            if (sym_form != .symbol) {
                return err.parseError(.invalid_binding, "loop binding name must be a symbol", .{});
            }

            const name = sym_form.symbol.name;
            const init_node = try self.analyze(binding_pairs[i + 1]);

            const idx: u32 = @intCast(self.locals.items.len);
            self.locals.append(self.allocator, .{ .name = name, .idx = idx }) catch return error.OutOfMemory;

            bindings[i / 2] = .{ .name = name, .init = init_node };
        }

        const body = if (items.len == 2)
            try self.makeConstant(value_mod.nil)
        else if (items.len == 3)
            try self.analyze(items[2])
        else blk: {
            var statements = self.allocator.alloc(*Node, items.len - 2) catch return error.OutOfMemory;
            for (items[2..], 0..) |item, j| {
                statements[j] = try self.analyze(item);
            }
            const do_data = self.allocator.create(node_mod.DoNode) catch return error.OutOfMemory;
            do_data.* = .{ .statements = statements, .stack = .{} };
            const do_node = self.allocator.create(Node) catch return error.OutOfMemory;
            do_node.* = .{ .do_node = do_data };
            break :blk do_node;
        };

        self.locals.shrinkRetainingCapacity(start_locals);

        const loop_data = self.allocator.create(node_mod.LoopNode) catch return error.OutOfMemory;
        loop_data.* = .{
            .bindings = bindings,
            .body = body,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .loop_node = loop_data };
        return node;
    }

    fn analyzeRecur(self: *Analyzer, items: []const Form) err.Error!*Node {
        // (recur arg1 arg2 ...)
        var args = self.allocator.alloc(*Node, items.len - 1) catch return error.OutOfMemory;
        for (items[1..], 0..) |item, i| {
            args[i] = try self.analyze(item);
        }

        const recur_data = self.allocator.create(node_mod.RecurNode) catch return error.OutOfMemory;
        recur_data.* = .{
            .args = args,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .recur_node = recur_data };
        return node;
    }

    fn analyzeApply(self: *Analyzer, items: []const Form) err.Error!*Node {
        // (apply f args) または (apply f x y z args)
        // 最低2引数（関数とシーケンス）
        if (items.len < 3) {
            return err.parseError(.invalid_arity, "apply requires at least 2 arguments", .{});
        }

        // 関数を解析
        const fn_node = try self.analyze(items[1]);

        // 中間引数（最後の1つを除く）
        const middle_count = items.len - 3; // items[0]=apply, items[1]=fn, items[-1]=seq
        var middle_args = self.allocator.alloc(*Node, middle_count) catch return error.OutOfMemory;
        for (0..middle_count) |i| {
            middle_args[i] = try self.analyze(items[2 + i]);
        }

        // シーケンス引数（最後の引数）
        const seq_node = try self.analyze(items[items.len - 1]);

        const apply_data = self.allocator.create(node_mod.ApplyNode) catch return error.OutOfMemory;
        apply_data.* = .{
            .fn_node = fn_node,
            .args = middle_args,
            .seq_node = seq_node,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .apply_node = apply_data };
        return node;
    }

    fn analyzePartial(self: *Analyzer, items: []const Form) err.Error!*Node {
        // (partial f arg1 arg2 ...)
        // 最低2引数（関数と1つ以上の引数）
        if (items.len < 3) {
            return err.parseError(.invalid_arity, "partial requires at least 2 arguments", .{});
        }

        // 関数を解析
        const fn_node = try self.analyze(items[1]);

        // 部分適用する引数
        var args = self.allocator.alloc(*Node, items.len - 2) catch return error.OutOfMemory;
        for (items[2..], 0..) |item, i| {
            args[i] = try self.analyze(item);
        }

        const partial_data = self.allocator.create(node_mod.PartialNode) catch return error.OutOfMemory;
        partial_data.* = .{
            .fn_node = fn_node,
            .args = args,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .partial_node = partial_data };
        return node;
    }

    fn analyzeComp(self: *Analyzer, items: []const Form) err.Error!*Node {
        // (comp) => identity
        // (comp f) => f
        // (comp f g h ...) => 関数合成

        // 関数を解析
        var fns = self.allocator.alloc(*Node, items.len - 1) catch return error.OutOfMemory;
        for (items[1..], 0..) |item, i| {
            fns[i] = try self.analyze(item);
        }

        const comp_data = self.allocator.create(node_mod.CompNode) catch return error.OutOfMemory;
        comp_data.* = .{
            .fns = fns,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .comp_node = comp_data };
        return node;
    }

    fn analyzeReduce(self: *Analyzer, items: []const Form) err.Error!*Node {
        // (reduce f coll) または (reduce f init coll)
        if (items.len < 3 or items.len > 4) {
            return err.parseError(.invalid_arity, "reduce requires 2 or 3 arguments", .{});
        }

        const fn_node = try self.analyze(items[1]);

        var init_node: ?*Node = null;
        var coll_node: *Node = undefined;

        if (items.len == 3) {
            // (reduce f coll) - 初期値なし
            coll_node = try self.analyze(items[2]);
        } else {
            // (reduce f init coll)
            init_node = try self.analyze(items[2]);
            coll_node = try self.analyze(items[3]);
        }

        const reduce_data = self.allocator.create(node_mod.ReduceNode) catch return error.OutOfMemory;
        reduce_data.* = .{
            .fn_node = fn_node,
            .init_node = init_node,
            .coll_node = coll_node,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .reduce_node = reduce_data };
        return node;
    }

    fn analyzeCall(self: *Analyzer, items: []const Form) err.Error!*Node {
        // (fn arg1 arg2 ...)
        const fn_node = try self.analyze(items[0]);

        var args = self.allocator.alloc(*Node, items.len - 1) catch return error.OutOfMemory;
        for (items[1..], 0..) |item, i| {
            args[i] = try self.analyze(item);
        }

        const call_data = self.allocator.create(node_mod.CallNode) catch return error.OutOfMemory;
        call_data.* = .{
            .fn_node = fn_node,
            .args = args,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .call_node = call_data };
        return node;
    }

    // === ヘルパー ===

    fn findLocal(self: *const Analyzer, name: []const u8) ?LocalBinding {
        // 後ろから検索（シャドウイング対応）
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) {
                return self.locals.items[i];
            }
        }
        return null;
    }

    fn makeConstant(self: *Analyzer, val: Value) err.Error!*Node {
        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .constant = val };
        return node;
    }

    fn makeLocalRef(self: *Analyzer, name: []const u8, idx: u32) err.Error!*Node {
        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{
            .local_ref = .{
                .name = name,
                .idx = idx,
                .stack = .{},
            },
        };
        return node;
    }

    fn makeVarRef(self: *Analyzer, v: *Var) err.Error!*Node {
        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{
            .var_ref = .{
                .var_ref = v,
                .stack = .{},
            },
        };
        return node;
    }

    fn makeEmptyList(self: *Analyzer) err.Error!*Node {
        const lst = self.allocator.create(value_mod.PersistentList) catch return error.OutOfMemory;
        lst.* = value_mod.PersistentList.emptyVal();
        return self.makeConstant(.{ .list = lst });
    }

    /// Form を Value に変換（quote 用）
    fn formToValue(self: *Analyzer, form: Form) err.Error!Value {
        return switch (form) {
            .nil => value_mod.nil,
            .bool_true => value_mod.true_val,
            .bool_false => value_mod.false_val,
            .int => |n| value_mod.intVal(n),
            .float => |n| value_mod.floatVal(n),
            .string => |s| blk: {
                const str = self.allocator.create(value_mod.String) catch return error.OutOfMemory;
                str.* = value_mod.String.init(s);
                break :blk .{ .string = str };
            },
            .keyword => |sym| blk: {
                const kw = self.allocator.create(value_mod.Keyword) catch return error.OutOfMemory;
                kw.* = if (sym.namespace) |ns|
                    value_mod.Keyword.initNs(ns, sym.name)
                else
                    value_mod.Keyword.init(sym.name);
                break :blk .{ .keyword = kw };
            },
            .symbol => |sym| blk: {
                const s = self.allocator.create(RuntimeSymbol) catch return error.OutOfMemory;
                s.* = if (sym.namespace) |ns|
                    RuntimeSymbol.initNs(ns, sym.name)
                else
                    RuntimeSymbol.init(sym.name);
                break :blk .{ .symbol = s };
            },
            .list => |items| blk: {
                var vals = self.allocator.alloc(Value, items.len) catch return error.OutOfMemory;
                for (items, 0..) |item, i| {
                    vals[i] = try self.formToValue(item);
                }
                const lst = self.allocator.create(value_mod.PersistentList) catch return error.OutOfMemory;
                lst.* = .{ .items = vals };
                break :blk .{ .list = lst };
            },
            .vector => |items| blk: {
                var vals = self.allocator.alloc(Value, items.len) catch return error.OutOfMemory;
                for (items, 0..) |item, i| {
                    vals[i] = try self.formToValue(item);
                }
                const vec = self.allocator.create(value_mod.PersistentVector) catch return error.OutOfMemory;
                vec.* = .{ .items = vals };
                break :blk .{ .vector = vec };
            },
        };
    }

    // === defmacro ===

    fn analyzeDefmacro(self: *Analyzer, items: []const Form) err.Error!*Node {
        // (defmacro name [params] body...)
        // 内部的には (def name (fn [params] body...)) を生成し、マクロフラグを設定
        if (items.len < 3) {
            return err.parseError(.invalid_arity, "defmacro requires at least name and params", .{});
        }

        if (items[1] != .symbol) {
            return err.parseError(.invalid_binding, "defmacro name must be a symbol", .{});
        }

        const macro_name = items[1].symbol.name;

        // fn 形式を構築して解析
        // (defmacro name [params] body...) → (fn name [params] body...)
        // items: [defmacro, name, params, body...]   (len = N)
        // fn_items: [fn, name, params, body...]      (len = N)
        var fn_items = self.allocator.alloc(Form, items.len) catch return error.OutOfMemory;
        fn_items[0] = .{ .symbol = FormSymbol.init("fn") };
        fn_items[1] = items[1]; // name
        for (items[2..], 0..) |item, i| {
            fn_items[i + 2] = item;
        }

        const fn_node = try self.analyzeFn(fn_items);

        // DefmacroNode を作成（DefNode と同じ構造だが、evaluator でマクロフラグを設定）
        const def_data = self.allocator.create(node_mod.DefNode) catch return error.OutOfMemory;
        def_data.* = .{
            .sym_name = macro_name,
            .init = fn_node,
            .is_macro = true,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .def_node = def_data };
        return node;
    }

    // === マクロ展開 ===

    /// マクロ呼び出しかどうかをチェックし、展開する
    fn tryMacroExpand(self: *Analyzer, items: []const Form) err.Error!?*Node {
        // 先頭がシンボルでなければマクロではない
        if (items[0] != .symbol) return null;

        const sym = items[0].symbol;
        if (sym.namespace != null) return null; // 名前空間付きは後で対応

        // シンボルを解決
        const runtime_sym = RuntimeSymbol.init(sym.name);
        const v = self.env.resolve(runtime_sym) orelse return null;

        // マクロでなければ通常の関数呼び出し
        if (!v.isMacro()) return null;

        // マクロの値を取得
        const macro_val = v.deref();
        if (macro_val != .fn_val) return null;

        const macro_fn = macro_val.fn_val;

        // 引数を quote して Value に変換（マクロは引数を評価せずに受け取る）
        var macro_args = self.allocator.alloc(Value, items.len - 1) catch return error.OutOfMemory;
        for (items[1..], 0..) |item, i| {
            macro_args[i] = try self.formToValue(item);
        }

        // マクロを実行
        const expanded_value = try self.callMacro(macro_fn, macro_args);

        // 展開結果を Form に変換して再解析
        const expanded_form = try self.valueToForm(expanded_value);
        return self.analyze(expanded_form);
    }

    /// マクロ関数を呼び出す
    fn callMacro(self: *Analyzer, macro_fn: *Fn, args: []const Value) err.Error!Value {
        // 組み込み関数（BuiltinFn）としてのマクロはサポートしない
        // ユーザー定義マクロのみ
        const arity = macro_fn.findArity(args.len) orelse
            return err.parseError(.invalid_arity, "Macro arity mismatch", .{});

        // 新しいコンテキストを作成
        var ctx = Context.init(self.allocator, self.env);

        // クロージャ環境をバインド
        if (macro_fn.closure_bindings) |bindings| {
            ctx = ctx.withBindings(bindings) catch return error.OutOfMemory;
        }

        // 引数をバインド
        ctx = ctx.withBindings(args) catch return error.OutOfMemory;

        // ボディを評価
        const body: *const Node = @ptrCast(@alignCast(arity.body));
        return evaluator.run(body, &ctx) catch return err.parseError(.macro_error, "Macro expansion failed", .{});
    }

    /// Value を Form に変換（マクロ展開結果の再解析用）
    fn valueToForm(self: *Analyzer, val: Value) err.Error!Form {
        return switch (val) {
            .nil => Form.nil,
            .bool_val => |b| if (b) Form.bool_true else Form.bool_false,
            .int => |n| Form{ .int = n },
            .float => |f| Form{ .float = f },
            .string => |s| Form{ .string = s.data },
            .keyword => |k| Form{ .keyword = if (k.namespace) |ns|
                FormSymbol.initNs(ns, k.name)
            else
                FormSymbol.init(k.name) },
            .symbol => |s| Form{ .symbol = if (s.namespace) |ns|
                FormSymbol.initNs(ns, s.name)
            else
                FormSymbol.init(s.name) },
            .list => |l| blk: {
                var forms = self.allocator.alloc(Form, l.items.len) catch return error.OutOfMemory;
                for (l.items, 0..) |item, i| {
                    forms[i] = try self.valueToForm(item);
                }
                break :blk Form{ .list = forms };
            },
            .vector => |v| blk: {
                var forms = self.allocator.alloc(Form, v.items.len) catch return error.OutOfMemory;
                for (v.items, 0..) |item, i| {
                    forms[i] = try self.valueToForm(item);
                }
                break :blk Form{ .vector = forms };
            },
            .char_val, .map, .set, .fn_val, .partial_fn, .comp_fn, .fn_proto, .var_val => return err.parseError(.invalid_token, "Cannot convert to form", .{}),
        };
    }
};

// === テスト ===

test "analyze constant" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    var analyzer = Analyzer.init(allocator, &env);
    defer analyzer.deinit();

    const node = try analyzer.analyze(.{ .int = 42 });
    try std.testing.expectEqualStrings("constant", node.kindName());
}

test "analyze if" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    var analyzer = Analyzer.init(allocator, &env);
    defer analyzer.deinit();

    // (if true 1 2)
    const items = [_]Form{
        .{ .symbol = FormSymbol.init("if") },
        .bool_true,
        .{ .int = 1 },
        .{ .int = 2 },
    };

    const node = try analyzer.analyze(.{ .list = &items });
    try std.testing.expectEqualStrings("if", node.kindName());
}

test "analyze def" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();
    try env.setupBasic();

    var analyzer = Analyzer.init(allocator, &env);
    defer analyzer.deinit();

    // (def x 42)
    const items = [_]Form{
        .{ .symbol = FormSymbol.init("def") },
        .{ .symbol = FormSymbol.init("x") },
        .{ .int = 42 },
    };

    const node = try analyzer.analyze(.{ .list = &items });
    try std.testing.expectEqualStrings("def", node.kindName());
}
