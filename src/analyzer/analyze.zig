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
            } else if (std.mem.eql(u8, sym_name, "throw")) {
                return self.analyzeThrow(items);
            } else if (std.mem.eql(u8, sym_name, "try")) {
                return self.analyzeTry(items);
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

    fn analyzeMap(self: *Analyzer, items: []const Form) err.Error!*Node {
        // マップリテラル {k1 v1 k2 v2 ...}
        // items は偶数個であることが Reader で保証されている
        var analyzed = self.allocator.alloc(Value, items.len) catch return error.OutOfMemory;
        for (items, 0..) |item, i| {
            const node = try self.analyze(item);
            // 定数のみサポート（現時点）
            switch (node.*) {
                .constant => |val| analyzed[i] = val,
                else => return err.parseError(.invalid_token, "Map literal must contain constants", .{}),
            }
        }

        const m = self.allocator.create(value_mod.PersistentMap) catch return error.OutOfMemory;
        m.* = .{ .entries = analyzed };
        return self.makeConstant(.{ .map = m });
    }

    fn analyzeSet(self: *Analyzer, items: []const Form) err.Error!*Node {
        // セットリテラル #{...}
        var analyzed = self.allocator.alloc(Value, items.len) catch return error.OutOfMemory;
        for (items, 0..) |item, i| {
            const node = try self.analyze(item);
            // 定数のみサポート（現時点）
            switch (node.*) {
                .constant => |val| analyzed[i] = val,
                else => return err.parseError(.invalid_token, "Set literal must contain constants", .{}),
            }
        }

        const s = self.allocator.create(value_mod.PersistentSet) catch return error.OutOfMemory;
        s.* = .{ .items = analyzed };
        return self.makeConstant(.{ .set = s });
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
