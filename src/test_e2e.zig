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
    const out = try engine_mod.runAndCompare(allocator, env, node, null);

    // 一致を検証（VM が動作する場合のみ）
    if (out.result.vm != .nil or out.result.tree_walk == .nil) {
        try std.testing.expect(out.result.match);
    }

    return out.result.tree_walk;
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

/// 両バックエンドで文字列を期待
fn expectStrBoth(allocator: std.mem.Allocator, env: *Env, source: []const u8, expected: []const u8) !void {
    const result = try evalBothAndCompare(allocator, env, source);
    switch (result) {
        .string => |s| try std.testing.expectEqualStrings(expected, s.data),
        else => return error.UnexpectedValue,
    }
}

/// 両バックエンドで nil を期待
fn expectNilBoth(allocator: std.mem.Allocator, env: *Env, source: []const u8) !void {
    const result = try evalBothAndCompare(allocator, env, source);
    try std.testing.expectEqual(Value.nil, result);
}

/// 両バックエンドでキーワードを期待
fn expectKwBoth(allocator: std.mem.Allocator, env: *Env, source: []const u8, expected: []const u8) !void {
    const result = try evalBothAndCompare(allocator, env, source);
    switch (result) {
        .keyword => |kw| try std.testing.expectEqualStrings(expected, kw.name),
        else => return error.UnexpectedValue,
    }
}

/// 両バックエンドでエラーを期待（式が正常に評価されたらテスト失敗）
fn expectErrorBoth(allocator: std.mem.Allocator, env: *Env, source: []const u8) !void {
    // TreeWalk
    if (evalWithBackend(allocator, env, source, .tree_walk)) |_| {
        return error.UnexpectedValue; // エラーを期待したが成功した
    } else |_| {}

    // VM
    if (evalWithBackend(allocator, env, source, .vm)) |_| {
        return error.UnexpectedValue;
    } else |_| {}
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

test "compare: reduce" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // 基本的な reduce（初期値なし）
    try expectIntBoth(allocator, &env, "(reduce + [1 2 3 4 5])", 15);

    // 初期値あり
    try expectIntBoth(allocator, &env, "(reduce + 0 [1 2 3 4 5])", 15);
    try expectIntBoth(allocator, &env, "(reduce + 100 [1 2 3])", 106);

    // 空コレクションと初期値
    try expectIntBoth(allocator, &env, "(reduce + 10 [])", 10);

    // 空コレクションで初期値なし（(+) = 0）
    try expectIntBoth(allocator, &env, "(reduce + [])", 0);

    // 単一要素（初期値なし）
    try expectIntBoth(allocator, &env, "(reduce + [42])", 42);

    // 単一要素（初期値あり）
    try expectIntBoth(allocator, &env, "(reduce + 10 [42])", 52);

    // ユーザー定義関数（二乗の和）
    try expectIntBoth(allocator, &env, "(reduce (fn [acc x] (+ acc (* x x))) 0 [1 2 3 4])", 30);

    // リストでも動作
    try expectIntBoth(allocator, &env, "(reduce + '(1 2 3 4))", 10);
}

test "compare: destructuring" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // === シーケンシャル分配 ===

    // 基本的な分配
    try expectIntBoth(allocator, &env, "(let [[a] [1]] a)", 1);
    try expectIntBoth(allocator, &env, "(let [[a b] [1 2]] (+ a b))", 3);
    try expectIntBoth(allocator, &env, "(let [[a b c] [1 2 3]] (+ a b c))", 6);

    // ネスト分配
    try expectIntBoth(allocator, &env, "(let [[a [b c]] [1 [2 3]]] (+ a b c))", 6);

    // :as 分配
    try expectIntBoth(allocator, &env, "(let [[a b :as all] [1 2]] (count all))", 2);
    try expectIntBoth(allocator, &env, "(let [[a b :as all] [1 2]] (+ a b (first all)))", 4);

    // & rest 分配
    try expectIntBoth(allocator, &env, "(let [[x & rest] [1 2 3 4]] x)", 1);
    try expectIntBoth(allocator, &env, "(let [[x & rest] [1 2 3 4]] (count rest))", 3);
    try expectIntBoth(allocator, &env, "(let [[x & rest] [1 2 3 4]] (first rest))", 2);

    // & rest と :as の組み合わせ
    // x=1, rest=(2 3), all=[1 2 3] -> 1 + 2 + 3 = 6
    try expectIntBoth(allocator, &env, "(let [[x & rest :as all] [1 2 3]] (+ x (count rest) (count all)))", 6);

    // リストの分配
    try expectIntBoth(allocator, &env, "(let [[a b] '(10 20)] (+ a b))", 30);

    // === 順次バインディング ===

    // 後続のバインディングが前のバインディングを参照
    try expectIntBoth(allocator, &env, "(let [x 1 y x] y)", 1);
    try expectIntBoth(allocator, &env, "(let [x 1 y x z (+ x y)] z)", 2);

    // 分配と順次バインディングの組み合わせ
    try expectIntBoth(allocator, &env, "(let [[a b] [1 2] c (+ a b)] c)", 3);

    // === fn 引数の分配 ===

    // 基本的な fn 引数分配
    try expectIntBoth(allocator, &env, "((fn [[a b]] (+ a b)) [1 2])", 3);
    try expectIntBoth(allocator, &env, "((fn [[a b c]] (+ a b c)) [1 2 3])", 6);

    // fn 引数分配と & rest
    try expectIntBoth(allocator, &env, "((fn [[x & rest]] (+ x (count rest))) [1 2 3 4])", 4);

    // 通常パラメータと分配パラメータの混在
    try expectIntBoth(allocator, &env, "((fn [x [a b]] (+ x a b)) 10 [1 2])", 13);

    // ネスト分配
    try expectIntBoth(allocator, &env, "((fn [[a [b c]]] (+ a b c)) [1 [2 3]])", 6);
}

test "compare: maps" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // マップリテラル
    try expectIntBoth(allocator, &env, "(count {:a 1 :b 2 :c 3})", 3);

    // get
    try expectIntBoth(allocator, &env, "(get {:a 1 :b 2} :a)", 1);
    try expectIntBoth(allocator, &env, "(get {:a 1 :b 2} :b)", 2);
    try expectIntBoth(allocator, &env, "(get {:a 1 :b 2} :c 99)", 99);

    // assoc
    try expectIntBoth(allocator, &env, "(get (assoc {:a 1} :b 2) :b)", 2);
    try expectIntBoth(allocator, &env, "(get (assoc {:a 1} :a 10) :a)", 10);
    try expectIntBoth(allocator, &env, "(count (assoc {:a 1} :b 2))", 2);

    // dissoc
    try expectIntBoth(allocator, &env, "(count (dissoc {:a 1 :b 2} :a))", 1);
    try expectIntBoth(allocator, &env, "(get (dissoc {:a 1 :b 2} :a) :b)", 2);

    // keys, vals
    try expectIntBoth(allocator, &env, "(count (keys {:a 1 :b 2}))", 2);
    try expectIntBoth(allocator, &env, "(count (vals {:a 1 :b 2}))", 2);

    // hash-map
    try expectIntBoth(allocator, &env, "(get (hash-map :x 10 :y 20) :x)", 10);
    try expectIntBoth(allocator, &env, "(count (hash-map :a 1 :b 2 :c 3))", 3);

    // contains?
    try expectBoolBoth(allocator, &env, "(contains? {:a 1 :b 2} :a)", true);
    try expectBoolBoth(allocator, &env, "(contains? {:a 1 :b 2} :c)", false);
}

test "compare: map destructuring" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // :keys による分配
    try expectStrBoth(allocator, &env,
        \\(let [{:keys [name age]} {:name "Alice" :age 30}] name)
    , "Alice");
    try expectIntBoth(allocator, &env,
        \\(let [{:keys [name age]} {:name "Alice" :age 30}] age)
    , 30);

    // 直接キーバインディング {x :x y :y}
    try expectIntBoth(allocator, &env,
        \\(let [{x :x y :y} {:x 1 :y 2}] (+ x y))
    , 3);

    // :or デフォルト値
    try expectIntBoth(allocator, &env,
        \\(let [{:keys [a] :or {a 0}} {}] a)
    , 0);
    try expectIntBoth(allocator, &env,
        \\(let [{:keys [a b] :or {a 10 b 20}} {:a 1}] (+ a b))
    , 21);

    // :as エイリアス
    try expectIntBoth(allocator, &env,
        \\(let [{:keys [a b] :as m} {:a 1 :b 2 :c 3}] (+ a b (count m)))
    , 6);

    // :strs による文字列キー分配
    try expectStrBoth(allocator, &env,
        \\(let [{:strs [name]} {"name" "Bob"}] name)
    , "Bob");

    // fn 引数でのマップ分配
    try expectIntBoth(allocator, &env,
        \\((fn [{:keys [x y]}] (+ x y)) {:x 3 :y 4})
    , 7);

    // fn 引数: 通常パラメータとマップ分配の混合
    try expectIntBoth(allocator, &env,
        \\((fn [z {:keys [x y]}] (+ z x y)) 10 {:x 3 :y 4})
    , 17);
}

test "compare: sequence operations" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // map
    try expectIntBoth(allocator, &env, "(count (map inc [1 2 3]))", 3);
    try expectIntBoth(allocator, &env, "(first (map inc [1 2 3]))", 2);
    try expectIntBoth(allocator, &env,
        \\(reduce + 0 (map inc [1 2 3]))
    , 9);
    try expectIntBoth(allocator, &env,
        \\(reduce + 0 (map (fn [x] (* x x)) [1 2 3]))
    , 14);

    // filter
    try expectIntBoth(allocator, &env,
        \\(count (filter (fn [x] (> x 2)) [1 2 3 4 5]))
    , 3);
    try expectIntBoth(allocator, &env,
        \\(reduce + 0 (filter (fn [x] (> x 2)) [1 2 3 4 5]))
    , 12);

    // map + filter チェーン
    try expectIntBoth(allocator, &env,
        \\(reduce + 0 (map inc (filter (fn [x] (> x 2)) [1 2 3 4 5])))
    , 15);

    // take
    try expectIntBoth(allocator, &env, "(count (take 3 [1 2 3 4 5]))", 3);
    try expectIntBoth(allocator, &env, "(first (take 3 [1 2 3 4 5]))", 1);

    // drop
    try expectIntBoth(allocator, &env, "(count (drop 2 [1 2 3 4 5]))", 3);
    try expectIntBoth(allocator, &env, "(first (drop 2 [1 2 3 4 5]))", 3);

    // range
    try expectIntBoth(allocator, &env, "(count (range 5))", 5);
    try expectIntBoth(allocator, &env, "(first (range 5))", 0);
    try expectIntBoth(allocator, &env, "(count (range 2 8))", 6);
    try expectIntBoth(allocator, &env, "(count (range 0 10 3))", 4);

    // concat
    try expectIntBoth(allocator, &env, "(count (concat [1 2] [3 4] [5]))", 5);
    try expectIntBoth(allocator, &env, "(first (concat [10] [20]))", 10);

    // reverse
    try expectIntBoth(allocator, &env, "(first (reverse [1 2 3 4]))", 4);

    // seq
    try expectNilBoth(allocator, &env, "(seq [])");
    try expectIntBoth(allocator, &env, "(first (seq [1 2 3]))", 1);

    // vec
    try expectIntBoth(allocator, &env, "(count (vec (list 1 2 3)))", 3);

    // repeat
    try expectIntBoth(allocator, &env, "(count (repeat 5 :x))", 5);

    // distinct
    try expectIntBoth(allocator, &env, "(count (distinct [1 2 1 3 2 4]))", 4);

    // flatten
    try expectIntBoth(allocator, &env, "(count (flatten [[1 2] [3 4] [5]]))", 5);

    // into
    try expectIntBoth(allocator, &env, "(count (into [] (list 1 2 3)))", 3);

    // 複合テスト: take + map + range
    try expectIntBoth(allocator, &env,
        \\(reduce + 0 (take 3 (map inc (range 10))))
    , 6);

    // 複合テスト: reduce + filter + range
    try expectIntBoth(allocator, &env,
        \\(reduce + 0 (filter (fn [x] (> x 5)) (range 10)))
    , 30);
}

// ============================================================
// Phase 8.5: 制御フローマクロ・スレッディングマクロ・ユーティリティ関数
// ============================================================

test "compare: control flow macros" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // cond
    try expectIntBoth(allocator, &env, "(cond true 1 true 2)", 1);
    try expectIntBoth(allocator, &env, "(cond false 1 true 2)", 2);
    try expectNilBoth(allocator, &env, "(cond false 1 false 2)");

    // when / when-not
    try expectIntBoth(allocator, &env, "(when true 42)", 42);
    try expectNilBoth(allocator, &env, "(when false 42)");
    try expectIntBoth(allocator, &env, "(when-not false 42)", 42);
    try expectNilBoth(allocator, &env, "(when-not true 42)");

    // if-let
    try expectIntBoth(allocator, &env, "(if-let [x 1] x 0)", 1);
    try expectIntBoth(allocator, &env, "(if-let [x nil] x 0)", 0);

    // when-let
    try expectIntBoth(allocator, &env, "(when-let [x 10] x)", 10);
    try expectNilBoth(allocator, &env, "(when-let [x nil] x)");

    // and
    try expectBoolBoth(allocator, &env, "(and true true)", true);
    try expectBoolBoth(allocator, &env, "(and true false)", false);
    try expectBoolBoth(allocator, &env, "(and false true)", false);
    try expectIntBoth(allocator, &env, "(and 1 2 3)", 3);

    // or
    try expectIntBoth(allocator, &env, "(or nil 2 3)", 2);
    try expectIntBoth(allocator, &env, "(or 1 2)", 1);
    try expectNilBoth(allocator, &env, "(or nil nil)");
}

test "compare: threading macros" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // -> (thread-first)
    try expectIntBoth(allocator, &env, "(-> 5 inc inc)", 7);
    try expectIntBoth(allocator, &env, "(-> 10 (- 3))", 7);

    // ->> (thread-last)
    try expectIntBoth(allocator, &env, "(->> 5 (+ 3))", 8);
    try expectIntBoth(allocator, &env,
        \\(->> (range 5) (map inc) (reduce + 0))
    , 15);
}

test "compare: utility functions" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // not=
    try expectBoolBoth(allocator, &env, "(not= 1 2)", true);
    try expectBoolBoth(allocator, &env, "(not= 1 1)", false);

    // identity
    try expectIntBoth(allocator, &env, "(identity 42)", 42);

    // some?
    try expectBoolBoth(allocator, &env, "(some? 1)", true);
    try expectBoolBoth(allocator, &env, "(some? nil)", false);

    // 数値述語
    try expectBoolBoth(allocator, &env, "(zero? 0)", true);
    try expectBoolBoth(allocator, &env, "(zero? 1)", false);
    try expectBoolBoth(allocator, &env, "(pos? 5)", true);
    try expectBoolBoth(allocator, &env, "(pos? -1)", false);
    try expectBoolBoth(allocator, &env, "(neg? -3)", true);
    try expectBoolBoth(allocator, &env, "(neg? 0)", false);
    try expectBoolBoth(allocator, &env, "(even? 4)", true);
    try expectBoolBoth(allocator, &env, "(even? 3)", false);
    try expectBoolBoth(allocator, &env, "(odd? 3)", true);
    try expectBoolBoth(allocator, &env, "(odd? 4)", false);

    // max / min
    try expectIntBoth(allocator, &env, "(max 3 7 2)", 7);
    try expectIntBoth(allocator, &env, "(min 3 7 2)", 2);

    // abs
    try expectIntBoth(allocator, &env, "(abs -5)", 5);
    try expectIntBoth(allocator, &env, "(abs 3)", 3);

    // mod
    try expectIntBoth(allocator, &env, "(mod 10 3)", 1);
    try expectIntBoth(allocator, &env, "(mod 9 3)", 0);
}

// ============================================================
// Phase 8.6: 例外処理
// ============================================================

test "compare: try/catch 基本" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // throw + catch
    try expectIntBoth(allocator, &env,
        \\(try (throw (ex-info "err" {})) (catch Exception e 42))
    , 42);

    // ex-message
    try expectStrBoth(allocator, &env,
        \\(try (throw (ex-info "hello" {})) (catch Exception e (ex-message e)))
    , "hello");

    // ex-data
    try expectIntBoth(allocator, &env,
        \\(try (throw (ex-info "err" {:code 42})) (catch Exception e (:code (ex-data e))))
    , 42);

    // body 正常時は catch をスキップ
    try expectIntBoth(allocator, &env,
        \\(try 99 (catch Exception e 0))
    , 99);

    // 内部エラー（DivisionByZero）を catch
    try expectIntBoth(allocator, &env,
        \\(try (/ 1 0) (catch Exception e 42))
    , 42);

    // 内部エラーの :type を取得
    try expectKwBoth(allocator, &env,
        \\(try (/ 1 0) (catch Exception e (:type e)))
    , "division-by-zero");

    // try + finally（正常時）
    try expectIntBoth(allocator, &env,
        \\(try 42 (finally (+ 1 2)))
    , 42);
}

// ============================================================
// Phase 8.7: Atom
// ============================================================

test "compare: atom 基本" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // atom? 述語
    try expectBoolBoth(allocator, &env, "(atom? (atom 0))", true);
    try expectBoolBoth(allocator, &env, "(atom? 42)", false);

    // deref
    try expectIntBoth(allocator, &env, "(deref (atom 10))", 10);

    // atom + deref
    try expectIntBoth(allocator, &env, "(let [a (atom 0)] (deref a))", 0);
}

// ============================================================
// Phase 8.8: 文字列操作拡充
// ============================================================

test "compare: string operations" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // subs
    try expectStrBoth(allocator, &env,
        \\(subs "hello" 1)
    , "ello");
    try expectStrBoth(allocator, &env,
        \\(subs "hello" 1 3)
    , "el");

    // name
    try expectStrBoth(allocator, &env, "(name :foo)", "foo");
    try expectStrBoth(allocator, &env,
        \\(name "bar")
    , "bar");

    // upper-case / lower-case
    try expectStrBoth(allocator, &env,
        \\(upper-case "hello")
    , "HELLO");
    try expectStrBoth(allocator, &env,
        \\(lower-case "WORLD")
    , "world");

    // trim
    try expectStrBoth(allocator, &env,
        \\(trim "  hi  ")
    , "hi");

    // blank?
    try expectBoolBoth(allocator, &env,
        \\(blank? "")
    , true);
    try expectBoolBoth(allocator, &env,
        \\(blank? "  ")
    , true);
    try expectBoolBoth(allocator, &env,
        \\(blank? "x")
    , false);

    // starts-with? / ends-with? / includes?
    try expectBoolBoth(allocator, &env,
        \\(starts-with? "hello" "he")
    , true);
    try expectBoolBoth(allocator, &env,
        \\(starts-with? "hello" "lo")
    , false);
    try expectBoolBoth(allocator, &env,
        \\(ends-with? "hello" "lo")
    , true);
    try expectBoolBoth(allocator, &env,
        \\(ends-with? "hello" "he")
    , false);
    try expectBoolBoth(allocator, &env,
        \\(includes? "hello world" "lo wo")
    , true);
    try expectBoolBoth(allocator, &env,
        \\(includes? "hello" "xyz")
    , false);
}

// ============================================================
// Phase 8.9: defn・追加マクロ
// ============================================================

test "compare: defn macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // if-not（マクロ展開のみ、def不要）
    try expectIntBoth(allocator, &env, "(if-not false 1 2)", 1);
    try expectIntBoth(allocator, &env, "(if-not true 1 2)", 2);

    // defn（TreeWalkで定義、TreeWalkのみで検証）
    _ = try evalExpr(allocator, &env, "(defn double [x] (* x 2))");
    try expectInt(allocator, &env, "(double 5)", 10);

    // defn + docstring
    _ = try evalExpr(allocator, &env,
        \\(defn greet "Greets someone" [name] (str "Hello " name))
    );
    const greet_result = try evalExpr(allocator, &env,
        \\(greet "World")
    );
    switch (greet_result) {
        .string => |s| try std.testing.expectEqualStrings("Hello World", s.data),
        else => return error.UnexpectedValue,
    }
}

// ============================================================
// Phase 8.10: condp・case・some->・mapv・filterv
// ============================================================

test "compare: condp and case" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // condp
    try expectStrBoth(allocator, &env,
        \\(condp = 2
        \\  1 "one"
        \\  2 "two"
        \\  3 "three")
    , "two");

    // case
    try expectStrBoth(allocator, &env,
        \\(case 2
        \\  1 "one"
        \\  2 "two"
        \\  "default")
    , "two");
    try expectStrBoth(allocator, &env,
        \\(case 99
        \\  1 "one"
        \\  2 "two"
        \\  "default")
    , "default");
}

test "compare: some-> some->> as->" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // some->
    try expectIntBoth(allocator, &env, "(some-> 1 inc inc)", 3);
    try expectNilBoth(allocator, &env, "(some-> nil inc)");

    // some->>
    try expectIntBoth(allocator, &env, "(some->> 5 (+ 3))", 8);
    try expectNilBoth(allocator, &env, "(some->> nil (+ 3))");

    // as->
    try expectIntBoth(allocator, &env, "(as-> 0 x (inc x) (+ x 3))", 4);
}

test "compare: mapv filterv" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // mapv はベクターを返す
    try expectIntBoth(allocator, &env, "(count (mapv inc [1 2 3]))", 3);
    try expectIntBoth(allocator, &env, "(first (mapv inc [1 2 3]))", 2);

    // filterv はベクターを返す
    try expectIntBoth(allocator, &env,
        \\(count (filterv (fn [x] (> x 2)) [1 2 3 4 5]))
    , 3);
}

// ============================================================
// Phase 8.11: キーワードを関数として使用
// ============================================================

test "compare: keyword as function" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // (:key map) → 値
    try expectIntBoth(allocator, &env, "(:a {:a 1 :b 2})", 1);
    try expectIntBoth(allocator, &env, "(:b {:a 1 :b 2})", 2);

    // (:key map default)
    try expectIntBoth(allocator, &env, "(:c {:a 1 :b 2} 99)", 99);

    // 存在しないキーで default なし → nil
    try expectNilBoth(allocator, &env, "(:z {:a 1})");
}

// ============================================================
// Phase 8.12: 述語関数
// ============================================================

test "compare: predicate functions" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // every?
    try expectBoolBoth(allocator, &env,
        \\(every? (fn [x] (> x 0)) [1 2 3])
    , true);
    try expectBoolBoth(allocator, &env,
        \\(every? (fn [x] (> x 0)) [1 -2 3])
    , false);

    // not-every?
    try expectBoolBoth(allocator, &env,
        \\(not-every? (fn [x] (> x 0)) [1 2 3])
    , false);
    try expectBoolBoth(allocator, &env,
        \\(not-every? (fn [x] (> x 0)) [1 -2 3])
    , true);

    // some（述語版: 最初の truthy な結果を返す）
    try expectBoolBoth(allocator, &env,
        \\(some (fn [x] (> x 3)) [1 2 3 4 5])
    , true);
    try expectNilBoth(allocator, &env,
        \\(some (fn [x] (> x 10)) [1 2 3])
    );

    // not-any?
    try expectBoolBoth(allocator, &env,
        \\(not-any? (fn [x] (> x 10)) [1 2 3])
    , true);
    try expectBoolBoth(allocator, &env,
        \\(not-any? (fn [x] (> x 2)) [1 2 3])
    , false);
}

// ============================================================
// Phase 8.13: バグ修正検証
// ============================================================

test "compare: error type preservation" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // DivisionByZero はキャッチ後に型が保全される
    try expectKwBoth(allocator, &env,
        \\(try (/ 1 0) (catch Exception e (:type e)))
    , "division-by-zero");

    // ArityError
    try expectKwBoth(allocator, &env,
        \\(try (inc) (catch Exception e (:type e)))
    , "arity-error");
}

test "compare: comp identity" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // (comp) は identity を返す
    try expectIntBoth(allocator, &env, "((comp) 42)", 42);
    try expectStrBoth(allocator, &env,
        \\((comp) "hello")
    , "hello");
}

// ============================================================
// マルチメソッド (defmulti / defmethod)
// ============================================================

test "compare: defmulti/defmethod keyword dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // defmulti + defmethod 基本（do で一括評価して各バックエンドが自前の MultiFn を持つ）
    try expectIntBoth(allocator, &env,
        \\(do (defmulti f (fn [x] (:t x)))
        \\    (defmethod f :a [x] 1)
        \\    (defmethod f :b [x] 2)
        \\    (f {:t :a}))
    , 1);
}

test "compare: defmulti/defmethod second dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectIntBoth(allocator, &env,
        \\(do (defmulti f2 (fn [x] (:t x)))
        \\    (defmethod f2 :a [x] 1)
        \\    (defmethod f2 :b [x] 2)
        \\    (f2 {:t :b}))
    , 2);
}

test "compare: defmulti/defmethod default" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // :default メソッドにフォールバック
    try expectIntBoth(allocator, &env,
        \\(do (defmulti g (fn [x] (:t x)))
        \\    (defmethod g :a [x] 10)
        \\    (defmethod g :default [x] 99)
        \\    (g {:t :z}))
    , 99);
}

test "compare: defmulti/defmethod default match" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // :default がある場合でも通常マッチが優先
    try expectIntBoth(allocator, &env,
        \\(do (defmulti g2 (fn [x] (:t x)))
        \\    (defmethod g2 :a [x] 10)
        \\    (defmethod g2 :default [x] 99)
        \\    (g2 {:t :a}))
    , 10);
}

test "compare: defmulti/defmethod with str" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // 文字列を返すマルチメソッド
    try expectStrBoth(allocator, &env,
        \\(do (defmulti greet (fn [p] (:lang p)))
        \\    (defmethod greet :english [p] (str "Hello, " (:name p)))
        \\    (defmethod greet :default [p] (str "Hi, " (:name p)))
        \\    (greet {:name "Alice" :lang :english}))
    , "Hello, Alice");
}

test "compare: defmulti/defmethod default str" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // :default にフォールバック
    try expectStrBoth(allocator, &env,
        \\(do (defmulti greet2 (fn [p] (:lang p)))
        \\    (defmethod greet2 :english [p] (str "Hello, " (:name p)))
        \\    (defmethod greet2 :default [p] (str "Hi, " (:name p)))
        \\    (greet2 {:name "Bob" :lang :french}))
    , "Hi, Bob");
}

test "compare: defmulti/defmethod multiple dispatch values" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // 複数のディスパッチ値を持つマルチメソッド
    try expectIntBoth(allocator, &env,
        \\(do (defmulti area (fn [shape] (:type shape)))
        \\    (defmethod area :circle [s] (* 3 (* (:r s) (:r s))))
        \\    (defmethod area :rect [s] (* (:w s) (:h s)))
        \\    (area {:type :circle :r 2}))
    , 12);
}

test "compare: defmulti/defmethod rect" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectIntBoth(allocator, &env,
        \\(do (defmulti area2 (fn [shape] (:type shape)))
        \\    (defmethod area2 :circle [s] (* 3 (* (:r s) (:r s))))
        \\    (defmethod area2 :rect [s] (* (:w s) (:h s)))
        \\    (area2 {:type :rect :w 3 :h 4}))
    , 12);
}

// ============================================================
// プロトコル (defprotocol / extend-type / extend-protocol)
// ============================================================

test "compare: defprotocol + extend-type basic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // 基本: defprotocol + extend-type + メソッド呼び出し
    try expectStrBoth(allocator, &env,
        \\(do (defprotocol IFoo (foo [this]))
        \\    (extend-type String IFoo
        \\      (foo [this] (str "foo:" this)))
        \\    (foo "bar"))
    , "foo:bar");
}

test "compare: protocol multiple methods" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // 1つのプロトコルに複数メソッド
    try expectIntBoth(allocator, &env,
        \\(do (defprotocol IMath (add1 [this]) (double [this]))
        \\    (extend-type Integer IMath
        \\      (add1 [this] (+ this 1))
        \\      (double [this] (* this 2)))
        \\    (add1 10))
    , 11);
}

test "compare: protocol multiple methods second" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectIntBoth(allocator, &env,
        \\(do (defprotocol IMath2 (add1 [this]) (double [this]))
        \\    (extend-type Integer IMath2
        \\      (add1 [this] (+ this 1))
        \\      (double [this] (* this 2)))
        \\    (double 5))
    , 10);
}

test "compare: protocol multiple types" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // 同じプロトコルを異なる型に extend
    try expectStrBoth(allocator, &env,
        \\(do (defprotocol IGreet (greet [this]))
        \\    (extend-type String IGreet
        \\      (greet [this] (str "Hello, " this)))
        \\    (extend-type Integer IGreet
        \\      (greet [this] (str "Number: " this)))
        \\    (greet "World"))
    , "Hello, World");
}

test "compare: protocol multiple types integer" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectStrBoth(allocator, &env,
        \\(do (defprotocol IGreet2 (greet [this]))
        \\    (extend-type String IGreet2
        \\      (greet [this] (str "Hello, " this)))
        \\    (extend-type Integer IGreet2
        \\      (greet [this] (str "Number: " this)))
        \\    (greet 42))
    , "Number: 42");
}

test "compare: extend-protocol macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // extend-protocol マクロによる一括拡張
    try expectStrBoth(allocator, &env,
        \\(do (defprotocol IShow (show [this]))
        \\    (extend-protocol IShow
        \\      String (show [this] (str "S:" this))
        \\      Integer (show [this] (str "I:" this)))
        \\    (show "hi"))
    , "S:hi");
}

test "compare: extend-protocol macro integer" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectStrBoth(allocator, &env,
        \\(do (defprotocol IShow2 (show [this]))
        \\    (extend-protocol IShow2
        \\      String (show [this] (str "S:" this))
        \\      Integer (show [this] (str "I:" this)))
        \\    (show 7))
    , "I:7");
}

test "compare: satisfies? true" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // satisfies? で型チェック
    try expectBoolBoth(allocator, &env,
        \\(do (defprotocol ICheck (check [this]))
        \\    (extend-type String ICheck
        \\      (check [this] this))
        \\    (satisfies? ICheck "hello"))
    , true);
}

test "compare: satisfies? false" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectBoolBoth(allocator, &env,
        \\(do (defprotocol ICheck2 (check [this]))
        \\    (extend-type String ICheck2
        \\      (check [this] this))
        \\    (satisfies? ICheck2 42))
    , false);
}

test "compare: protocol method with extra arg" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // this 以外の引数を持つメソッド
    try expectStrBoth(allocator, &env,
        \\(do (defprotocol IGreetWith (greet-with [this name]))
        \\    (extend-type String IGreetWith
        \\      (greet-with [this name] (str name " says hi to " this)))
        \\    (greet-with "World" "Alice"))
    , "Alice says hi to World");
}

// ============================================================
// Phase 8.16: ユーティリティ関数・高階関数・マクロ
// ============================================================

test "compare: merge" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    // 基本の merge
    try expectStrBoth(allocator, &env, "(pr-str (merge {:a 1} {:b 2}))", "{:a 1, :b 2}");
    // 後勝ち
    try expectStrBoth(allocator, &env, "(pr-str (merge {:a 1} {:a 2}))", "{:a 2}");
    // nil スキップ
    try expectStrBoth(allocator, &env, "(pr-str (merge {:a 1} nil {:b 2}))", "{:a 1, :b 2}");
    // 引数なし
    try expectNilBoth(allocator, &env, "(merge)");
}

test "compare: get-in" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectIntBoth(allocator, &env, "(get-in {:a {:b 42}} [:a :b])", 42);
    try expectKwBoth(allocator, &env, "(get-in {:a 1} [:b] :default)", "default");
    try expectNilBoth(allocator, &env, "(get-in {:a 1} [:b])");
}

test "compare: assoc-in" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectStrBoth(allocator, &env, "(pr-str (assoc-in {} [:a :b] 1))", "{:a {:b 1}}");
    try expectStrBoth(allocator, &env, "(pr-str (assoc-in {:a {:b 1}} [:a :b] 2))", "{:a {:b 2}}");
}

test "compare: select-keys" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectStrBoth(allocator, &env, "(pr-str (select-keys {:a 1 :b 2 :c 3} [:a :c]))", "{:a 1, :c 3}");
}

test "compare: zipmap" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectStrBoth(allocator, &env, "(pr-str (zipmap [:a :b] [1 2]))", "{:a 1, :b 2}");
    // 短い方に合わせる
    try expectStrBoth(allocator, &env, "(pr-str (zipmap [:a :b :c] [1 2]))", "{:a 1, :b 2}");
}

test "compare: not-empty" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectNilBoth(allocator, &env, "(not-empty [])");
    try expectStrBoth(allocator, &env, "(pr-str (not-empty [1]))", "[1]");
    try expectNilBoth(allocator, &env, "(not-empty nil)");
}

test "compare: type function" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectStrBoth(allocator, &env, "(type 42)", "integer");
    try expectStrBoth(allocator, &env, "(type \"hi\")", "string");
    try expectStrBoth(allocator, &env, "(type :foo)", "keyword");
    try expectStrBoth(allocator, &env, "(type nil)", "nil");
    try expectStrBoth(allocator, &env, "(type true)", "boolean");
    try expectStrBoth(allocator, &env, "(type [1 2])", "vector");
}

test "compare: take-while" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectStrBoth(allocator, &env, "(pr-str (take-while pos? [3 2 1 0 -1]))", "(3 2 1)");
    try expectStrBoth(allocator, &env, "(pr-str (take-while pos? []))", "()");
    try expectStrBoth(allocator, &env, "(pr-str (take-while pos? [-1 2 3]))", "()");
}

test "compare: drop-while" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectStrBoth(allocator, &env, "(pr-str (drop-while pos? [3 2 1 0 -1]))", "(0 -1)");
    try expectStrBoth(allocator, &env, "(pr-str (drop-while pos? []))", "()");
    try expectStrBoth(allocator, &env, "(pr-str (drop-while pos? [-1 2 3]))", "(-1 2 3)");
}

test "compare: map-indexed" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectStrBoth(allocator, &env, "(pr-str (map-indexed (fn [i x] (+ i x)) [10 20 30]))", "(10 21 32)");
    try expectStrBoth(allocator, &env, "(pr-str (map-indexed (fn [i x] i) [:a :b :c]))", "(0 1 2)");
}

test "compare: update macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectStrBoth(allocator, &env, "(pr-str (update {:a 1} :a inc))", "{:a 2}");
    try expectStrBoth(allocator, &env, "(pr-str (update {:a 1} :a + 10))", "{:a 11}");
}

test "compare: complement macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectBoolBoth(allocator, &env, "(do (def not-pos? (complement pos?)) (not-pos? -1))", true);
    try expectBoolBoth(allocator, &env, "(do (def not-pos? (complement pos?)) (not-pos? 1))", false);
}

test "compare: constantly macro" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env = try setupTestEnv(allocator);
    defer env.deinit();

    try expectStrBoth(allocator, &env, "(pr-str (map (constantly 0) [1 2 3]))", "(0 0 0)");
    try expectIntBoth(allocator, &env, "((constantly 42) 1 2 3)", 42);
}
