//! 算術演算・比較・ビット演算
//!
//! +,-,*,/,mod,rem,bit-ops,比較,checked arithmetic

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const CoreError = defs.CoreError;
const BuiltinDef = defs.BuiltinDef;

const helpers = @import("helpers.zig");

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
            else => {
                @branchHint(.cold);
                return error.TypeError;
            },
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
    if (args.len == 0) {
        @branchHint(.cold);
        return error.ArityError;
    }

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
    if (args.len != 1) {
        @branchHint(.cold);
        return error.ArityError;
    }

    return switch (args[0]) {
        .int => |n| Value{ .int = n + 1 },
        .float => |f| Value{ .float = f + 1.0 },
        else => {
            @branchHint(.cold);
            return error.TypeError;
        },
    };
}

/// dec : 1減算
pub fn dec(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) {
        @branchHint(.cold);
        return error.ArityError;
    }

    return switch (args[0]) {
        .int => |n| Value{ .int = n - 1 },
        .float => |f| Value{ .float = f - 1.0 },
        else => {
            @branchHint(.cold);
            return error.TypeError;
        },
    };
}

// ============================================================
// 比較演算
// ============================================================

/// = : 等価比較
pub fn eq(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) {
        @branchHint(.cold);
        return error.ArityError;
    }

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        // lazy-seq は実体化してから比較
        const ra = try helpers.ensureRealized(allocator, a);
        const rb = try helpers.ensureRealized(allocator, b);
        if (!ra.eql(rb)) {
            return value_mod.false_val;
        }
    }
    return value_mod.true_val;
}

/// < : 小なり
pub fn lt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) {
        @branchHint(.cold);
        return error.ArityError;
    }

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        const cmp = try helpers.compareNumbers(a, b);
        if (cmp >= 0) return value_mod.false_val;
    }
    return value_mod.true_val;
}

/// > : 大なり
pub fn gt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) {
        @branchHint(.cold);
        return error.ArityError;
    }

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        const cmp = try helpers.compareNumbers(a, b);
        if (cmp <= 0) return value_mod.false_val;
    }
    return value_mod.true_val;
}

/// <= : 小なりイコール
pub fn lte(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) {
        @branchHint(.cold);
        return error.ArityError;
    }

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        const cmp = try helpers.compareNumbers(a, b);
        if (cmp > 0) return value_mod.false_val;
    }
    return value_mod.true_val;
}

/// >= : 大なりイコール
pub fn gte(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 2) {
        @branchHint(.cold);
        return error.ArityError;
    }

    for (args[0 .. args.len - 1], args[1..]) |a, b| {
        const cmp = try helpers.compareNumbers(a, b);
        if (cmp < 0) return value_mod.false_val;
    }
    return value_mod.true_val;
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

// ============================================================
// max / min / abs
// ============================================================

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
// 型変換・真偽値
// ============================================================

/// boolean : 値を真偽値に変換
/// (boolean nil) => false, (boolean 0) => true
pub fn booleanFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0].isTruthy()) value_mod.true_val else value_mod.false_val;
}

/// true? : true かどうか
pub fn isTrue(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .bool_val and args[0].bool_val) value_mod.true_val else value_mod.false_val;
}

/// false? : false かどうか
pub fn isFalse(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .bool_val and !args[0].bool_val) value_mod.true_val else value_mod.false_val;
}

/// int : 値を整数に変換
pub fn intFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => args[0],
        .float => |f| value_mod.intVal(@intFromFloat(f)),
        else => error.TypeError,
    };
}

/// double : 値を浮動小数点に変換
pub fn doubleFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .float => args[0],
        .int => |n| Value{ .float = @floatFromInt(n) },
        else => error.TypeError,
    };
}

// ============================================================
// rem / quot
// ============================================================

/// rem : 剰余（Java 互換）
pub fn remFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] == .int and args[1] == .int) {
        if (args[1].int == 0) return error.DivisionByZero;
        return value_mod.intVal(@rem(args[0].int, args[1].int));
    }
    return error.TypeError;
}

/// quot : 整数除算
pub fn quotFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] == .int and args[1] == .int) {
        if (args[1].int == 0) return error.DivisionByZero;
        return value_mod.intVal(@divTrunc(args[0].int, args[1].int));
    }
    return error.TypeError;
}

// ============================================================
// ビット演算
// ============================================================

/// bit-and, bit-or, bit-xor, bit-not, bit-shift-left, bit-shift-right
pub fn bitAnd(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    return value_mod.intVal(args[0].int & args[1].int);
}

pub fn bitOr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    return value_mod.intVal(args[0].int | args[1].int);
}

pub fn bitXor(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    return value_mod.intVal(args[0].int ^ args[1].int);
}

pub fn bitNot(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    if (args[0] != .int) return error.TypeError;
    return value_mod.intVal(~args[0].int);
}

pub fn bitShiftLeft(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const shift: u6 = @intCast(@min(@max(args[1].int, 0), 63));
    return value_mod.intVal(args[0].int << shift);
}

pub fn bitShiftRight(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const shift: u6 = @intCast(@min(@max(args[1].int, 0), 63));
    return value_mod.intVal(args[0].int >> shift);
}

/// bit-and-not : (bit-and x (bit-not y))
pub fn bitAndNot(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    return value_mod.intVal(args[0].int & ~args[1].int);
}

/// bit-clear : n 番目のビットをクリア
pub fn bitClear(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const shift: u6 = @intCast(@min(@max(args[1].int, 0), 63));
    return value_mod.intVal(args[0].int & ~(@as(i64, 1) << shift));
}

/// bit-flip : n 番目のビットを反転
pub fn bitFlip(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const shift: u6 = @intCast(@min(@max(args[1].int, 0), 63));
    return value_mod.intVal(args[0].int ^ (@as(i64, 1) << shift));
}

/// bit-set : n 番目のビットをセット
pub fn bitSet(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const shift: u6 = @intCast(@min(@max(args[1].int, 0), 63));
    return value_mod.intVal(args[0].int | (@as(i64, 1) << shift));
}

/// bit-test : n 番目のビットをテスト
pub fn bitTest(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const shift: u6 = @intCast(@min(@max(args[1].int, 0), 63));
    const result = (args[0].int >> shift) & 1;
    return if (result == 1) value_mod.true_val else value_mod.false_val;
}

/// unsigned-bit-shift-right : 符号なし右シフト
pub fn unsignedBitShiftRight(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int or args[1] != .int) return error.TypeError;
    const shift: u6 = @intCast(@min(@max(args[1].int, 0), 63));
    const unsigned_val: u64 = @bitCast(args[0].int);
    const shifted = unsigned_val >> shift;
    return value_mod.intVal(@bitCast(shifted));
}

// ============================================================
// パース
// ============================================================

/// parse-long : 文字列を整数にパース
pub fn parseLong(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .string => |s| {
            const trimmed = std.mem.trim(u8, s.data, &[_]u8{ ' ', '\t', '\n', '\r' });
            const val = std.fmt.parseInt(i64, trimmed, 10) catch return value_mod.nil;
            return value_mod.intVal(val);
        },
        else => value_mod.nil,
    };
}

/// parse-double : 文字列を浮動小数点にパース
pub fn parseDouble(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .string => |s| {
            const trimmed = std.mem.trim(u8, s.data, &[_]u8{ ' ', '\t', '\n', '\r' });
            const val = std.fmt.parseFloat(f64, trimmed) catch return value_mod.nil;
            return value_mod.floatVal(val);
        },
        else => value_mod.nil,
    };
}

/// parse-boolean : 文字列を真偽値にパース（"true"→true, "false"→false, その他→nil）
pub fn parseBooleanFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .string => |s| {
            if (std.mem.eql(u8, s.data, "true")) return value_mod.true_val;
            if (std.mem.eql(u8, s.data, "false")) return value_mod.false_val;
            return value_mod.nil;
        },
        else => value_mod.nil,
    };
}

// ============================================================
// オーバーフロー安全算術
// ============================================================

/// +' : オーバーフロー時に ArithmeticOverflow エラー
pub fn addChecked(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
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
                    const ov = @addWithOverflow(result, n);
                    if (ov[1] != 0) return error.ArithmeticOverflow;
                    result = ov[0];
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
    return if (has_float) Value{ .float = float_result } else value_mod.intVal(result);
}

/// -' : オーバーフロー安全減算
pub fn subChecked(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len == 0) return error.ArityError;

    if (args.len == 1) {
        // 単項マイナス
        return switch (args[0]) {
            .int => |n| blk: {
                const ov = @subWithOverflow(@as(i64, 0), n);
                if (ov[1] != 0) return error.ArithmeticOverflow;
                break :blk value_mod.intVal(ov[0]);
            },
            .float => |f| Value{ .float = -f },
            else => error.TypeError,
        };
    }

    // float が含まれるかチェック
    var has_float = false;
    for (args) |arg| {
        if (arg == .float) {
            has_float = true;
            break;
        }
    }

    if (has_float) {
        // float 演算
        var fr: f64 = switch (args[0]) {
            .int => |n| @as(f64, @floatFromInt(n)),
            .float => |f| f,
            else => return error.TypeError,
        };
        for (args[1..]) |arg| {
            switch (arg) {
                .int => |n| fr -= @as(f64, @floatFromInt(n)),
                .float => |f| fr -= f,
                else => return error.TypeError,
            }
        }
        return Value{ .float = fr };
    }

    // 整数のみ — オーバーフロー検出
    var result: i64 = switch (args[0]) {
        .int => |n| n,
        else => return error.TypeError,
    };
    for (args[1..]) |arg| {
        const n = switch (arg) {
            .int => |v| v,
            else => return error.TypeError,
        };
        const ov = @subWithOverflow(result, n);
        if (ov[1] != 0) return error.ArithmeticOverflow;
        result = ov[0];
    }
    return value_mod.intVal(result);
}

/// *' : オーバーフロー安全乗算
pub fn mulChecked(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
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
                    const ov = @mulWithOverflow(result, n);
                    if (ov[1] != 0) return error.ArithmeticOverflow;
                    result = ov[0];
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
    return if (has_float) Value{ .float = float_result } else value_mod.intVal(result);
}

/// inc' : オーバーフロー安全インクリメント
pub fn incChecked(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| blk: {
            const ov = @addWithOverflow(n, @as(i64, 1));
            if (ov[1] != 0) return error.ArithmeticOverflow;
            break :blk value_mod.intVal(ov[0]);
        },
        .float => |f| Value{ .float = f + 1.0 },
        else => error.TypeError,
    };
}

/// dec' : オーバーフロー安全デクリメント
pub fn decChecked(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| blk: {
            const ov = @subWithOverflow(n, @as(i64, 1));
            if (ov[1] != 0) return error.ArithmeticOverflow;
            break :blk value_mod.intVal(ov[0]);
        },
        .float => |f| Value{ .float = f - 1.0 },
        else => error.TypeError,
    };
}

// ============================================================
// 数値等価・比較・コンパレータ
// ============================================================

/// == : 数値等価比較（数値型同士のみ true）
pub fn numericEq(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1) return error.ArityError;
    if (args.len == 1) return value_mod.true_val;

    const first_f = helpers.numToFloat(args[0]) orelse return value_mod.false_val;
    for (args[1..]) |arg| {
        const b_f = helpers.numToFloat(arg) orelse return value_mod.false_val;
        if (first_f != b_f) return value_mod.false_val;
    }
    return value_mod.true_val;
}

/// compare : 2つの値を比較（-1, 0, 1 を返す）
pub fn compareFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const a = args[0];
    const b = args[1];

    // 数値比較
    if (a == .int and b == .int) {
        if (a.int < b.int) return value_mod.intVal(-1);
        if (a.int > b.int) return value_mod.intVal(1);
        return value_mod.intVal(0);
    }
    if ((a == .int or a == .float) and (b == .int or b == .float)) {
        const af: f64 = if (a == .int) @floatFromInt(a.int) else a.float;
        const bf: f64 = if (b == .int) @floatFromInt(b.int) else b.float;
        if (af < bf) return value_mod.intVal(-1);
        if (af > bf) return value_mod.intVal(1);
        return value_mod.intVal(0);
    }
    // 文字列比較
    if (a == .string and b == .string) {
        const order = std.mem.order(u8, a.string.data, b.string.data);
        return value_mod.intVal(switch (order) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        });
    }
    // キーワード比較
    if (a == .keyword and b == .keyword) {
        const order = std.mem.order(u8, a.keyword.name, b.keyword.name);
        return value_mod.intVal(switch (order) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        });
    }
    // シンボル比較
    if (a == .symbol and b == .symbol) {
        const order = std.mem.order(u8, a.symbol.name, b.symbol.name);
        return value_mod.intVal(switch (order) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        });
    }

    return error.TypeError;
}

/// comparator : 述語関数をコンパレータに変換
/// (comparator pred) → pred が true なら -1、false なら 1 を返す関数
/// 注: 高階関数を返すにはクロージャが必要。簡略実装として pred を呼んで -1/0/1 を返す
pub fn comparatorFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    // comparator は関数を返す — ここでは引数の関数をそのまま返す（ラッパーは Phase 12E で改善）
    return switch (args[0]) {
        .fn_val, .partial_fn, .comp_fn => args[0],
        else => error.TypeError,
    };
}

// ============================================================
// 型キャスト
// ============================================================

/// char : 整数を文字に変換
pub fn charFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .char_val => args[0],
        .int => |n| Value{ .char_val = @intCast(n) },
        else => error.TypeError,
    };
}

/// byte : 整数をバイト範囲にキャスト
pub fn byteFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| value_mod.intVal(@as(i64, @as(i8, @truncate(n)))),
        else => error.TypeError,
    };
}

/// short : 整数をshort範囲にキャスト
pub fn shortFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| value_mod.intVal(@as(i64, @as(i16, @truncate(n)))),
        else => error.TypeError,
    };
}

/// long : 値をlong（i64）に変換
pub fn longFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => args[0],
        .float => |f| value_mod.intVal(@intFromFloat(f)),
        .char_val => |c| value_mod.intVal(@as(i64, c)),
        else => error.TypeError,
    };
}

/// float : 値をfloat（f64）に変換（double のエイリアス）
pub fn floatFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .float => args[0],
        .int => |n| Value{ .float = @floatFromInt(n) },
        else => error.TypeError,
    };
}

/// num : 数値をそのまま返す（数値でなければエラー）
pub fn numFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int, .float => args[0],
        else => error.TypeError,
    };
}

// ============================================================
// Builtins 登録テーブル
// ============================================================

pub const builtins = [_]BuiltinDef{
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
    // 型変換・真偽値
    .{ .name = "boolean", .func = booleanFn },
    .{ .name = "true?", .func = isTrue },
    .{ .name = "false?", .func = isFalse },
    .{ .name = "int", .func = intFn },
    .{ .name = "double", .func = doubleFn },
    // rem / quot
    .{ .name = "rem", .func = remFn },
    .{ .name = "quot", .func = quotFn },
    // ビット演算
    .{ .name = "bit-and", .func = bitAnd },
    .{ .name = "bit-or", .func = bitOr },
    .{ .name = "bit-xor", .func = bitXor },
    .{ .name = "bit-not", .func = bitNot },
    .{ .name = "bit-shift-left", .func = bitShiftLeft },
    .{ .name = "bit-shift-right", .func = bitShiftRight },
    .{ .name = "bit-and-not", .func = bitAndNot },
    .{ .name = "bit-clear", .func = bitClear },
    .{ .name = "bit-flip", .func = bitFlip },
    .{ .name = "bit-set", .func = bitSet },
    .{ .name = "bit-test", .func = bitTest },
    .{ .name = "unsigned-bit-shift-right", .func = unsignedBitShiftRight },
    // パース
    .{ .name = "parse-long", .func = parseLong },
    .{ .name = "parse-double", .func = parseDouble },
    .{ .name = "parse-boolean", .func = parseBooleanFn },
    // オーバーフロー安全算術
    .{ .name = "+'", .func = addChecked },
    .{ .name = "-'", .func = subChecked },
    .{ .name = "*'", .func = mulChecked },
    .{ .name = "inc'", .func = incChecked },
    .{ .name = "dec'", .func = decChecked },
    // 数値等価・比較・コンパレータ
    .{ .name = "==", .func = numericEq },
    .{ .name = "compare", .func = compareFn },
    .{ .name = "comparator", .func = comparatorFn },
    // 型キャスト
    .{ .name = "char", .func = charFn },
    .{ .name = "byte", .func = byteFn },
    .{ .name = "short", .func = shortFn },
    .{ .name = "long", .func = longFn },
    .{ .name = "float", .func = floatFn },
    .{ .name = "num", .func = numFn },
};

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
