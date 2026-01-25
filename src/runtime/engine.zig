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

/// 両バックエンドで実行して比較（開発・テスト用）
pub fn runAndCompare(
    allocator: std.mem.Allocator,
    env: *Env,
    node: *const Node,
) !struct { tree_walk: Value, vm: Value, match: bool } {
    var tw_engine = EvalEngine.init(allocator, env, .tree_walk);
    const tw_result = try tw_engine.run(node);

    var vm_engine = EvalEngine.init(allocator, env, .vm);
    const vm_result = vm_engine.run(node) catch {
        // VM がまだ未実装の機能でエラーになる場合
        return .{
            .tree_walk = tw_result,
            .vm = Value.nil,
            .match = false,
        };
    };

    return .{
        .tree_walk = tw_result,
        .vm = vm_result,
        .match = tw_result.eql(vm_result),
    };
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
    const result = try runAndCompare(allocator, &env, &node);

    try std.testing.expect(result.match);
    try std.testing.expect(result.tree_walk.eql(value_mod.intVal(42)));
    try std.testing.expect(result.vm.eql(value_mod.intVal(42)));
}
