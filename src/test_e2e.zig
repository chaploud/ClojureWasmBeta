//! E2E テスト
//!
//! Reader → Analyzer → Evaluator の統合テスト。
//! 文字列から式を評価して結果を検証。

const std = @import("std");
const reader_mod = @import("reader/reader.zig");
const Reader = reader_mod.Reader;
const analyze_mod = @import("analyzer/analyze.zig");
const Analyzer = analyze_mod.Analyzer;
const evaluator_mod = @import("runtime/evaluator.zig");
const value_mod = @import("runtime/value.zig");
const Value = value_mod.Value;
const env_mod = @import("runtime/env.zig");
const Env = env_mod.Env;
const context_mod = @import("runtime/context.zig");
const Context = context_mod.Context;
const core = @import("lib/core.zig");

/// 式を文字列から評価
fn evalExpr(allocator: std.mem.Allocator, env: *Env, source: []const u8) !Value {
    // Reader
    var rdr = Reader.init(allocator, source);
    const form = try rdr.read() orelse return error.EmptyInput;

    // Analyzer
    var analyzer = Analyzer.init(allocator, env);
    const node = try analyzer.analyze(form);

    // Evaluator
    var ctx = Context.init(allocator, env);
    return evaluator_mod.run(node, &ctx);
}

/// 式を評価して整数を期待
fn expectInt(allocator: std.mem.Allocator, env: *Env, source: []const u8, expected: i64) !void {
    const result = try evalExpr(allocator, env, source);
    try std.testing.expectEqual(Value{ .int = expected }, result);
}

/// 式を評価して真偽値を期待
fn expectBool(allocator: std.mem.Allocator, env: *Env, source: []const u8, expected: bool) !void {
    const result = try evalExpr(allocator, env, source);
    try std.testing.expectEqual(Value{ .bool_val = expected }, result);
}

/// 式を評価して nil を期待
fn expectNil(allocator: std.mem.Allocator, env: *Env, source: []const u8) !void {
    const result = try evalExpr(allocator, env, source);
    try std.testing.expectEqual(Value.nil, result);
}

/// テスト用の環境を初期化
fn setupTestEnv(allocator: std.mem.Allocator) !Env {
    var env = Env.init(allocator);
    try env.setupBasic();
    try core.registerCore(&env);
    return env;
}

// ============================================================
// 基本テスト
// ============================================================

test "e2e: リテラル" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectInt(allocator, &env, "42", 42);
    try expectInt(allocator, &env, "-123", -123);
    try expectBool(allocator, &env, "true", true);
    try expectBool(allocator, &env, "false", false);
    try expectNil(allocator, &env, "nil");
}

test "e2e: 算術演算" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectInt(allocator, &env, "(+ 1 2)", 3);
    try expectInt(allocator, &env, "(+ 1 2 3 4 5)", 15);
    try expectInt(allocator, &env, "(- 10 3)", 7);
    try expectInt(allocator, &env, "(- 5)", -5);
    try expectInt(allocator, &env, "(* 2 3 4)", 24);
}

test "e2e: 比較演算" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectBool(allocator, &env, "(= 1 1)", true);
    try expectBool(allocator, &env, "(= 1 2)", false);
    try expectBool(allocator, &env, "(< 1 2 3)", true);
    try expectBool(allocator, &env, "(< 1 3 2)", false);
    try expectBool(allocator, &env, "(> 3 2 1)", true);
    try expectBool(allocator, &env, "(<= 1 1 2)", true);
    try expectBool(allocator, &env, "(>= 3 2 2)", true);
}

test "e2e: if" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectInt(allocator, &env, "(if true 1 2)", 1);
    try expectInt(allocator, &env, "(if false 1 2)", 2);
    try expectNil(allocator, &env, "(if false 1)");
    try expectInt(allocator, &env, "(if nil 1 2)", 2);
    try expectInt(allocator, &env, "(if 0 1 2)", 1); // 0 は truthy
}

test "e2e: do" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectInt(allocator, &env, "(do 1 2 3)", 3);
    try expectInt(allocator, &env, "(do 42)", 42);
}

test "e2e: let" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectInt(allocator, &env, "(let [x 42] x)", 42);
    try expectInt(allocator, &env, "(let [x 1 y 2] (+ x y))", 3);
    try expectInt(allocator, &env, "(let [x 10] (let [y 20] (+ x y)))", 30);
}

test "e2e: 述語" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectBool(allocator, &env, "(nil? nil)", true);
    try expectBool(allocator, &env, "(nil? 1)", false);
    try expectBool(allocator, &env, "(number? 42)", true);
    try expectBool(allocator, &env, "(number? \"hello\")", false);
    try expectBool(allocator, &env, "(integer? 42)", true);
    try expectBool(allocator, &env, "(integer? 3.14)", false);
}

test "e2e: コレクション操作" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectInt(allocator, &env, "(first [1 2 3])", 1);
    try expectNil(allocator, &env, "(first [])");
    try expectNil(allocator, &env, "(first nil)");
    try expectInt(allocator, &env, "(count [1 2 3])", 3);
    try expectInt(allocator, &env, "(count nil)", 0);
    try expectBool(allocator, &env, "(empty? [])", true);
    try expectBool(allocator, &env, "(empty? [1])", false);
    try expectInt(allocator, &env, "(nth [10 20 30] 1)", 20);
}

test "e2e: loop/recur" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // (loop [n 5 acc 0] (if (= n 0) acc (recur (- n 1) (+ acc n))))
    // = 5 + 4 + 3 + 2 + 1 = 15
    const sum_expr =
        \\(loop [n 5 acc 0]
        \\  (if (= n 0)
        \\    acc
        \\    (recur (- n 1) (+ acc n))))
    ;
    try expectInt(allocator, &env, sum_expr, 15);
}

test "e2e: ネストした式" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectInt(allocator, &env, "(+ (* 2 3) (* 4 5))", 26);
    try expectInt(allocator, &env, "(if (< 1 2) (+ 10 20) 0)", 30);
    try expectInt(allocator, &env,
        \\(let [a 10]
        \\  (let [b 20]
        \\    (+ a b (let [c 30] c))))
    , 60);
}

test "e2e: quote" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // quote はシンボルをそのまま返す
    const result = try evalExpr(allocator, &env, "'x");
    try std.testing.expect(result == .symbol);
    try std.testing.expectEqualStrings("x", result.symbol.name);

    // quote はリストをそのまま返す
    const list_result = try evalExpr(allocator, &env, "'(1 2 3)");
    try std.testing.expect(list_result == .list);
    try std.testing.expectEqual(@as(usize, 3), list_result.list.items.len);
}

test "e2e: ユーザー定義関数" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // 即時実行の無名関数
    try expectInt(allocator, &env, "((fn [x] x) 42)", 42);
    try expectInt(allocator, &env, "((fn [x y] (+ x y)) 1 2)", 3);

    // 式の中で関数を使う
    try expectInt(allocator, &env, "(+ ((fn [x] (* x x)) 3) 1)", 10);
}

test "e2e: クロージャ" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // let で束縛された変数をキャプチャ
    try expectInt(allocator, &env,
        \\(let [x 10]
        \\  ((fn [y] (+ x y)) 5))
    , 15);

    // ネストしたクロージャ
    try expectInt(allocator, &env,
        \\(let [a 1]
        \\  (let [b 2]
        \\    ((fn [c] (+ a b c)) 3)))
    , 6);
}

test "e2e: def された関数" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // 関数を定義して呼び出し
    _ = try evalExpr(allocator, &env, "(def inc (fn [x] (+ x 1)))");
    try expectInt(allocator, &env, "(inc 5)", 6);

    // 複数引数の関数
    _ = try evalExpr(allocator, &env, "(def add3 (fn [a b c] (+ a b c)))");
    try expectInt(allocator, &env, "(add3 1 2 3)", 6);

    // 関数を使った複雑な式
    _ = try evalExpr(allocator, &env, "(def square (fn [x] (* x x)))");
    try expectInt(allocator, &env, "(+ (square 3) (square 4))", 25);
}
