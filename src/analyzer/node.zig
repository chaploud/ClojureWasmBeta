//! Analyzer出力: 実行可能ノード (Node)
//!
//! Form を解析して生成される実行可能な中間表現。
//! 各 Node は run() メソッドで Value を返す。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md

const std = @import("std");
const err = @import("../base/error.zig");
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const Symbol = value_mod.Symbol;
const var_mod = @import("../runtime/var.zig");
const Var = var_mod.Var;

/// ソース位置情報（エラー追跡用）
pub const SourceInfo = struct {
    line: u32 = 0,
    column: u32 = 0,
    file: ?[]const u8 = null,
};

// === ノード構造体 ===

/// Var 参照ノード
pub const VarRefNode = struct {
    var_ref: *Var,
    stack: SourceInfo,
};

/// ローカル変数参照ノード
pub const LocalRefNode = struct {
    name: []const u8, // シンボル名
    idx: u32, // bindings 配列のインデックス
    stack: SourceInfo,
};

/// if ノード
pub const IfNode = struct {
    test_node: *Node,
    then_node: *Node,
    else_node: ?*Node,
    stack: SourceInfo,
};

/// do ノード
pub const DoNode = struct {
    statements: []const *Node,
    stack: SourceInfo,
};

/// let バインディング
pub const LetBinding = struct {
    name: []const u8,
    init: *Node,
};

/// let ノード
pub const LetNode = struct {
    bindings: []const LetBinding,
    body: *Node,
    stack: SourceInfo,
};

/// 関数のアリティ（引数パターン）
pub const FnArity = struct {
    params: []const []const u8,
    variadic: bool, // & rest 引数があるか
    body: *Node,
};

/// fn ノード
pub const FnNode = struct {
    name: ?[]const u8,
    arities: []const FnArity,
    stack: SourceInfo,
};

/// 関数呼び出しノード
pub const CallNode = struct {
    fn_node: *Node,
    args: []const *Node,
    stack: SourceInfo,
};

/// def ノード
pub const DefNode = struct {
    sym_name: []const u8,
    init: ?*Node,
    is_macro: bool = false, // defmacro の場合は true
    stack: SourceInfo,
};

/// quote ノード
pub const QuoteNode = struct {
    form: Value, // クォートされたフォーム（Valueとして保持）
    stack: SourceInfo,
};

/// loop ノード
pub const LoopNode = struct {
    bindings: []const LetBinding,
    body: *Node,
    stack: SourceInfo,
};

/// recur ノード
pub const RecurNode = struct {
    args: []const *Node,
    stack: SourceInfo,
};

/// throw ノード
pub const ThrowNode = struct {
    expr: *Node,
    stack: SourceInfo,
};

/// catch 節
pub const CatchClause = struct {
    binding_name: []const u8, // 例外バインディング変数名（e）
    body: *Node, // catch ハンドラ本体
};

/// try ノード
pub const TryNode = struct {
    body: *Node, // try 本体（do ノードでラップ）
    catch_clause: ?CatchClause, // catch 節（省略可能）
    finally_body: ?*Node, // finally 本体（省略可能）
    stack: SourceInfo,
};

/// apply ノード
/// (apply f args) または (apply f x y z args)
pub const ApplyNode = struct {
    fn_node: *Node, // 関数
    args: []const *Node, // 中間引数（0個以上）
    seq_node: *Node, // 最後のシーケンス引数
    stack: SourceInfo,
};

/// partial ノード
/// (partial f args...)
pub const PartialNode = struct {
    fn_node: *Node, // 関数
    args: []const *Node, // 部分適用する引数
    stack: SourceInfo,
};

/// comp ノード
/// (comp f g h ...)
pub const CompNode = struct {
    fns: []const *Node, // 合成する関数（左から右の順、実行は右から左）
    stack: SourceInfo,
};

/// reduce ノード
/// (reduce f coll) または (reduce f init coll)
pub const ReduceNode = struct {
    fn_node: *Node, // 畳み込み関数
    init_node: ?*Node, // 初期値（nilの場合はcollの最初の要素を使用）
    coll_node: *Node, // コレクション
    stack: SourceInfo,
};

/// map ノード
/// (map f coll)
pub const MapNode = struct {
    fn_node: *Node, // 変換関数
    coll_node: *Node, // コレクション
    stack: SourceInfo,
};

/// filter ノード
/// (filter pred coll)
pub const FilterNode = struct {
    fn_node: *Node, // 述語関数
    coll_node: *Node, // コレクション
    stack: SourceInfo,
};

/// swap! ノード
/// (swap! atom f) または (swap! atom f x y ...)
pub const SwapNode = struct {
    atom_node: *Node, // Atom 式
    fn_node: *Node, // 適用する関数
    args: []const *Node, // 追加引数（0個以上）
    stack: SourceInfo,
};

/// defmulti ノード
/// (defmulti name dispatch-fn)
pub const DefmultiNode = struct {
    name: []const u8,
    dispatch_fn: *Node,
    stack: SourceInfo,
};

/// defmethod ノード
/// (defmethod name dispatch-val [params] body...)
pub const DefmethodNode = struct {
    multi_name: []const u8,
    dispatch_val: *Node, // ディスパッチ値（定数ノード）
    method_fn: *Node, // メソッド関数ノード
    stack: SourceInfo,
};

// === Node 本体 ===

/// 実行可能ノード
pub const Node = union(enum) {
    // リテラル（即値）
    constant: Value,

    // 参照
    var_ref: VarRefNode,
    local_ref: LocalRefNode,

    // 制御構造
    if_node: *IfNode,
    do_node: *DoNode,
    let_node: *LetNode,
    loop_node: *LoopNode,
    recur_node: *RecurNode,

    // 関数
    fn_node: *FnNode,
    call_node: *CallNode,

    // 定義
    def_node: *DefNode,

    // quote
    quote_node: *QuoteNode,

    // 例外
    throw_node: *ThrowNode,
    try_node: *TryNode,

    // 高階関数
    apply_node: *ApplyNode,
    partial_node: *PartialNode,
    comp_node: *CompNode,
    reduce_node: *ReduceNode,
    map_node: *MapNode,
    filter_node: *FilterNode,

    // Atom
    swap_node: *SwapNode,

    // マルチメソッド
    defmulti_node: *DefmultiNode,
    defmethod_node: *DefmethodNode,

    /// スタック情報を取得
    pub fn stack(self: Node) SourceInfo {
        return switch (self) {
            .constant => .{},
            .var_ref => |n| n.stack,
            .local_ref => |n| n.stack,
            .if_node => |n| n.stack,
            .do_node => |n| n.stack,
            .let_node => |n| n.stack,
            .loop_node => |n| n.stack,
            .recur_node => |n| n.stack,
            .fn_node => |n| n.stack,
            .call_node => |n| n.stack,
            .def_node => |n| n.stack,
            .quote_node => |n| n.stack,
            .throw_node => |n| n.stack,
            .try_node => |n| n.stack,
            .apply_node => |n| n.stack,
            .partial_node => |n| n.stack,
            .comp_node => |n| n.stack,
            .reduce_node => |n| n.stack,
            .map_node => |n| n.stack,
            .filter_node => |n| n.stack,
            .swap_node => |n| n.stack,
            .defmulti_node => |n| n.stack,
            .defmethod_node => |n| n.stack,
        };
    }

    /// ノードの種類名を返す（デバッグ用）
    pub fn kindName(self: Node) []const u8 {
        return switch (self) {
            .constant => "constant",
            .var_ref => "var-ref",
            .local_ref => "local-ref",
            .if_node => "if",
            .do_node => "do",
            .let_node => "let",
            .loop_node => "loop",
            .recur_node => "recur",
            .fn_node => "fn",
            .call_node => "call",
            .def_node => "def",
            .quote_node => "quote",
            .throw_node => "throw",
            .try_node => "try",
            .apply_node => "apply",
            .partial_node => "partial",
            .comp_node => "comp",
            .reduce_node => "reduce",
            .map_node => "map",
            .filter_node => "filter",
            .swap_node => "swap!",
            .defmulti_node => "defmulti",
            .defmethod_node => "defmethod",
        };
    }

    /// Node ツリーを指定アロケータに深コピー（scratch → persistent 移行用）
    /// TreeWalk 評価器で fn body を永続化するために使用。
    /// constant ノードの Value もヒープデータごと複製する。
    pub fn deepClone(self: *const Node, allocator: std.mem.Allocator) error{OutOfMemory}!*Node {
        const new_node = try allocator.create(Node);
        new_node.* = switch (self.*) {
            .constant => |val| .{ .constant = try val.deepClone(allocator) },
            .var_ref => |ref| .{ .var_ref = ref },
            .local_ref => |ref| .{ .local_ref = ref },
            .if_node => |n| blk: {
                const d = try allocator.create(IfNode);
                d.* = .{
                    .test_node = try n.test_node.deepClone(allocator),
                    .then_node = try n.then_node.deepClone(allocator),
                    .else_node = if (n.else_node) |e| try e.deepClone(allocator) else null,
                    .stack = n.stack,
                };
                break :blk .{ .if_node = d };
            },
            .do_node => |n| blk: {
                const stmts = try cloneNodeSlice(allocator, n.statements);
                const d = try allocator.create(DoNode);
                d.* = .{ .statements = stmts, .stack = n.stack };
                break :blk .{ .do_node = d };
            },
            .let_node => |n| blk: {
                const bindings = try cloneLetBindings(allocator, n.bindings);
                const d = try allocator.create(LetNode);
                d.* = .{
                    .bindings = bindings,
                    .body = try n.body.deepClone(allocator),
                    .stack = n.stack,
                };
                break :blk .{ .let_node = d };
            },
            .loop_node => |n| blk: {
                const bindings = try cloneLetBindings(allocator, n.bindings);
                const d = try allocator.create(LoopNode);
                d.* = .{
                    .bindings = bindings,
                    .body = try n.body.deepClone(allocator),
                    .stack = n.stack,
                };
                break :blk .{ .loop_node = d };
            },
            .recur_node => |n| blk: {
                const d = try allocator.create(RecurNode);
                d.* = .{ .args = try cloneNodeSlice(allocator, n.args), .stack = n.stack };
                break :blk .{ .recur_node = d };
            },
            .fn_node => |n| blk: {
                const arities = try allocator.alloc(FnArity, n.arities.len);
                for (n.arities, 0..) |a, i| {
                    arities[i] = .{
                        .params = a.params,
                        .variadic = a.variadic,
                        .body = try a.body.deepClone(allocator),
                    };
                }
                const d = try allocator.create(FnNode);
                d.* = .{ .name = n.name, .arities = arities, .stack = n.stack };
                break :blk .{ .fn_node = d };
            },
            .call_node => |n| blk: {
                const d = try allocator.create(CallNode);
                d.* = .{
                    .fn_node = try n.fn_node.deepClone(allocator),
                    .args = try cloneNodeSlice(allocator, n.args),
                    .stack = n.stack,
                };
                break :blk .{ .call_node = d };
            },
            .def_node => |n| blk: {
                const d = try allocator.create(DefNode);
                d.* = .{
                    .sym_name = n.sym_name,
                    .init = if (n.init) |init| try init.deepClone(allocator) else null,
                    .is_macro = n.is_macro,
                    .stack = n.stack,
                };
                break :blk .{ .def_node = d };
            },
            .quote_node => |n| blk: {
                const d = try allocator.create(QuoteNode);
                d.* = .{ .form = try n.form.deepClone(allocator), .stack = n.stack };
                break :blk .{ .quote_node = d };
            },
            .throw_node => |n| blk: {
                const d = try allocator.create(ThrowNode);
                d.* = .{ .expr = try n.expr.deepClone(allocator), .stack = n.stack };
                break :blk .{ .throw_node = d };
            },
            .try_node => |n| blk: {
                const d = try allocator.create(TryNode);
                d.* = .{
                    .body = try n.body.deepClone(allocator),
                    .catch_clause = if (n.catch_clause) |c| CatchClause{
                        .binding_name = c.binding_name,
                        .body = try c.body.deepClone(allocator),
                    } else null,
                    .finally_body = if (n.finally_body) |f| try f.deepClone(allocator) else null,
                    .stack = n.stack,
                };
                break :blk .{ .try_node = d };
            },
            .apply_node => |n| blk: {
                const d = try allocator.create(ApplyNode);
                d.* = .{
                    .fn_node = try n.fn_node.deepClone(allocator),
                    .args = try cloneNodeSlice(allocator, n.args),
                    .seq_node = try n.seq_node.deepClone(allocator),
                    .stack = n.stack,
                };
                break :blk .{ .apply_node = d };
            },
            .partial_node => |n| blk: {
                const d = try allocator.create(PartialNode);
                d.* = .{
                    .fn_node = try n.fn_node.deepClone(allocator),
                    .args = try cloneNodeSlice(allocator, n.args),
                    .stack = n.stack,
                };
                break :blk .{ .partial_node = d };
            },
            .comp_node => |n| blk: {
                const d = try allocator.create(CompNode);
                d.* = .{ .fns = try cloneNodeSlice(allocator, n.fns), .stack = n.stack };
                break :blk .{ .comp_node = d };
            },
            .reduce_node => |n| blk: {
                const d = try allocator.create(ReduceNode);
                d.* = .{
                    .fn_node = try n.fn_node.deepClone(allocator),
                    .init_node = if (n.init_node) |init| try init.deepClone(allocator) else null,
                    .coll_node = try n.coll_node.deepClone(allocator),
                    .stack = n.stack,
                };
                break :blk .{ .reduce_node = d };
            },
            .map_node => |n| blk: {
                const d = try allocator.create(MapNode);
                d.* = .{
                    .fn_node = try n.fn_node.deepClone(allocator),
                    .coll_node = try n.coll_node.deepClone(allocator),
                    .stack = n.stack,
                };
                break :blk .{ .map_node = d };
            },
            .filter_node => |n| blk: {
                const d = try allocator.create(FilterNode);
                d.* = .{
                    .fn_node = try n.fn_node.deepClone(allocator),
                    .coll_node = try n.coll_node.deepClone(allocator),
                    .stack = n.stack,
                };
                break :blk .{ .filter_node = d };
            },
            .swap_node => |n| blk: {
                const d = try allocator.create(SwapNode);
                d.* = .{
                    .atom_node = try n.atom_node.deepClone(allocator),
                    .fn_node = try n.fn_node.deepClone(allocator),
                    .args = try cloneNodeSlice(allocator, n.args),
                    .stack = n.stack,
                };
                break :blk .{ .swap_node = d };
            },
            .defmulti_node => |n| blk: {
                const d = try allocator.create(DefmultiNode);
                d.* = .{
                    .name = n.name,
                    .dispatch_fn = try n.dispatch_fn.deepClone(allocator),
                    .stack = n.stack,
                };
                break :blk .{ .defmulti_node = d };
            },
            .defmethod_node => |n| blk: {
                const d = try allocator.create(DefmethodNode);
                d.* = .{
                    .multi_name = n.multi_name,
                    .dispatch_val = try n.dispatch_val.deepClone(allocator),
                    .method_fn = try n.method_fn.deepClone(allocator),
                    .stack = n.stack,
                };
                break :blk .{ .defmethod_node = d };
            },
        };
        return new_node;
    }
};

/// Node ポインタのスライスを深コピー
fn cloneNodeSlice(allocator: std.mem.Allocator, nodes: []const *Node) error{OutOfMemory}![]*Node {
    const cloned = try allocator.alloc(*Node, nodes.len);
    for (nodes, 0..) |n, i| {
        cloned[i] = try n.deepClone(allocator);
    }
    return cloned;
}

/// LetBinding スライスを深コピー
fn cloneLetBindings(allocator: std.mem.Allocator, bindings: []const LetBinding) error{OutOfMemory}![]LetBinding {
    const cloned = try allocator.alloc(LetBinding, bindings.len);
    for (bindings, 0..) |b, i| {
        cloned[i] = .{
            .name = b.name,
            .init = try b.init.deepClone(allocator),
        };
    }
    return cloned;
}

// === ノード作成ヘルパー ===

/// 定数ノードを作成
pub fn constantNode(val: Value) Node {
    return .{ .constant = val };
}

/// nil 定数ノード
pub fn nilNode() Node {
    return .{ .constant = value_mod.nil };
}

/// true 定数ノード
pub fn trueNode() Node {
    return .{ .constant = value_mod.true_val };
}

/// false 定数ノード
pub fn falseNode() Node {
    return .{ .constant = value_mod.false_val };
}

// === テスト ===

test "constantNode" {
    const node = constantNode(value_mod.intVal(42));
    try std.testing.expectEqualStrings("constant", node.kindName());

    switch (node) {
        .constant => |val| {
            try std.testing.expect(val.eql(value_mod.intVal(42)));
        },
        else => unreachable,
    }
}

test "nilNode" {
    const node = nilNode();
    switch (node) {
        .constant => |val| {
            try std.testing.expect(val.isNil());
        },
        else => unreachable,
    }
}

test "IfNode" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var test_node = constantNode(value_mod.true_val);
    var then_node = constantNode(value_mod.intVal(1));
    var else_node = constantNode(value_mod.intVal(2));

    const if_data = try allocator.create(IfNode);
    if_data.* = .{
        .test_node = &test_node,
        .then_node = &then_node,
        .else_node = &else_node,
        .stack = .{ .line = 1, .column = 0 },
    };

    const node = Node{ .if_node = if_data };
    try std.testing.expectEqualStrings("if", node.kindName());
    try std.testing.expectEqual(@as(u32, 1), node.stack().line);
}

test "CallNode" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fn_node = nilNode(); // 仮の関数ノード
    var arg1 = constantNode(value_mod.intVal(1));
    var arg2 = constantNode(value_mod.intVal(2));

    const args = try allocator.alloc(*Node, 2);
    args[0] = &arg1;
    args[1] = &arg2;

    const call_data = try allocator.create(CallNode);
    call_data.* = .{
        .fn_node = &fn_node,
        .args = args,
        .stack = .{},
    };

    const node = Node{ .call_node = call_data };
    try std.testing.expectEqualStrings("call", node.kindName());
    try std.testing.expectEqual(@as(usize, 2), call_data.args.len);
}
