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

/// 分配パターン情報（fn パラメータ用）
const DestructurePattern = struct {
    idx: usize,
    pattern: Form,
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
            .map => |items| self.analyzeMap(items),
            .set => |items| self.analyzeSet(items),
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
            } else if (std.mem.eql(u8, sym_name, "letfn")) {
                return self.analyzeLetfn(items);
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
            } else if (std.mem.eql(u8, sym_name, "map")) {
                return self.analyzeMap2(items);
            } else if (std.mem.eql(u8, sym_name, "filter")) {
                return self.analyzeFilter(items);
            } else if (std.mem.eql(u8, sym_name, "take-while")) {
                return self.analyzeTakeWhile(items);
            } else if (std.mem.eql(u8, sym_name, "drop-while")) {
                return self.analyzeDropWhile(items);
            } else if (std.mem.eql(u8, sym_name, "map-indexed")) {
                return self.analyzeMapIndexed(items);
            } else if (std.mem.eql(u8, sym_name, "sort-by")) {
                return self.analyzeSortBy(items);
            } else if (std.mem.eql(u8, sym_name, "group-by")) {
                return self.analyzeGroupBy(items);
            } else if (std.mem.eql(u8, sym_name, "throw")) {
                return self.analyzeThrow(items);
            } else if (std.mem.eql(u8, sym_name, "try")) {
                return self.analyzeTry(items);
            } else if (std.mem.eql(u8, sym_name, "swap!")) {
                return self.analyzeSwap(items);
            } else if (std.mem.eql(u8, sym_name, "defmulti")) {
                return self.analyzeDefmulti(items);
            } else if (std.mem.eql(u8, sym_name, "defmethod")) {
                return self.analyzeDefmethod(items);
            } else if (std.mem.eql(u8, sym_name, "defprotocol")) {
                return self.analyzeDefprotocol(items);
            } else if (std.mem.eql(u8, sym_name, "extend-type")) {
                return self.analyzeExtendType(items);
            }

            // 組み込みマクロ展開（Form→Form 変換して再解析）
            if (try self.expandBuiltinMacro(sym_name, items)) |expanded| {
                return self.analyze(expanded);
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
        // ベクターリテラル: まず全要素を解析
        var nodes = self.allocator.alloc(*Node, items.len) catch return error.OutOfMemory;
        var all_const = true;
        for (items, 0..) |item, i| {
            nodes[i] = try self.analyze(item);
            if (nodes[i].* != .constant) {
                all_const = false;
            }
        }

        if (all_const) {
            // 全定数: 即値ベクターを構築
            var values = self.allocator.alloc(Value, items.len) catch return error.OutOfMemory;
            for (nodes, 0..) |n, i| {
                values[i] = n.constant;
            }
            const vec = self.allocator.create(value_mod.PersistentVector) catch return error.OutOfMemory;
            vec.* = .{ .items = values };
            return self.makeConstant(.{ .vector = vec });
        }

        // 非定数要素あり: (vector item1 item2 ...) 呼び出しに変換
        return self.makeBuiltinCall("vector", nodes);
    }

    fn analyzeMap(self: *Analyzer, items: []const Form) err.Error!*Node {
        // マップリテラル {k1 v1 k2 v2 ...}
        // items は偶数個であることが Reader で保証されている
        var nodes = self.allocator.alloc(*Node, items.len) catch return error.OutOfMemory;
        var all_const = true;
        for (items, 0..) |item, i| {
            nodes[i] = try self.analyze(item);
            if (nodes[i].* != .constant) {
                all_const = false;
            }
        }

        if (all_const) {
            var values = self.allocator.alloc(Value, items.len) catch return error.OutOfMemory;
            for (nodes, 0..) |n, i| {
                values[i] = n.constant;
            }
            const m = self.allocator.create(value_mod.PersistentMap) catch return error.OutOfMemory;
            m.* = .{ .entries = values };
            return self.makeConstant(.{ .map = m });
        }

        // 非定数要素あり: (hash-map k1 v1 k2 v2 ...) 呼び出しに変換
        return self.makeBuiltinCall("hash-map", nodes);
    }

    fn analyzeSet(self: *Analyzer, items: []const Form) err.Error!*Node {
        // セットリテラル #{...}
        var nodes = self.allocator.alloc(*Node, items.len) catch return error.OutOfMemory;
        var all_const = true;
        for (items, 0..) |item, i| {
            nodes[i] = try self.analyze(item);
            if (nodes[i].* != .constant) {
                all_const = false;
            }
        }

        if (all_const) {
            var values = self.allocator.alloc(Value, items.len) catch return error.OutOfMemory;
            for (nodes, 0..) |n, i| {
                values[i] = n.constant;
            }
            const s = self.allocator.create(value_mod.PersistentSet) catch return error.OutOfMemory;
            s.* = .{ .items = values };
            return self.makeConstant(.{ .set = s });
        }

        // 非定数要素あり: (set (vector item1 item2 ...)) に変換
        // set は1引数(コレクション)を取るため、まず vector を作ってから set に渡す
        const vec_call = try self.makeBuiltinCall("vector", nodes);
        const set_args = self.allocator.alloc(*Node, 1) catch return error.OutOfMemory;
        set_args[0] = vec_call;
        return self.makeBuiltinCall("set", set_args);
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

        // 分配束縛を展開してバインディングリストを構築
        var bindings_list: std.ArrayListUnmanaged(node_mod.LetBinding) = .empty;
        defer bindings_list.deinit(self.allocator);

        var i: usize = 0;
        while (i < binding_pairs.len) : (i += 2) {
            const pattern = binding_pairs[i];
            const init_node = try self.analyze(binding_pairs[i + 1]);

            // パターンを展開してバインディングを追加
            try self.expandBindingPattern(pattern, init_node, &bindings_list);
        }

        // バインディングを確定
        const bindings = self.allocator.alloc(node_mod.LetBinding, bindings_list.items.len) catch return error.OutOfMemory;
        @memcpy(bindings, bindings_list.items);

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

    /// letfn: 相互再帰ローカル関数
    /// (letfn [(f [x] body1) (g [x] body2)] expr)
    fn analyzeLetfn(self: *Analyzer, items: []const Form) err.Error!*Node {
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "letfn requires binding vector and body", .{});
        }

        // バインディングベクター
        const bindings_form = items[1];
        if (bindings_form != .vector) {
            return err.parseError(.invalid_binding, "letfn bindings must be a vector", .{});
        }

        const binding_forms = bindings_form.vector;

        // Phase 1: 全関数名をローカルに登録（相互参照を可能に）
        const start_locals = self.locals.items.len;
        var fn_names = std.ArrayListUnmanaged([]const u8).empty;
        defer fn_names.deinit(self.allocator);

        for (binding_forms) |bf| {
            if (bf != .list) {
                return err.parseError(.invalid_binding, "letfn binding must be a list: (name [params] body...)", .{});
            }
            const bf_items = bf.list;
            if (bf_items.len < 2) {
                return err.parseError(.invalid_binding, "letfn binding requires name and params", .{});
            }
            if (bf_items[0] != .symbol) {
                return err.parseError(.invalid_binding, "letfn binding name must be a symbol", .{});
            }
            const name = bf_items[0].symbol.name;
            fn_names.append(self.allocator, name) catch return error.OutOfMemory;

            // ローカルに追加（idx はグローバルインデックス）
            const idx: u32 = @intCast(self.locals.items.len);
            self.locals.append(self.allocator, .{ .name = name, .idx = idx }) catch return error.OutOfMemory;
        }

        // Phase 2: 各関数本体を解析（全関数名がスコープ内にある状態で）
        var bindings = self.allocator.alloc(node_mod.LetfnBinding, binding_forms.len) catch return error.OutOfMemory;
        for (binding_forms, 0..) |bf, i| {
            const bf_items = bf.list;
            const name = bf_items[0].symbol.name;

            // (name [params] body...) を (fn name [params] body...) として解析
            // analyzeFn は items[0] = "fn" を想定するので、先頭に fn シンボルを追加
            var fn_items = self.allocator.alloc(Form, bf_items.len + 1) catch return error.OutOfMemory;
            fn_items[0] = .{ .symbol = FormSymbol.init("fn") };
            @memcpy(fn_items[1..], bf_items);

            const fn_node = try self.analyzeFn(fn_items);
            bindings[i] = .{
                .name = name,
                .fn_node = fn_node,
            };
        }

        // Phase 3: ボディを解析
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

        // ローカルをポップ
        self.locals.shrinkRetainingCapacity(start_locals);

        const letfn_data = self.allocator.create(node_mod.LetfnNode) catch return error.OutOfMemory;
        letfn_data.* = .{
            .bindings = bindings,
            .body = body,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .letfn_node = letfn_data };
        return node;
    }

    /// バインディングパターンを展開
    /// symbol: 単純バインディング
    /// vector: シーケンシャル分配
    /// (将来) map: 連想分配
    fn expandBindingPattern(
        self: *Analyzer,
        pattern: Form,
        init_node: *Node,
        bindings: *std.ArrayListUnmanaged(node_mod.LetBinding),
    ) err.Error!void {
        switch (pattern) {
            .symbol => |sym| {
                // 単純バインディング: name = init
                const name = sym.name;
                const idx: u32 = @intCast(self.locals.items.len);
                self.locals.append(self.allocator, .{ .name = name, .idx = idx }) catch return error.OutOfMemory;
                bindings.append(self.allocator, .{ .name = name, .init = init_node }) catch return error.OutOfMemory;
            },
            .vector => |elems| {
                // シーケンシャル分配: [a b c] = coll
                try self.expandSequentialPattern(elems, init_node, bindings);
            },
            .map => |entries| {
                // マップ分配: {:keys [a b], x :x, :or {a 0}, :as all}
                try self.expandMapPattern(entries, init_node, bindings);
            },
            else => {
                return err.parseError(.invalid_binding, "binding pattern must be a symbol, vector, or map", .{});
            },
        }
    }

    /// シーケンシャル分配を展開
    /// [a b c] -> a = (nth coll 0), b = (nth coll 1), c = (nth coll 2)
    /// [a b & rest] -> a = (nth coll 0), b = (nth coll 1), rest = (drop 2 coll)
    /// [a b :as all] -> a = (nth coll 0), b = (nth coll 1), all = coll
    fn expandSequentialPattern(
        self: *Analyzer,
        elems: []const Form,
        init_node: *Node,
        bindings: *std.ArrayListUnmanaged(node_mod.LetBinding),
    ) err.Error!void {
        // まず全体を一時変数にバインド（複数回評価を避ける）
        const temp_name = "__destructure_seq__";
        const temp_idx: u32 = @intCast(self.locals.items.len);
        self.locals.append(self.allocator, .{ .name = temp_name, .idx = temp_idx }) catch return error.OutOfMemory;
        bindings.append(self.allocator, .{ .name = temp_name, .init = init_node }) catch return error.OutOfMemory;

        // 一時変数への参照ノードを作成
        const temp_ref = try self.makeLocalRef(temp_name, temp_idx);

        var pos: usize = 0;
        var i: usize = 0;
        while (i < elems.len) : (i += 1) {
            const elem = elems[i];

            // & rest チェック
            if (elem == .symbol and std.mem.eql(u8, elem.symbol.name, "&")) {
                // 次の要素が rest パラメータ
                if (i + 1 >= elems.len) {
                    return err.parseError(.invalid_binding, "& must be followed by a binding", .{});
                }
                const rest_pattern = elems[i + 1];

                // rest = (drop pos coll) - 簡易実装として nthnext を使う
                // nthnext がないので、一時的に rest 関数を複数回呼ぶ形で実装
                const rest_init = try self.makeNthRest(temp_ref, pos);
                try self.expandBindingPattern(rest_pattern, rest_init, bindings);

                i += 1; // rest パターンをスキップ

                // :as チェック（& rest の後にも :as がある可能性）
                if (i + 1 < elems.len) {
                    const maybe_as = elems[i + 1];
                    if (maybe_as == .keyword and std.mem.eql(u8, maybe_as.keyword.name, "as")) {
                        if (i + 2 >= elems.len) {
                            return err.parseError(.invalid_binding, ":as must be followed by a symbol", .{});
                        }
                        const as_pattern = elems[i + 2];
                        try self.expandBindingPattern(as_pattern, temp_ref, bindings);
                        i += 2;
                    }
                }
                continue;
            }

            // :as チェック
            if (elem == .keyword and std.mem.eql(u8, elem.keyword.name, "as")) {
                if (i + 1 >= elems.len) {
                    return err.parseError(.invalid_binding, ":as must be followed by a symbol", .{});
                }
                const as_pattern = elems[i + 1];
                try self.expandBindingPattern(as_pattern, temp_ref, bindings);
                i += 1; // as パターンをスキップ
                continue;
            }

            // 通常要素: elem = (nth coll pos)
            const nth_init = try self.makeNth(temp_ref, pos);
            try self.expandBindingPattern(elem, nth_init, bindings);
            pos += 1;
        }
    }

    /// マップ分配を展開
    /// {:keys [a b]} -> a = (get coll :a), b = (get coll :b)
    /// {x :x, y :y} -> x = (get coll :x), y = (get coll :y)
    /// {:keys [a] :or {a 0}} -> a = (get coll :a) ?? 0
    /// {:keys [a] :as all} -> a = (get coll :a), all = coll
    fn expandMapPattern(
        self: *Analyzer,
        entries: []const Form,
        init_node: *Node,
        bindings: *std.ArrayListUnmanaged(node_mod.LetBinding),
    ) err.Error!void {
        // まず全体を一時変数にバインド
        const temp_name = "__destructure_map__";
        const temp_idx: u32 = @intCast(self.locals.items.len);
        self.locals.append(self.allocator, .{ .name = temp_name, .idx = temp_idx }) catch return error.OutOfMemory;
        bindings.append(self.allocator, .{ .name = temp_name, .init = init_node }) catch return error.OutOfMemory;

        const temp_ref = try self.makeLocalRef(temp_name, temp_idx);

        // :or のデフォルト値マップを探す
        var defaults: ?[]const Form = null;

        // まず :or を探す
        var i: usize = 0;
        while (i < entries.len) : (i += 2) {
            if (i + 1 >= entries.len) break;
            const key = entries[i];
            const val = entries[i + 1];

            if (key == .keyword and std.mem.eql(u8, key.keyword.name, "or")) {
                if (val == .map) {
                    defaults = val.map;
                }
            }
        }

        // 各エントリを処理
        i = 0;
        while (i < entries.len) : (i += 2) {
            if (i + 1 >= entries.len) break;
            const key = entries[i];
            const val = entries[i + 1];

            if (key == .keyword) {
                const kw_name = key.keyword.name;

                if (std.mem.eql(u8, kw_name, "keys")) {
                    // :keys [a b c] -> 各シンボルを同名キーワードで get
                    if (val != .vector) {
                        return err.parseError(.invalid_binding, ":keys must be followed by a vector", .{});
                    }
                    for (val.vector) |sym_form| {
                        if (sym_form != .symbol) {
                            return err.parseError(.invalid_binding, ":keys elements must be symbols", .{});
                        }
                        const sym_name = sym_form.symbol.name;
                        const get_init = try self.makeGet(temp_ref, sym_name, defaults);
                        const bind_idx: u32 = @intCast(self.locals.items.len);
                        self.locals.append(self.allocator, .{ .name = sym_name, .idx = bind_idx }) catch return error.OutOfMemory;
                        bindings.append(self.allocator, .{ .name = sym_name, .init = get_init }) catch return error.OutOfMemory;
                    }
                } else if (std.mem.eql(u8, kw_name, "strs")) {
                    // :strs [a b] -> 各シンボルを同名文字列キーで get
                    if (val != .vector) {
                        return err.parseError(.invalid_binding, ":strs must be followed by a vector", .{});
                    }
                    for (val.vector) |sym_form| {
                        if (sym_form != .symbol) {
                            return err.parseError(.invalid_binding, ":strs elements must be symbols", .{});
                        }
                        const sym_name = sym_form.symbol.name;
                        const get_init = try self.makeGetStr(temp_ref, sym_name, defaults);
                        const bind_idx: u32 = @intCast(self.locals.items.len);
                        self.locals.append(self.allocator, .{ .name = sym_name, .idx = bind_idx }) catch return error.OutOfMemory;
                        bindings.append(self.allocator, .{ .name = sym_name, .init = get_init }) catch return error.OutOfMemory;
                    }
                } else if (std.mem.eql(u8, kw_name, "as")) {
                    // :as all -> all = coll
                    try self.expandBindingPattern(val, temp_ref, bindings);
                } else if (std.mem.eql(u8, kw_name, "or")) {
                    // :or は既に処理済み、スキップ
                    continue;
                } else {
                    // 未知のキーワード
                    return err.parseError(.invalid_binding, "unknown map destructuring keyword", .{});
                }
            } else if (key == .symbol) {
                // {x :x, y :y} -> x = (get coll :x)
                const sym_name = key.symbol.name;
                if (val != .keyword) {
                    return err.parseError(.invalid_binding, "map destructuring: value must be a keyword", .{});
                }
                const get_init = try self.makeGetKeyword(temp_ref, val.keyword.name);
                const bind_idx: u32 = @intCast(self.locals.items.len);
                self.locals.append(self.allocator, .{ .name = sym_name, .idx = bind_idx }) catch return error.OutOfMemory;
                bindings.append(self.allocator, .{ .name = sym_name, .init = get_init }) catch return error.OutOfMemory;
            } else {
                return err.parseError(.invalid_binding, "map destructuring: key must be keyword or symbol", .{});
            }
        }
    }

    /// (get coll :key) を生成（:keys 用、:or デフォルト対応）
    fn makeGet(self: *Analyzer, coll_node: *Node, key_name: []const u8, defaults: ?[]const Form) err.Error!*Node {
        // デフォルト値を探す
        const default_node: ?*Node = if (defaults) |defs| blk: {
            var j: usize = 0;
            while (j < defs.len) : (j += 2) {
                if (j + 1 >= defs.len) break;
                if (defs[j] == .symbol and std.mem.eql(u8, defs[j].symbol.name, key_name)) {
                    break :blk try self.analyze(defs[j + 1]);
                }
            }
            break :blk null;
        } else null;

        return self.makeGetKeywordWithDefault(coll_node, key_name, default_node);
    }

    /// (get coll "key") を生成（:strs 用）
    fn makeGetStr(self: *Analyzer, coll_node: *Node, key_name: []const u8, defaults: ?[]const Form) err.Error!*Node {
        // デフォルト値を探す
        const default_node: ?*Node = if (defaults) |defs| blk: {
            var j: usize = 0;
            while (j < defs.len) : (j += 2) {
                if (j + 1 >= defs.len) break;
                if (defs[j] == .symbol and std.mem.eql(u8, defs[j].symbol.name, key_name)) {
                    break :blk try self.analyze(defs[j + 1]);
                }
            }
            break :blk null;
        } else null;

        // 文字列キーを生成
        const str = self.allocator.create(value_mod.String) catch return error.OutOfMemory;
        str.* = value_mod.String.init(key_name);
        const key_node = try self.makeConstant(.{ .string = str });

        return self.makeGetCall(coll_node, key_node, default_node);
    }

    /// (get coll :keyword) を生成
    fn makeGetKeyword(self: *Analyzer, coll_node: *Node, key_name: []const u8) err.Error!*Node {
        return self.makeGetKeywordWithDefault(coll_node, key_name, null);
    }

    /// (get coll :keyword default) を生成
    fn makeGetKeywordWithDefault(self: *Analyzer, coll_node: *Node, key_name: []const u8, default_node: ?*Node) err.Error!*Node {
        // キーワード値を生成
        const kw = self.allocator.create(value_mod.Keyword) catch return error.OutOfMemory;
        kw.* = value_mod.Keyword.init(key_name);
        const key_node = try self.makeConstant(.{ .keyword = kw });

        return self.makeGetCall(coll_node, key_node, default_node);
    }

    /// (get coll key) または (get coll key default) を生成
    fn makeGetCall(self: *Analyzer, coll_node: *Node, key_node: *Node, default_node: ?*Node) err.Error!*Node {
        const get_sym = RuntimeSymbol.init("get");
        const get_var = self.env.resolve(get_sym) orelse return err.parseError(.undefined_symbol, "get not found", .{});
        const fn_node = try self.makeVarRef(get_var);

        const arg_count: usize = if (default_node != null) 3 else 2;
        const args = self.allocator.alloc(*Node, arg_count) catch return error.OutOfMemory;
        args[0] = coll_node;
        args[1] = key_node;
        if (default_node) |def| {
            args[2] = def;
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

    /// (nth coll idx) を生成
    fn makeNth(self: *Analyzer, coll_node: *Node, idx: usize) err.Error!*Node {
        // nth Var を取得
        const nth_sym = RuntimeSymbol.init("nth");
        const nth_var = self.env.resolve(nth_sym) orelse return err.parseError(.undefined_symbol, "nth not found", .{});

        const fn_node = try self.makeVarRef(nth_var);
        const idx_node = try self.makeConstant(value_mod.intVal(@intCast(idx)));

        const args = self.allocator.alloc(*Node, 2) catch return error.OutOfMemory;
        args[0] = coll_node;
        args[1] = idx_node;

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

    /// rest 部分を取得（pos 番目以降）
    /// 簡易実装: rest を pos 回呼び出す
    fn makeNthRest(self: *Analyzer, coll_node: *Node, pos: usize) err.Error!*Node {
        if (pos == 0) {
            return coll_node;
        }

        // rest Var を取得
        const rest_sym = RuntimeSymbol.init("rest");
        const rest_var = self.env.resolve(rest_sym) orelse return err.parseError(.undefined_symbol, "rest not found", .{});

        var current = coll_node;
        for (0..pos) |_| {
            const fn_node = try self.makeVarRef(rest_var);
            const args = self.allocator.alloc(*Node, 1) catch return error.OutOfMemory;
            args[0] = current;

            const call_data = self.allocator.create(node_mod.CallNode) catch return error.OutOfMemory;
            call_data.* = .{
                .fn_node = fn_node,
                .args = args,
                .stack = .{},
            };

            const node = self.allocator.create(Node) catch return error.OutOfMemory;
            node.* = .{ .call_node = call_data };
            current = node;
        }

        return current;
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

    /// fn の単一アリティを解析
    /// パラメータに分配束縛が含まれる場合は、ボディを let でラップして展開
    fn analyzeFnArity(self: *Analyzer, params_form: []const Form, body_forms: []const Form) err.Error!node_mod.FnArity {
        // パラメータを解析
        var params = std.ArrayListUnmanaged([]const u8).empty;
        var variadic = false;

        // 分配パターンがあるパラメータを記録
        var destructure_patterns = std.ArrayListUnmanaged(DestructurePattern).empty;
        defer destructure_patterns.deinit(self.allocator);

        // fn 本体では新しいスコープを開始
        const start_locals = self.locals.items.len;

        var param_idx: usize = 0;
        for (params_form) |p| {
            switch (p) {
                .symbol => |sym| {
                    const param_name = sym.name;

                    if (std.mem.eql(u8, param_name, "&")) {
                        variadic = true;
                        continue;
                    }

                    params.append(self.allocator, param_name) catch return error.OutOfMemory;

                    // ローカルに追加
                    const idx: u32 = @intCast(self.locals.items.len);
                    self.locals.append(self.allocator, .{ .name = param_name, .idx = idx }) catch return error.OutOfMemory;
                },
                .vector, .map => {
                    // 分配パターン → 合成パラメータ名を生成
                    const synthetic_name = try self.makeSyntheticParamName(param_idx);
                    params.append(self.allocator, synthetic_name) catch return error.OutOfMemory;

                    // 後で展開するためにパターンを記録
                    destructure_patterns.append(self.allocator, .{ .idx = param_idx, .pattern = p }) catch return error.OutOfMemory;

                    // 合成パラメータをローカルに追加
                    const idx: u32 = @intCast(self.locals.items.len);
                    self.locals.append(self.allocator, .{ .name = synthetic_name, .idx = idx }) catch return error.OutOfMemory;
                },
                else => {
                    return err.parseError(.invalid_binding, "fn parameter must be a symbol, vector, or map pattern", .{});
                },
            }
            param_idx += 1;
        }

        // ボディを解析
        var body: *Node = undefined;

        // 分配パターンがある場合、ボディを let でラップ
        if (destructure_patterns.items.len > 0) {
            body = try self.wrapBodyWithDestructure(params.items, destructure_patterns.items, body_forms);
        } else {
            body = if (body_forms.len == 0)
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
        }

        // ローカルをポップ
        self.locals.shrinkRetainingCapacity(start_locals);

        return .{
            .params = params.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .variadic = variadic,
            .body = body,
        };
    }

    /// 合成パラメータ名を生成
    fn makeSyntheticParamName(self: *Analyzer, idx: usize) err.Error![]const u8 {
        var buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "__p{d}__", .{idx}) catch return error.OutOfMemory;
        return self.allocator.dupe(u8, name) catch return error.OutOfMemory;
    }

    /// fn ボディを分配束縛の let でラップ
    /// (fn [[a b]] body) -> let [__p0__ param] で分配して body
    fn wrapBodyWithDestructure(
        self: *Analyzer,
        params: []const []const u8,
        patterns: []const DestructurePattern,
        body_forms: []const Form,
    ) err.Error!*Node {
        // 分配バインディングを構築
        var bindings_list: std.ArrayListUnmanaged(node_mod.LetBinding) = .empty;
        defer bindings_list.deinit(self.allocator);

        for (patterns) |entry| {
            // 合成パラメータへの参照を作成
            const param_name = params[entry.idx];
            const local = self.findLocal(param_name) orelse return err.parseError(.undefined_symbol, "internal error: param not found", .{});
            const param_ref = try self.makeLocalRef(local.name, local.idx);

            // パターンを展開
            try self.expandBindingPattern(entry.pattern, param_ref, &bindings_list);
        }

        // バインディングを確定
        const bindings = self.allocator.alloc(node_mod.LetBinding, bindings_list.items.len) catch return error.OutOfMemory;
        @memcpy(bindings, bindings_list.items);

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

        // let ノードを作成
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

    fn analyzeDef(self: *Analyzer, items: []const Form) err.Error!*Node {
        // (def name) または (def name value)
        if (items.len < 2 or items.len > 3) {
            return err.parseError(.invalid_arity, "def requires 1 or 2 arguments", .{});
        }

        if (items[1] != .symbol) {
            return err.parseError(.invalid_binding, "def name must be a symbol", .{});
        }

        const sym_name = items[1].symbol.name;

        // Var を先に作成（再帰的な defn で fn body から参照できるように）
        if (self.env.getCurrentNs()) |ns| {
            _ = ns.intern(sym_name) catch return error.OutOfMemory;
        }

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

    /// (map f coll) の解析
    fn analyzeMap2(self: *Analyzer, items: []const Form) err.Error!*Node {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "map requires 2 arguments (map f coll)", .{});
        }

        const fn_node = try self.analyze(items[1]);
        const coll_node = try self.analyze(items[2]);

        const map_data = self.allocator.create(node_mod.MapNode) catch return error.OutOfMemory;
        map_data.* = .{
            .fn_node = fn_node,
            .coll_node = coll_node,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .map_node = map_data };
        return node;
    }

    /// (filter pred coll) の解析
    fn analyzeFilter(self: *Analyzer, items: []const Form) err.Error!*Node {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "filter requires 2 arguments (filter pred coll)", .{});
        }

        const fn_node = try self.analyze(items[1]);
        const coll_node = try self.analyze(items[2]);

        const filter_data = self.allocator.create(node_mod.FilterNode) catch return error.OutOfMemory;
        filter_data.* = .{
            .fn_node = fn_node,
            .coll_node = coll_node,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .filter_node = filter_data };
        return node;
    }

    /// (take-while pred coll) の解析
    fn analyzeTakeWhile(self: *Analyzer, items: []const Form) err.Error!*Node {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "take-while requires 2 arguments (take-while pred coll)", .{});
        }

        const fn_node = try self.analyze(items[1]);
        const coll_node = try self.analyze(items[2]);

        const data = self.allocator.create(node_mod.TakeWhileNode) catch return error.OutOfMemory;
        data.* = .{ .fn_node = fn_node, .coll_node = coll_node, .stack = .{} };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .take_while_node = data };
        return node;
    }

    /// (drop-while pred coll) の解析
    fn analyzeDropWhile(self: *Analyzer, items: []const Form) err.Error!*Node {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "drop-while requires 2 arguments (drop-while pred coll)", .{});
        }

        const fn_node = try self.analyze(items[1]);
        const coll_node = try self.analyze(items[2]);

        const data = self.allocator.create(node_mod.DropWhileNode) catch return error.OutOfMemory;
        data.* = .{ .fn_node = fn_node, .coll_node = coll_node, .stack = .{} };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .drop_while_node = data };
        return node;
    }

    /// (map-indexed f coll) の解析
    fn analyzeMapIndexed(self: *Analyzer, items: []const Form) err.Error!*Node {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "map-indexed requires 2 arguments (map-indexed f coll)", .{});
        }

        const fn_node = try self.analyze(items[1]);
        const coll_node = try self.analyze(items[2]);

        const data = self.allocator.create(node_mod.MapIndexedNode) catch return error.OutOfMemory;
        data.* = .{ .fn_node = fn_node, .coll_node = coll_node, .stack = .{} };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .map_indexed_node = data };
        return node;
    }

    /// (sort-by keyfn coll) の解析
    fn analyzeSortBy(self: *Analyzer, items: []const Form) err.Error!*Node {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "sort-by requires 2 arguments (sort-by keyfn coll)", .{});
        }
        const fn_node = try self.analyze(items[1]);
        const coll_node = try self.analyze(items[2]);
        const data = self.allocator.create(node_mod.SortByNode) catch return error.OutOfMemory;
        data.* = .{ .fn_node = fn_node, .coll_node = coll_node, .stack = .{} };
        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .sort_by_node = data };
        return node;
    }

    /// (group-by f coll) の解析
    fn analyzeGroupBy(self: *Analyzer, items: []const Form) err.Error!*Node {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "group-by requires 2 arguments (group-by f coll)", .{});
        }
        const fn_node = try self.analyze(items[1]);
        const coll_node = try self.analyze(items[2]);
        const data = self.allocator.create(node_mod.GroupByNode) catch return error.OutOfMemory;
        data.* = .{ .fn_node = fn_node, .coll_node = coll_node, .stack = .{} };
        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .group_by_node = data };
        return node;
    }

    // ============================================================
    // Atom 操作
    // ============================================================

    /// (swap! atom f) または (swap! atom f x y ...) の解析
    fn analyzeSwap(self: *Analyzer, items: []const Form) err.Error!*Node {
        // 最低3引数: swap!, atom, fn
        if (items.len < 3) {
            return err.parseError(.invalid_arity, "swap! requires at least 2 arguments (swap! atom f)", .{});
        }

        const atom_node = try self.analyze(items[1]);
        const fn_node = try self.analyze(items[2]);

        // 追加引数（0個以上）
        const extra_count = items.len - 3;
        var extra_args = self.allocator.alloc(*Node, extra_count) catch return error.OutOfMemory;
        for (0..extra_count) |i| {
            extra_args[i] = try self.analyze(items[3 + i]);
        }

        const swap_data = self.allocator.create(node_mod.SwapNode) catch return error.OutOfMemory;
        swap_data.* = .{
            .atom_node = atom_node,
            .fn_node = fn_node,
            .args = extra_args,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .swap_node = swap_data };
        return node;
    }

    // ============================================================
    // 例外処理
    // ============================================================

    /// (throw expr) の解析
    fn analyzeThrow(self: *Analyzer, items: []const Form) err.Error!*Node {
        if (items.len != 2) {
            return err.parseError(.invalid_arity, "throw requires 1 argument", .{});
        }

        const expr = try self.analyze(items[1]);

        const throw_data = self.allocator.create(node_mod.ThrowNode) catch return error.OutOfMemory;
        throw_data.* = .{
            .expr = expr,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .throw_node = throw_data };
        return node;
    }

    /// (try body* (catch Exception e handler*) (finally cleanup*)) の解析
    fn analyzeTry(self: *Analyzer, items: []const Form) err.Error!*Node {
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "try requires at least a body expression", .{});
        }

        // items[0] は "try" シンボル自体
        // 残りを走査して body / catch / finally に分離
        var body_forms: std.ArrayListUnmanaged(Form) = .empty;
        var catch_clause: ?node_mod.CatchClause = null;
        var finally_body: ?*Node = null;

        for (items[1..]) |item| {
            if (item == .list) {
                const sub_items = item.list;
                if (sub_items.len > 0 and sub_items[0] == .symbol) {
                    const name = sub_items[0].symbol.name;

                    if (std.mem.eql(u8, name, "catch")) {
                        // (catch Exception e handler-body*)
                        if (sub_items.len < 4) {
                            return err.parseError(.invalid_arity, "catch requires (catch ExceptionType name body*)", .{});
                        }
                        // sub_items[1] は Exception 型（初期は無視）
                        // sub_items[2] はバインディング名
                        if (sub_items[2] != .symbol) {
                            return err.parseError(.invalid_binding, "catch binding must be a symbol", .{});
                        }
                        const binding_name = sub_items[2].symbol.name;

                        // catch ハンドラ本体を解析
                        // ローカルバインディングを追加してハンドラを解析
                        const saved_depth = self.locals.items.len;
                        self.locals.append(self.allocator, .{
                            .name = binding_name,
                            .idx = @intCast(saved_depth),
                        }) catch return error.OutOfMemory;

                        const handler_body = if (sub_items.len == 4)
                            try self.analyze(sub_items[3])
                        else
                            try self.analyze(try self.wrapInDo(sub_items[3..]));

                        // ローカルを復元
                        self.locals.shrinkRetainingCapacity(saved_depth);

                        catch_clause = .{
                            .binding_name = binding_name,
                            .body = handler_body,
                        };
                        continue;
                    }

                    if (std.mem.eql(u8, name, "finally")) {
                        // (finally cleanup-body*)
                        if (sub_items.len < 2) {
                            return err.parseError(.invalid_arity, "finally requires at least one expression", .{});
                        }

                        finally_body = if (sub_items.len == 2)
                            try self.analyze(sub_items[1])
                        else
                            try self.analyze(try self.wrapInDo(sub_items[1..]));
                        continue;
                    }
                }
            }

            // catch/finally 以外は body
            body_forms.append(self.allocator, item) catch return error.OutOfMemory;
        }

        // body を do ノードにラップ
        const body_node = if (body_forms.items.len == 1)
            try self.analyze(body_forms.items[0])
        else if (body_forms.items.len == 0)
            try self.makeConstant(value_mod.nil)
        else
            try self.analyze(try self.wrapInDo(body_forms.items));

        const try_data = self.allocator.create(node_mod.TryNode) catch return error.OutOfMemory;
        try_data.* = .{
            .body = body_node,
            .catch_clause = catch_clause,
            .finally_body = finally_body,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .try_node = try_data };
        return node;
    }

    // ============================================================
    // 組み込みマクロ展開（Form → Form 変換）
    // ============================================================

    /// 組み込みマクロを展開する。該当しない場合は null を返す。
    fn expandBuiltinMacro(self: *Analyzer, name: []const u8, items: []const Form) err.Error!?Form {
        if (std.mem.eql(u8, name, "cond")) {
            return try self.expandCond(items);
        } else if (std.mem.eql(u8, name, "when")) {
            return try self.expandWhen(items);
        } else if (std.mem.eql(u8, name, "when-not")) {
            return try self.expandWhenNot(items);
        } else if (std.mem.eql(u8, name, "if-let")) {
            return try self.expandIfLet(items);
        } else if (std.mem.eql(u8, name, "when-let")) {
            return try self.expandWhenLet(items);
        } else if (std.mem.eql(u8, name, "and")) {
            return try self.expandAnd(items);
        } else if (std.mem.eql(u8, name, "or")) {
            return try self.expandOr(items);
        } else if (std.mem.eql(u8, name, "->")) {
            return try self.expandThreadFirst(items);
        } else if (std.mem.eql(u8, name, "->>")) {
            return try self.expandThreadLast(items);
        } else if (std.mem.eql(u8, name, "defn")) {
            return try self.expandDefn(items);
        } else if (std.mem.eql(u8, name, "if-not")) {
            return try self.expandIfNot(items);
        } else if (std.mem.eql(u8, name, "dotimes")) {
            return try self.expandDotimes(items);
        } else if (std.mem.eql(u8, name, "doseq")) {
            return try self.expandDoseq(items);
        } else if (std.mem.eql(u8, name, "comment")) {
            return Form.nil; // (comment ...) → nil
        } else if (std.mem.eql(u8, name, "condp")) {
            return try self.expandCondp(items);
        } else if (std.mem.eql(u8, name, "case")) {
            return try self.expandCase(items);
        } else if (std.mem.eql(u8, name, "some->")) {
            return try self.expandSomeThreadFirst(items);
        } else if (std.mem.eql(u8, name, "some->>")) {
            return try self.expandSomeThreadLast(items);
        } else if (std.mem.eql(u8, name, "as->")) {
            return try self.expandAsThread(items);
        } else if (std.mem.eql(u8, name, "mapv")) {
            return try self.expandMapv(items);
        } else if (std.mem.eql(u8, name, "filterv")) {
            return try self.expandFilterv(items);
        } else if (std.mem.eql(u8, name, "every?")) {
            return try self.expandEvery(items);
        } else if (std.mem.eql(u8, name, "some")) {
            return try self.expandSome(items);
        } else if (std.mem.eql(u8, name, "not-every?")) {
            return try self.expandNotEvery(items);
        } else if (std.mem.eql(u8, name, "not-any?")) {
            return try self.expandNotAny(items);
        } else if (std.mem.eql(u8, name, "extend-protocol")) {
            return try self.expandExtendProtocol(items);
        } else if (std.mem.eql(u8, name, "update")) {
            return try self.expandUpdate(items);
        } else if (std.mem.eql(u8, name, "complement")) {
            return try self.expandComplement(items);
        } else if (std.mem.eql(u8, name, "constantly")) {
            return try self.expandConstantly(items);
        } else if (std.mem.eql(u8, name, "defonce")) {
            return try self.expandDefonce(items);
        } else if (std.mem.eql(u8, name, "defn-")) {
            return try self.expandDefnPrivate(items);
        } else if (std.mem.eql(u8, name, "declare")) {
            return try self.expandDeclare(items);
        } else if (std.mem.eql(u8, name, "while")) {
            return try self.expandWhile(items);
        } else if (std.mem.eql(u8, name, "doto")) {
            return try self.expandDoto(items);
        } else if (std.mem.eql(u8, name, "cond->")) {
            return try self.expandCondThread(items, false);
        } else if (std.mem.eql(u8, name, "cond->>")) {
            return try self.expandCondThread(items, true);
        } else if (std.mem.eql(u8, name, "if-some")) {
            return try self.expandIfSome(items);
        } else if (std.mem.eql(u8, name, "when-some")) {
            return try self.expandWhenSome(items);
        } else if (std.mem.eql(u8, name, "when-first")) {
            return try self.expandWhenFirst(items);
        } else if (std.mem.eql(u8, name, "for")) {
            return try self.expandFor(items);
        } else if (std.mem.eql(u8, name, "some-fn")) {
            return try self.expandSomeFn(items);
        } else if (std.mem.eql(u8, name, "every-pred")) {
            return try self.expandEveryPred(items);
        } else if (std.mem.eql(u8, name, "fnil")) {
            return try self.expandFnil(items);
        } else if (std.mem.eql(u8, name, "assert")) {
            return try self.expandAssert(items);
        } else if (std.mem.eql(u8, name, "mapcat")) {
            return try self.expandMapcat(items);
        } else if (std.mem.eql(u8, name, "keep")) {
            return try self.expandKeep(items);
        } else if (std.mem.eql(u8, name, "keep-indexed")) {
            return try self.expandKeepIndexed(items);
        } else if (std.mem.eql(u8, name, "run!")) {
            return try self.expandRunBang(items);
        } else if (std.mem.eql(u8, name, "doall")) {
            return try self.expandDoall(items);
        } else if (std.mem.eql(u8, name, "dorun")) {
            return try self.expandDorun(items);
        }
        return null;
    }

    /// (cond test1 expr1 test2 expr2 ... :else default)
    /// → (if test1 expr1 (if test2 expr2 ... default))
    fn expandCond(self: *Analyzer, items: []const Form) err.Error!Form {
        const pairs = items[1..]; // cond を除く
        if (pairs.len == 0) return Form.nil;
        if (pairs.len % 2 != 0) {
            return err.parseError(.invalid_arity, "cond requires an even number of forms", .{});
        }
        return self.buildCondChain(pairs);
    }

    fn buildCondChain(self: *Analyzer, pairs: []const Form) err.Error!Form {
        if (pairs.len == 0) return Form.nil;
        if (pairs.len < 2) return err.parseError(.invalid_arity, "cond requires pairs", .{});

        const test_form = pairs[0];
        const expr = pairs[1];
        const rest = pairs[2..];

        // :else は常に真
        const is_else = switch (test_form) {
            .keyword => |k| std.mem.eql(u8, k.name, "else"),
            else => false,
        };

        if (is_else or rest.len == 0) {
            // 最後のペア: (if test expr nil)
            const if_forms = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
            if_forms[0] = Form{ .symbol = form_mod.Symbol.init("if") };
            if_forms[1] = if (is_else) Form.bool_true else test_form;
            if_forms[2] = expr;
            if_forms[3] = Form.nil;
            return Form{ .list = if_forms };
        }

        // (if test expr (cond rest...))
        const else_branch = try self.buildCondChain(rest);
        const if_forms = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
        if_forms[0] = Form{ .symbol = form_mod.Symbol.init("if") };
        if_forms[1] = test_form;
        if_forms[2] = expr;
        if_forms[3] = else_branch;
        return Form{ .list = if_forms };
    }

    /// (when test body1 body2 ...) → (if test (do body1 body2 ...))
    fn expandWhen(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "when requires at least a test", .{});
        }

        const body = items[2..];
        const body_form = try self.wrapInDo(body);

        const if_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        if_forms[0] = Form{ .symbol = form_mod.Symbol.init("if") };
        if_forms[1] = items[1]; // test
        if_forms[2] = body_form;
        return Form{ .list = if_forms };
    }

    /// (when-not test body1 body2 ...) → (if (not test) (do body1 body2 ...))
    fn expandWhenNot(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "when-not requires at least a test", .{});
        }

        // (not test)
        const not_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        not_forms[0] = Form{ .symbol = form_mod.Symbol.init("not") };
        not_forms[1] = items[1];
        const not_form = Form{ .list = not_forms };

        const body = items[2..];
        const body_form = try self.wrapInDo(body);

        const if_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        if_forms[0] = Form{ .symbol = form_mod.Symbol.init("if") };
        if_forms[1] = not_form;
        if_forms[2] = body_form;
        return Form{ .list = if_forms };
    }

    /// (if-let [x expr] then else?)
    /// → (let [x expr] (if x then else))
    fn expandIfLet(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 3 or items.len > 4) {
            return err.parseError(.invalid_arity, "if-let requires 2-3 arguments", .{});
        }

        const binding_vec = items[1];
        if (binding_vec != .vector or binding_vec.vector.len != 2) {
            return err.parseError(.invalid_binding, "if-let requires a binding vector [sym expr]", .{});
        }

        const bindings = binding_vec.vector;
        const then_form = items[2];
        const else_form: Form = if (items.len > 3) items[3] else Form.nil;

        // (if x then else)
        const if_forms = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
        if_forms[0] = Form{ .symbol = form_mod.Symbol.init("if") };
        if_forms[1] = bindings[0]; // x
        if_forms[2] = then_form;
        if_forms[3] = else_form;
        const if_form = Form{ .list = if_forms };

        // (let [x expr] (if x then else))
        const let_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        let_forms[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        let_forms[1] = binding_vec;
        let_forms[2] = if_form;
        return Form{ .list = let_forms };
    }

    /// (when-let [x expr] body...) → (let [x expr] (when x body...))
    fn expandWhenLet(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 3) {
            return err.parseError(.invalid_arity, "when-let requires at least a binding and body", .{});
        }

        const binding_vec = items[1];
        if (binding_vec != .vector or binding_vec.vector.len != 2) {
            return err.parseError(.invalid_binding, "when-let requires a binding vector [sym expr]", .{});
        }

        const bindings = binding_vec.vector;
        const body = items[2..];

        // (when x body...)
        const when_forms = self.allocator.alloc(Form, 2 + body.len) catch return error.OutOfMemory;
        when_forms[0] = Form{ .symbol = form_mod.Symbol.init("when") };
        when_forms[1] = bindings[0]; // x
        @memcpy(when_forms[2..], body);
        const when_form = Form{ .list = when_forms };

        // (let [x expr] (when x body...))
        const let_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        let_forms[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        let_forms[1] = binding_vec;
        let_forms[2] = when_form;
        return Form{ .list = let_forms };
    }

    /// (and) → true
    /// (and x) → x
    /// (and x y ...) → (let [__and x] (if __and (and y ...) __and))
    fn expandAnd(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len == 1) return Form.bool_true; // (and) → true
        if (items.len == 2) return items[1]; // (and x) → x

        // (and x y ...) → (let [__and x] (if __and (and y ...) __and))
        const x = items[1];
        const rest = items[2..];
        const temp_sym = form_mod.Symbol.init("__and__");

        // (and y ...)
        const and_rest = self.allocator.alloc(Form, 1 + rest.len) catch return error.OutOfMemory;
        and_rest[0] = Form{ .symbol = form_mod.Symbol.init("and") };
        @memcpy(and_rest[1..], rest);
        const and_rest_form = Form{ .list = and_rest };

        // (if __and (and y ...) __and)
        const if_forms = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
        if_forms[0] = Form{ .symbol = form_mod.Symbol.init("if") };
        if_forms[1] = Form{ .symbol = temp_sym };
        if_forms[2] = and_rest_form;
        if_forms[3] = Form{ .symbol = temp_sym };
        const if_form = Form{ .list = if_forms };

        // [__and x]
        const bind_vec = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        bind_vec[0] = Form{ .symbol = temp_sym };
        bind_vec[1] = x;

        // (let [__and x] (if ...))
        const let_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        let_forms[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        let_forms[1] = Form{ .vector = bind_vec };
        let_forms[2] = if_form;
        return Form{ .list = let_forms };
    }

    /// (or) → nil
    /// (or x) → x
    /// (or x y ...) → (let [__or x] (if __or __or (or y ...)))
    fn expandOr(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len == 1) return Form.nil; // (or) → nil
        if (items.len == 2) return items[1]; // (or x) → x

        const x = items[1];
        const rest = items[2..];
        const temp_sym = form_mod.Symbol.init("__or__");

        // (or y ...)
        const or_rest = self.allocator.alloc(Form, 1 + rest.len) catch return error.OutOfMemory;
        or_rest[0] = Form{ .symbol = form_mod.Symbol.init("or") };
        @memcpy(or_rest[1..], rest);
        const or_rest_form = Form{ .list = or_rest };

        // (if __or __or (or y ...))
        const if_forms = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
        if_forms[0] = Form{ .symbol = form_mod.Symbol.init("if") };
        if_forms[1] = Form{ .symbol = temp_sym };
        if_forms[2] = Form{ .symbol = temp_sym };
        if_forms[3] = or_rest_form;
        const if_form = Form{ .list = if_forms };

        // [__or x]
        const bind_vec = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        bind_vec[0] = Form{ .symbol = temp_sym };
        bind_vec[1] = x;

        // (let [__or x] (if ...))
        const let_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        let_forms[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        let_forms[1] = Form{ .vector = bind_vec };
        let_forms[2] = if_form;
        return Form{ .list = let_forms };
    }

    /// (-> x (f a) (g b)) → (g (f x a) b)
    /// (-> x f) → (f x) （シンボルの場合）
    fn expandThreadFirst(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "-> requires at least one argument", .{});
        }

        var result = items[1]; // 初期値
        for (items[2..]) |form| {
            result = try self.threadInsert(result, form, .first);
        }
        return result;
    }

    /// (->> x (f a) (g b)) → (g a (f b x))
    fn expandThreadLast(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "->> requires at least one argument", .{});
        }

        var result = items[1];
        for (items[2..]) |form| {
            result = try self.threadInsert(result, form, .last);
        }
        return result;
    }

    const ThreadPosition = enum { first, last };

    fn threadInsert(self: *Analyzer, val: Form, form: Form, pos: ThreadPosition) err.Error!Form {
        switch (form) {
            .symbol => {
                // (-> x f) → (f x)
                const call = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
                call[0] = form;
                call[1] = val;
                return Form{ .list = call };
            },
            .list => |lst| {
                // (-> x (f a b)) → (f x a b) or (f a b x)
                if (pos == .first) {
                    // 第1引数として挿入
                    const new_list = self.allocator.alloc(Form, lst.len + 1) catch return error.OutOfMemory;
                    new_list[0] = lst[0]; // 関数
                    new_list[1] = val; // 挿入
                    @memcpy(new_list[2..], lst[1..]); // 残りの引数
                    return Form{ .list = new_list };
                } else {
                    // 末尾引数として挿入
                    const new_list = self.allocator.alloc(Form, lst.len + 1) catch return error.OutOfMemory;
                    @memcpy(new_list[0..lst.len], lst); // 元の全要素
                    new_list[lst.len] = val; // 末尾に挿入
                    return Form{ .list = new_list };
                }
            },
            else => {
                return err.parseError(.invalid_token, "threading form must be a symbol or list", .{});
            },
        }
    }

    /// body を (do ...) で包む。要素が1つなら do 不要。
    fn wrapInDo(self: *Analyzer, body: []const Form) err.Error!Form {
        if (body.len == 0) return Form.nil;
        if (body.len == 1) return body[0];

        const do_forms = self.allocator.alloc(Form, 1 + body.len) catch return error.OutOfMemory;
        do_forms[0] = Form{ .symbol = form_mod.Symbol.init("do") };
        @memcpy(do_forms[1..], body);
        return Form{ .list = do_forms };
    }

    // ============================================================
    // defn / if-not / dotimes / doseq マクロ展開
    // ============================================================

    /// (defn name "doc"? [params] body...) → (def name (fn name [params] body...))
    /// (defn name "doc"? ([a] body1) ([a b] body2)) → (def name (fn name ([a] body1) ([a b] body2)))
    fn expandDefn(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 3) {
            return err.parseError(.invalid_arity, "defn requires a name and at least one body", .{});
        }

        // items[0] = defn, items[1] = name
        const name_form = items[1];
        const name_sym = switch (name_form) {
            .symbol => |s| s,
            else => return err.parseError(.invalid_token, "defn name must be a symbol", .{}),
        };

        // docstring をスキップ（items[2] が文字列なら無視）
        var body_start: usize = 2;
        if (body_start < items.len and items[body_start] == .string) {
            body_start += 1; // docstring をスキップ
        }

        if (body_start >= items.len) {
            return err.parseError(.invalid_arity, "defn requires at least one body", .{});
        }

        // (def name (fn name ...)) を構築
        // fn 部分: items[body_start..] をそのまま fn に渡す
        const rest = items[body_start..];
        const fn_forms_len = 2 + rest.len; // fn, name, rest...
        const fn_forms = self.allocator.alloc(Form, fn_forms_len) catch return error.OutOfMemory;
        fn_forms[0] = Form{ .symbol = form_mod.Symbol.init("fn") };
        fn_forms[1] = name_form; // fn に名前を渡す
        @memcpy(fn_forms[2..], rest);

        // (def name (fn name ...))
        const def_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        def_forms[0] = Form{ .symbol = form_mod.Symbol.init("def") };
        def_forms[1] = Form{ .symbol = name_sym };
        def_forms[2] = Form{ .list = fn_forms };
        return Form{ .list = def_forms };
    }

    /// (if-not test then) → (if (not test) then)
    /// (if-not test then else) → (if (not test) then else)
    fn expandIfNot(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 3 or items.len > 4) {
            return err.parseError(.invalid_arity, "if-not requires 2 or 3 arguments", .{});
        }

        // (not test)
        const not_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        not_forms[0] = Form{ .symbol = form_mod.Symbol.init("not") };
        not_forms[1] = items[1];

        // (if (not test) then else?)
        const if_len: usize = if (items.len == 4) 4 else 3;
        const if_forms = self.allocator.alloc(Form, if_len) catch return error.OutOfMemory;
        if_forms[0] = Form{ .symbol = form_mod.Symbol.init("if") };
        if_forms[1] = Form{ .list = not_forms };
        if_forms[2] = items[2];
        if (items.len == 4) {
            if_forms[3] = items[3];
        }
        return Form{ .list = if_forms };
    }

    /// (dotimes [i n] body...) → (loop [i 0] (when (< i n) body... (recur (inc i))))
    fn expandDotimes(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 3) {
            return err.parseError(.invalid_arity, "dotimes requires a binding vector and body", .{});
        }

        const binding_vec = switch (items[1]) {
            .vector => |v| v,
            else => return err.parseError(.invalid_binding, "dotimes requires a binding vector [i n]", .{}),
        };
        if (binding_vec.len != 2) {
            return err.parseError(.invalid_binding, "dotimes binding must be [i n]", .{});
        }

        const var_sym = binding_vec[0];
        const count_form = binding_vec[1];
        const body = items[2..];

        // (recur (inc i))
        const inc_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        inc_forms[0] = Form{ .symbol = form_mod.Symbol.init("inc") };
        inc_forms[1] = var_sym;

        const recur_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        recur_forms[0] = Form{ .symbol = form_mod.Symbol.init("recur") };
        recur_forms[1] = Form{ .list = inc_forms };

        // (< i n)
        const lt_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        lt_forms[0] = Form{ .symbol = form_mod.Symbol.init("<") };
        lt_forms[1] = var_sym;
        lt_forms[2] = count_form;

        // (when (< i n) body... (recur (inc i)))
        const when_forms = self.allocator.alloc(Form, 2 + body.len + 1) catch return error.OutOfMemory;
        when_forms[0] = Form{ .symbol = form_mod.Symbol.init("when") };
        when_forms[1] = Form{ .list = lt_forms };
        @memcpy(when_forms[2 .. 2 + body.len], body);
        when_forms[2 + body.len] = Form{ .list = recur_forms };

        // loop バインディング [i 0]
        const loop_bindings = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        loop_bindings[0] = var_sym;
        loop_bindings[1] = Form{ .int = 0 };

        // (loop [i 0] (when ...))
        const loop_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        loop_forms[0] = Form{ .symbol = form_mod.Symbol.init("loop") };
        loop_forms[1] = Form{ .vector = loop_bindings };
        loop_forms[2] = Form{ .list = when_forms };
        return Form{ .list = loop_forms };
    }

    /// (doseq [x coll] body...) → 各要素について body を実行、nil を返す
    /// 展開: (loop [__items (seq coll)] (when __items (let [x (first __items)] body... (recur (rest __items)))))
    fn expandDoseq(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 3) {
            return err.parseError(.invalid_arity, "doseq requires a binding vector and body", .{});
        }

        const binding_vec = switch (items[1]) {
            .vector => |v| v,
            else => return err.parseError(.invalid_binding, "doseq requires a binding vector [x coll]", .{}),
        };
        if (binding_vec.len != 2) {
            return err.parseError(.invalid_binding, "doseq binding must be [x coll]", .{});
        }

        const var_sym = binding_vec[0];
        const coll_form = binding_vec[1];
        const body = items[2..];

        const items_sym = Form{ .symbol = form_mod.Symbol.init("__doseq_items__") };

        // (seq coll)
        const seq_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        seq_forms[0] = Form{ .symbol = form_mod.Symbol.init("seq") };
        seq_forms[1] = coll_form;

        // (first __items)
        const first_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        first_forms[0] = Form{ .symbol = form_mod.Symbol.init("first") };
        first_forms[1] = items_sym;

        // (rest __items)
        const rest_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        rest_forms[0] = Form{ .symbol = form_mod.Symbol.init("rest") };
        rest_forms[1] = items_sym;

        // (seq (rest __items))  — seq で空リストを nil に変換
        const seq_rest_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        seq_rest_forms[0] = Form{ .symbol = form_mod.Symbol.init("seq") };
        seq_rest_forms[1] = Form{ .list = rest_forms };

        // (recur (seq (rest __items)))
        const recur_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        recur_forms[0] = Form{ .symbol = form_mod.Symbol.init("recur") };
        recur_forms[1] = Form{ .list = seq_rest_forms };

        // let バインディング [x (first __items)]
        const let_bindings = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        let_bindings[0] = var_sym;
        let_bindings[1] = Form{ .list = first_forms };

        // (let [x (first __items)] body... (recur (rest __items)))
        const let_forms = self.allocator.alloc(Form, 2 + body.len + 1) catch return error.OutOfMemory;
        let_forms[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        let_forms[1] = Form{ .vector = let_bindings };
        @memcpy(let_forms[2 .. 2 + body.len], body);
        let_forms[2 + body.len] = Form{ .list = recur_forms };

        // (when __items (let ...))
        const when_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        when_forms[0] = Form{ .symbol = form_mod.Symbol.init("when") };
        when_forms[1] = items_sym;
        when_forms[2] = Form{ .list = let_forms };

        // loop バインディング [__items (seq coll)]
        const loop_bindings = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        loop_bindings[0] = items_sym;
        loop_bindings[1] = Form{ .list = seq_forms };

        // (loop [__items (seq coll)] (when ...))
        const loop_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        loop_forms[0] = Form{ .symbol = form_mod.Symbol.init("loop") };
        loop_forms[1] = Form{ .vector = loop_bindings };
        loop_forms[2] = Form{ .list = when_forms };
        return Form{ .list = loop_forms };
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

    /// 組み込み関数呼び出しノードを構築: (fn_name arg1 arg2 ...)
    fn makeBuiltinCall(self: *Analyzer, fn_name: []const u8, args: []*Node) err.Error!*Node {
        const runtime_sym = RuntimeSymbol.init(fn_name);
        const v = self.env.resolve(runtime_sym) orelse {
            return err.parseError(.undefined_symbol, "Unable to resolve builtin function", .{});
        };
        const fn_node = try self.makeVarRef(v);

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
            .map => |items| blk: {
                var vals = self.allocator.alloc(Value, items.len) catch return error.OutOfMemory;
                for (items, 0..) |item, i| {
                    vals[i] = try self.formToValue(item);
                }
                const m = self.allocator.create(value_mod.PersistentMap) catch return error.OutOfMemory;
                m.* = .{ .entries = vals };
                break :blk .{ .map = m };
            },
            .set => |items| blk: {
                var vals = self.allocator.alloc(Value, items.len) catch return error.OutOfMemory;
                for (items, 0..) |item, i| {
                    vals[i] = try self.formToValue(item);
                }
                const s = self.allocator.create(value_mod.PersistentSet) catch return error.OutOfMemory;
                s.* = .{ .items = vals };
                break :blk .{ .set = s };
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

    // === マルチメソッド解析 ===

    /// (defmulti name dispatch-fn)
    fn analyzeDefmulti(self: *Analyzer, items: []const Form) err.Error!*Node {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "defmulti requires name and dispatch-fn", .{});
        }

        if (items[1] != .symbol) {
            return err.parseError(.invalid_binding, "defmulti name must be a symbol", .{});
        }

        const name = items[1].symbol.name;

        // Var を先に作成（後で defmethod が参照できるように）
        if (self.env.getCurrentNs()) |ns| {
            _ = ns.intern(name) catch return error.OutOfMemory;
        }

        // ディスパッチ関数を解析
        const dispatch_fn = try self.analyze(items[2]);

        const data = self.allocator.create(node_mod.DefmultiNode) catch return error.OutOfMemory;
        data.* = .{
            .name = name,
            .dispatch_fn = dispatch_fn,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .defmulti_node = data };
        return node;
    }

    /// (defmethod name dispatch-val fn-expr)
    /// または (defmethod name dispatch-val [params] body...)
    fn analyzeDefmethod(self: *Analyzer, items: []const Form) err.Error!*Node {
        // 最低4要素: defmethod name dispatch-val [params]
        if (items.len < 4) {
            return err.parseError(.invalid_arity, "defmethod requires name, dispatch-val, and method body", .{});
        }

        if (items[1] != .symbol) {
            return err.parseError(.invalid_binding, "defmethod name must be a symbol", .{});
        }

        const multi_name = items[1].symbol.name;

        // ディスパッチ値を解析
        const dispatch_val = try self.analyze(items[2]);

        // メソッド関数を解析
        // (defmethod name dispatch-val [params] body...) → fn として解析
        const method_fn = if (items[3] == .vector) blk: {
            // [params] body... 形式 → (fn [params] body...) を構築
            var fn_items = self.allocator.alloc(Form, items.len - 2) catch return error.OutOfMemory;
            fn_items[0] = .{ .symbol = FormSymbol.init("fn") };
            for (items[3..], 0..) |item, i| {
                fn_items[i + 1] = item;
            }
            break :blk try self.analyzeFn(fn_items);
        } else blk: {
            // fn 式がそのまま与えられた場合
            break :blk try self.analyze(items[3]);
        };

        const data = self.allocator.create(node_mod.DefmethodNode) catch return error.OutOfMemory;
        data.* = .{
            .multi_name = multi_name,
            .dispatch_val = dispatch_val,
            .method_fn = method_fn,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .defmethod_node = data };
        return node;
    }

    // === プロトコル解析 ===

    /// (defprotocol Name (method1 [this]) (method2 [this arg]))
    fn analyzeDefprotocol(self: *Analyzer, items: []const Form) err.Error!*Node {
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "defprotocol requires at least a name", .{});
        }

        if (items[1] != .symbol) {
            return err.parseError(.invalid_binding, "defprotocol name must be a symbol", .{});
        }

        const proto_name = items[1].symbol.name;

        // Var を先に作成
        if (self.env.getCurrentNs()) |ns| {
            _ = ns.intern(proto_name) catch return error.OutOfMemory;
        }

        // メソッドシグネチャをパース: (method-name [this ...])
        var sigs_buf: std.ArrayListUnmanaged(node_mod.DefprotocolNode.ProtocolMethodSig) = .empty;
        for (items[2..]) |item| {
            if (item != .list) {
                return err.parseError(.invalid_token, "defprotocol method signature must be a list", .{});
            }
            const sig_items = item.list;
            if (sig_items.len < 2) {
                return err.parseError(.invalid_arity, "defprotocol method signature requires name and params", .{});
            }
            if (sig_items[0] != .symbol) {
                return err.parseError(.invalid_binding, "defprotocol method name must be a symbol", .{});
            }
            if (sig_items[1] != .vector) {
                return err.parseError(.invalid_token, "defprotocol method params must be a vector", .{});
            }

            const method_name = sig_items[0].symbol.name;
            const param_count: u8 = @intCast(sig_items[1].vector.len);

            // メソッド名の Var を intern
            if (self.env.getCurrentNs()) |ns| {
                _ = ns.intern(method_name) catch return error.OutOfMemory;
            }

            sigs_buf.append(self.allocator, .{
                .name = method_name,
                .arity = param_count,
            }) catch return error.OutOfMemory;
        }

        const data = self.allocator.create(node_mod.DefprotocolNode) catch return error.OutOfMemory;
        data.* = .{
            .name = proto_name,
            .method_sigs = sigs_buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .defprotocol_node = data };
        return node;
    }

    /// (extend-type TypeName ProtoName (m1 [this] body) ... ProtoName2 (m2 [this] body) ...)
    fn analyzeExtendType(self: *Analyzer, items: []const Form) err.Error!*Node {
        if (items.len < 3) {
            return err.parseError(.invalid_arity, "extend-type requires type-name and at least one protocol extension", .{});
        }

        if (items[1] != .symbol) {
            return err.parseError(.invalid_binding, "extend-type type name must be a symbol", .{});
        }

        const type_name = items[1].symbol.name;

        // items[2..] をプロトコルごとにグループ化
        // パターン: ProtoName (method1 [params] body) (method2 [params] body) ProtoName2 ...
        var extensions: std.ArrayListUnmanaged(node_mod.ExtendTypeNode.ProtocolExtension) = .empty;
        var idx: usize = 2;

        while (idx < items.len) {
            // プロトコル名を取得
            if (items[idx] != .symbol) {
                return err.parseError(.invalid_binding, "extend-type expects a protocol name symbol", .{});
            }
            const protocol_name = items[idx].symbol.name;
            idx += 1;

            // このプロトコルに属するメソッド実装を収集
            var methods: std.ArrayListUnmanaged(node_mod.ExtendTypeNode.MethodImpl) = .empty;
            while (idx < items.len) {
                // 次のシンボルがリストでなければプロトコル名 → 終了
                if (items[idx] != .list) break;

                const method_items = items[idx].list;
                if (method_items.len < 2) {
                    return err.parseError(.invalid_arity, "extend-type method requires name and params", .{});
                }
                if (method_items[0] != .symbol) {
                    return err.parseError(.invalid_binding, "extend-type method name must be a symbol", .{});
                }

                const method_name = method_items[0].symbol.name;

                // (method-name [params] body...) → (fn [params] body...) を構築して解析
                var fn_items = self.allocator.alloc(Form, method_items.len) catch return error.OutOfMemory;
                fn_items[0] = .{ .symbol = FormSymbol.init("fn") };
                for (method_items[1..], 0..) |mi, i| {
                    fn_items[i + 1] = mi;
                }
                const fn_node = try self.analyzeFn(fn_items);

                methods.append(self.allocator, .{
                    .name = method_name,
                    .fn_node = fn_node,
                }) catch return error.OutOfMemory;

                idx += 1;
            }

            extensions.append(self.allocator, .{
                .protocol_name = protocol_name,
                .methods = methods.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            }) catch return error.OutOfMemory;
        }

        const data = self.allocator.create(node_mod.ExtendTypeNode) catch return error.OutOfMemory;
        data.* = .{
            .type_name = type_name,
            .extensions = extensions.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .stack = .{},
        };

        const node = self.allocator.create(Node) catch return error.OutOfMemory;
        node.* = .{ .extend_type_node = data };
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

    // ============================================================
    // condp / case / some-> / some->> / as-> / mapv / filterv
    // ============================================================

    /// (condp pred expr clause...) → (let [__p expr] (cond (pred val1 __p) result1 ...))
    /// 各 clause: test-val result, 最後に default（奇数なら）
    fn expandCondp(self: *Analyzer, items: []const Form) err.Error!Form {
        // (condp pred expr clause1 clause2 ... default?)
        if (items.len < 4) {
            return err.parseError(.invalid_arity, "condp requires pred, expr, and at least one clause", .{});
        }

        const pred = items[1];
        const expr = items[2];
        const clauses = items[3..];

        // (let [__condp__ expr] (cond ...))
        const binding_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        binding_forms[0] = Form{ .symbol = form_mod.Symbol.init("__condp__") };
        binding_forms[1] = expr;

        // cond ペアを構築
        const has_default = (clauses.len % 2 != 0);
        const pair_count = clauses.len / 2;
        const cond_len = 1 + pair_count * 2 + (if (has_default) @as(usize, 2) else 0);
        const cond_forms = self.allocator.alloc(Form, cond_len) catch return error.OutOfMemory;
        cond_forms[0] = Form{ .symbol = form_mod.Symbol.init("cond") };

        var idx: usize = 1;
        var ci: usize = 0;
        while (ci + 1 < clauses.len) : (ci += 2) {
            // (pred test-val __condp__)
            const test_call = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
            test_call[0] = pred;
            test_call[1] = clauses[ci];
            test_call[2] = Form{ .symbol = form_mod.Symbol.init("__condp__") };
            cond_forms[idx] = Form{ .list = test_call };
            cond_forms[idx + 1] = clauses[ci + 1];
            idx += 2;
        }
        if (has_default) {
            // :else default
            const else_kw = self.allocator.create(value_mod.Keyword) catch return error.OutOfMemory;
            else_kw.* = value_mod.Keyword.init("else");
            cond_forms[idx] = Form{ .keyword = form_mod.Symbol.init("else") };
            cond_forms[idx + 1] = clauses[clauses.len - 1];
        }

        // (let [__condp__ expr] (cond ...))
        const let_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        let_forms[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        let_forms[1] = Form{ .vector = binding_forms };
        let_forms[2] = Form{ .list = cond_forms };
        return Form{ .list = let_forms };
    }

    /// (case expr val1 result1 val2 result2 ... default?)
    /// → (let [__case__ expr] (cond (= __case__ val1) result1 ... :else default))
    fn expandCase(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 4) {
            return err.parseError(.invalid_arity, "case requires expr and at least one clause", .{});
        }

        const expr = items[1];
        const clauses = items[2..];

        // (let [__case__ expr] (cond ...))
        const binding_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        binding_forms[0] = Form{ .symbol = form_mod.Symbol.init("__case__") };
        binding_forms[1] = expr;

        // cond ペアを構築
        const has_default = (clauses.len % 2 != 0);
        const pair_count = clauses.len / 2;
        const cond_len = 1 + pair_count * 2 + (if (has_default) @as(usize, 2) else 0);
        const cond_forms = self.allocator.alloc(Form, cond_len) catch return error.OutOfMemory;
        cond_forms[0] = Form{ .symbol = form_mod.Symbol.init("cond") };

        var idx: usize = 1;
        var ci: usize = 0;
        while (ci + 1 < clauses.len) : (ci += 2) {
            // (= __case__ val)
            const eq_call = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
            eq_call[0] = Form{ .symbol = form_mod.Symbol.init("=") };
            eq_call[1] = Form{ .symbol = form_mod.Symbol.init("__case__") };
            eq_call[2] = clauses[ci];
            cond_forms[idx] = Form{ .list = eq_call };
            cond_forms[idx + 1] = clauses[ci + 1];
            idx += 2;
        }
        if (has_default) {
            cond_forms[idx] = Form{ .keyword = form_mod.Symbol.init("else") };
            cond_forms[idx + 1] = clauses[clauses.len - 1];
        }

        const let_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        let_forms[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        let_forms[1] = Form{ .vector = binding_forms };
        let_forms[2] = Form{ .list = cond_forms };
        return Form{ .list = let_forms };
    }

    /// (some-> expr form1 form2 ...) → (let [__st x] (if (nil? __st) nil (let [__st form1(__st)] (if (nil? __st) nil ...))))
    fn expandSomeThreadFirst(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "some-> requires an expression", .{});
        }
        return self.buildSomeThread(items[1], items[2..], true);
    }

    /// (some->> expr form1 form2 ...)
    fn expandSomeThreadLast(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "some->> requires an expression", .{});
        }
        return self.buildSomeThread(items[1], items[2..], false);
    }

    /// some-> / some->> の共通実装
    fn buildSomeThread(self: *Analyzer, initial: Form, forms: []const Form, thread_first: bool) err.Error!Form {
        if (forms.len == 0) return initial;

        // (let [__st initial] (if (nil? __st) nil (let [__st step1] (if ...))))
        const result = initial;
        // 逆順に内側から外側へ構築する代わりに、順に構築
        // 最内側から構築するため、まず最終式を作り、そこから巻き戻す
        // 実装: 再帰的に展開
        const step_form = forms[0];
        const threaded = try self.threadForm(Form{ .symbol = form_mod.Symbol.init("__st__") }, step_form, thread_first);

        // 残りのステップを再帰的に構築
        const rest_forms = forms[1..];
        const inner = if (rest_forms.len > 0)
            try self.buildSomeThread(threaded, rest_forms, thread_first)
        else
            threaded;

        // (let [__st__ result] (if (nil? __st__) nil inner))
        const nil_check = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        nil_check[0] = Form{ .symbol = form_mod.Symbol.init("nil?") };
        nil_check[1] = Form{ .symbol = form_mod.Symbol.init("__st__") };

        const if_forms = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
        if_forms[0] = Form{ .symbol = form_mod.Symbol.init("if") };
        if_forms[1] = Form{ .list = nil_check };
        if_forms[2] = Form.nil;
        if_forms[3] = inner;

        const binding = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        binding[0] = Form{ .symbol = form_mod.Symbol.init("__st__") };
        binding[1] = result;

        const let_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        let_forms[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        let_forms[1] = Form{ .vector = binding };
        let_forms[2] = Form{ .list = if_forms };
        return Form{ .list = let_forms };
    }

    /// スレッディング: 式をフォームに挿入
    fn threadForm(self: *Analyzer, val: Form, form: Form, thread_first: bool) error{OutOfMemory}!Form {
        if (form == .list) {
            // (f a b) → (f val a b) or (f a b val)
            const items = form.list;
            const new_items = self.allocator.alloc(Form, items.len + 1) catch return error.OutOfMemory;
            if (thread_first) {
                new_items[0] = items[0];
                new_items[1] = val;
                @memcpy(new_items[2..], items[1..]);
            } else {
                @memcpy(new_items[0..items.len], items);
                new_items[items.len] = val;
            }
            return Form{ .list = new_items };
        } else {
            // f → (f val)
            const new_items = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
            new_items[0] = form;
            new_items[1] = val;
            return Form{ .list = new_items };
        }
    }

    /// (as-> expr name form1 form2 ...) → (let [name expr name form1 name form2 ...] name)
    fn expandAsThread(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 3) {
            return err.parseError(.invalid_arity, "as-> requires expr, name, and at least one form", .{});
        }

        const expr = items[1];
        const name = items[2];
        const forms = items[3..];

        // [name expr name form1 name form2 ...]
        const bindings_len = 2 + forms.len * 2;
        const bindings = self.allocator.alloc(Form, bindings_len) catch return error.OutOfMemory;
        bindings[0] = name;
        bindings[1] = expr;
        for (forms, 0..) |f, i| {
            bindings[2 + i * 2] = name;
            bindings[2 + i * 2 + 1] = f;
        }

        // (let [...] name)
        const let_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        let_forms[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        let_forms[1] = Form{ .vector = bindings };
        let_forms[2] = name;
        return Form{ .list = let_forms };
    }

    /// (mapv f coll) → (vec (map f coll))
    fn expandMapv(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "mapv requires 2 arguments", .{});
        }
        // (vec (map f coll))
        const map_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        map_forms[0] = Form{ .symbol = form_mod.Symbol.init("map") };
        map_forms[1] = items[1];
        map_forms[2] = items[2];

        const vec_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        vec_forms[0] = Form{ .symbol = form_mod.Symbol.init("vec") };
        vec_forms[1] = Form{ .list = map_forms };
        return Form{ .list = vec_forms };
    }

    /// (filterv f coll) → (vec (filter f coll))
    fn expandFilterv(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "filterv requires 2 arguments", .{});
        }
        const filter_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        filter_forms[0] = Form{ .symbol = form_mod.Symbol.init("filter") };
        filter_forms[1] = items[1];
        filter_forms[2] = items[2];

        const vec_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        vec_forms[0] = Form{ .symbol = form_mod.Symbol.init("vec") };
        vec_forms[1] = Form{ .list = filter_forms };
        return Form{ .list = vec_forms };
    }

    /// (every? pred coll) →
    /// (let [__ep__ pred __es__ (seq coll)]
    ///   (loop [__s__ __es__]
    ///     (if (nil? __s__) true
    ///       (if (__ep__ (first __s__))
    ///         (recur (seq (rest __s__)))
    ///         false))))
    fn expandEvery(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "every? requires 2 arguments", .{});
        }
        const pred = items[1];
        const coll = items[2];

        // (seq coll)
        const seq_coll = try self.makeCall2("seq", coll);
        // (first __s__)
        const first_s = try self.makeCall2("first", Form{ .symbol = form_mod.Symbol.init("__s__") });
        // (__ep__ (first __s__))
        const pred_call = try self.makeList2(Form{ .symbol = form_mod.Symbol.init("__ep__") }, first_s);
        // (rest __s__)
        const rest_s = try self.makeCall2("rest", Form{ .symbol = form_mod.Symbol.init("__s__") });
        // (seq (rest __s__))
        const seq_rest = try self.makeCall2("seq", rest_s);
        // (recur (seq (rest __s__)))
        const recur_form = try self.makeCall2("recur", seq_rest);
        // (if (__ep__ (first __s__)) (recur ...) false)
        const inner_if = try self.makeIf(pred_call, recur_form, Form.bool_false);
        // (nil? __s__)
        const nil_check = try self.makeCall2("nil?", Form{ .symbol = form_mod.Symbol.init("__s__") });
        // (if (nil? __s__) true (if ...))
        const outer_if = try self.makeIf(nil_check, Form.bool_true, inner_if);
        // (loop [__s__ __es__] (if ...))
        const loop_form = try self.makeLoop1("__s__", Form{ .symbol = form_mod.Symbol.init("__es__") }, outer_if);
        // (let [__ep__ pred __es__ (seq coll)] (loop ...))
        return self.makeLet4("__ep__", pred, "__es__", seq_coll, loop_form);
    }

    /// (some pred coll) →
    /// (let [__sp__ pred __ss__ (seq coll)]
    ///   (loop [__s__ __ss__]
    ///     (if (nil? __s__) nil
    ///       (let [__v__ (__sp__ (first __s__))]
    ///         (if __v__ __v__
    ///           (recur (seq (rest __s__))))))))
    fn expandSome(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "some requires 2 arguments", .{});
        }
        const pred = items[1];
        const coll = items[2];

        const seq_coll = try self.makeCall2("seq", coll);
        const first_s = try self.makeCall2("first", Form{ .symbol = form_mod.Symbol.init("__s__") });
        const pred_call = try self.makeList2(Form{ .symbol = form_mod.Symbol.init("__sp__") }, first_s);
        const rest_s = try self.makeCall2("rest", Form{ .symbol = form_mod.Symbol.init("__s__") });
        const seq_rest = try self.makeCall2("seq", rest_s);
        const recur_form = try self.makeCall2("recur", seq_rest);
        // (if __v__ __v__ (recur ...))
        const v_sym = Form{ .symbol = form_mod.Symbol.init("__v__") };
        const inner_if = try self.makeIf(v_sym, v_sym, recur_form);
        // (let [__v__ (__sp__ (first __s__))] (if __v__ __v__ (recur ...)))
        const let_v = try self.makeLet2("__v__", pred_call, inner_if);
        // (nil? __s__)
        const nil_check = try self.makeCall2("nil?", Form{ .symbol = form_mod.Symbol.init("__s__") });
        // (if (nil? __s__) nil (let ...))
        const outer_if = try self.makeIf(nil_check, Form.nil, let_v);
        // (loop [__s__ __ss__] ...)
        const loop_form = try self.makeLoop1("__s__", Form{ .symbol = form_mod.Symbol.init("__ss__") }, outer_if);
        // (let [__sp__ pred __ss__ (seq coll)] (loop ...))
        return self.makeLet4("__sp__", pred, "__ss__", seq_coll, loop_form);
    }

    /// (not-every? pred coll) → (not (every? pred coll))
    fn expandNotEvery(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "not-every? requires 2 arguments", .{});
        }
        // 未展開の (every? pred coll) を構築（Analyzer が再帰的に展開する）
        const every_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        every_forms[0] = Form{ .symbol = form_mod.Symbol.init("every?") };
        every_forms[1] = items[1];
        every_forms[2] = items[2];
        return self.makeCall2("not", Form{ .list = every_forms });
    }

    /// (not-any? pred coll) → (nil? (some pred coll))
    fn expandNotAny(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "not-any? requires 2 arguments", .{});
        }
        // 未展開の (some pred coll) を構築（Analyzer が再帰的に展開する）
        const some_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        some_forms[0] = Form{ .symbol = form_mod.Symbol.init("some") };
        some_forms[1] = items[1];
        some_forms[2] = items[2];
        // some は truthy value を返す（nil or 値）ので nil? でチェック
        return self.makeCall2("nil?", Form{ .list = some_forms });
    }

    /// (extend-protocol Proto
    ///   Type1 (m [this] ...) (m2 [this] ...)
    ///   Type2 (m [this] ...))
    /// → (do (extend-type Type1 Proto (m [this] ...) (m2 [this] ...))
    ///       (extend-type Type2 Proto (m [this] ...)))
    fn expandExtendProtocol(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 3) {
            return err.parseError(.invalid_arity, "extend-protocol requires protocol name and at least one type extension", .{});
        }

        if (items[1] != .symbol) {
            return err.parseError(.invalid_binding, "extend-protocol first argument must be a protocol name", .{});
        }

        const proto_name = items[1];

        // items[2..] を型ごとにグループ化して extend-type に変換
        var extend_forms: std.ArrayListUnmanaged(Form) = .empty;
        var idx: usize = 2;

        while (idx < items.len) {
            if (items[idx] != .symbol) {
                return err.parseError(.invalid_binding, "extend-protocol expects a type name symbol", .{});
            }
            const type_sym = items[idx];
            idx += 1;

            // このタイプに属するメソッド実装を収集
            var type_methods: std.ArrayListUnmanaged(Form) = .empty;
            while (idx < items.len) {
                if (items[idx] != .list) break;
                type_methods.append(self.allocator, items[idx]) catch return error.OutOfMemory;
                idx += 1;
            }

            // (extend-type TypeName Proto (m1 ...) (m2 ...)) を構築
            const et_len = 3 + type_methods.items.len;
            const et_forms = self.allocator.alloc(Form, et_len) catch return error.OutOfMemory;
            et_forms[0] = Form{ .symbol = form_mod.Symbol.init("extend-type") };
            et_forms[1] = type_sym;
            et_forms[2] = proto_name;
            for (type_methods.items, 0..) |m, i| {
                et_forms[3 + i] = m;
            }

            extend_forms.append(self.allocator, Form{ .list = et_forms }) catch return error.OutOfMemory;
        }

        // (do (extend-type ...) (extend-type ...)) を構築
        const do_forms = self.allocator.alloc(Form, 1 + extend_forms.items.len) catch return error.OutOfMemory;
        do_forms[0] = Form{ .symbol = form_mod.Symbol.init("do") };
        for (extend_forms.items, 0..) |ef, i| {
            do_forms[1 + i] = ef;
        }

        return Form{ .list = do_forms };
    }

    // ── Phase 8.16 マクロ ──

    /// (update m k f args...) → (let [__um__ m __uk__ k] (assoc __um__ __uk__ (f (get __um__ __uk__) args...)))
    fn expandUpdate(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 4) {
            return err.parseError(.invalid_arity, "update requires at least 3 arguments (update m k f)", .{});
        }

        const m_form = items[1];
        const k_form = items[2];
        const f_form = items[3];

        // (get __um__ __uk__) を構築
        const get_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        get_forms[0] = Form{ .symbol = form_mod.Symbol.init("get") };
        get_forms[1] = Form{ .symbol = form_mod.Symbol.init("__um__") };
        get_forms[2] = Form{ .symbol = form_mod.Symbol.init("__uk__") };
        const get_call = Form{ .list = get_forms };

        // (f (get __um__ __uk__) args...) を構築
        const extra_args = items[4..];
        const f_call_forms = self.allocator.alloc(Form, 2 + extra_args.len) catch return error.OutOfMemory;
        f_call_forms[0] = f_form;
        f_call_forms[1] = get_call;
        for (extra_args, 0..) |arg, i| {
            f_call_forms[2 + i] = arg;
        }
        const f_call = Form{ .list = f_call_forms };

        // (assoc __um__ __uk__ (f ...)) を構築
        const assoc_forms = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
        assoc_forms[0] = Form{ .symbol = form_mod.Symbol.init("assoc") };
        assoc_forms[1] = Form{ .symbol = form_mod.Symbol.init("__um__") };
        assoc_forms[2] = Form{ .symbol = form_mod.Symbol.init("__uk__") };
        assoc_forms[3] = f_call;
        const assoc_call = Form{ .list = assoc_forms };

        // (let [__um__ m __uk__ k] (assoc ...))
        return self.makeLet4("__um__", m_form, "__uk__", k_form, assoc_call);
    }

    /// (complement f) → ((fn [__cf__] (fn [& __ca__] (not (apply __cf__ __ca__)))) f)
    /// fn-within-fn パターンで展開（VM の let-closure バグを回避）
    fn expandComplement(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len != 2) {
            return err.parseError(.invalid_arity, "complement requires 1 argument", .{});
        }

        const f_form = items[1];

        // (apply __cf__ __ca__)
        const apply_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        apply_forms[0] = Form{ .symbol = form_mod.Symbol.init("apply") };
        apply_forms[1] = Form{ .symbol = form_mod.Symbol.init("__cf__") };
        apply_forms[2] = Form{ .symbol = form_mod.Symbol.init("__ca__") };
        const apply_call = Form{ .list = apply_forms };

        // (not (apply ...))
        const not_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        not_forms[0] = Form{ .symbol = form_mod.Symbol.init("not") };
        not_forms[1] = apply_call;
        const not_call = Form{ .list = not_forms };

        // 内側: (fn [& __ca__] (not ...))
        const inner_params = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        inner_params[0] = Form{ .symbol = form_mod.Symbol.init("&") };
        inner_params[1] = Form{ .symbol = form_mod.Symbol.init("__ca__") };

        const inner_fn = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        inner_fn[0] = Form{ .symbol = form_mod.Symbol.init("fn") };
        inner_fn[1] = Form{ .vector = inner_params };
        inner_fn[2] = not_call;

        // 外側: (fn [__cf__] (fn ...))
        const outer_params = self.allocator.alloc(Form, 1) catch return error.OutOfMemory;
        outer_params[0] = Form{ .symbol = form_mod.Symbol.init("__cf__") };

        const outer_fn = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        outer_fn[0] = Form{ .symbol = form_mod.Symbol.init("fn") };
        outer_fn[1] = Form{ .vector = outer_params };
        outer_fn[2] = Form{ .list = inner_fn };

        // ((fn [__cf__] ...) f)
        const call_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        call_forms[0] = Form{ .list = outer_fn };
        call_forms[1] = f_form;
        return Form{ .list = call_forms };
    }

    /// (constantly v) → ((fn [__cv__] (fn [& _] __cv__)) v)
    /// fn-within-fn パターンで展開（VM の let-closure バグを回避）
    fn expandConstantly(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len != 2) {
            return err.parseError(.invalid_arity, "constantly requires 1 argument", .{});
        }

        const v_form = items[1];

        // 内側: (fn [& _] __cv__)
        const inner_params = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        inner_params[0] = Form{ .symbol = form_mod.Symbol.init("&") };
        inner_params[1] = Form{ .symbol = form_mod.Symbol.init("_") };

        const inner_fn = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        inner_fn[0] = Form{ .symbol = form_mod.Symbol.init("fn") };
        inner_fn[1] = Form{ .vector = inner_params };
        inner_fn[2] = Form{ .symbol = form_mod.Symbol.init("__cv__") };

        // 外側: (fn [__cv__] (fn ...))
        const outer_params = self.allocator.alloc(Form, 1) catch return error.OutOfMemory;
        outer_params[0] = Form{ .symbol = form_mod.Symbol.init("__cv__") };

        const outer_fn = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        outer_fn[0] = Form{ .symbol = form_mod.Symbol.init("fn") };
        outer_fn[1] = Form{ .vector = outer_params };
        outer_fn[2] = Form{ .list = inner_fn };

        // ((fn [__cv__] ...) v)
        const call_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        call_forms[0] = Form{ .list = outer_fn };
        call_forms[1] = v_form;
        return Form{ .list = call_forms };
    }

    // ── Phase 8.19 マクロ ──

    /// (defonce name expr) → (do (when (not (resolve 'name)) (def name expr)) (var-get name))
    /// 簡易版: (def name expr) と同じ（二重定義を許容）
    fn expandDefonce(self: *Analyzer, items: []const Form) err.Error!Form {
        // (defonce name expr) → (def name expr)
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "defonce requires a name and an expression", .{});
        }
        const def_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        def_forms[0] = Form{ .symbol = form_mod.Symbol.init("def") };
        def_forms[1] = items[1]; // name
        def_forms[2] = items[2]; // expr
        return Form{ .list = def_forms };
    }

    /// (defn- name ...) → (defn name ...)（private は未サポートなので defn と同等）
    fn expandDefnPrivate(self: *Analyzer, items: []const Form) err.Error!Form {
        // defn- → defn
        if (items.len < 3) {
            return err.parseError(.invalid_arity, "defn- requires at least a name and body", .{});
        }
        const new_items = self.allocator.alloc(Form, items.len) catch return error.OutOfMemory;
        new_items[0] = Form{ .symbol = form_mod.Symbol.init("defn") };
        @memcpy(new_items[1..], items[1..]);
        return Form{ .list = new_items };
    }

    /// (declare name1 name2 ...) → (do (def name1) (def name2) ...)
    fn expandDeclare(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "declare requires at least one name", .{});
        }
        const names = items[1..];
        const do_forms = self.allocator.alloc(Form, names.len + 1) catch return error.OutOfMemory;
        do_forms[0] = Form{ .symbol = form_mod.Symbol.init("do") };
        for (names, 0..) |name, i| {
            const def_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
            def_forms[0] = Form{ .symbol = form_mod.Symbol.init("def") };
            def_forms[1] = name;
            do_forms[i + 1] = Form{ .list = def_forms };
        }
        return Form{ .list = do_forms };
    }

    /// (while test body...) → (loop [] (when test body... (recur)))
    fn expandWhile(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "while requires a test expression", .{});
        }
        const test_form = items[1];
        const body = items[2..];

        // (recur)
        const recur_forms = self.allocator.alloc(Form, 1) catch return error.OutOfMemory;
        recur_forms[0] = Form{ .symbol = form_mod.Symbol.init("recur") };
        const recur_form = Form{ .list = recur_forms };

        // (when test body... (recur))
        const when_forms = self.allocator.alloc(Form, 2 + body.len + 1) catch return error.OutOfMemory;
        when_forms[0] = Form{ .symbol = form_mod.Symbol.init("when") };
        when_forms[1] = test_form;
        @memcpy(when_forms[2 .. 2 + body.len], body);
        when_forms[2 + body.len] = recur_form;

        // (loop [] (when ...))
        const empty_vec = self.allocator.alloc(Form, 0) catch return error.OutOfMemory;
        const loop_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        loop_forms[0] = Form{ .symbol = form_mod.Symbol.init("loop") };
        loop_forms[1] = Form{ .vector = empty_vec };
        loop_forms[2] = Form{ .list = when_forms };
        return Form{ .list = loop_forms };
    }

    /// (doto x (method1 args...) (method2 args...) ...)
    /// → (let [__doto__ x] (method1 __doto__ args...) (method2 __doto__ args...) ... __doto__)
    fn expandDoto(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "doto requires at least an expression", .{});
        }
        const x = items[1];
        const calls = items[2..];
        const temp = form_mod.Symbol.init("__doto__");

        // ボディ: 各メソッド呼び出しに __doto__ を最初の引数として挿入
        // + 最後に __doto__ を返す
        const body_len = calls.len + 1; // calls + final __doto__

        // (let [__doto__ x] calls... __doto__)
        const bind_vec = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        bind_vec[0] = Form{ .symbol = temp };
        bind_vec[1] = x;

        const let_forms = self.allocator.alloc(Form, 2 + body_len) catch return error.OutOfMemory;
        let_forms[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        let_forms[1] = Form{ .vector = bind_vec };

        for (calls, 0..) |call, i| {
            if (call == .list) {
                const old_items = call.list;
                const new_call = self.allocator.alloc(Form, old_items.len + 1) catch return error.OutOfMemory;
                new_call[0] = old_items[0]; // method name
                new_call[1] = Form{ .symbol = temp }; // __doto__ as first arg
                if (old_items.len > 1) {
                    @memcpy(new_call[2..], old_items[1..]);
                }
                let_forms[2 + i] = Form{ .list = new_call };
            } else {
                // 非リスト: (call __doto__) の形に
                const new_call = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
                new_call[0] = call;
                new_call[1] = Form{ .symbol = temp };
                let_forms[2 + i] = Form{ .list = new_call };
            }
        }
        let_forms[2 + calls.len] = Form{ .symbol = temp }; // 最後に __doto__ を返す

        return Form{ .list = let_forms };
    }

    /// (cond-> expr test1 form1 test2 form2 ...)
    /// → (let [__ct__ expr] (let [__ct__ (if test1 (-> __ct__ form1) __ct__)] (let [...] ...)))
    /// last=false → cond->, last=true → cond->>
    fn expandCondThread(self: *Analyzer, items: []const Form, last: bool) err.Error!Form {
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "cond->/cond->> requires an expression", .{});
        }
        const expr = items[1];
        const pairs = items[2..];
        if (pairs.len % 2 != 0) {
            return err.parseError(.invalid_arity, "cond->/cond->> requires an even number of test/form pairs", .{});
        }

        const temp = form_mod.Symbol.init("__ct__");
        const thread_name = if (last) "->>" else "->";

        // ネストされた let チェーンを内側から構築
        var current = Form{ .symbol = temp };
        var i: usize = pairs.len;
        while (i >= 2) {
            i -= 2;
            const test_form = pairs[i];
            const thread_form = pairs[i + 1];

            const threaded = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
            threaded[0] = Form{ .symbol = form_mod.Symbol.init(thread_name) };
            threaded[1] = Form{ .symbol = temp };
            threaded[2] = thread_form;

            const if_forms = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
            if_forms[0] = Form{ .symbol = form_mod.Symbol.init("if") };
            if_forms[1] = test_form;
            if_forms[2] = Form{ .list = threaded };
            if_forms[3] = Form{ .symbol = temp };

            const bind = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
            bind[0] = Form{ .symbol = temp };
            bind[1] = Form{ .list = if_forms };

            const let_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
            let_forms[0] = Form{ .symbol = form_mod.Symbol.init("let") };
            let_forms[1] = Form{ .vector = bind };
            let_forms[2] = current;
            current = Form{ .list = let_forms };
        }

        // 最外側: (let [__ct__ expr] inner)
        const outer_bind = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        outer_bind[0] = Form{ .symbol = temp };
        outer_bind[1] = expr;

        const outer_let = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        outer_let[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        outer_let[1] = Form{ .vector = outer_bind };
        outer_let[2] = current;
        return Form{ .list = outer_let };
    }

    /// (if-some [x expr] then else?)
    /// → (let [__is__ expr] (if (not (nil? __is__)) (let [x __is__] then) else?))
    fn expandIfSome(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 3 or items.len > 4) {
            return err.parseError(.invalid_arity, "if-some requires a binding and then branch", .{});
        }
        if (items[1] != .vector or items[1].vector.len != 2) {
            return err.parseError(.invalid_arity, "if-some binding must be [sym expr]", .{});
        }
        const binding = items[1].vector;
        const sym = binding[0];
        const expr = binding[1];
        const then_form = items[2];
        const else_form = if (items.len == 4) items[3] else Form.nil;

        const temp = form_mod.Symbol.init("__is__");

        // (nil? __is__)
        const nil_check = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        nil_check[0] = Form{ .symbol = form_mod.Symbol.init("nil?") };
        nil_check[1] = Form{ .symbol = temp };

        // (not (nil? __is__))
        const not_nil = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        not_nil[0] = Form{ .symbol = form_mod.Symbol.init("not") };
        not_nil[1] = Form{ .list = nil_check };

        // (let [x __is__] then)
        const inner_bind = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        inner_bind[0] = sym;
        inner_bind[1] = Form{ .symbol = temp };
        const inner_let = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        inner_let[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        inner_let[1] = Form{ .vector = inner_bind };
        inner_let[2] = then_form;

        // (if (not (nil? __is__)) (let [x __is__] then) else)
        const if_forms = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
        if_forms[0] = Form{ .symbol = form_mod.Symbol.init("if") };
        if_forms[1] = Form{ .list = not_nil };
        if_forms[2] = Form{ .list = inner_let };
        if_forms[3] = else_form;

        // (let [__is__ expr] (if ...))
        const outer_bind = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        outer_bind[0] = Form{ .symbol = temp };
        outer_bind[1] = expr;
        const outer_let = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        outer_let[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        outer_let[1] = Form{ .vector = outer_bind };
        outer_let[2] = Form{ .list = if_forms };
        return Form{ .list = outer_let };
    }

    /// (when-some [x expr] body...) → (if-some [x expr] (do body...))
    fn expandWhenSome(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 3) {
            return err.parseError(.invalid_arity, "when-some requires a binding and body", .{});
        }
        const body = items[2..];
        const body_form = try self.wrapInDo(body);

        const if_some = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        if_some[0] = Form{ .symbol = form_mod.Symbol.init("if-some") };
        if_some[1] = items[1]; // binding vector
        if_some[2] = body_form;
        return Form{ .list = if_some };
    }

    /// (when-first [x coll] body...)
    /// → (when-let [__wf__ (seq coll)] (let [x (first __wf__)] body...))
    fn expandWhenFirst(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 3) {
            return err.parseError(.invalid_arity, "when-first requires a binding and body", .{});
        }
        if (items[1] != .vector or items[1].vector.len != 2) {
            return err.parseError(.invalid_arity, "when-first binding must be [sym coll]", .{});
        }
        const binding = items[1].vector;
        const sym = binding[0];
        const coll = binding[1];
        const body = items[2..];

        const temp = form_mod.Symbol.init("__wf__");

        // (seq coll)
        const seq_call = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        seq_call[0] = Form{ .symbol = form_mod.Symbol.init("seq") };
        seq_call[1] = coll;

        // (first __wf__)
        const first_call = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        first_call[0] = Form{ .symbol = form_mod.Symbol.init("first") };
        first_call[1] = Form{ .symbol = temp };

        // (let [x (first __wf__)] body...)
        const inner_bind = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        inner_bind[0] = sym;
        inner_bind[1] = Form{ .list = first_call };

        const inner_let_forms = self.allocator.alloc(Form, 2 + body.len) catch return error.OutOfMemory;
        inner_let_forms[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        inner_let_forms[1] = Form{ .vector = inner_bind };
        @memcpy(inner_let_forms[2..], body);

        // [__wf__ (seq coll)]
        const outer_bind = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        outer_bind[0] = Form{ .symbol = temp };
        outer_bind[1] = Form{ .list = seq_call };

        // (when-let [__wf__ (seq coll)] (let [x (first __wf__)] body...))
        const when_let = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        when_let[0] = Form{ .symbol = form_mod.Symbol.init("when-let") };
        when_let[1] = Form{ .vector = outer_bind };
        when_let[2] = Form{ .list = inner_let_forms };
        return Form{ .list = when_let };
    }

    /// (for [x coll] body) → (map (fn [x] body) coll)
    /// 簡易版: 単一バインディング、:when/:let/:while 未対応
    fn expandFor(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 3) {
            return err.parseError(.invalid_arity, "for requires a binding vector and body", .{});
        }
        if (items[1] != .vector or items[1].vector.len < 2) {
            return err.parseError(.invalid_arity, "for binding must be [sym coll ...]", .{});
        }
        const bindings = items[1].vector;
        const body = items[2..];
        const body_form = if (body.len == 1) body[0] else try self.wrapInDo(body);

        // 単一バインディング: (for [x coll] body) → (map (fn [x] body) coll)
        if (bindings.len == 2) {
            const sym = bindings[0];
            const coll = bindings[1];

            // (fn [x] body)
            const fn_params = self.allocator.alloc(Form, 1) catch return error.OutOfMemory;
            fn_params[0] = sym;
            const fn_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
            fn_forms[0] = Form{ .symbol = form_mod.Symbol.init("fn") };
            fn_forms[1] = Form{ .vector = fn_params };
            fn_forms[2] = body_form;

            // (map (fn [x] body) coll)
            const map_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
            map_forms[0] = Form{ .symbol = form_mod.Symbol.init("map") };
            map_forms[1] = Form{ .list = fn_forms };
            map_forms[2] = coll;
            return Form{ .list = map_forms };
        }

        // ネストされたバインディング: (for [x coll1 y coll2] body)
        // → (mapcat (fn [x] (for [y coll2] body)) coll1)
        if (bindings.len >= 4 and bindings.len % 2 == 0) {
            const sym = bindings[0];
            const coll = bindings[1];
            const rest_bindings = bindings[2..];

            // 内側の for: (for [y coll2 ...] body)
            const inner_bind_vec = self.allocator.alloc(Form, rest_bindings.len) catch return error.OutOfMemory;
            @memcpy(inner_bind_vec, rest_bindings);
            var inner_for = self.allocator.alloc(Form, 2 + body.len) catch return error.OutOfMemory;
            inner_for[0] = Form{ .symbol = form_mod.Symbol.init("for") };
            inner_for[1] = Form{ .vector = inner_bind_vec };
            @memcpy(inner_for[2..], body);

            // (fn [x] (for [...] body))
            const fn_params = self.allocator.alloc(Form, 1) catch return error.OutOfMemory;
            fn_params[0] = sym;
            const fn_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
            fn_forms[0] = Form{ .symbol = form_mod.Symbol.init("fn") };
            fn_forms[1] = Form{ .vector = fn_params };
            fn_forms[2] = Form{ .list = inner_for };

            // (mapcat (fn [x] ...) coll)
            const mapcat_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
            mapcat_forms[0] = Form{ .symbol = form_mod.Symbol.init("mapcat") };
            mapcat_forms[1] = Form{ .list = fn_forms };
            mapcat_forms[2] = coll;
            return Form{ .list = mapcat_forms };
        }

        return err.parseError(.invalid_arity, "for requires even number of bindings", .{});
    }

    /// (some-fn f g h) → (fn [& __args__] (or (apply f __args__) (apply g __args__) (apply h __args__)))
    fn expandSomeFn(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "some-fn requires at least one function", .{});
        }
        const fns = items[1..];
        const args_sym = form_mod.Symbol.init("__sfargs__");

        // 各 (apply f __args__) を構築
        const or_forms = self.allocator.alloc(Form, fns.len + 1) catch return error.OutOfMemory;
        or_forms[0] = Form{ .symbol = form_mod.Symbol.init("or") };
        for (fns, 0..) |f, i| {
            const apply_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
            apply_forms[0] = Form{ .symbol = form_mod.Symbol.init("apply") };
            apply_forms[1] = f;
            apply_forms[2] = Form{ .symbol = args_sym };
            or_forms[i + 1] = Form{ .list = apply_forms };
        }

        // (fn [& __args__] (or ...))
        const fn_params = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        fn_params[0] = Form{ .symbol = form_mod.Symbol.init("&") };
        fn_params[1] = Form{ .symbol = args_sym };
        const fn_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        fn_forms[0] = Form{ .symbol = form_mod.Symbol.init("fn") };
        fn_forms[1] = Form{ .vector = fn_params };
        fn_forms[2] = Form{ .list = or_forms };
        return Form{ .list = fn_forms };
    }

    /// (every-pred f g h) → (fn [& __args__] (and (apply f __args__) (apply g __args__) ...))
    fn expandEveryPred(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 2) {
            return err.parseError(.invalid_arity, "every-pred requires at least one function", .{});
        }
        const fns = items[1..];
        const args_sym = form_mod.Symbol.init("__epargs__");

        // 各 (apply f __args__) を構築
        const and_forms = self.allocator.alloc(Form, fns.len + 1) catch return error.OutOfMemory;
        and_forms[0] = Form{ .symbol = form_mod.Symbol.init("and") };
        for (fns, 0..) |f, i| {
            const apply_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
            apply_forms[0] = Form{ .symbol = form_mod.Symbol.init("apply") };
            apply_forms[1] = f;
            apply_forms[2] = Form{ .symbol = args_sym };
            and_forms[i + 1] = Form{ .list = apply_forms };
        }

        // (fn [& __args__] (and ...))
        const fn_params = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        fn_params[0] = Form{ .symbol = form_mod.Symbol.init("&") };
        fn_params[1] = Form{ .symbol = args_sym };
        const fn_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        fn_forms[0] = Form{ .symbol = form_mod.Symbol.init("fn") };
        fn_forms[1] = Form{ .vector = fn_params };
        fn_forms[2] = Form{ .list = and_forms };
        return Form{ .list = fn_forms };
    }

    /// (fnil f default1 default2 ...)
    /// → (fn [& __fargs__] (apply f (map-indexed (fn [i v] (if (nil? v) (nth defaults i) v)) __fargs__)))
    /// 簡易版: 1〜3引数のみ対応
    fn expandFnil(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 3 or items.len > 5) {
            return err.parseError(.invalid_arity, "fnil requires a function and 1-3 defaults", .{});
        }
        const f = items[1];
        const defaults = items[2..];
        const n = defaults.len;

        // 引数名を生成
        const param_names = [_][]const u8{ "__fn1__", "__fn2__", "__fn3__" };

        // パラメータリスト
        const fn_params = self.allocator.alloc(Form, n) catch return error.OutOfMemory;
        for (0..n) |i| {
            fn_params[i] = Form{ .symbol = form_mod.Symbol.init(param_names[i]) };
        }

        // 呼び出し引数: (if (nil? __fn1__) default1 __fn1__) ...
        const call_forms = self.allocator.alloc(Form, n + 1) catch return error.OutOfMemory;
        call_forms[0] = f;
        for (0..n) |i| {
            // (nil? __fni__)
            const nil_check = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
            nil_check[0] = Form{ .symbol = form_mod.Symbol.init("nil?") };
            nil_check[1] = Form{ .symbol = form_mod.Symbol.init(param_names[i]) };

            // (if (nil? __fni__) default_i __fni__)
            const if_forms = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
            if_forms[0] = Form{ .symbol = form_mod.Symbol.init("if") };
            if_forms[1] = Form{ .list = nil_check };
            if_forms[2] = defaults[i];
            if_forms[3] = Form{ .symbol = form_mod.Symbol.init(param_names[i]) };
            call_forms[i + 1] = Form{ .list = if_forms };
        }

        // (fn [args...] (f args...))
        const fn_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        fn_forms[0] = Form{ .symbol = form_mod.Symbol.init("fn") };
        fn_forms[1] = Form{ .vector = fn_params };
        fn_forms[2] = Form{ .list = call_forms };
        return Form{ .list = fn_forms };
    }

    /// (keep f coll) → (filter some? (map f coll))
    fn expandKeep(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "keep requires a function and a collection", .{});
        }
        // (map f coll)
        const map_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        map_forms[0] = Form{ .symbol = form_mod.Symbol.init("map") };
        map_forms[1] = items[1];
        map_forms[2] = items[2];

        // (filter some? (map f coll))
        const filter_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        filter_forms[0] = Form{ .symbol = form_mod.Symbol.init("filter") };
        filter_forms[1] = Form{ .symbol = form_mod.Symbol.init("some?") };
        filter_forms[2] = Form{ .list = map_forms };
        return Form{ .list = filter_forms };
    }

    /// (keep-indexed f coll) → (filter some? (map-indexed f coll))
    fn expandKeepIndexed(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "keep-indexed requires a function and a collection", .{});
        }
        // (map-indexed f coll)
        const map_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        map_forms[0] = Form{ .symbol = form_mod.Symbol.init("map-indexed") };
        map_forms[1] = items[1];
        map_forms[2] = items[2];

        // (filter some? (map-indexed f coll))
        const filter_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        filter_forms[0] = Form{ .symbol = form_mod.Symbol.init("filter") };
        filter_forms[1] = Form{ .symbol = form_mod.Symbol.init("some?") };
        filter_forms[2] = Form{ .list = map_forms };
        return Form{ .list = filter_forms };
    }

    /// (mapcat f coll) → (apply concat (map f coll))
    fn expandMapcat(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "mapcat requires a function and a collection", .{});
        }
        // (map f coll)
        const map_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        map_forms[0] = Form{ .symbol = form_mod.Symbol.init("map") };
        map_forms[1] = items[1];
        map_forms[2] = items[2];

        // (apply concat (map f coll))
        const apply_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        apply_forms[0] = Form{ .symbol = form_mod.Symbol.init("apply") };
        apply_forms[1] = Form{ .symbol = form_mod.Symbol.init("concat") };
        apply_forms[2] = Form{ .list = map_forms };
        return Form{ .list = apply_forms };
    }

    /// (run! f coll) → (doseq [__run_x__ coll] (f __run_x__)) nil
    fn expandRunBang(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len != 3) {
            return err.parseError(.invalid_arity, "run! requires a function and a collection", .{});
        }
        const f = items[1];
        const coll = items[2];
        const temp = form_mod.Symbol.init("__run_x__");

        // (f __run_x__)
        const call_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        call_forms[0] = f;
        call_forms[1] = Form{ .symbol = temp };

        // [__run_x__ coll]
        const bind_vec = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        bind_vec[0] = Form{ .symbol = temp };
        bind_vec[1] = coll;

        // (doseq [__run_x__ coll] (f __run_x__))
        const doseq_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        doseq_forms[0] = Form{ .symbol = form_mod.Symbol.init("doseq") };
        doseq_forms[1] = Form{ .vector = bind_vec };
        doseq_forms[2] = Form{ .list = call_forms };
        return Form{ .list = doseq_forms };
    }

    /// (doall coll) → (do (doseq [_ coll]) coll)
    /// 簡易版: 全要素を強制評価（Eager なので実質 identity）
    fn expandDoall(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len != 2) {
            return err.parseError(.invalid_arity, "doall requires a collection", .{});
        }
        // Eager 実装なので、コレクション自体を返すだけでよい
        // (let [__da__ coll] (doseq [__dax__ __da__]) __da__)
        const temp = form_mod.Symbol.init("__da__");
        const temp2 = form_mod.Symbol.init("__dax__");

        const bind = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        bind[0] = Form{ .symbol = temp };
        bind[1] = items[1];

        const doseq_bind = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        doseq_bind[0] = Form{ .symbol = temp2 };
        doseq_bind[1] = Form{ .symbol = temp };

        const doseq_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        doseq_forms[0] = Form{ .symbol = form_mod.Symbol.init("doseq") };
        doseq_forms[1] = Form{ .vector = doseq_bind };
        doseq_forms[2] = Form{ .symbol = temp2 }; // force eval

        const let_forms = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
        let_forms[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        let_forms[1] = Form{ .vector = bind };
        let_forms[2] = Form{ .list = doseq_forms };
        let_forms[3] = Form{ .symbol = temp };
        return Form{ .list = let_forms };
    }

    /// (dorun coll) → (doseq [_ coll] nil)
    fn expandDorun(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len != 2) {
            return err.parseError(.invalid_arity, "dorun requires a collection", .{});
        }
        const temp = form_mod.Symbol.init("__dr__");

        const bind = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        bind[0] = Form{ .symbol = temp };
        bind[1] = items[1];

        const doseq_forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        doseq_forms[0] = Form{ .symbol = form_mod.Symbol.init("doseq") };
        doseq_forms[1] = Form{ .vector = bind };
        doseq_forms[2] = Form.nil;
        return Form{ .list = doseq_forms };
    }

    /// (assert expr) → (when-not expr (throw "Assert failed"))
    /// (assert expr msg) → (when-not expr (throw msg))
    fn expandAssert(self: *Analyzer, items: []const Form) err.Error!Form {
        if (items.len < 2 or items.len > 3) {
            return err.parseError(.invalid_arity, "assert requires 1-2 arguments", .{});
        }
        const expr = items[1];
        const msg = if (items.len == 3) items[2] else Form{ .string = "Assert failed" };

        // (throw msg)
        const throw_forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        throw_forms[0] = Form{ .symbol = form_mod.Symbol.init("throw") };
        throw_forms[1] = msg;

        // (when-not expr (throw msg))
        const when_not = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        when_not[0] = Form{ .symbol = form_mod.Symbol.init("when-not") };
        when_not[1] = expr;
        when_not[2] = Form{ .list = throw_forms };
        return Form{ .list = when_not };
    }

    // ── ヘルパー関数 ──

    /// (fn-name arg) の形のリストを作成
    fn makeCall2(self: *Analyzer, fn_name: []const u8, arg: Form) err.Error!Form {
        const forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        forms[0] = Form{ .symbol = form_mod.Symbol.init(fn_name) };
        forms[1] = arg;
        return Form{ .list = forms };
    }

    /// (fn_form arg) の形のリストを作成（fn_form は任意の Form）
    fn makeList2(self: *Analyzer, fn_form: Form, arg: Form) err.Error!Form {
        const forms = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        forms[0] = fn_form;
        forms[1] = arg;
        return Form{ .list = forms };
    }

    /// (if cond_form then else_) を作成
    fn makeIf(self: *Analyzer, cond_form: Form, then: Form, else_: Form) err.Error!Form {
        const forms = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
        forms[0] = Form{ .symbol = form_mod.Symbol.init("if") };
        forms[1] = cond_form;
        forms[2] = then;
        forms[3] = else_;
        return Form{ .list = forms };
    }

    /// (loop [name init_val] body) を作成
    fn makeLoop1(self: *Analyzer, name: []const u8, init_val: Form, body: Form) err.Error!Form {
        const bindings = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        bindings[0] = Form{ .symbol = form_mod.Symbol.init(name) };
        bindings[1] = init_val;

        const forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        forms[0] = Form{ .symbol = form_mod.Symbol.init("loop") };
        forms[1] = Form{ .vector = bindings };
        forms[2] = body;
        return Form{ .list = forms };
    }

    /// (let [name1 val1] body) を作成
    fn makeLet2(self: *Analyzer, name: []const u8, val: Form, body: Form) err.Error!Form {
        const bindings = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
        bindings[0] = Form{ .symbol = form_mod.Symbol.init(name) };
        bindings[1] = val;

        const forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        forms[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        forms[1] = Form{ .vector = bindings };
        forms[2] = body;
        return Form{ .list = forms };
    }

    /// (let [name1 val1 name2 val2] body) を作成
    fn makeLet4(self: *Analyzer, name1: []const u8, val1: Form, name2: []const u8, val2: Form, body: Form) err.Error!Form {
        const bindings = self.allocator.alloc(Form, 4) catch return error.OutOfMemory;
        bindings[0] = Form{ .symbol = form_mod.Symbol.init(name1) };
        bindings[1] = val1;
        bindings[2] = Form{ .symbol = form_mod.Symbol.init(name2) };
        bindings[3] = val2;

        const forms = self.allocator.alloc(Form, 3) catch return error.OutOfMemory;
        forms[0] = Form{ .symbol = form_mod.Symbol.init("let") };
        forms[1] = Form{ .vector = bindings };
        forms[2] = body;
        return Form{ .list = forms };
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
            .char_val, .map, .set, .fn_val, .partial_fn, .comp_fn, .multi_fn, .fn_proto, .var_val, .atom, .protocol, .protocol_fn => return err.parseError(.invalid_token, "Cannot convert to form", .{}),
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
