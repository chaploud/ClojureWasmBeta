//! ClojureWasmBeta CLI
//!
//! Clojure式を評価するコマンドラインツール。
//!
//! 使用法:
//!   clj-wasm -e "(+ 1 2)"                     # 式を評価
//!   clj-wasm -e "(def x 10)" -e "(+ x 5)"     # 複数式を連続評価
//!   clj-wasm --backend=vm -e "(+ 1 2)"        # VMバックエンドで評価
//!   clj-wasm --compare -e "(+ 1 2)"           # 両バックエンドで評価して比較
//!
//! メモリ管理:
//!   - persistent: Env, Var, Namespace, def された値（プロセス終了まで保持）
//!   - scratch: Reader/Analyzer の中間構造（式ごとに解放）

const std = @import("std");
const clj = @import("ClojureWasmBeta");

const Reader = clj.Reader;
const Analyzer = clj.Analyzer;
const Context = clj.Context;
const Env = clj.Env;
const Value = clj.Value;
const EvalEngine = clj.EvalEngine;
const Backend = clj.Backend;
const Allocators = clj.Allocators;
const core = clj.core;
const engine_mod = clj.engine;

/// CLI エラー
const CliError = error{
    NoExpression,
    EmptyInput,
    InvalidBackend,
};

pub fn main() !void {
    // 引数解析用の一時アロケータ（プロセス終了で自動解放）
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    // 引数を解析
    const args = try std.process.argsAlloc(gpa_allocator);
    defer std.process.argsFree(gpa_allocator, args);

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
    defer expressions.deinit(gpa_allocator);
    var backend: Backend = .tree_walk; // デフォルト
    var compare_mode = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-e")) {
            i += 1;
            if (i < args.len) {
                try expressions.append(gpa_allocator, args[i]);
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
        } else if (std.mem.startsWith(u8, args[i], "--classpath=")) {
            const cp_str = args[i]["--classpath=".len..];
            // : で分割してクラスパスルートに追加
            var iter = std.mem.splitScalar(u8, cp_str, ':');
            while (iter.next()) |path| {
                if (path.len > 0) {
                    core.addClasspathRoot(path);
                }
            }
        } else if (std.mem.startsWith(u8, args[i], "-cp")) {
            // -cp path1:path2 形式
            if (std.mem.eql(u8, args[i], "-cp")) {
                i += 1;
                if (i < args.len) {
                    var iter = std.mem.splitScalar(u8, args[i], ':');
                    while (iter.next()) |path| {
                        if (path.len > 0) {
                            core.addClasspathRoot(path);
                        }
                    }
                }
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
        // REPL モード
        return runRepl(gpa_allocator, backend, compare_mode);
    }

    // 寿命別アロケータを初期化
    // persistent: Env, Var, def された値（GPA でリーク検出可能）
    // scratch: Reader/Analyzer の中間構造（式ごとに Arena でリセット）
    var allocs = Allocators.init(gpa_allocator);
    defer allocs.deinit();

    // 環境を初期化（GPA を直接使用: Env/Namespace/Var/HashMap はインフラ）
    // GcAllocator 経由にすると GC sweep がインフラの HashMap backing を解放してしまう
    var env = Env.init(gpa_allocator);
    defer env.deinit();
    try env.setupBasic();
    try core.registerCore(&env, allocs.persistent());
    core.initLoadedLibs(allocs.persistent());

    // 各式を評価
    var vm_snapshot: ?engine_mod.VarSnapshot = null;
    for (expressions.items) |expr| {
        // scratch をリセット（前回の Form/Node を解放）
        allocs.resetScratch();

        if (compare_mode) {
            const compare_out = runCompare(&allocs, &env, expr, vm_snapshot, stdout, stderr) catch |err| {
                stderr.print("Error: {any}\n", .{err}) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            };
            vm_snapshot = compare_out;
        } else {
            runWithBackend(&allocs, &env, expr, backend, stdout) catch |err| {
                stderr.print("Error: {any}\n", .{err}) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            };
        }
        stdout.flush() catch {};

        // 式境界で GC（閾値超過時のみ）
        allocs.collectGarbage(&env, core.getGcGlobals());
    }
}

/// 指定バックエンドで式を評価して結果を出力
fn runWithBackend(
    allocs: *Allocators,
    env: *Env,
    source: []const u8,
    backend: Backend,
    writer: *std.Io.Writer,
) !void {
    // Reader（scratch アロケータ - Form は一時的）
    var reader = Reader.init(allocs.scratch(), source);
    const form = try reader.read() orelse return error.EmptyInput;

    // Analyzer（scratch アロケータ - Node は一時的）
    var analyzer = Analyzer.init(allocs.scratch(), env);
    const node = try analyzer.analyze(form);

    // Engine で評価（persistent アロケータ - 結果の Value は永続的かもしれない）
    var eng = EvalEngine.init(allocs.persistent(), env, backend);
    const raw_result = try eng.run(node);

    // LazySeq を実体化（Clojure と同様、出力時にforceする）
    const result = core.ensureRealized(allocs.persistent(), raw_result) catch raw_result;

    // 結果を出力
    try printValue(writer, result);
    try writer.writeByte('\n');
}

/// 両バックエンドで評価して比較
fn runCompare(
    allocs: *Allocators,
    env: *Env,
    source: []const u8,
    vm_snapshot: ?engine_mod.VarSnapshot,
    writer: *std.Io.Writer,
    err_writer: *std.Io.Writer,
) !engine_mod.VarSnapshot {
    // Reader（scratch アロケータ）
    var reader = Reader.init(allocs.scratch(), source);
    const form = try reader.read() orelse return error.EmptyInput;

    // Analyzer（scratch アロケータ）
    var analyzer = Analyzer.init(allocs.scratch(), env);
    const node = try analyzer.analyze(form);

    // 両バックエンドで評価（persistent アロケータ、VM snapshot を伝搬）
    const out = try engine_mod.runAndCompare(allocs.persistent(), env, node, vm_snapshot);
    const result = out.result;

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

    return out.vm_snapshot;
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
        .partial_fn => try writer.writeAll("#<partial-fn>"),
        .comp_fn => try writer.writeAll("#<comp-fn>"),
        .multi_fn => |mf| {
            if (mf.name) |name| {
                try writer.writeAll("#<multi-fn ");
                try writer.writeAll(name.name);
                try writer.writeByte('>');
            } else {
                try writer.writeAll("#<multi-fn>");
            }
        },
        .fn_proto => try writer.writeAll("#<fn-proto>"),
        .var_val => try writer.writeAll("#<var>"),
        .atom => |a| {
            try writer.writeAll("#<atom ");
            try printValue(writer, a.value);
            try writer.writeByte('>');
        },
        .protocol => |p| {
            try writer.writeAll("#<protocol ");
            try writer.writeAll(p.name.name);
            try writer.writeByte('>');
        },
        .protocol_fn => |pf| {
            try writer.writeAll("#<protocol-fn ");
            try writer.writeAll(pf.method_name);
            try writer.writeByte('>');
        },
        .lazy_seq => |ls| {
            if (ls.realized) |realized| {
                try printValue(writer, realized);
            } else {
                try writer.writeAll("#<lazy-seq>");
            }
        },
        .delay_val => |d| {
            if (d.realized) {
                try writer.writeAll("#<delay ");
                if (d.cached) |cached| {
                    try printValue(writer, cached);
                }
                try writer.writeByte('>');
            } else {
                try writer.writeAll("#<delay :pending>");
            }
        },
        .volatile_val => |v| {
            try writer.writeAll("#<volatile ");
            try printValue(writer, v.value);
            try writer.writeByte('>');
        },
        .reduced_val => |r| {
            try writer.writeAll("#<reduced ");
            try printValue(writer, r.value);
            try writer.writeByte('>');
        },
        .transient => |t| {
            const kind_str: []const u8 = switch (t.kind) {
                .vector => "vector",
                .map => "map",
                .set => "set",
            };
            try writer.print("#<transient-{s}>", .{kind_str});
        },
        .promise => |p| {
            if (p.delivered) {
                try writer.writeAll("#<promise (delivered)>");
            } else {
                try writer.writeAll("#<promise (pending)>");
            }
        },
        .regex => |pat| {
            try writer.writeAll("#\"");
            try writer.writeAll(pat.source);
            try writer.writeByte('"');
        },
        .matcher => try writer.writeAll("#<matcher>"),
    }
}

/// REPL: 対話型シェル
fn runRepl(gpa_allocator: std.mem.Allocator, backend: Backend, compare_mode: bool) !void {
    // stdout/stderr
    const stdout_file = std.fs.File.stdout();
    const stderr_file = std.fs.File.stderr();
    const stdin_file = std.fs.File.stdin();
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    var stderr_writer = stderr_file.writer(&stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    // 環境を初期化
    var allocs = Allocators.init(gpa_allocator);
    defer allocs.deinit();

    var env = Env.init(gpa_allocator);
    defer env.deinit();
    try env.setupBasic();
    try core.registerCore(&env, allocs.persistent());
    core.initLoadedLibs(allocs.persistent());

    // バナー
    stdout.writeAll("ClojureWasmBeta 0.1.0 — Clojure interpreter in Zig\n") catch {};
    stdout.writeAll("Type expressions to evaluate. Ctrl-D to exit.\n") catch {};
    stdout.flush() catch {};

    // *1, *2, *3, *e 用の Var
    const var1 = env.findOrCreateNs("user") catch unreachable;
    const v1 = var1.intern("*1") catch unreachable;
    const v2 = var1.intern("*2") catch unreachable;
    const v3 = var1.intern("*3") catch unreachable;
    const ve = var1.intern("*e") catch unreachable;
    v1.bindRoot(Value.nil);
    v2.bindRoot(Value.nil);
    v3.bindRoot(Value.nil);
    ve.bindRoot(Value.nil);

    // 入力バッファ
    var input_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer input_buf.deinit(gpa_allocator);

    var vm_snapshot: ?engine_mod.VarSnapshot = null;

    // stdin リーダー（ループ外で初期化）
    var stdin_reader_buf: [4096]u8 = undefined;
    var stdin_reader = stdin_file.reader(&stdin_reader_buf);

    while (true) {
        // プロンプト
        const ns_name = if (env.getCurrentNs()) |ns| ns.name else "user";
        if (input_buf.items.len == 0) {
            stdout.print("{s}=> ", .{ns_name}) catch {};
        } else {
            // 継続入力プロンプト
            stdout.print("{s}.. ", .{ns_name}) catch {};
        }
        stdout.flush() catch {};

        // 1行読み込み
        const line_opt = stdin_reader.interface.takeDelimiter('\n') catch |err| {
            switch (err) {
                error.StreamTooLong => {
                    stderr.writeAll("Error: input line too long\n") catch {};
                    stderr.flush() catch {};
                    input_buf.clearRetainingCapacity();
                    continue;
                },
                error.ReadFailed => return err,
            }
        };
        const line = line_opt orelse {
            // EOF (Ctrl-D)
            stdout.writeByte('\n') catch {};
            stdout.flush() catch {};
            return;
        };

        // 空行は無視
        if (line.len == 0 and input_buf.items.len == 0) continue;

        // 入力バッファに追加
        if (input_buf.items.len > 0) {
            try input_buf.append(gpa_allocator, '\n');
        }
        try input_buf.appendSlice(gpa_allocator, line);

        // 括弧バランスチェック
        if (!isBalanced(input_buf.items)) continue;

        // 入力を評価
        // persistent アロケータを使用（シンボル名が source 内を指すため解放不可）
        const source = try allocs.persistent().dupe(u8, input_buf.items);
        input_buf.clearRetainingCapacity();

        // scratch リセット
        allocs.resetScratch();

        if (compare_mode) {
            const compare_out = runCompare(&allocs, &env, source, vm_snapshot, stdout, stderr) catch |err| {
                stderr.print("Error: {any}\n", .{err}) catch {};
                stderr.flush() catch {};
                ve.bindRoot(Value.nil); // *e にエラー情報は格納できない（Value 表現なし）
                continue;
            };
            vm_snapshot = compare_out;
        } else {
            // 評価
            const result = evalForRepl(&allocs, &env, source, backend) catch |err| {
                stderr.print("Error: {any}\n", .{err}) catch {};
                stderr.flush() catch {};
                continue;
            };

            // 結果を出力
            printValue(stdout, result) catch {};
            stdout.writeByte('\n') catch {};
            stdout.flush() catch {};

            // *1, *2, *3 を更新
            v3.bindRoot(v2.deref());
            v2.bindRoot(v1.deref());
            v1.bindRoot(result);
        }

        stdout.flush() catch {};

        // 式境界で GC
        allocs.collectGarbage(&env, core.getGcGlobals());
    }
}

/// REPL 用: 式を評価して結果を返す（出力しない）
fn evalForRepl(
    allocs: *Allocators,
    env: *Env,
    source: []const u8,
    backend: Backend,
) !Value {
    var reader = Reader.init(allocs.scratch(), source);
    const form = try reader.read() orelse return error.EmptyInput;
    var analyzer = Analyzer.init(allocs.scratch(), env);
    const node = try analyzer.analyze(form);
    var eng = EvalEngine.init(allocs.persistent(), env, backend);
    const raw_result = try eng.run(node);
    return core.ensureRealized(allocs.persistent(), raw_result) catch raw_result;
}

/// 括弧のバランスチェック（全ての開き括弧に対応する閉じ括弧があるか）
fn isBalanced(input: []const u8) bool {
    var parens: i32 = 0;
    var brackets: i32 = 0;
    var braces: i32 = 0;
    var in_string = false;
    var escape = false;

    for (input) |c| {
        if (escape) {
            escape = false;
            continue;
        }
        if (c == '\\' and in_string) {
            escape = true;
            continue;
        }
        if (c == '"') {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        // コメント行はスキップ
        if (c == ';') return parens <= 0 and brackets <= 0 and braces <= 0;

        switch (c) {
            '(' => parens += 1,
            ')' => parens -= 1,
            '[' => brackets += 1,
            ']' => brackets -= 1,
            '{' => braces += 1,
            '}' => braces -= 1,
            else => {},
        }
    }

    return parens <= 0 and brackets <= 0 and braces <= 0;
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
        \\  --classpath=<paths>    Add classpath roots (colon-separated)
        \\  -cp <paths>            Add classpath roots (colon-separated)
        \\  --backend=<backend>    Select backend: tree_walk (default), vm
        \\  --compare              Run both backends and compare results
        \\  -h, --help             Show this help message
        \\  --version              Show version information
        \\
        \\Examples:
        \\  clj-wasm -e "(+ 1 2 3)"
        \\  clj-wasm -e "(def x 10)" -e "(+ x 5)"
        \\  clj-wasm --classpath=src:test/libs -e "(require 'my.lib)"
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
