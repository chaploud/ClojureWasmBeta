//! 評価エンジン抽象化レイヤー
//!
//! TreeWalk と BytecodeVM の両方式を統一的に扱う。
//! バックエンドを切り替えてベンチマーク比較や並行開発が可能。
//!
//! 使用例:
//!   var engine = EvalEngine.init(allocator, env, .tree_walk);
//!   const result = try engine.run(node);

const std = @import("std");
const Node = @import("../analyzer/node.zig").Node;
const Value = @import("value.zig").Value;
const Context = @import("context.zig").Context;
const Env = @import("env.zig").Env;
const tree_walk = @import("evaluator.zig");
const Var = @import("var.zig").Var;
const Compiler = @import("../compiler/emit.zig").Compiler;
const VM = @import("../vm/vm.zig").VM;
const OpCode = @import("../compiler/bytecode.zig").OpCode;

/// 評価バックエンド
pub const Backend = enum {
    /// ツリーウォークインタプリタ（安定版）
    tree_walk,
    /// バイトコードVM（開発中）
    vm,
};

/// 評価エンジン
pub const EvalEngine = struct {
    allocator: std.mem.Allocator,
    env: *Env,
    backend: Backend,

    /// 初期化
    pub fn init(allocator: std.mem.Allocator, env: *Env, backend: Backend) EvalEngine {
        return .{
            .allocator = allocator,
            .env = env,
            .backend = backend,
        };
    }

    /// Node を評価して Value を返す
    pub fn run(self: *EvalEngine, node: *const Node) !Value {
        return switch (self.backend) {
            .tree_walk => self.runTreeWalk(node),
            .vm => self.runVM(node),
        };
    }

    /// TreeWalk バックエンド
    fn runTreeWalk(self: *EvalEngine, node: *const Node) !Value {
        var ctx = Context.init(self.allocator, self.env);
        return tree_walk.run(node, &ctx);
    }

    /// VM バックエンド
    fn runVM(self: *EvalEngine, node: *const Node) !Value {
        // コンパイル
        var compiler = Compiler.init(self.allocator);
        defer compiler.deinit();
        try compiler.compile(node);
        try compiler.chunk.emitOp(OpCode.ret);

        // 実行
        var vm = VM.init(self.allocator, self.env);
        return vm.run(&compiler.chunk);
    }
};

/// 比較実行の結果
pub const CompareResult = struct {
    tree_walk: Value,
    vm: Value,
    match: bool,
};

/// 両バックエンドで実行して比較（開発・テスト用）
/// TreeWalk と VM は fn body の型が異なるため、各バックエンドの
/// Var 状態を独立に維持する。vm_snapshot に VM 用の Var root 値を保持。
pub fn runAndCompare(
    allocator: std.mem.Allocator,
    env: *Env,
    node: *const Node,
    vm_snapshot: ?VarSnapshot,
) !struct { result: CompareResult, vm_snapshot: VarSnapshot } {
    // TreeWalk を実行（現在の Var 状態 = TreeWalk 用）
    var tw_engine = EvalEngine.init(allocator, env, .tree_walk);
    const tw_result = try tw_engine.run(node);

    // TreeWalk 実行後の Var 状態を保存
    const tw_state = try saveVarRoots(allocator, env);

    // VM 用の Var 状態を復元（前回の VM 実行後の状態）
    if (vm_snapshot) |snap| {
        restoreVarRoots(snap);
    }

    // VM を実行
    var vm_engine = EvalEngine.init(allocator, env, .vm);
    const vm_result = vm_engine.run(node) catch {
        // VM がまだ未実装の機能でエラーになる場合
        const new_vm_snap = saveVarRoots(allocator, env) catch VarSnapshot{ .vars = &.{} };
        restoreVarRoots(tw_state);
        return .{
            .result = .{ .tree_walk = tw_result, .vm = Value.nil, .match = false },
            .vm_snapshot = new_vm_snap,
        };
    };

    // VM 実行後の Var 状態を保存
    const new_vm_snap = try saveVarRoots(allocator, env);

    // TreeWalk の Var 状態を復元（次の式で TreeWalk が正しい状態を見るため）
    restoreVarRoots(tw_state);

    return .{
        .result = .{ .tree_walk = tw_result, .vm = vm_result, .match = tw_result.eql(vm_result) },
        .vm_snapshot = new_vm_snap,
    };
}

/// Var → root 値のスナップショット
pub const VarSnapshot = struct {
    vars: []VarEntry,

    const VarEntry = struct {
        var_ptr: *Var,
        root: Value,
    };
};

/// 全 Namespace の全 Var の root 値を保存
fn saveVarRoots(allocator: std.mem.Allocator, env: *Env) !VarSnapshot {
    // まず総数をカウント
    var count: usize = 0;
    var ns_iter = env.namespaces.iterator();
    while (ns_iter.next()) |ns_entry| {
        var var_iter = ns_entry.value_ptr.*.getAllVars();
        while (var_iter.next()) |_| {
            count += 1;
        }
    }

    const entries = try allocator.alloc(VarSnapshot.VarEntry, count);
    var idx: usize = 0;
    ns_iter = env.namespaces.iterator();
    while (ns_iter.next()) |ns_entry| {
        var var_iter = ns_entry.value_ptr.*.getAllVars();
        while (var_iter.next()) |var_entry| {
            entries[idx] = .{
                .var_ptr = var_entry.value_ptr.*,
                .root = var_entry.value_ptr.*.root,
            };
            idx += 1;
        }
    }

    return .{ .vars = entries };
}

/// 保存した root 値を復元
fn restoreVarRoots(snapshot: VarSnapshot) void {
    for (snapshot.vars) |entry| {
        entry.var_ptr.root = entry.root;
    }
}

// === テスト ===

test "EvalEngine tree_walk" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    var engine = EvalEngine.init(allocator, &env, .tree_walk);

    // 定数を評価
    const value_mod = @import("value.zig");
    var node = Node{ .constant = value_mod.intVal(42) };
    const result = try engine.run(&node);
    try std.testing.expect(result.eql(value_mod.intVal(42)));
}

test "EvalEngine vm" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    var engine = EvalEngine.init(allocator, &env, .vm);

    // 定数を評価
    const value_mod = @import("value.zig");
    var node = Node{ .constant = value_mod.intVal(42) };
    const result = try engine.run(&node);
    try std.testing.expect(result.eql(value_mod.intVal(42)));
}

test "runAndCompare" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    const value_mod = @import("value.zig");
    var node = Node{ .constant = value_mod.intVal(42) };
    const out = try runAndCompare(allocator, &env, &node, null);

    try std.testing.expect(out.result.match);
    try std.testing.expect(out.result.tree_walk.eql(value_mod.intVal(42)));
    try std.testing.expect(out.result.vm.eql(value_mod.intVal(42)));
}
