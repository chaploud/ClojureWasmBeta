//! E2E テスト
//!
//! Reader → Analyzer → Evaluator の統合テスト。
//! 文字列から式を評価して結果を検証。
//!
//! 両バックエンド（TreeWalk / VM）でのテスト実行をサポート。

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
const engine_mod = @import("runtime/engine.zig");
const EvalEngine = engine_mod.EvalEngine;
const Backend = engine_mod.Backend;

// ============================================================
// 評価ヘルパー
// ============================================================

/// 式を文字列から評価（TreeWalk）
fn evalExpr(allocator: std.mem.Allocator, env: *Env, source: []const u8) !Value {
    return evalWithBackend(allocator, env, source, .tree_walk);
}

/// 指定バックエンドで式を評価
fn evalWithBackend(allocator: std.mem.Allocator, env: *Env, source: []const u8, backend: Backend) !Value {
    // Reader
    var rdr = Reader.init(allocator, source);
    const form = try rdr.read() orelse return error.EmptyInput;

    // Analyzer
    var analyzer = Analyzer.init(allocator, env);
    const node = try analyzer.analyze(form);

    // Engine
    var eng = EvalEngine.init(allocator, env, backend);
    return eng.run(node);
}

/// 両バックエンドで評価して一致を検証
fn evalBothAndCompare(allocator: std.mem.Allocator, env: *Env, source: []const u8) !Value {
    // Reader
    var rdr = Reader.init(allocator, source);
    const form = try rdr.read() orelse return error.EmptyInput;

    // Analyzer
    var analyzer = Analyzer.init(allocator, env);
    const node = try analyzer.analyze(form);

    // 両バックエンドで実行
    const result = try engine_mod.runAndCompare(allocator, env, node);

    // 一致を検証（VM が動作する場合のみ）
    if (result.vm != .nil or result.tree_walk == .nil) {
        try std.testing.expect(result.match);
    }

    return result.tree_walk;
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

/// 両バックエンドで整数を期待
fn expectIntBoth(allocator: std.mem.Allocator, env: *Env, source: []const u8, expected: i64) !void {
    const result = try evalBothAndCompare(allocator, env, source);
    try std.testing.expectEqual(Value{ .int = expected }, result);
}

/// 両バックエンドで真偽値を期待
fn expectBoolBoth(allocator: std.mem.Allocator, env: *Env, source: []const u8, expected: bool) !void {
    const result = try evalBothAndCompare(allocator, env, source);
    try std.testing.expectEqual(Value{ .bool_val = expected }, result);
}

/// 両バックエンドで nil を期待
fn expectNilBoth(allocator: std.mem.Allocator, env: *Env, source: []const u8) !void {
    const result = try evalBothAndCompare(allocator, env, source);
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

test "e2e: マクロ" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // when マクロ
    _ = try evalExpr(allocator, &env, "(defmacro when [test body] (list 'if test body nil))");
    try expectInt(allocator, &env, "(when true 42)", 42);
    try expectNil(allocator, &env, "(when false 42)");

    // unless マクロ
    _ = try evalExpr(allocator, &env, "(defmacro unless [test body] (list 'if test nil body))");
    try expectInt(allocator, &env, "(unless false 100)", 100);
    try expectNil(allocator, &env, "(unless true 100)");

    // マクロ内で変数を使用
    _ = try evalExpr(allocator, &env, "(def x 10)");
    try expectInt(allocator, &env, "(when true x)", 10);
}

// ============================================================
// VM テスト（engine 経由）
// ============================================================

test "vm: 定数" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // 整数
    const result1 = try evalWithBackend(allocator, &env, "42", .vm);
    try std.testing.expect(result1.eql(Value{ .int = 42 }));

    // nil
    const result2 = try evalWithBackend(allocator, &env, "nil", .vm);
    try std.testing.expect(result2.isNil());

    // true/false
    const result3 = try evalWithBackend(allocator, &env, "true", .vm);
    try std.testing.expect(result3.eql(Value{ .bool_val = true }));

    const result4 = try evalWithBackend(allocator, &env, "false", .vm);
    try std.testing.expect(result4.eql(Value{ .bool_val = false }));
}

test "vm: if" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // true ブランチ
    const result1 = try evalWithBackend(allocator, &env, "(if true 1 2)", .vm);
    try std.testing.expect(result1.eql(Value{ .int = 1 }));

    // false ブランチ
    const result2 = try evalWithBackend(allocator, &env, "(if false 1 2)", .vm);
    try std.testing.expect(result2.eql(Value{ .int = 2 }));

    // else なし
    const result3 = try evalWithBackend(allocator, &env, "(if false 1)", .vm);
    try std.testing.expect(result3.isNil());
}

test "vm: 関数呼び出し（組み込み）" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // 算術演算
    const result1 = try evalWithBackend(allocator, &env, "(+ 1 2)", .vm);
    try std.testing.expect(result1.eql(Value{ .int = 3 }));

    const result2 = try evalWithBackend(allocator, &env, "(* 3 4)", .vm);
    try std.testing.expect(result2.eql(Value{ .int = 12 }));
}

// ============================================================
// 両バックエンド比較テスト
// ============================================================

test "compare: 定数" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectIntBoth(allocator, &env, "42", 42);
    try expectBoolBoth(allocator, &env, "true", true);
    try expectBoolBoth(allocator, &env, "false", false);
    try expectNilBoth(allocator, &env, "nil");
}

test "compare: if" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectIntBoth(allocator, &env, "(if true 1 2)", 1);
    try expectIntBoth(allocator, &env, "(if false 1 2)", 2);
    try expectNilBoth(allocator, &env, "(if false 1)");
}

test "compare: 関数呼び出し（組み込み）" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectIntBoth(allocator, &env, "(+ 1 2)", 3);
    try expectIntBoth(allocator, &env, "(* 3 4)", 12);
    try expectIntBoth(allocator, &env, "(- 10 3)", 7);
}

test "compare: 可変長引数" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // rest の first を取得
    try expectIntBoth(allocator, &env, "((fn [x & rest] (first rest)) 1 2 3)", 2);

    // rest が空の場合
    try expectNilBoth(allocator, &env, "((fn [x & rest] (first rest)) 1)");

    // rest のみ（固定引数なし）
    try expectIntBoth(allocator, &env, "((fn [& args] (first args)) 42)", 42);

    // 固定引数を使う
    try expectIntBoth(allocator, &env, "((fn [x y & rest] (+ x y)) 10 20 30)", 30);
}

test "compare: apply" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // 基本的な apply
    try expectIntBoth(allocator, &env, "(apply + [1 2 3])", 6);

    // 中間引数あり
    try expectIntBoth(allocator, &env, "(apply + 1 2 [3 4])", 10);

    // 空のシーケンス
    try expectIntBoth(allocator, &env, "(apply + [])", 0);
    try expectIntBoth(allocator, &env, "(apply + 5 [])", 5);

    // ユーザー定義関数への apply
    try expectIntBoth(allocator, &env, "(apply (fn [x y] (+ x y)) [10 20])", 30);
}

test "compare: 複数アリティ fn" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // 複数アリティ: 1引数
    try expectIntBoth(allocator, &env, "((fn ([x] x) ([x y] (+ x y))) 42)", 42);

    // 複数アリティ: 2引数
    try expectIntBoth(allocator, &env, "((fn ([x] x) ([x y] (+ x y))) 10 20)", 30);

    // 複数アリティ: 0引数
    try expectIntBoth(allocator, &env, "((fn ([] 0) ([x] x) ([x y] (+ x y))))", 0);

    // 3つのアリティ
    try expectIntBoth(allocator, &env, "((fn ([] 100) ([x] x) ([x y z] (+ x y z))) 1 2 3)", 6);
}

test "compare: partial" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // 基本的な partial
    try expectIntBoth(allocator, &env, "((partial + 10) 5)", 15);

    // 複数の部分適用引数
    try expectIntBoth(allocator, &env, "((partial + 10 20) 5)", 35);

    // let で束縛
    try expectIntBoth(allocator, &env, "(let [add5 (partial + 5)] (add5 10))", 15);

    // ユーザー定義関数への partial
    try expectIntBoth(allocator, &env, "((partial (fn [x y] (+ x y)) 100) 23)", 123);

    // ネストした partial
    try expectIntBoth(allocator, &env, "((partial (partial + 1) 2) 3)", 6);

    // apply と partial の組み合わせ
    try expectIntBoth(allocator, &env, "(apply (partial + 10) [1 2 3])", 16);
}

test "compare: comp" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // 基本的な comp（右から左に適用）
    // (comp (partial + 1) (partial * 2)) = (fn [x] (+ 1 (* 2 x)))
    // 5 -> (* 2 5) = 10 -> (+ 1 10) = 11
    try expectIntBoth(allocator, &env, "((comp (partial + 1) (partial * 2)) 5)", 11);

    // 単一関数の comp
    try expectIntBoth(allocator, &env, "((comp (partial + 1)) 5)", 6);

    // 3つの関数合成
    // (comp f g h) = (fn [x] (f (g (h x))))
    // 2 -> (+ 3 2) = 5 -> (* 2 5) = 10 -> (+ 1 10) = 11
    try expectIntBoth(allocator, &env, "((comp (partial + 1) (partial * 2) (partial + 3)) 2)", 11);

    // let で束縛
    try expectIntBoth(allocator, &env,
        \\(let [inc-then-double (comp (partial * 2) (partial + 1))]
        \\  (inc-then-double 5))
    , 12); // 5 -> (+ 1 5) = 6 -> (* 2 6) = 12

    // ユーザー定義関数との組み合わせ
    try expectIntBoth(allocator, &env, "((comp (partial + 1) (fn [x] (* x x))) 3)", 10); // 3 -> 9 -> 10

    // comp と partial の組み合わせ
    try expectIntBoth(allocator, &env, "((comp + (fn [x y] (+ x y))) 5 10)", 15);

    // 複数引数を受け取る最右の関数
    try expectIntBoth(allocator, &env, "((comp (partial * 2) +) 1 2 3)", 12); // (+ 1 2 3) = 6 -> (* 2 6) = 12
}
