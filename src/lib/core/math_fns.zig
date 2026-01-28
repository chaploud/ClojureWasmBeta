//! 数学関数
//!
//! clojure.math 名前空間用の builtin 関数群。
//! Zig std.math を使用して java.lang.Math 互換の数学関数を提供。

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const BuiltinDef = defs.BuiltinDef;

// ============================================================
// ヘルパー
// ============================================================

/// Value → f64 変換
fn toDouble(v: Value) !f64 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        else => error.TypeError,
    };
}

/// 1引数 double→double 関数の共通ラッパー
fn unaryDoubleFn(comptime func: fn (f64) f64) fn (std.mem.Allocator, []const Value) anyerror!Value {
    return struct {
        pub fn call(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
            _ = allocator;
            if (args.len != 1) return error.ArityError;
            const a = try toDouble(args[0]);
            return Value{ .float = func(a) };
        }
    }.call;
}

/// 2引数 (double,double)→double 関数の共通ラッパー
fn binaryDoubleFn(comptime func: fn (f64, f64) f64) fn (std.mem.Allocator, []const Value) anyerror!Value {
    return struct {
        pub fn call(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
            _ = allocator;
            if (args.len != 2) return error.ArityError;
            const a = try toDouble(args[0]);
            const b = try toDouble(args[1]);
            return Value{ .float = func(a, b) };
        }
    }.call;
}

// ============================================================
// std.math ラッパー (comptime 関数ポインタ用)
// ============================================================

fn sinFn(x: f64) f64 {
    return @sin(x);
}
fn cosFn(x: f64) f64 {
    return @cos(x);
}
fn tanFn(x: f64) f64 {
    return @tan(x);
}
fn asinFn(x: f64) f64 {
    return std.math.asin(x);
}
fn acosFn(x: f64) f64 {
    return std.math.acos(x);
}
fn atanFn(x: f64) f64 {
    return std.math.atan(x);
}
fn atan2Fn(y: f64, x: f64) f64 {
    return std.math.atan2(y, x);
}
fn sinhFn(x: f64) f64 {
    return std.math.sinh(x);
}
fn coshFn(x: f64) f64 {
    return std.math.cosh(x);
}
fn tanhFn(x: f64) f64 {
    return std.math.tanh(x);
}
fn sqrtFn(x: f64) f64 {
    return @sqrt(x);
}
fn cbrtFn(x: f64) f64 {
    return std.math.cbrt(x);
}
fn expFn(x: f64) f64 {
    return @exp(x);
}
fn expm1Fn(x: f64) f64 {
    return std.math.expm1(x);
}
fn logFn(x: f64) f64 {
    return @log(x);
}
fn log10Fn(x: f64) f64 {
    return @log10(x);
}
fn log1pFn(x: f64) f64 {
    return std.math.log1p(x);
}
fn powFn(base: f64, exp: f64) f64 {
    return std.math.pow(f64, base, exp);
}
fn hypotFn(x: f64, y: f64) f64 {
    return std.math.hypot(x, y);
}
fn copySignFn(magnitude: f64, sign: f64) f64 {
    return std.math.copysign(magnitude, sign);
}

// ============================================================
// 個別実装が必要な関数
// ============================================================

/// ceil: 天井関数
fn ceilImpl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const a = try toDouble(args[0]);
    return Value{ .float = @ceil(a) };
}

/// floor: 床関数
fn floorImpl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const a = try toDouble(args[0]);
    return Value{ .float = @floor(a) };
}

/// rint: 最近接偶数への丸め
fn rintImpl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const a = try toDouble(args[0]);
    return Value{ .float = @round(a) };
}

/// round: 四捨五入 → long
fn roundImpl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const a = try toDouble(args[0]);
    if (std.math.isNan(a)) return Value{ .int = 0 };
    if (std.math.isInf(a)) {
        if (a > 0) return Value{ .int = std.math.maxInt(i64) };
        return Value{ .int = std.math.minInt(i64) };
    }
    return Value{ .int = @intFromFloat(@round(a)) };
}

/// signum: 符号関数
fn signumImpl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const a = try toDouble(args[0]);
    if (std.math.isNan(a)) return Value{ .float = std.math.nan(f64) };
    if (a > 0.0) return Value{ .float = 1.0 };
    if (a < 0.0) return Value{ .float = -1.0 };
    return Value{ .float = a }; // ±0.0 を保持
}

/// random: 0.0 以上 1.0 未満の疑似乱数
/// (簡易 LCG — セキュリティ用途には非推奨)
var rng_state: u64 = 0x853C49E6748FEA9B;

fn randomImpl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 0) return error.ArityError;
    rng_state = rng_state *% 6364136223846793005 +% 1442695040888963407;
    const bits = rng_state >> 11;
    const result: f64 = @as(f64, @floatFromInt(bits)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    return Value{ .float = result };
}

/// floor-div: 切り捨て除算 (long, long) → long
fn floorDivImpl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const a = switch (args[0]) {
        .int => |i| i,
        else => return error.TypeError,
    };
    const b = switch (args[1]) {
        .int => |i| i,
        else => return error.TypeError,
    };
    if (b == 0) return error.ArithmeticError;
    return Value{ .int = @divFloor(a, b) };
}

/// floor-mod: 切り捨て剰余 (long, long) → long
fn floorModImpl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const a = switch (args[0]) {
        .int => |i| i,
        else => return error.TypeError,
    };
    const b = switch (args[1]) {
        .int => |i| i,
        else => return error.TypeError,
    };
    if (b == 0) return error.ArithmeticError;
    return Value{ .int = @mod(a, b) };
}

/// IEEE-remainder: IEEE 754 剰余
fn ieeeRemainderImpl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const a = try toDouble(args[0]);
    const b = try toDouble(args[1]);
    return Value{ .float = @rem(a, b) };
}

/// to-degrees: ラジアン → 度
fn toDegreesImpl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const a = try toDouble(args[0]);
    return Value{ .float = a * (180.0 / std.math.pi) };
}

/// to-radians: 度 → ラジアン
fn toRadiansImpl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const a = try toDouble(args[0]);
    return Value{ .float = a * (std.math.pi / 180.0) };
}

/// abs: 絶対値
fn absImpl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |i| Value{ .int = if (i < 0) -i else i },
        .float => |f| Value{ .float = @abs(f) },
        else => error.TypeError,
    };
}

// ============================================================
// Builtin テーブル
// ============================================================

pub const builtins = [_]BuiltinDef{
    // 三角関数
    .{ .name = "__math-sin", .func = unaryDoubleFn(sinFn) },
    .{ .name = "__math-cos", .func = unaryDoubleFn(cosFn) },
    .{ .name = "__math-tan", .func = unaryDoubleFn(tanFn) },
    .{ .name = "__math-asin", .func = unaryDoubleFn(asinFn) },
    .{ .name = "__math-acos", .func = unaryDoubleFn(acosFn) },
    .{ .name = "__math-atan", .func = unaryDoubleFn(atanFn) },
    .{ .name = "__math-atan2", .func = binaryDoubleFn(atan2Fn) },
    // 双曲線
    .{ .name = "__math-sinh", .func = unaryDoubleFn(sinhFn) },
    .{ .name = "__math-cosh", .func = unaryDoubleFn(coshFn) },
    .{ .name = "__math-tanh", .func = unaryDoubleFn(tanhFn) },
    // 指数・対数
    .{ .name = "__math-exp", .func = unaryDoubleFn(expFn) },
    .{ .name = "__math-expm1", .func = unaryDoubleFn(expm1Fn) },
    .{ .name = "__math-log", .func = unaryDoubleFn(logFn) },
    .{ .name = "__math-log10", .func = unaryDoubleFn(log10Fn) },
    .{ .name = "__math-log1p", .func = unaryDoubleFn(log1pFn) },
    .{ .name = "__math-pow", .func = binaryDoubleFn(powFn) },
    // 冪根・距離
    .{ .name = "__math-sqrt", .func = unaryDoubleFn(sqrtFn) },
    .{ .name = "__math-cbrt", .func = unaryDoubleFn(cbrtFn) },
    .{ .name = "__math-hypot", .func = binaryDoubleFn(hypotFn) },
    // 丸め
    .{ .name = "__math-ceil", .func = ceilImpl },
    .{ .name = "__math-floor", .func = floorImpl },
    .{ .name = "__math-rint", .func = rintImpl },
    .{ .name = "__math-round", .func = roundImpl },
    // 符号・浮動小数点
    .{ .name = "__math-signum", .func = signumImpl },
    .{ .name = "__math-copy-sign", .func = binaryDoubleFn(copySignFn) },
    .{ .name = "__math-abs", .func = absImpl },
    // 整数演算
    .{ .name = "__math-floor-div", .func = floorDivImpl },
    .{ .name = "__math-floor-mod", .func = floorModImpl },
    // その他
    .{ .name = "__math-IEEE-remainder", .func = ieeeRemainderImpl },
    .{ .name = "__math-to-degrees", .func = toDegreesImpl },
    .{ .name = "__math-to-radians", .func = toRadiansImpl },
    .{ .name = "__math-random", .func = randomImpl },
};
