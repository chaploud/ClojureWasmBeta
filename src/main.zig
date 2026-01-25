//! ClojureWasmBeta CLI
//!
//! Clojure式を評価するコマンドラインツール。
//!
//! 使用法:
//!   clj-wasm -e "(+ 1 2)"                     # 式を評価
//!   clj-wasm -e "(def x 10)" -e "(+ x 5)"     # 複数式を連続評価
//!   clj-wasm --backend=vm -e "(+ 1 2)"        # VMバックエンドで評価
//!   clj-wasm --compare -e "(+ 1 2)"           # 両バックエンドで評価して比較

const std = @import("std");
const clj = @import("ClojureWasmBeta");

const Reader = clj.Reader;
const Analyzer = clj.Analyzer;
const Context = clj.Context;
const Env = clj.Env;
const Value = clj.Value;
const EvalEngine = clj.EvalEngine;
const Backend = clj.Backend;
const core = clj.core;
const engine_mod = clj.engine;

/// CLI エラー
const CliError = error{
    NoExpression,
    EmptyInput,
    InvalidBackend,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 引数を解析
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // stdout/stderr（バッファ付き）
    const stdout_file = std.fs.File.stdout();
    const stderr_file = std.fs.File.stderr();
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    var stderr_writer = stderr_file.writer(&stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    // オプション解析
    var expressions: std.ArrayListUnmanaged([]const u8) = .empty;
    defer expressions.deinit(allocator);
    var backend: Backend = .tree_walk; // デフォルト
    var compare_mode = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-e")) {
            i += 1;
            if (i < args.len) {
                try expressions.append(allocator, args[i]);
            } else {
                stderr.writeAll("Error: -e requires an expression\n") catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, args[i], "--backend=")) {
            const backend_str = args[i]["--backend=".len..];
            if (std.mem.eql(u8, backend_str, "tree_walk") or std.mem.eql(u8, backend_str, "tw")) {
                backend = .tree_walk;
            } else if (std.mem.eql(u8, backend_str, "vm")) {
                backend = .vm;
            } else {
                stderr.print("Error: Invalid backend: {s} (use 'tree_walk' or 'vm')\n", .{backend_str}) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, args[i], "--compare")) {
            compare_mode = true;
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            try printHelp(stdout);
            stdout.flush() catch {};
            return;
        } else if (std.mem.eql(u8, args[i], "--version")) {
            stdout.writeAll("ClojureWasmBeta 0.1.0\n") catch {};
            stdout.flush() catch {};
            return;
        } else {
            stderr.print("Error: Unknown option: {s}\n", .{args[i]}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        }
    }

    if (expressions.items.len == 0) {
        try printHelp(stdout);
        stdout.flush() catch {};
        return;
    }

    // 環境を初期化
    var env = Env.init(allocator);
    defer env.deinit();
    try env.setupBasic();
    try core.registerCore(&env);

    // 各式を評価
    for (expressions.items) |expr| {
        if (compare_mode) {
            runCompare(allocator, &env, expr, stdout, stderr) catch |err| {
                stderr.print("Error: {any}\n", .{err}) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            };
        } else {
            runWithBackend(allocator, &env, expr, backend, stdout) catch |err| {
                stderr.print("Error: {any}\n", .{err}) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            };
        }
        stdout.flush() catch {};
    }
}

/// 指定バックエンドで式を評価して結果を出力
fn runWithBackend(
    allocator: std.mem.Allocator,
    env: *Env,
    source: []const u8,
    backend: Backend,
    writer: *std.Io.Writer,
) !void {
    // Reader
    var reader = Reader.init(allocator, source);
    const form = try reader.read() orelse return error.EmptyInput;

    // Analyzer
    var analyzer = Analyzer.init(allocator, env);
    const node = try analyzer.analyze(form);

    // Engine で評価
    var eng = EvalEngine.init(allocator, env, backend);
    const result = try eng.run(node);

    // 結果を出力
    try printValue(writer, result);
    try writer.writeByte('\n');
}

/// 両バックエンドで評価して比較
fn runCompare(
    allocator: std.mem.Allocator,
    env: *Env,
    source: []const u8,
    writer: *std.Io.Writer,
    err_writer: *std.Io.Writer,
) !void {
    // Reader
    var reader = Reader.init(allocator, source);
    const form = try reader.read() orelse return error.EmptyInput;

    // Analyzer
    var analyzer = Analyzer.init(allocator, env);
    const node = try analyzer.analyze(form);

    // 両バックエンドで評価
    const result = try engine_mod.runAndCompare(allocator, env, node);

    // TreeWalk の結果を出力
    try writer.writeAll("tree_walk: ");
    try printValue(writer, result.tree_walk);
    try writer.writeByte('\n');

    // VM の結果を出力
    try writer.writeAll("vm:        ");
    try printValue(writer, result.vm);
    try writer.writeByte('\n');

    // 一致判定
    if (result.match) {
        try writer.writeAll("=> MATCH\n");
    } else {
        try err_writer.writeAll("=> MISMATCH!\n");
        err_writer.flush() catch {};
    }
}

/// 値を出力
fn printValue(writer: *std.Io.Writer, val: Value) !void {
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
        .symbol => |sym| {
            if (sym.namespace) |ns| {
                try writer.writeAll(ns);
                try writer.writeByte('/');
            }
            try writer.writeAll(sym.name);
        },
        .list => |l| {
            try writer.writeByte('(');
            for (l.items, 0..) |item, idx| {
                if (idx > 0) try writer.writeByte(' ');
                try printValue(writer, item);
            }
            try writer.writeByte(')');
        },
        .vector => |v| {
            try writer.writeByte('[');
            for (v.items, 0..) |item, idx| {
                if (idx > 0) try writer.writeByte(' ');
                try printValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .map => |m| {
            try writer.writeByte('{');
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
        .set => |st| {
            try writer.writeAll("#{");
            for (st.items, 0..) |item, idx| {
                if (idx > 0) try writer.writeByte(' ');
                try printValue(writer, item);
            }
            try writer.writeByte('}');
        },
        .fn_val => |fn_v| {
            try writer.writeAll("#<fn");
            if (fn_v.name) |name| {
                try writer.writeByte(' ');
                if (name.namespace) |ns| {
                    try writer.writeAll(ns);
                    try writer.writeByte('/');
                }
                try writer.writeAll(name.name);
            }
            try writer.writeByte('>');
        },
        .fn_proto => try writer.writeAll("#<fn-proto>"),
        .var_val => try writer.writeAll("#<var>"),
    }
}

/// ヘルプを出力
fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\ClojureWasmBeta - A Clojure interpreter written in Zig
        \\
        \\Usage:
        \\  clj-wasm [options]
        \\
        \\Options:
        \\  -e <expr>              Evaluate the expression
        \\  --backend=<backend>    Select backend: tree_walk (default), vm
        \\  --compare              Run both backends and compare results
        \\  -h, --help             Show this help message
        \\  --version              Show version information
        \\
        \\Examples:
        \\  clj-wasm -e "(+ 1 2 3)"
        \\  clj-wasm -e "(def x 10)" -e "(+ x 5)"
        \\  clj-wasm --backend=vm -e "(+ 1 2)"
        \\  clj-wasm --compare -e "(if true 1 2)"
        \\
    );
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
