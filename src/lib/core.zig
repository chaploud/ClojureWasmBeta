//! clojure.core 組み込み関数
//!
//! Clojure標準ライブラリの中核関数群。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md

const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const Fn = value_mod.Fn;
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;

/// 組み込み関数の型（value.zig との循環依存を避けるためここで定義）
pub const BuiltinFn = *const fn (allocator: std.mem.Allocator, args: []const Value) anyerror!Value;

/// 組み込み関数エラー
pub const CoreError = error{
    TypeError,
    ArityError,
    DivisionByZero,
    OutOfMemory,
};

// ============================================================
// 算術演算
// ============================================================

/// + : 可変長引数の加算
pub fn add(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    var result: i64 = 0;
    var has_float = false;
    var float_result: f64 = 0.0;

    for (args) |arg| {
        switch (arg) {
            .int => |n| {
                if (has_float) {
                    float_result += @as(f64, @floatFromInt(n));
                } else {
                    result += n;
                }
            },
            .float => |f| {
                if (!has_float) {
                    float_result = @as(f64, @floatFromInt(result));
                    has_float = true;
                }
                float_result += f;
            },
            else => return error.TypeError,
        }
    }

    if (has_float) {
        return Value{ .float = float_result };
    }
    return Value{ .int = result };
}

/// - : 減算
pub fn sub(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len == 0) return error.ArityError;

    var has_float = false;
    var result: i64 = 0;
    var float_result: f64 = 0.0;

    // 最初の引数
    switch (args[0]) {
        .int => |n| result = n,
        .float => |f| {
            float_result = f;
            has_float = true;
        },
        else => return error.TypeError,
    }

    // 単項マイナス
    if (args.len == 1) {
        if (has_float) {
            return Value{ .float = -float_result };
        }
        return Value{ .int = -result };
    }

    // 残りの引数を減算
    for (args[1..]) |arg| {
        switch (arg) {
            .int => |n| {
                if (has_float) {
                    float_result -= @as(f64, @floatFromInt(n));
                } else {
                    result -= n;
                }
            },
            .float => |f| {
                if (!has_float) {
                    float_result = @as(f64, @floatFromInt(result));
                    has_float = true;
                }
                float_result -= f;
            },
            else => return error.TypeError,
        }
    }

    if (has_float) {
        return Value{ .float = float_result };
    }
    return Value{ .int = result };
}

/// * : 乗算
pub fn mul(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    var result: i64 = 1;
    var has_float = false;
    var float_result: f64 = 1.0;

    for (args) |arg| {
        switch (arg) {
            .int => |n| {
                if (has_float) {
                    float_result *= @as(f64, @floatFromInt(n));
                } else {
                    result *= n;
                }
            },
            .float => |f| {
                if (!has_float) {
                    float_result = @as(f64, @floatFromInt(result));
                    has_float = true;
                }
                float_result *= f;
            },
            else => return error.TypeError,
        }
    }

    if (has_float) {
        return Value{ .float = float_result };
    }
    return Value{ .int = result };
}

/// / : 除算（常に float を返す）
pub fn div(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len == 0) return error.ArityError;

    // 最初の引数を取得
    var result: f64 = switch (args[0]) {
        .int => |n| @as(f64, @floatFromInt(n)),
        .float => |f| f,
        else => return error.TypeError,
    };

    // 単項 (/ x) は 1/x
    if (args.len == 1) {
        if (result == 0.0) return error.DivisionByZero;
        return Value{ .float = 1.0 / result };
    }

    // 残りの引数で除算
    for (args[1..]) |arg| {
        const divisor: f64 = switch (arg) {
            .int => |n| @as(f64, @floatFromInt(n)),
            .float => |f| f,
            else => return error.TypeError,
        };
        if (divisor == 0.0) return error.DivisionByZero;
        result /= divisor;
    }

    return Value{ .float = result };
}

/// inc : 1加算
pub fn inc(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .int => |n| Value{ .int = n + 1 },
        .float => |f| Value{ .float = f + 1.0 },
        else => error.TypeError,
    };
}

/// dec : 1減算
pub fn dec(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .int => |n| Value{ .int = n - 1 },
        .float => |f| Value{ .float = f - 1.0 },
        else => error.TypeError,
    };
}

// ============================================================
// 比較演算
// ============================================================

/// = : 等価比較
pub fn eq(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) return error.ArityError;

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        if (!a.eql(b)) {
            return value_mod.false_val;
        }
    }
    return value_mod.true_val;
}

/// < : 小なり
pub fn lt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) return error.ArityError;

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        const cmp = try compareNumbers(a, b);
        if (cmp >= 0) return value_mod.false_val;
    }
    return value_mod.true_val;
}

/// > : 大なり
pub fn gt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) return error.ArityError;

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        const cmp = try compareNumbers(a, b);
        if (cmp <= 0) return value_mod.false_val;
    }
    return value_mod.true_val;
}

/// <= : 小なりイコール
pub fn lte(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) return error.ArityError;

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        const cmp = try compareNumbers(a, b);
        if (cmp > 0) return value_mod.false_val;
    }
    return value_mod.true_val;
}

/// >= : 大なりイコール
pub fn gte(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) return error.ArityError;

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        const cmp = try compareNumbers(a, b);
        if (cmp < 0) return value_mod.false_val;
    }
    return value_mod.true_val;
}

/// 数値比較ヘルパー（-1, 0, 1 を返す）
fn compareNumbers(a: Value, b: Value) CoreError!i8 {
    const fa: f64 = switch (a) {
        .int => |n| @as(f64, @floatFromInt(n)),
        .float => |f| f,
        else => return error.TypeError,
    };
    const fb: f64 = switch (b) {
        .int => |n| @as(f64, @floatFromInt(n)),
        .float => |f| f,
        else => return error.TypeError,
    };

    if (fa < fb) return -1;
    if (fa > fb) return 1;
    return 0;
}

// ============================================================
// 論理演算
// ============================================================

/// not : 論理否定（nil と false が truthy でない）
pub fn notFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    // nil と false が falsy、それ以外は truthy
    return switch (args[0]) {
        .nil => value_mod.true_val,
        .bool_val => |b| if (b) value_mod.false_val else value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// not= : 等しくないかどうか
pub fn notEq(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    return if (args[0].eql(args[1])) value_mod.false_val else value_mod.true_val;
}

/// identity : 引数をそのまま返す
pub fn identity(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return args[0];
}

/// some? : nil でないかどうか
pub fn isSome(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0].isNil()) value_mod.false_val else value_mod.true_val;
}

/// zero? : 0 かどうか
pub fn isZero(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| if (n == 0) value_mod.true_val else value_mod.false_val,
        .float => |n| if (n == 0.0) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// pos? : 正数かどうか
pub fn isPos(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| if (n > 0) value_mod.true_val else value_mod.false_val,
        .float => |n| if (n > 0.0) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// neg? : 負数かどうか
pub fn isNeg(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| if (n < 0) value_mod.true_val else value_mod.false_val,
        .float => |n| if (n < 0.0) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// even? : 偶数かどうか
pub fn isEven(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| if (@mod(n, 2) == 0) value_mod.true_val else value_mod.false_val,
        else => error.TypeError,
    };
}

/// odd? : 奇数かどうか
pub fn isOdd(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| if (@mod(n, 2) != 0) value_mod.true_val else value_mod.false_val,
        else => error.TypeError,
    };
}

/// max : 最大値
pub fn max(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1) return error.ArityError;
    var result = args[0];
    for (args[1..]) |arg| {
        const is_less = switch (result) {
            .int => |a| switch (arg) {
                .int => |b| a < b,
                .float => |b| @as(f64, @floatFromInt(a)) < b,
                else => return error.TypeError,
            },
            .float => |a| switch (arg) {
                .int => |b| a < @as(f64, @floatFromInt(b)),
                .float => |b| a < b,
                else => return error.TypeError,
            },
            else => return error.TypeError,
        };
        if (is_less) result = arg;
    }
    return result;
}

/// min : 最小値
pub fn min(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1) return error.ArityError;
    var result = args[0];
    for (args[1..]) |arg| {
        const is_greater = switch (result) {
            .int => |a| switch (arg) {
                .int => |b| a > b,
                .float => |b| @as(f64, @floatFromInt(a)) > b,
                else => return error.TypeError,
            },
            .float => |a| switch (arg) {
                .int => |b| a > @as(f64, @floatFromInt(b)),
                .float => |b| a > b,
                else => return error.TypeError,
            },
            else => return error.TypeError,
        };
        if (is_greater) result = arg;
    }
    return result;
}

/// abs : 絶対値
pub fn abs(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| value_mod.intVal(if (n < 0) -n else n),
        .float => |n| value_mod.floatVal(@abs(n)),
        else => error.TypeError,
    };
}

/// mod : 剰余
pub fn modFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const a = args[0].int;
    const b = args[1].int;
    if (b == 0) return error.DivisionByZero;
    return value_mod.intVal(@mod(a, b));
}

// ============================================================
// 述語
// ============================================================

/// nil? : nil かどうか
pub fn isNil(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .nil => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// number? : 数値かどうか
pub fn isNumber(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .int, .float => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// integer? : 整数かどうか
pub fn isInteger(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .int => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// float? : 浮動小数点かどうか
pub fn isFloat(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .float => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// string? : 文字列かどうか
pub fn isString(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .string => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// keyword? : キーワードかどうか
pub fn isKeyword(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .keyword => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// symbol? : シンボルかどうか
pub fn isSymbol(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .symbol => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// fn? : 関数かどうか
pub fn isFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .fn_val => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// coll? : コレクションかどうか
pub fn isColl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .list, .vector, .map, .set => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// list? : リストかどうか
pub fn isList(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .list => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// vector? : ベクタかどうか
pub fn isVector(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .vector => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// map? : マップかどうか
pub fn isMap(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .map => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// set? : セットかどうか
pub fn isSet(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .set => value_mod.true_val,
        else => value_mod.false_val,
    };
}

// ============================================================
// コンストラクタ
// ============================================================

/// list : 引数からリストを作成
pub fn list(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    const items = allocator.alloc(Value, args.len) catch return error.OutOfMemory;
    @memcpy(items, args);

    const lst = allocator.create(value_mod.PersistentList) catch return error.OutOfMemory;
    lst.* = .{ .items = items };

    return Value{ .list = lst };
}

/// vector : 引数からベクタを作成
pub fn vector(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    const items = allocator.alloc(Value, args.len) catch return error.OutOfMemory;
    @memcpy(items, args);

    const vec = allocator.create(value_mod.PersistentVector) catch return error.OutOfMemory;
    vec.* = .{ .items = items };

    return Value{ .vector = vec };
}

// ============================================================
// コレクション操作
// ============================================================

/// first : コレクションの最初の要素
pub fn first(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .nil => value_mod.nil,
        .list => |l| if (l.items.len > 0) l.items[0] else value_mod.nil,
        .vector => |v| if (v.items.len > 0) v.items[0] else value_mod.nil,
        else => error.TypeError,
    };
}

/// rest : コレクションの最初以外
pub fn rest(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .nil => Value{ .list = try value_mod.PersistentList.empty(allocator) },
        .list => |l| blk: {
            if (l.items.len <= 1) {
                break :blk Value{ .list = try value_mod.PersistentList.empty(allocator) };
            }
            break :blk Value{ .list = try value_mod.PersistentList.fromSlice(allocator, l.items[1..]) };
        },
        .vector => |v| blk: {
            if (v.items.len <= 1) {
                break :blk Value{ .list = try value_mod.PersistentList.empty(allocator) };
            }
            break :blk Value{ .list = try value_mod.PersistentList.fromSlice(allocator, v.items[1..]) };
        },
        else => error.TypeError,
    };
}

/// cons : 先頭に要素を追加
pub fn cons(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;

    const elem = args[0];
    const coll = args[1];

    // コレクションの要素を取得
    const items: []const Value = switch (coll) {
        .nil => &[_]Value{},
        .list => |l| l.items,
        .vector => |v| v.items,
        else => return error.TypeError,
    };

    // 新しいリストを作成
    const new_items = try allocator.alloc(Value, items.len + 1);
    new_items[0] = elem;
    @memcpy(new_items[1..], items);

    const new_list = try allocator.create(value_mod.PersistentList);
    new_list.* = .{ .items = new_items };
    return Value{ .list = new_list };
}

/// conj : コレクションに要素を追加（型に応じた位置）
pub fn conj(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;

    const coll = args[0];
    const elems = args[1..];

    switch (coll) {
        .nil => {
            // nil は空リストとして扱う
            const new_list = try allocator.create(value_mod.PersistentList);
            const items = try allocator.alloc(Value, elems.len);
            // リストは逆順で追加
            for (elems, 0..) |e, i| {
                items[elems.len - 1 - i] = e;
            }
            new_list.* = .{ .items = items };
            return Value{ .list = new_list };
        },
        .list => |l| {
            // リストは先頭に追加
            const new_items = try allocator.alloc(Value, l.items.len + elems.len);
            // 新しい要素を先頭に（逆順で）
            for (elems, 0..) |e, i| {
                new_items[elems.len - 1 - i] = e;
            }
            @memcpy(new_items[elems.len..], l.items);

            const new_list = try allocator.create(value_mod.PersistentList);
            new_list.* = .{ .items = new_items };
            return Value{ .list = new_list };
        },
        .vector => |v| {
            // ベクタは末尾に追加
            const new_items = try allocator.alloc(Value, v.items.len + elems.len);
            @memcpy(new_items[0..v.items.len], v.items);
            @memcpy(new_items[v.items.len..], elems);

            const new_vec = try allocator.create(value_mod.PersistentVector);
            new_vec.* = .{ .items = new_items };
            return Value{ .vector = new_vec };
        },
        else => return error.TypeError,
    }
}

/// count : コレクションの要素数
pub fn count(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    const n: i64 = switch (args[0]) {
        .nil => 0,
        .list => |l| @intCast(l.items.len),
        .vector => |v| @intCast(v.items.len),
        .map => |m| @intCast(m.count()),
        .set => |s| @intCast(s.items.len),
        .string => |s| @intCast(s.data.len),
        else => return error.TypeError,
    };

    return Value{ .int = n };
}

/// empty? : コレクションが空かどうか
pub fn isEmpty(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    const empty = switch (args[0]) {
        .nil => true,
        .list => |l| l.items.len == 0,
        .vector => |v| v.items.len == 0,
        .map => |m| m.entries.len == 0,
        .set => |s| s.items.len == 0,
        .string => |s| s.data.len == 0,
        else => return error.TypeError,
    };

    if (empty) return value_mod.true_val;
    return value_mod.false_val;
}

/// nth : インデックスで要素取得
pub fn nth(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2 or args.len > 3) return error.ArityError;

    const coll = args[0];
    const idx: usize = switch (args[1]) {
        .int => |n| if (n >= 0) @intCast(n) else return error.TypeError,
        else => return error.TypeError,
    };

    const not_found = if (args.len == 3) args[2] else null;

    const items: []const Value = switch (coll) {
        .list => |l| l.items,
        .vector => |v| v.items,
        else => return error.TypeError,
    };

    if (idx < items.len) {
        return items[idx];
    } else if (not_found) |nf| {
        return nf;
    } else {
        return error.TypeError; // IndexOutOfBounds
    }
}

// ============================================================
// 出力
// ============================================================

/// println : 改行付き出力（文字列はクォートなし）
pub fn println_fn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout.writer(&buf);
    const writer = &file_writer.interface;

    for (args, 0..) |arg, i| {
        if (i > 0) writer.writeByte(' ') catch {};
        printValueForPrint(writer, arg) catch {};
    }
    writer.writeByte('\n') catch {};
    // flush via interface
    writer.flush() catch {};

    return value_mod.nil;
}

/// 値を出力（print/println 用 - 文字列はクォートなし）
fn printValueForPrint(writer: anytype, val: Value) !void {
    switch (val) {
        .string => |s| try writer.writeAll(s.data), // クォートなし
        else => try printValue(writer, val),
    }
}

/// pr-str : 文字列表現を返す（print 用）
pub fn prStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (args, 0..) |arg, i| {
        if (i > 0) try buf.append(allocator, ' ');
        try printValueToBuf(allocator, &buf, arg);
    }

    const str = try allocator.create(value_mod.String);
    str.* = .{ .data = try buf.toOwnedSlice(allocator) };
    return Value{ .string = str };
}

/// 値を出力（writer 版）
fn printValue(writer: anytype, val: Value) !void {
    switch (val) {
        .nil => try writer.writeAll("nil"),
        .bool_val => |b| try writer.writeAll(if (b) "true" else "false"),
        .int => |n| try writer.print("{d}", .{n}),
        .float => |f| try writer.print("{d}", .{f}),
        .char_val => |c| {
            try writer.writeByte('\\');
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c, &buf) catch 1;
            try writer.writeAll(buf[0..len]);
        },
        .string => |s| {
            try writer.writeByte('"');
            try writer.writeAll(s.data);
            try writer.writeByte('"');
        },
        .keyword => |k| {
            try writer.writeByte(':');
            if (k.namespace) |ns| {
                try writer.writeAll(ns);
                try writer.writeByte('/');
            }
            try writer.writeAll(k.name);
        },
        .symbol => |s| {
            if (s.namespace) |ns| {
                try writer.writeAll(ns);
                try writer.writeByte('/');
            }
            try writer.writeAll(s.name);
        },
        .list => |l| {
            try writer.writeByte('(');
            for (l.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(' ');
                try printValue(writer, item);
            }
            try writer.writeByte(')');
        },
        .vector => |v| {
            try writer.writeByte('[');
            for (v.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(' ');
                try printValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .map => |m| {
            try writer.writeByte('{');
            // entries はフラット配列 [k1, v1, k2, v2, ...]
            var idx: usize = 0;
            while (idx < m.entries.len) : (idx += 2) {
                if (idx > 0) try writer.writeAll(", ");
                try printValue(writer, m.entries[idx]);
                try writer.writeByte(' ');
                if (idx + 1 < m.entries.len) {
                    try printValue(writer, m.entries[idx + 1]);
                }
            }
            try writer.writeByte('}');
        },
        .set => |s| {
            try writer.writeAll("#{");
            for (s.items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(' ');
                try printValue(writer, item);
            }
            try writer.writeByte('}');
        },
        .fn_val => |f| {
            try writer.writeAll("#<fn");
            if (f.name) |name| {
                try writer.writeByte(' ');
                if (name.namespace) |ns| {
                    try writer.writeAll(ns);
                    try writer.writeByte('/');
                }
                try writer.writeAll(name.name);
            }
            try writer.writeByte('>');
        },
        .partial_fn => try writer.writeAll("#<partial-fn>"),
        .comp_fn => try writer.writeAll("#<comp-fn>"),
        .fn_proto => try writer.writeAll("#<fn-proto>"),
        .var_val => try writer.writeAll("#<var>"),
        .atom => |a| {
            try writer.writeAll("#<atom ");
            try printValue(writer, a.value);
            try writer.writeByte('>');
        },
    }
}

/// 値を出力（ArrayListUnmanaged 版）
fn printValueToBuf(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), val: Value) !void {
    const Context = struct {
        buf: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,

        pub fn writeByte(self: *@This(), byte: u8) !void {
            try self.buf.append(self.allocator, byte);
        }

        pub fn writeAll(self: *@This(), data: []const u8) !void {
            try self.buf.appendSlice(self.allocator, data);
        }

        pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
            var local_buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&local_buf, fmt, args) catch return error.OutOfMemory;
            try self.buf.appendSlice(self.allocator, s);
        }
    };
    var ctx = Context{ .buf = buf, .allocator = allocator };
    try printValue(&ctx, val);
}

// ============================================================
// 文字列操作
// ============================================================

/// str : 引数を連結して文字列を返す
pub fn strFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (args) |arg| {
        try valueToString(allocator, &buf, arg);
    }

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = try buf.toOwnedSlice(allocator) };
    return Value{ .string = str_obj };
}

/// 値を文字列に変換（str 用 - pr-str と違ってクォートなし）
fn valueToString(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), val: Value) !void {
    switch (val) {
        .nil => {}, // nil は空文字列
        .bool_val => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .int => |n| {
            var local_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&local_buf, "{d}", .{n}) catch return error.OutOfMemory;
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            var local_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&local_buf, "{d}", .{f}) catch return error.OutOfMemory;
            try buf.appendSlice(allocator, s);
        },
        .string => |s| try buf.appendSlice(allocator, s.data),
        .keyword => |k| {
            try buf.append(allocator, ':');
            if (k.namespace) |ns| {
                try buf.appendSlice(allocator, ns);
                try buf.append(allocator, '/');
            }
            try buf.appendSlice(allocator, k.name);
        },
        .symbol => |s| {
            if (s.namespace) |ns| {
                try buf.appendSlice(allocator, ns);
                try buf.append(allocator, '/');
            }
            try buf.appendSlice(allocator, s.name);
        },
        else => {
            // その他の型は pr-str と同じ表現
            try printValueToBuf(allocator, buf, val);
        },
    }
}

// ============================================================
// コレクションアクセス
// ============================================================

/// get : コレクションから値を取得（見つからない場合は nil または not-found）
pub fn get(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2 or args.len > 3) return error.ArityError;

    const coll = args[0];
    const key = args[1];
    const not_found = if (args.len == 3) args[2] else value_mod.nil;

    return switch (coll) {
        .nil => not_found,
        .vector => |vec| {
            // ベクターはインデックスでアクセス
            if (key != .int) return not_found;
            const idx = key.int;
            if (idx < 0 or idx >= vec.items.len) return not_found;
            return vec.items[@intCast(idx)];
        },
        .list => |lst| {
            // リストもインデックスでアクセス
            if (key != .int) return not_found;
            const idx = key.int;
            if (idx < 0 or idx >= lst.items.len) return not_found;
            return lst.items[@intCast(idx)];
        },
        .map => |m| {
            // マップはキーでアクセス
            return m.get(key) orelse not_found;
        },
        .set => |s| {
            // セットは要素の存在確認
            for (s.items) |item| {
                if (key.eql(item)) return key;
            }
            return not_found;
        },
        else => not_found,
    };
}

/// assoc : マップにキー値を追加/更新
pub fn assoc(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 3 or (args.len - 1) % 2 != 0) return error.ArityError;

    const coll = args[0];

    switch (coll) {
        .nil => {
            // nil に assoc すると新しいマップを作成
            const entries = try allocator.alloc(Value, args.len - 1);
            @memcpy(entries, args[1..]);
            const m = try allocator.create(value_mod.PersistentMap);
            m.* = .{ .entries = entries };
            return Value{ .map = m };
        },
        .map => |m| {
            var result = m.*;
            var i: usize = 1;
            while (i < args.len) : (i += 2) {
                result = try result.assoc(allocator, args[i], args[i + 1]);
            }
            const new_map = try allocator.create(value_mod.PersistentMap);
            new_map.* = result;
            return Value{ .map = new_map };
        },
        .vector => |vec| {
            // ベクターの assoc はインデックス更新
            if (args.len != 3) return error.ArityError;
            if (args[1] != .int) return error.TypeError;
            const idx = args[1].int;
            if (idx < 0 or idx > vec.items.len) return error.IndexOutOfBounds;
            const uidx: usize = @intCast(idx);

            var new_items: []Value = undefined;
            if (uidx == vec.items.len) {
                // 末尾に追加
                new_items = try allocator.alloc(Value, vec.items.len + 1);
                @memcpy(new_items[0..vec.items.len], vec.items);
                new_items[vec.items.len] = args[2];
            } else {
                // 既存要素を更新
                new_items = try allocator.dupe(Value, vec.items);
                new_items[uidx] = args[2];
            }
            const new_vec = try allocator.create(value_mod.PersistentVector);
            new_vec.* = .{ .items = new_items };
            return Value{ .vector = new_vec };
        },
        else => return error.TypeError,
    }
}

/// dissoc : マップからキーを削除
pub fn dissoc(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;

    const coll = args[0];
    if (coll == .nil) return value_mod.nil;
    if (coll != .map) return error.TypeError;

    const m = coll.map;
    var result = m.*;

    for (args[1..]) |key| {
        result = try result.dissoc(allocator, key);
    }

    const new_map = try allocator.create(value_mod.PersistentMap);
    new_map.* = result;
    return Value{ .map = new_map };
}

/// keys : マップのキーをシーケンスで返す
pub fn keys(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    const coll = args[0];
    if (coll == .nil) return value_mod.nil;
    if (coll != .map) return error.TypeError;

    const m = coll.map;
    const count_val = m.count();
    if (count_val == 0) return value_mod.nil;

    const key_vals = try allocator.alloc(Value, count_val);
    var i: usize = 0;
    var j: usize = 0;
    while (j < m.entries.len) : (j += 2) {
        key_vals[i] = m.entries[j];
        i += 1;
    }

    const lst = try allocator.create(value_mod.PersistentList);
    lst.* = .{ .items = key_vals };
    return Value{ .list = lst };
}

/// vals : マップの値をシーケンスで返す
pub fn vals(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    const coll = args[0];
    if (coll == .nil) return value_mod.nil;
    if (coll != .map) return error.TypeError;

    const m = coll.map;
    const count_val = m.count();
    if (count_val == 0) return value_mod.nil;

    const val_vals = try allocator.alloc(Value, count_val);
    var i: usize = 0;
    var j: usize = 1;
    while (j < m.entries.len) : (j += 2) {
        val_vals[i] = m.entries[j];
        i += 1;
    }

    const lst = try allocator.create(value_mod.PersistentList);
    lst.* = .{ .items = val_vals };
    return Value{ .list = lst };
}

/// hash-map : キー値ペアからマップを作成
pub fn hashMap(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len % 2 != 0) return error.ArityError;

    if (args.len == 0) {
        const m = try allocator.create(value_mod.PersistentMap);
        m.* = value_mod.PersistentMap.empty();
        return Value{ .map = m };
    }

    const entries = try allocator.dupe(Value, args);
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

/// contains? : コレクションにキーが含まれるか
pub fn containsKey(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;

    const coll = args[0];
    const key = args[1];

    return switch (coll) {
        .nil => value_mod.false_val,
        .map => |m| if (m.get(key) != null) value_mod.true_val else value_mod.false_val,
        .set => |s| blk: {
            for (s.items) |item| {
                if (key.eql(item)) break :blk value_mod.true_val;
            }
            break :blk value_mod.false_val;
        },
        .vector => |vec| blk: {
            if (key != .int) break :blk value_mod.false_val;
            const idx = key.int;
            if (idx >= 0 and idx < vec.items.len) break :blk value_mod.true_val;
            break :blk value_mod.false_val;
        },
        else => value_mod.false_val,
    };
}

// ============================================================
// シーケンス操作
// ============================================================

/// コレクションの要素を取得するヘルパー
fn getItems(val: Value) ?[]const Value {
    return switch (val) {
        .list => |l| l.items,
        .vector => |v| v.items,
        .nil => &[_]Value{},
        else => null,
    };
}

/// take : 先頭 n 個の要素を取得
pub fn take(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int) return error.TypeError;
    const n_raw = args[0].int;
    const n: usize = if (n_raw < 0) 0 else @intCast(n_raw);

    const items = getItems(args[1]) orelse return error.TypeError;
    const take_count = @min(n, items.len);

    const new_items = try allocator.dupe(Value, items[0..take_count]);
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = new_items };
    return Value{ .list = result };
}

/// drop : 先頭 n 個を除いた残りの要素
pub fn drop(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int) return error.TypeError;
    const n_raw = args[0].int;
    const n: usize = if (n_raw < 0) 0 else @intCast(n_raw);

    const items = getItems(args[1]) orelse return error.TypeError;
    const drop_count = @min(n, items.len);

    const new_items = try allocator.dupe(Value, items[drop_count..]);
    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = new_items };
    return Value{ .list = result };
}

/// range : 数列を生成
/// (range end), (range start end), (range start end step)
pub fn range(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 3) return error.ArityError;

    var start: i64 = 0;
    var end: i64 = undefined;
    var step: i64 = 1;

    if (args.len == 1) {
        if (args[0] != .int) return error.TypeError;
        end = args[0].int;
    } else if (args.len == 2) {
        if (args[0] != .int or args[1] != .int) return error.TypeError;
        start = args[0].int;
        end = args[1].int;
    } else {
        if (args[0] != .int or args[1] != .int or args[2] != .int) return error.TypeError;
        start = args[0].int;
        end = args[1].int;
        step = args[2].int;
        if (step == 0) return error.TypeError;
    }

    // 要素数を計算
    var count_val: usize = 0;
    if (step > 0 and start < end) {
        count_val = @intCast(@divTrunc(end - start + step - 1, step));
    } else if (step < 0 and start > end) {
        count_val = @intCast(@divTrunc(start - end - step - 1, -step));
    }

    const items = try allocator.alloc(Value, count_val);
    var val = start;
    for (0..count_val) |i| {
        items[i] = value_mod.intVal(val);
        val += step;
    }

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = items };
    return Value{ .list = result };
}

/// concat : 複数のコレクションを連結
pub fn concat(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // 全要素数を計算
    var total: usize = 0;
    for (args) |arg| {
        const items = getItems(arg) orelse return error.TypeError;
        total += items.len;
    }

    const new_items = try allocator.alloc(Value, total);
    var offset: usize = 0;
    for (args) |arg| {
        const items = getItems(arg).?;
        @memcpy(new_items[offset .. offset + items.len], items);
        offset += items.len;
    }

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = new_items };
    return Value{ .list = result };
}

/// into : コレクションに要素を追加
/// (into to from) — to の型に応じて結合
pub fn into(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;

    const from_items = getItems(args[1]) orelse return error.TypeError;

    switch (args[0]) {
        .nil => {
            // nil → リストとして返す（逆順）
            const new_items = try allocator.alloc(Value, from_items.len);
            for (from_items, 0..) |item, i| {
                new_items[from_items.len - 1 - i] = item;
            }
            const result = try allocator.create(value_mod.PersistentList);
            result.* = .{ .items = new_items };
            return Value{ .list = result };
        },
        .list => |l| {
            // リスト → 先頭に追加（逆順）
            const new_items = try allocator.alloc(Value, l.items.len + from_items.len);
            for (from_items, 0..) |item, i| {
                new_items[from_items.len - 1 - i] = item;
            }
            @memcpy(new_items[from_items.len..], l.items);
            const result = try allocator.create(value_mod.PersistentList);
            result.* = .{ .items = new_items };
            return Value{ .list = result };
        },
        .vector => |v| {
            // ベクター → 末尾に追加
            const new_items = try allocator.alloc(Value, v.items.len + from_items.len);
            @memcpy(new_items[0..v.items.len], v.items);
            @memcpy(new_items[v.items.len..], from_items);
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = .{ .items = new_items };
            return Value{ .vector = result };
        },
        .set => |s| {
            // セット → 追加（重複除外）
            var set = s.*;
            for (from_items) |item| {
                set = try set.conj(allocator, item);
            }
            const result = try allocator.create(value_mod.PersistentSet);
            result.* = set;
            return Value{ .set = result };
        },
        .map => |m| {
            // マップ → キーバリューペアを追加
            var map = m.*;
            var i: usize = 0;
            while (i + 1 < from_items.len) : (i += 2) {
                map = try map.assoc(allocator, from_items[i], from_items[i + 1]);
            }
            const result = try allocator.create(value_mod.PersistentMap);
            result.* = map;
            return Value{ .map = result };
        },
        else => return error.TypeError,
    }
}

/// reverse : コレクションを逆順に
pub fn reverseFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;

    const new_items = try allocator.alloc(Value, items.len);
    for (items, 0..) |item, i| {
        new_items[items.len - 1 - i] = item;
    }

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = new_items };
    return Value{ .list = result };
}

/// seq : シーケンスに変換（空なら nil）
pub fn seq(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .nil => value_mod.nil,
        .list => |l| if (l.items.len == 0) value_mod.nil else args[0],
        .vector => |v| blk: {
            if (v.items.len == 0) break :blk value_mod.nil;
            const result = try value_mod.PersistentList.fromSlice(allocator, v.items);
            break :blk Value{ .list = result };
        },
        .map => |m| blk: {
            if (m.count() == 0) break :blk value_mod.nil;
            // マップはキーバリューペアのベクタのリストに変換
            const pair_count = m.count();
            const items = try allocator.alloc(Value, pair_count);
            var i: usize = 0;
            var entry_idx: usize = 0;
            while (entry_idx < m.entries.len) : (entry_idx += 2) {
                const pair_items = try allocator.alloc(Value, 2);
                pair_items[0] = m.entries[entry_idx];
                pair_items[1] = m.entries[entry_idx + 1];
                const pair_vec = try allocator.create(value_mod.PersistentVector);
                pair_vec.* = .{ .items = pair_items };
                items[i] = Value{ .vector = pair_vec };
                i += 1;
            }
            const result = try allocator.create(value_mod.PersistentList);
            result.* = .{ .items = items };
            break :blk Value{ .list = result };
        },
        .set => |s| blk: {
            if (s.items.len == 0) break :blk value_mod.nil;
            const result = try value_mod.PersistentList.fromSlice(allocator, s.items);
            break :blk Value{ .list = result };
        },
        .string => |s| blk: {
            if (s.data.len == 0) break :blk value_mod.nil;
            // 文字列を1文字ずつのリストに（UTF-8バイト単位で簡易実装）
            const items = try allocator.alloc(Value, s.data.len);
            for (s.data, 0..) |byte, idx| {
                const char_str = try allocator.alloc(u8, 1);
                char_str[0] = byte;
                const str_obj = try allocator.create(value_mod.String);
                str_obj.* = value_mod.String.init(char_str);
                items[idx] = Value{ .string = str_obj };
            }
            const result = try allocator.create(value_mod.PersistentList);
            result.* = .{ .items = items };
            break :blk Value{ .list = result };
        },
        else => error.TypeError,
    };
}

/// vec : ベクターに変換
pub fn vecFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .nil => blk: {
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = value_mod.PersistentVector.empty();
            break :blk Value{ .vector = result };
        },
        .vector => args[0],
        .list => |l| blk: {
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = .{ .items = try allocator.dupe(Value, l.items) };
            break :blk Value{ .vector = result };
        },
        .set => |s| blk: {
            const result = try allocator.create(value_mod.PersistentVector);
            result.* = .{ .items = try allocator.dupe(Value, s.items) };
            break :blk Value{ .vector = result };
        },
        else => error.TypeError,
    };
}

/// repeat : 値を n 回繰り返したリストを生成
pub fn repeat(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int) return error.TypeError;
    const n_raw = args[0].int;
    if (n_raw < 0) return error.TypeError;
    const n: usize = @intCast(n_raw);

    const items = try allocator.alloc(Value, n);
    for (0..n) |i| {
        items[i] = args[1];
    }

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = items };
    return Value{ .list = result };
}

/// distinct : 重複を除いたリストを返す
pub fn distinct(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const items = getItems(args[0]) orelse return error.TypeError;

    var result_buf: std.ArrayListUnmanaged(Value) = .empty;
    for (items) |item| {
        var found = false;
        for (result_buf.items) |existing| {
            if (item.eql(existing)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try result_buf.append(allocator, item);
        }
    }

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = try result_buf.toOwnedSlice(allocator) };
    return Value{ .list = result };
}

/// flatten : ネストされたコレクションを平坦化
pub fn flatten(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;

    var result_buf: std.ArrayListUnmanaged(Value) = .empty;
    try flattenInto(allocator, args[0], &result_buf);

    const result = try allocator.create(value_mod.PersistentList);
    result.* = .{ .items = try result_buf.toOwnedSlice(allocator) };
    return Value{ .list = result };
}

fn flattenInto(allocator: std.mem.Allocator, val: Value, buf: *std.ArrayListUnmanaged(Value)) !void {
    switch (val) {
        .list => |l| {
            for (l.items) |item| try flattenInto(allocator, item, buf);
        },
        .vector => |v| {
            for (v.items) |item| try flattenInto(allocator, item, buf);
        },
        .nil => {},
        else => try buf.append(allocator, val),
    }
}

// ============================================================
// 例外処理
// ============================================================

/// ex-info: (ex-info msg data) → {:message msg, :data data}
pub fn exInfo(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;

    const msg = args[0];
    const data = args[1];

    // {:message msg, :data data} マップを作成
    const Keyword = value_mod.Keyword;
    const map_ptr = try allocator.create(value_mod.PersistentMap);
    const entries = try allocator.alloc(Value, 4);

    // :message キー
    const msg_kw = try allocator.create(Keyword);
    msg_kw.* = Keyword.init("message");
    entries[0] = Value{ .keyword = msg_kw };
    entries[1] = msg;

    // :data キー
    const data_kw = try allocator.create(Keyword);
    data_kw.* = Keyword.init("data");
    entries[2] = Value{ .keyword = data_kw };
    entries[3] = data;

    map_ptr.* = .{ .entries = entries };
    return Value{ .map = map_ptr };
}

/// ex-message: (ex-message ex) → (:message ex) 相当
pub fn exMessage(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    const ex = args[0];
    if (ex != .map) return value_mod.nil;

    // :message キーで検索
    const entries = ex.map.entries;
    var i: usize = 0;
    while (i < entries.len) : (i += 2) {
        if (entries[i] == .keyword) {
            if (std.mem.eql(u8, entries[i].keyword.name, "message")) {
                return entries[i + 1];
            }
        }
    }
    return value_mod.nil;
}

/// ex-data: (ex-data ex) → (:data ex) 相当
pub fn exData(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    const ex = args[0];
    if (ex != .map) return value_mod.nil;

    // :data キーで検索
    const entries = ex.map.entries;
    var i: usize = 0;
    while (i < entries.len) : (i += 2) {
        if (entries[i] == .keyword) {
            if (std.mem.eql(u8, entries[i].keyword.name, "data")) {
                return entries[i + 1];
            }
        }
    }
    return value_mod.nil;
}

// ============================================================
// Atom 操作
// ============================================================

/// atom: Atom を生成
/// (atom val) → #<atom val>
pub fn atomFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const a = try allocator.create(value_mod.Atom);
    a.* = value_mod.Atom.init(args[0]);
    return Value{ .atom = a };
}

/// deref: Atom の現在値を返す
/// (deref atom) → val
pub fn derefFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .atom => |a| a.value,
        else => error.TypeError,
    };
}

/// reset!: Atom の値を新しい値に置換
/// (reset! atom new-val) → new-val
pub fn resetBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    return switch (args[0]) {
        .atom => |a| {
            a.value = args[1];
            return args[1];
        },
        else => error.TypeError,
    };
}

/// atom?: Atom かどうか
pub fn isAtom(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .atom => value_mod.true_val,
        else => value_mod.false_val,
    };
}

// ============================================================
// 文字列操作（拡充）
// ============================================================

/// subs: 部分文字列
/// (subs s start) または (subs s start end)
pub fn subs(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const start: usize = switch (args[1]) {
        .int => |n| if (n >= 0) @intCast(n) else return error.TypeError,
        else => return error.TypeError,
    };
    if (start > s.len) return error.TypeError;

    const end: usize = if (args.len == 3)
        switch (args[2]) {
            .int => |n| if (n >= 0) @intCast(n) else return error.TypeError,
            else => return error.TypeError,
        }
    else
        s.len;
    if (end > s.len or end < start) return error.TypeError;

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = s[start..end] };
    return Value{ .string = str_obj };
}

/// name: keyword/symbol/string の名前部分
/// (name :foo) → "foo", (name 'bar) → "bar", (name "baz") → "baz"
pub fn nameFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const data = switch (args[0]) {
        .keyword => |k| k.name,
        .symbol => |s| s.name,
        .string => |s| s.data,
        else => return error.TypeError,
    };
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = data };
    return Value{ .string = str_obj };
}

/// namespace: keyword/symbol の名前空間部分
/// (namespace :foo/bar) → "foo", (namespace :foo) → nil
pub fn namespaceFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const ns = switch (args[0]) {
        .keyword => |k| k.namespace,
        .symbol => |s| s.namespace,
        else => return error.TypeError,
    };
    if (ns) |n| {
        const str_obj = try allocator.create(value_mod.String);
        str_obj.* = .{ .data = n };
        return Value{ .string = str_obj };
    }
    return value_mod.nil;
}

/// str/join 相当: (string-join sep coll)
/// 将来 clojure.string/join にマッピング
pub fn stringJoin(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;

    // (string-join coll) または (string-join sep coll)
    var sep: []const u8 = "";
    const coll: Value = if (args.len == 2) blk: {
        sep = switch (args[0]) {
            .string => |s| s.data,
            else => return error.TypeError,
        };
        break :blk args[1];
    } else args[0];

    const items: []const Value = switch (coll) {
        .list => |l| l.items,
        .vector => |v| v.items,
        .nil => &[_]Value{},
        else => return error.TypeError,
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (items, 0..) |item, i| {
        if (i > 0 and sep.len > 0) try buf.appendSlice(allocator, sep);
        try valueToString(allocator, &buf, item);
    }

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = try buf.toOwnedSlice(allocator) };
    return Value{ .string = str_obj };
}

/// str/upper-case 相当
pub fn upperCase(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const upper = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        upper[i] = std.ascii.toUpper(c);
    }
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = upper };
    return Value{ .string = str_obj };
}

/// str/lower-case 相当
pub fn lowerCase(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const lower = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        lower[i] = std.ascii.toLower(c);
    }
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = lower };
    return Value{ .string = str_obj };
}

/// str/trim 相当
pub fn trimStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const trimmed = std.mem.trim(u8, s, " \t\n\r");
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = trimmed };
    return Value{ .string = str_obj };
}

/// str/triml 相当（左トリム）
pub fn trimlStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const trimmed = std.mem.trimLeft(u8, s, " \t\n\r");
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = trimmed };
    return Value{ .string = str_obj };
}

/// str/trimr 相当（右トリム）
pub fn trimrStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const trimmed = std.mem.trimRight(u8, s, " \t\n\r");
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = trimmed };
    return Value{ .string = str_obj };
}

/// str/blank? 相当
pub fn isBlank(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .nil => value_mod.true_val,
        .string => |s| if (std.mem.trim(u8, s.data, " \t\n\r").len == 0)
            value_mod.true_val
        else
            value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// str/starts-with? 相当
pub fn startsWith(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const prefix = switch (args[1]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    return if (std.mem.startsWith(u8, s, prefix)) value_mod.true_val else value_mod.false_val;
}

/// str/ends-with? 相当
pub fn endsWith(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const suffix = switch (args[1]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    return if (std.mem.endsWith(u8, s, suffix)) value_mod.true_val else value_mod.false_val;
}

/// str/includes? 相当
pub fn includesStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const substr = switch (args[1]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    return if (std.mem.indexOf(u8, s, substr) != null) value_mod.true_val else value_mod.false_val;
}

/// str/replace 相当: (string-replace s match replacement)
pub fn stringReplace(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const match = switch (args[1]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const replacement = switch (args[2]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };

    if (match.len == 0) {
        // 空文字列マッチはそのまま返す
        const str_obj = try allocator.create(value_mod.String);
        str_obj.* = .{ .data = s };
        return Value{ .string = str_obj };
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (i + match.len <= s.len and std.mem.eql(u8, s[i..][0..match.len], match)) {
            try buf.appendSlice(allocator, replacement);
            i += match.len;
        } else {
            try buf.append(allocator, s[i]);
            i += 1;
        }
    }

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = try buf.toOwnedSlice(allocator) };
    return Value{ .string = str_obj };
}

/// char-at: 文字列のインデックス位置の文字を返す
/// (char-at s idx) → 文字列
pub fn charAt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const idx: usize = switch (args[1]) {
        .int => |n| if (n >= 0) @intCast(n) else return error.TypeError,
        else => return error.TypeError,
    };
    if (idx >= s.len) return error.TypeError;
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = s[idx .. idx + 1] };
    return Value{ .string = str_obj };
}

// ============================================================
// Env への登録
// ============================================================

/// 組み込み関数の定義
const BuiltinDef = struct {
    name: []const u8,
    func: BuiltinFn,
};

/// 登録する組み込み関数リスト
const builtins = [_]BuiltinDef{
    // 算術
    .{ .name = "+", .func = add },
    .{ .name = "-", .func = sub },
    .{ .name = "*", .func = mul },
    .{ .name = "/", .func = div },
    .{ .name = "inc", .func = inc },
    .{ .name = "dec", .func = dec },
    // 比較
    .{ .name = "=", .func = eq },
    .{ .name = "<", .func = lt },
    .{ .name = ">", .func = gt },
    .{ .name = "<=", .func = lte },
    .{ .name = ">=", .func = gte },
    // 論理
    .{ .name = "not", .func = notFn },
    .{ .name = "not=", .func = notEq },
    // ユーティリティ
    .{ .name = "identity", .func = identity },
    .{ .name = "abs", .func = abs },
    .{ .name = "mod", .func = modFn },
    .{ .name = "max", .func = max },
    .{ .name = "min", .func = min },
    // 述語
    .{ .name = "nil?", .func = isNil },
    .{ .name = "number?", .func = isNumber },
    .{ .name = "integer?", .func = isInteger },
    .{ .name = "float?", .func = isFloat },
    .{ .name = "string?", .func = isString },
    .{ .name = "keyword?", .func = isKeyword },
    .{ .name = "symbol?", .func = isSymbol },
    .{ .name = "fn?", .func = isFn },
    .{ .name = "coll?", .func = isColl },
    .{ .name = "list?", .func = isList },
    .{ .name = "vector?", .func = isVector },
    .{ .name = "map?", .func = isMap },
    .{ .name = "set?", .func = isSet },
    .{ .name = "empty?", .func = isEmpty },
    .{ .name = "some?", .func = isSome },
    .{ .name = "zero?", .func = isZero },
    .{ .name = "pos?", .func = isPos },
    .{ .name = "neg?", .func = isNeg },
    .{ .name = "even?", .func = isEven },
    .{ .name = "odd?", .func = isOdd },
    // コンストラクタ
    .{ .name = "list", .func = list },
    .{ .name = "vector", .func = vector },
    .{ .name = "hash-map", .func = hashMap },
    // コレクション
    .{ .name = "first", .func = first },
    .{ .name = "rest", .func = rest },
    .{ .name = "cons", .func = cons },
    .{ .name = "conj", .func = conj },
    .{ .name = "count", .func = count },
    .{ .name = "nth", .func = nth },
    .{ .name = "get", .func = get },
    .{ .name = "assoc", .func = assoc },
    .{ .name = "dissoc", .func = dissoc },
    .{ .name = "keys", .func = keys },
    .{ .name = "vals", .func = vals },
    .{ .name = "contains?", .func = containsKey },
    // シーケンス操作
    .{ .name = "take", .func = take },
    .{ .name = "drop", .func = drop },
    .{ .name = "range", .func = range },
    .{ .name = "concat", .func = concat },
    .{ .name = "into", .func = into },
    .{ .name = "reverse", .func = reverseFn },
    .{ .name = "seq", .func = seq },
    .{ .name = "vec", .func = vecFn },
    .{ .name = "repeat", .func = repeat },
    .{ .name = "distinct", .func = distinct },
    .{ .name = "flatten", .func = flatten },
    // 文字列
    .{ .name = "str", .func = strFn },
    // 出力
    .{ .name = "println", .func = println_fn },
    .{ .name = "pr-str", .func = prStr },
    // 例外
    .{ .name = "ex-info", .func = exInfo },
    .{ .name = "ex-message", .func = exMessage },
    .{ .name = "ex-data", .func = exData },
    // Atom
    .{ .name = "atom", .func = atomFn },
    .{ .name = "deref", .func = derefFn },
    .{ .name = "reset!", .func = resetBang },
    .{ .name = "atom?", .func = isAtom },
    // 文字列操作（拡充）
    .{ .name = "subs", .func = subs },
    .{ .name = "name", .func = nameFn },
    .{ .name = "namespace", .func = namespaceFn },
    .{ .name = "string-join", .func = stringJoin },
    .{ .name = "upper-case", .func = upperCase },
    .{ .name = "lower-case", .func = lowerCase },
    .{ .name = "trim", .func = trimStr },
    .{ .name = "triml", .func = trimlStr },
    .{ .name = "trimr", .func = trimrStr },
    .{ .name = "blank?", .func = isBlank },
    .{ .name = "starts-with?", .func = startsWith },
    .{ .name = "ends-with?", .func = endsWith },
    .{ .name = "includes?", .func = includesStr },
    .{ .name = "string-replace", .func = stringReplace },
    .{ .name = "char-at", .func = charAt },
};

/// clojure.core の組み込み関数を Env に登録
pub fn registerCore(env: *Env) !void {
    const core_ns = try env.findOrCreateNs("clojure.core");

    for (builtins) |b| {
        const v = try core_ns.intern(b.name);
        const fn_obj = try env.allocator.create(Fn);
        fn_obj.* = Fn.initBuiltin(b.name, b.func);
        v.bindRoot(Value{ .fn_val = fn_obj });
    }
}

// ============================================================
// テスト
// ============================================================

test "add" {
    const alloc = std.testing.allocator;
    const args = [_]Value{ value_mod.intVal(1), value_mod.intVal(2), value_mod.intVal(3) };
    const result = try add(alloc, &args);
    try std.testing.expect(result.eql(value_mod.intVal(6)));
}

test "add with float" {
    const alloc = std.testing.allocator;
    const args = [_]Value{ value_mod.intVal(1), Value{ .float = 2.5 } };
    const result = try add(alloc, &args);
    try std.testing.expectEqual(@as(f64, 3.5), result.float);
}

test "sub" {
    const alloc = std.testing.allocator;
    const args = [_]Value{ value_mod.intVal(10), value_mod.intVal(3) };
    const result = try sub(alloc, &args);
    try std.testing.expect(result.eql(value_mod.intVal(7)));
}

test "sub unary" {
    const alloc = std.testing.allocator;
    const args = [_]Value{value_mod.intVal(5)};
    const result = try sub(alloc, &args);
    try std.testing.expect(result.eql(value_mod.intVal(-5)));
}

test "mul" {
    const alloc = std.testing.allocator;
    const args = [_]Value{ value_mod.intVal(2), value_mod.intVal(3), value_mod.intVal(4) };
    const result = try mul(alloc, &args);
    try std.testing.expect(result.eql(value_mod.intVal(24)));
}

test "div" {
    const alloc = std.testing.allocator;
    const args = [_]Value{ value_mod.intVal(10), value_mod.intVal(2) };
    const result = try div(alloc, &args);
    try std.testing.expectEqual(@as(f64, 5.0), result.float);
}

test "div by zero" {
    const alloc = std.testing.allocator;
    const args = [_]Value{ value_mod.intVal(10), value_mod.intVal(0) };
    const result = div(alloc, &args);
    try std.testing.expectError(error.DivisionByZero, result);
}

test "eq" {
    const alloc = std.testing.allocator;
    const args_eq = [_]Value{ value_mod.intVal(1), value_mod.intVal(1) };
    const result_eq = try eq(alloc, &args_eq);
    try std.testing.expect(result_eq.eql(value_mod.true_val));

    const args_neq = [_]Value{ value_mod.intVal(1), value_mod.intVal(2) };
    const result_neq = try eq(alloc, &args_neq);
    try std.testing.expect(result_neq.eql(value_mod.false_val));
}

test "lt" {
    const alloc = std.testing.allocator;
    const args = [_]Value{ value_mod.intVal(1), value_mod.intVal(2), value_mod.intVal(3) };
    const result = try lt(alloc, &args);
    try std.testing.expect(result.eql(value_mod.true_val));
}

test "isNil" {
    const alloc = std.testing.allocator;
    const args_nil = [_]Value{value_mod.nil};
    const result_nil = try isNil(alloc, &args_nil);
    try std.testing.expect(result_nil.eql(value_mod.true_val));

    const args_not_nil = [_]Value{value_mod.intVal(1)};
    const result_not_nil = try isNil(alloc, &args_not_nil);
    try std.testing.expect(result_not_nil.eql(value_mod.false_val));
}

test "first" {
    const alloc = std.testing.allocator;

    const test_list = try value_mod.PersistentList.fromSlice(alloc, &[_]Value{
        value_mod.intVal(1),
        value_mod.intVal(2),
        value_mod.intVal(3),
    });
    defer alloc.destroy(test_list);
    defer alloc.free(test_list.items);

    const args = [_]Value{Value{ .list = test_list }};
    const result = try first(alloc, &args);
    try std.testing.expect(result.eql(value_mod.intVal(1)));
}

test "rest" {
    const alloc = std.testing.allocator;

    const test_list = try value_mod.PersistentList.fromSlice(alloc, &[_]Value{
        value_mod.intVal(1),
        value_mod.intVal(2),
        value_mod.intVal(3),
    });
    defer alloc.destroy(test_list);
    defer alloc.free(test_list.items);

    const args = [_]Value{Value{ .list = test_list }};
    const result = try rest(alloc, &args);

    // rest は新しいリストを返す
    try std.testing.expectEqual(@as(usize, 2), result.list.items.len);
    try std.testing.expect(result.list.items[0].eql(value_mod.intVal(2)));
    try std.testing.expect(result.list.items[1].eql(value_mod.intVal(3)));

    alloc.destroy(result.list);
    alloc.free(result.list.items);
}

test "cons" {
    const alloc = std.testing.allocator;

    const test_list = try value_mod.PersistentList.fromSlice(alloc, &[_]Value{
        value_mod.intVal(2),
        value_mod.intVal(3),
    });
    defer alloc.destroy(test_list);
    defer alloc.free(test_list.items);

    const args = [_]Value{ value_mod.intVal(1), Value{ .list = test_list } };
    const result = try cons(alloc, &args);

    try std.testing.expectEqual(@as(usize, 3), result.list.items.len);
    try std.testing.expect(result.list.items[0].eql(value_mod.intVal(1)));
    try std.testing.expect(result.list.items[1].eql(value_mod.intVal(2)));
    try std.testing.expect(result.list.items[2].eql(value_mod.intVal(3)));

    alloc.destroy(result.list);
    alloc.free(result.list.items);
}

test "count" {
    const alloc = std.testing.allocator;

    const test_list = try value_mod.PersistentList.fromSlice(alloc, &[_]Value{
        value_mod.intVal(1),
        value_mod.intVal(2),
        value_mod.intVal(3),
    });
    defer alloc.destroy(test_list);
    defer alloc.free(test_list.items);

    const args = [_]Value{Value{ .list = test_list }};
    const result = try count(alloc, &args);
    try std.testing.expect(result.eql(value_mod.intVal(3)));
}
