//! Context: 評価コンテキスト
//!
//! 評価時のローカル環境を管理。
//! ローカルバインディング、recur ターゲット。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md

const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const env_mod = @import("env.zig");
const Env = env_mod.Env;
const namespace_mod = @import("namespace.zig");
const Namespace = namespace_mod.Namespace;

/// recur で値を渡すための構造体
pub const RecurValues = struct {
    values: []Value,
};

/// Context: 評価コンテキスト
pub const Context = struct {
    /// グローバル環境
    env: *Env,

    /// アロケータ
    allocator: std.mem.Allocator,

    /// ローカルバインディングの値（インデックスでアクセス）
    bindings: []Value,

    /// recur 発生フラグと値
    /// null: recur 未発生
    /// non-null: recur 発生、値を含む
    recur_values: ?RecurValues = null,

    /// 初期化（バインディングなし）
    pub fn init(allocator: std.mem.Allocator, env: *Env) Context {
        return .{
            .env = env,
            .allocator = allocator,
            .bindings = &[_]Value{},
        };
    }

    /// インデックスでローカル変数を取得
    pub fn getLocal(self: *const Context, idx: u32) ?Value {
        if (idx >= self.bindings.len) return null;
        return self.bindings[idx];
    }

    /// 新しいバインディングを追加したコンテキストを作成
    pub fn withBindings(self: *const Context, new_bindings: []const Value) !Context {
        const combined = try self.allocator.alloc(Value, self.bindings.len + new_bindings.len);
        @memcpy(combined[0..self.bindings.len], self.bindings);
        @memcpy(combined[self.bindings.len..], new_bindings);

        return Context{
            .env = self.env,
            .allocator = self.allocator,
            .bindings = combined,
        };
    }

    /// バインディングを置き換えたコンテキストを作成（recur 用）
    pub fn replaceBindings(self: *const Context, start_idx: usize, new_values: []const Value) !Context {
        const new_bindings = try self.allocator.dupe(Value, self.bindings);
        for (new_values, 0..) |val, i| {
            new_bindings[start_idx + i] = val;
        }

        return Context{
            .env = self.env,
            .allocator = self.allocator,
            .bindings = new_bindings,
        };
    }

    /// recur を設定
    pub fn setRecur(self: *Context, values: []Value) void {
        self.recur_values = .{ .values = values };
    }

    /// recur をクリア
    pub fn clearRecur(self: *Context) void {
        self.recur_values = null;
    }

    /// recur が発生したか
    pub fn hasRecur(self: *const Context) bool {
        return self.recur_values != null;
    }
};

// === テスト ===

test "Context 基本操作" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    var ctx = Context.init(allocator, &env);

    // 初期状態
    try std.testing.expect(ctx.getLocal(0) == null);

    // バインディング追加
    const vals = [_]Value{ value_mod.intVal(1), value_mod.intVal(2) };
    ctx = try ctx.withBindings(&vals);

    try std.testing.expect(ctx.getLocal(0).?.eql(value_mod.intVal(1)));
    try std.testing.expect(ctx.getLocal(1).?.eql(value_mod.intVal(2)));
    try std.testing.expect(ctx.getLocal(2) == null);
}

test "Context recur" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = Env.init(allocator);
    defer env.deinit();

    var ctx = Context.init(allocator, &env);

    // recur 未発生
    try std.testing.expect(!ctx.hasRecur());

    // recur 設定
    var vals = [_]Value{ value_mod.intVal(10) };
    ctx.setRecur(&vals);
    try std.testing.expect(ctx.hasRecur());

    // recur クリア
    ctx.clearRecur();
    try std.testing.expect(!ctx.hasRecur());
}
