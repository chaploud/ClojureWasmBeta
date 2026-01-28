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
const var_mod = clj.var_mod;
const LineEditor = @import("repl/line_editor.zig").LineEditor;
const base_error = clj.err;

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
    var gc_stats = false;
    var dump_bytecode = false;

    var script_file: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, args[i], "--gc-stats")) {
            gc_stats = true;
        } else if (std.mem.eql(u8, args[i], "--dump-bytecode")) {
            dump_bytecode = true;
        } else if (std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "--help")) {
            try printHelp(stdout);
            stdout.flush() catch {};
            return;
        } else if (std.mem.eql(u8, args[i], "--version")) {
            stdout.writeAll("ClojureWasmBeta 0.1.0\n") catch {};
            stdout.flush() catch {};
            return;
        } else if (!std.mem.startsWith(u8, args[i], "-")) {
            // オプションでない引数はスクリプトファイルとして扱う
            script_file = args[i];
        } else {
            stderr.print("Error: Unknown option: {s}\n", .{args[i]}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        }
    }

    if (expressions.items.len == 0 and script_file == null) {
        // REPL モード
        return runRepl(gpa_allocator, backend, compare_mode, gc_stats);
    }

    // 寿命別アロケータを初期化
    // persistent: Env, Var, def された値（GPA でリーク検出可能）
    // scratch: Reader/Analyzer の中間構造（式ごとに Arena でリセット）
    var allocs = Allocators.init(gpa_allocator);
    defer {
        if (gc_stats) allocs.printGcSummary();
        allocs.deinit();
    }
    allocs.gc_stats_enabled = gc_stats;

    // 環境を初期化（GPA を直接使用: Env/Namespace/Var/HashMap はインフラ）
    // GcAllocator 経由にすると GC sweep がインフラの HashMap backing を解放してしまう
    var env = Env.init(gpa_allocator);
    defer env.deinit();
    try env.setupBasic();
    try core.registerCore(&env, allocs.persistent());
    core.initLoadedLibs(allocs.persistent());

    // デフォルトクラスパス: src/clj (clojure.string 等の標準ライブラリ)
    core.addClasspathRoot("src/clj");

    // スクリプトファイルがある場合は (load-file "path") 式を追加
    var load_file_buf: [1024]u8 = undefined;
    if (script_file) |sf| {
        const load_expr = std.fmt.bufPrint(&load_file_buf, "(load-file \"{s}\")", .{sf}) catch {
            stderr.writeAll("Error: Script file path too long\n") catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };
        try expressions.append(gpa_allocator, load_expr);
    }

    // 各式を評価
    var vm_snapshot: ?engine_mod.VarSnapshot = null;
    for (expressions.items) |expr| {
        // scratch をリセット（前回の Form/Node を解放）
        allocs.resetScratch();

        // エラー表示用にソーステキストを設定
        base_error.setSourceText(expr);

        if (dump_bytecode) {
            dumpBytecode(&allocs, &env, expr, stderr) catch |err| {
                reportError(err, stderr);
                base_error.setSourceText(null);
                std.process.exit(1);
            };
        }

        if (compare_mode) {
            const compare_out = runCompare(&allocs, &env, expr, vm_snapshot, stdout, stderr) catch |err| {
                reportError(err, stderr);
                base_error.setSourceText(null);
                std.process.exit(1);
            };
            vm_snapshot = compare_out;
        } else {
            runWithBackend(&allocs, &env, expr, backend, stdout) catch |err| {
                reportError(err, stderr);
                base_error.setSourceText(null);
                std.process.exit(1);
            };
        }
        stdout.flush() catch {};

        base_error.setSourceText(null);

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
    const located = try reader.readLocated() orelse return error.EmptyInput;

    // Analyzer（scratch アロケータ - Node は一時的）
    var analyzer = Analyzer.init(allocs.scratch(), env);
    analyzer.source_line = located.line;
    analyzer.source_column = located.column;
    const node = try analyzer.analyze(located.form);

    // Engine で評価（persistent アロケータ - 結果の Value は永続的かもしれない）
    var eng = EvalEngine.init(allocs.persistent(), env, backend);
    const raw_result = try eng.run(node);

    // LazySeq を実体化（Clojure と同様、出力時にforceする）
    const result = core.ensureRealized(allocs.persistent(), raw_result) catch raw_result;

    // 結果を出力
    try printValue(writer, result);
    try writer.writeByte('\n');
}

/// コンパイルしてバイトコードをダンプ（stderr に出力）
fn dumpBytecode(
    allocs: *Allocators,
    env: *Env,
    source: []const u8,
    writer: *std.Io.Writer,
) !void {
    const bytecode = clj.bytecode;
    const Compiler = clj.compiler.Compiler;
    const OpCode = bytecode.OpCode;

    // Reader → Analyzer
    var reader = Reader.init(allocs.scratch(), source);
    const located = try reader.readLocated() orelse return error.EmptyInput;
    var analyzer = Analyzer.init(allocs.scratch(), env);
    analyzer.source_line = located.line;
    analyzer.source_column = located.column;
    const node = try analyzer.analyze(located.form);

    // コンパイル
    var compiler = Compiler.init(allocs.persistent());
    defer compiler.deinit();
    try compiler.compile(node);
    try compiler.chunk.emitOp(OpCode.ret);

    // ダンプ
    try bytecode.dumpChunk(&compiler.chunk, writer);

    // 定数テーブル内の FnProto を再帰的にダンプ
    for (compiler.chunk.constants.items) |c| {
        if (c == .fn_proto) {
            const proto: *const bytecode.FnProto = @ptrCast(@alignCast(c.fn_proto));
            try bytecode.dumpFnProto(proto, writer);
        }
    }

    writer.flush() catch {};
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
    const located = try reader.readLocated() orelse return error.EmptyInput;

    // Analyzer（scratch アロケータ）
    var analyzer = Analyzer.init(allocs.scratch(), env);
    analyzer.source_line = located.line;
    analyzer.source_column = located.column;
    const node = try analyzer.analyze(located.form);

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
        .var_val => |vp| {
            const v: *const var_mod.Var = @ptrCast(@alignCast(vp));
            try writer.writeAll("#'");
            if (v.ns_name.len > 0) {
                try writer.writeAll(v.ns_name);
                try writer.writeByte('/');
            }
            try writer.writeAll(v.sym.name);
        },
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
        .wasm_module => |wm| {
            if (wm.path) |path| {
                try writer.writeAll("#<wasm-module ");
                try writer.writeAll(path);
                try writer.writeByte('>');
            } else {
                try writer.writeAll("#<wasm-module>");
            }
        },
    }
}

/// REPL: 対話型シェル
fn runRepl(gpa_allocator: std.mem.Allocator, backend: Backend, compare_mode: bool, gc_stats: bool) !void {
    // stdout/stderr
    const stderr_file = std.fs.File.stderr();
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_writer = stderr_file.writer(&stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    // 環境を初期化
    var allocs = Allocators.init(gpa_allocator);
    defer {
        if (gc_stats) allocs.printGcSummary();
        allocs.deinit();
    }
    allocs.gc_stats_enabled = gc_stats;

    var env = Env.init(gpa_allocator);
    defer env.deinit();
    try env.setupBasic();
    try core.registerCore(&env, allocs.persistent());
    core.initLoadedLibs(allocs.persistent());

    // デフォルトクラスパス
    core.addClasspathRoot("src/clj");

    // 行エディタ初期化
    var editor = LineEditor.init(gpa_allocator);
    defer editor.deinit();

    // 履歴ファイル設定
    if (std.posix.getenv("HOME")) |home| {
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/.clj_wasm_history", .{home}) catch null;
        if (path) |p| {
            editor.setHistoryPath(p) catch {};
            editor.loadHistory();
        }
    }

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

    // 入力バッファ (複数行入力用)
    var input_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer input_buf.deinit(gpa_allocator);

    var vm_snapshot: ?engine_mod.VarSnapshot = null;

    // プロンプトバッファ
    var prompt_buf: [128]u8 = undefined;

    while (true) {
        // プロンプト構築
        const ns_name = if (env.getCurrentNs()) |ns| ns.name else "user";
        const prompt = if (input_buf.items.len == 0)
            std.fmt.bufPrint(&prompt_buf, "{s}=> ", .{ns_name}) catch "=> "
        else
            std.fmt.bufPrint(&prompt_buf, "{s}.. ", .{ns_name}) catch ".. ";

        // 1行読み込み (LineEditor)
        const line = editor.readLine(prompt) catch |err| {
            reportError(err, stderr);
            return;
        } orelse {
            // EOF (Ctrl-D)
            editor.saveHistory();
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

        // 完全な式が入力されたら履歴に追加
        editor.addHistory(input_buf.items) catch {};

        // 入力を評価
        // persistent アロケータを使用（シンボル名が source 内を指すため解放不可）
        const source = try allocs.persistent().dupe(u8, input_buf.items);
        input_buf.clearRetainingCapacity();

        // scratch リセット
        allocs.resetScratch();

        // エラー表示用にソーステキストを設定
        base_error.setSourceText(source);

        if (compare_mode) {
            const compare_out = runCompare(&allocs, &env, source, vm_snapshot, stdout, stderr) catch |err| {
                reportError(err, stderr);
                base_error.setSourceText(null);
                ve.bindRoot(Value.nil);
                continue;
            };
            vm_snapshot = compare_out;
        } else {
            // 評価
            const result = evalForRepl(&allocs, &env, source, backend) catch |err| {
                reportError(err, stderr);
                base_error.setSourceText(null);
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

        base_error.setSourceText(null);

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
    const located = try reader.readLocated() orelse return error.EmptyInput;
    var analyzer = Analyzer.init(allocs.scratch(), env);
    analyzer.source_line = located.line;
    analyzer.source_column = located.column;
    const node = try analyzer.analyze(located.form);
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
        \\  clj-wasm [options] [script.clj]
        \\
        \\Options:
        \\  -e <expr>              Evaluate the expression
        \\  --classpath=<paths>    Add classpath roots (colon-separated)
        \\  -cp <paths>            Add classpath roots (colon-separated)
        \\  --backend=<backend>    Select backend: tree_walk (default), vm
        \\  --compare              Run both backends and compare results
        \\  --gc-stats             Show GC statistics on stderr
        \\  --dump-bytecode        Dump compiled bytecode (VM backend)
        \\  -h, --help             Show this help message
        \\  --version              Show version information
        \\
        \\Examples:
        \\  clj-wasm script.clj
        \\  clj-wasm -e "(+ 1 2 3)"
        \\  clj-wasm -e "(def x 10)" -e "(+ x 5)"
        \\  clj-wasm --classpath=src:test/libs -e "(require 'my.lib)"
        \\  clj-wasm --backend=vm -e "(+ 1 2)"
        \\  clj-wasm --compare -e "(if true 1 2)"
        \\  clj-wasm --dump-bytecode -e "(defn f [x] (+ x 1))"
        \\
    );
}

/// babashka 風エラー表示
/// base/error.zig に詳細情報があればフォーマット表示、なければ従来通り
fn reportError(err: anyerror, writer: *std.Io.Writer) void {
    if (base_error.getLastError()) |info| {
        // babashka 風フォーマット
        writer.writeAll("----- Error --------------------------------------------------------------------\n") catch {};
        writer.print("Type:     {s}\n", .{@tagName(info.kind)}) catch {};
        writer.print("Message:  {s}\n", .{info.message}) catch {};
        if (info.phase != .eval) {
            writer.print("Phase:    {s}\n", .{@tagName(info.phase)}) catch {};
        }
        if (info.location.line > 0) {
            writer.writeAll("Location: ") catch {};
            const file = info.location.file orelse "NO_SOURCE_PATH";
            writer.print("{s}:{d}:{d}\n", .{ file, info.location.line, info.location.column }) catch {};
        }
        // 周辺ソースコード表示
        if (info.location.line > 0) {
            showSourceContext(writer, info.location);
        }
        // スタックトレース
        if (info.callstack) |frames| {
            writer.writeAll("----- Stack Trace --------------------------------------------------------------\n") catch {};
            for (frames) |frame| {
                if (frame.is_builtin) {
                    writer.print("  {s} (builtin)\n", .{frame.name}) catch {};
                } else {
                    writer.print("  {s}\n", .{frame.name}) catch {};
                }
            }
        }
    } else {
        // 詳細なし — Zig エラー名をフォールバック表示
        writer.print("Error: {s}\n", .{@errorName(err)}) catch {};
    }
    writer.flush() catch {};
}

/// エラー位置の周辺ソースコードを表示
/// ファイルパスがあればファイルを読み込み、なければ threadlocal のソーステキストを使用
fn showSourceContext(writer: *std.Io.Writer, location: base_error.SourceLocation) void {
    const source = getSourceForLocation(location) orelse return;
    const error_line = location.line; // 1-based

    // 行を分割してエラー行の前後2行を表示
    var lines: [512][]const u8 = undefined; // 最大512行
    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |line| {
        if (line_count >= lines.len) break;
        lines[line_count] = line;
        line_count += 1;
    }

    if (error_line == 0 or error_line > line_count) return;

    // 表示範囲: エラー行の前後2行
    const context_lines: u32 = 2;
    const start = if (error_line > context_lines) error_line - context_lines else 1;
    const end = @min(error_line + context_lines, @as(u32, @intCast(line_count)));

    // 行番号の最大桁数を計算
    const max_digits = countDigits(end);

    writer.writeByte('\n') catch {};
    var line_num: u32 = start;
    while (line_num <= end) : (line_num += 1) {
        const line_text = lines[line_num - 1];
        // 行番号を右寄せで表示
        writeLineNumber(writer, line_num, max_digits);
        writer.print(" | {s}\n", .{line_text}) catch {};
        // エラー行にはポインタを付与
        if (line_num == error_line) {
            writeErrorPointer(writer, max_digits, location.column);
        }
    }
    writer.writeByte('\n') catch {};
}

/// 行番号を右寄せで表示（"  " + 右寄せ行番号）
fn writeLineNumber(writer: *std.Io.Writer, line_num: u32, width: u32) void {
    const digits = countDigits(line_num);
    writer.writeAll("  ") catch {};
    // パディング
    var pad: u32 = 0;
    while (pad + digits < width) : (pad += 1) {
        writer.writeByte(' ') catch {};
    }
    writer.print("{d}", .{line_num}) catch {};
}

/// エラーカラム位置にポインタを表示
fn writeErrorPointer(writer: *std.Io.Writer, max_digits: u32, column: u32) void {
    // "  " + digits + " | " の分のスペース
    const prefix_len = 2 + max_digits + 3;
    var i: u32 = 0;
    while (i < prefix_len + column) : (i += 1) {
        writer.writeByte(' ') catch {};
    }
    writer.writeAll("^--- error here\n") catch {};
}

/// 数値の桁数を返す
fn countDigits(n: u32) u32 {
    if (n == 0) return 1;
    var count: u32 = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        count += 1;
    }
    return count;
}

/// エラー位置に対応するソースコードを取得
/// ファイルパスがあればファイル読み込み、なければ threadlocal を参照
fn getSourceForLocation(location: base_error.SourceLocation) ?[]const u8 {
    // ファイルパスからの読み込みを優先
    if (location.file) |file_path| {
        if (readFileForError(file_path)) |content| {
            return content;
        }
    }
    // フォールバック: threadlocal のソーステキスト（-e 引数やREPL入力）
    return base_error.getSourceText();
}

/// エラー表示用にファイルを読み込む（静的バッファ使用）
var file_read_buf: [64 * 1024]u8 = undefined; // 64KB
fn readFileForError(path: []const u8) ?[]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const bytes_read = file.readAll(&file_read_buf) catch return null;
    return file_read_buf[0..bytes_read];
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
