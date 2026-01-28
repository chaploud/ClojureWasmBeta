//! 入出力
//!
//! println, pr, prn, slurp, spit, read-line, capture

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const BuiltinDef = defs.BuiltinDef;

const helpers = @import("helpers.zig");
const strings = @import("strings.zig");

// ============================================================
// 出力関数
// ============================================================

/// println : 改行付き出力（文字列はクォートなし）
pub fn println_fn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    for (args, 0..) |arg, i| {
        if (i > 0) helpers.writeByteToOutput(' ');
        helpers.outputValueForPrint(allocator, arg);
    }
    helpers.writeByteToOutput('\n');
    return value_mod.nil;
}

/// pr : 値を印字（改行なし、readably）
pub fn prFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    for (args, 0..) |arg, i| {
        if (i > 0) helpers.writeByteToOutput(' ');
        helpers.outputValueForPr(allocator, arg);
    }
    return value_mod.nil;
}

/// print : 値を印字（改行なし、文字列はクォートなし）
pub fn printFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    for (args, 0..) |arg, i| {
        if (i > 0) helpers.writeByteToOutput(' ');
        helpers.outputValueForPrint(allocator, arg);
    }
    return value_mod.nil;
}

/// prn : pr + 改行
pub fn prnFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    for (args, 0..) |arg, i| {
        if (i > 0) helpers.writeByteToOutput(' ');
        helpers.outputValueForPr(allocator, arg);
    }
    helpers.writeByteToOutput('\n');
    return value_mod.nil;
}

// ============================================================
// バージョン・改行・フォーマット出力
// ============================================================

/// clojure-version : バージョン文字列を返す
pub fn clojureVersion(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = args;
    const s = try allocator.create(value_mod.String);
    s.* = value_mod.String.init("1.12.0-zig");
    return Value{ .string = s };
}

/// newline : 改行を出力
pub fn newlineFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    _ = args;
    helpers.writeByteToOutput('\n');
    return value_mod.nil;
}

/// printf : format + print（書式付き出力）
pub fn printfFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // (printf fmt & args) — 簡略実装: format を呼んで print
    if (args.len == 0) return error.ArityError;
    const formatted = try strings.formatFn(allocator, args);
    const s = switch (formatted) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    helpers.writeToOutput(s);
    return value_mod.nil;
}

// ============================================================
// with-out-str サポート
// ============================================================

/// __begin-capture : output_capture を開始し、キャプチャ前の状態を返す
/// 戻り値: 以前のキャプチャバッファ (nil = なし、int = ポインタ)
pub fn beginCaptureFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = args;
    // 新しいキャプチャバッファを作成
    const cap = try allocator.create(std.ArrayListUnmanaged(u8));
    cap.* = .empty;
    // 前のキャプチャ状態を保存
    const prev_cap = defs.output_capture;
    const prev_alloc = defs.output_capture_allocator;
    // 新しいキャプチャを設定
    defs.output_capture = cap;
    defs.output_capture_allocator = allocator;
    // 前の状態を Value として返す (ネスト対応)
    // int の上位ビットにキャプチャポインタ、下位に allocator は同じなので不要
    if (prev_cap) |p| {
        return value_mod.intVal(@intCast(@intFromPtr(p)));
    }
    _ = prev_alloc;
    return value_mod.nil;
}

/// __end-capture : キャプチャを終了し、バッファ内容を文字列として返す
/// 引数: 0=以前の状態 (beginCapture の戻り値)
pub fn endCaptureFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    const prev_state = args[0];

    // 現在のキャプチャバッファを取得
    const cap = defs.output_capture orelse return Value{ .string = try allocator.create(value_mod.String) };
    const result_data = cap.toOwnedSlice(allocator) catch return error.OutOfMemory;
    allocator.destroy(cap);

    // 前の状態を復元
    if (prev_state == .int) {
        const ptr_val: usize = @intCast(prev_state.int);
        defs.output_capture = @ptrFromInt(ptr_val);
        // allocator は同じ (threadlocal)
    } else {
        defs.output_capture = null;
        defs.output_capture_allocator = null;
    }

    // キャプチャした内容を文字列として返す
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = value_mod.String.init(result_data);
    return Value{ .string = str_obj };
}

// ============================================================
// 出力メソッド・フラッシュ
// ============================================================

/// print-method / print-dup / print-simple: 出力スタブ
pub fn printMethodFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // (print-method x writer) — 簡易: str と同じ
    if (args.len < 1) return error.ArityError;
    return strings.strFn(allocator, args[0..1]);
}

/// flush : 出力フラッシュ（スタブ、何もしない）
pub fn flushFn(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    return value_mod.nil;
}

// ============================================================
// IO stubs
// ============================================================

/// read-line — スタブ: nil（stdin 読み取りは未実装）
pub fn readLineFn(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    return value_mod.nil;
}

/// slurp — ファイル読み込み
pub fn slurpFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const path = args[0].string.data;
    const file = std.fs.cwd().openFile(path, .{}) catch return value_mod.nil;
    defer file.close();
    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return value_mod.nil;
    const str = try allocator.create(value_mod.String);
    str.* = value_mod.String.init(content);
    return Value{ .string = str };
}

/// spit — ファイル書き出し
pub fn spitFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const path = args[0].string.data;
    const content = switch (args[1]) {
        .string => |s| s.data,
        else => return error.TypeError,
    };
    const file = std.fs.cwd().createFile(path, .{}) catch return value_mod.nil;
    defer file.close();
    file.writeAll(content) catch return value_mod.nil;
    return value_mod.nil;
}

/// file-seq — スタブ: 空リスト
pub fn fileSeqFn(allocator: std.mem.Allocator, _: []const Value) anyerror!Value {
    const l = try allocator.create(value_mod.PersistentList);
    l.* = .{ .items = &[_]Value{} };
    return Value{ .list = l };
}

/// line-seq — スタブ: 空リスト
pub fn lineSeqFn(allocator: std.mem.Allocator, _: []const Value) anyerror!Value {
    const l = try allocator.create(value_mod.PersistentList);
    l.* = .{ .items = &[_]Value{} };
    return Value{ .list = l };
}

/// __time-start / System/nanoTime : nanoTimestamp を記録して int として返す
pub fn timeStartFn(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    const ts: i64 = @intCast(@as(i128, @bitCast(std.time.nanoTimestamp())));
    return Value{ .int = ts };
}

/// System/currentTimeMillis : エポックからのミリ秒を返す
pub fn currentTimeMillisFn(_: std.mem.Allocator, _: []const Value) anyerror!Value {
    const ts_ns: i128 = @bitCast(std.time.nanoTimestamp());
    const ts_ms: i64 = @intCast(@divTrunc(ts_ns, 1_000_000));
    return Value{ .int = ts_ms };
}

/// __time-end : 開始時刻を受け取り、経過時間を stderr に出力。nil を返す
pub fn timeEndFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.TypeError;
    const start_ns: i128 = switch (args[0]) {
        .int => |v| @as(i128, v),
        else => return error.TypeError,
    };
    const end_ns: i128 = @bitCast(std.time.nanoTimestamp());
    const elapsed_ns = end_ns - start_ns;
    const elapsed_ms_whole: u64 = @intCast(@divTrunc(@as(u128, @bitCast(elapsed_ns)), 1_000_000));
    const elapsed_us_frac: u64 = @intCast(@rem(@divTrunc(@as(u128, @bitCast(elapsed_ns)), 1_000), 1_000));

    // stderr に出力
    var buf: [256]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    const stderr = &writer.interface;
    stderr.print("\"Elapsed time: {d}.{d:0>3} msecs\"\n", .{ elapsed_ms_whole, elapsed_us_frac }) catch {};
    stderr.flush() catch {};
    return value_mod.nil;
}

// ============================================================
// Builtin 定義
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{ .name = "println", .func = println_fn },
    .{ .name = "pr", .func = prFn },
    .{ .name = "print", .func = printFn },
    .{ .name = "prn", .func = prnFn },
    .{ .name = "clojure-version", .func = clojureVersion },
    .{ .name = "newline", .func = newlineFn },
    .{ .name = "printf", .func = printfFn },
    .{ .name = "__begin-capture", .func = beginCaptureFn },
    .{ .name = "__end-capture", .func = endCaptureFn },
    .{ .name = "print-method", .func = printMethodFn },
    .{ .name = "flush", .func = flushFn },
    .{ .name = "read-line", .func = readLineFn },
    .{ .name = "slurp", .func = slurpFn },
    .{ .name = "spit", .func = spitFn },
    .{ .name = "file-seq", .func = fileSeqFn },
    .{ .name = "line-seq", .func = lineSeqFn },
    .{ .name = "__time-start", .func = timeStartFn },
    .{ .name = "__time-end", .func = timeEndFn },
    .{ .name = "__nano-time", .func = timeStartFn },
    .{ .name = "__current-time-millis", .func = currentTimeMillisFn },
};
