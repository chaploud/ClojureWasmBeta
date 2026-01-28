//! nREPL サーバー
//!
//! TCP ベースの nREPL プロトコル実装。
//! CIDER/Calva/Conjure 互換の最小 ops セットを提供。
//!
//! ops: clone, close, describe, eval, load-file,
//!      completions, info, lookup, eldoc, ls-sessions, ns-list

const std = @import("std");
const bencode = @import("bencode.zig");
const BencodeValue = bencode.BencodeValue;
const clj = @import("../root.zig");

const Reader = clj.Reader;
const Analyzer = clj.Analyzer;
const Env = clj.Env;
const Value = clj.Value;
const EvalEngine = clj.EvalEngine;
const Backend = clj.Backend;
const Allocators = clj.Allocators;
const core = clj.core;
const base_error = clj.err;
const var_mod = clj.var_mod;

/// セッション
const Session = struct {
    id: []const u8,
    ns_name: []const u8,
    // *1/*2/*3/*e は Env の user NS に保持 (シンプル化)
};

/// サーバー状態 (全クライアントスレッドで共有)
const ServerState = struct {
    env: *Env,
    allocs: *Allocators,
    sessions: std.StringHashMapUnmanaged(Session),
    mutex: std.Thread.Mutex,
    backend: Backend,
    running: bool,
    gpa: std.mem.Allocator,
    port_file_written: bool,
};

/// nREPL サーバーを起動
pub fn startServer(gpa_allocator: std.mem.Allocator, port: u16, backend: Backend) !void {
    // stdout/stderr
    const stderr_file = std.fs.File.stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = stderr_file.writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    // 環境初期化
    var allocs = Allocators.init(gpa_allocator);
    defer allocs.deinit();

    var env = Env.init(gpa_allocator);
    defer env.deinit();
    try env.setupBasic();
    try core.registerCore(&env, allocs.persistent());
    core.initLoadedLibs(allocs.persistent());
    core.addClasspathRoot("src/clj");

    // サーバー状態
    var state = ServerState{
        .env = &env,
        .allocs = &allocs,
        .sessions = .empty,
        .mutex = .{},
        .backend = backend,
        .running = true,
        .gpa = gpa_allocator,
        .port_file_written = false,
    };
    defer {
        // .nrepl-port 削除
        if (state.port_file_written) {
            std.fs.cwd().deleteFile(".nrepl-port") catch {};
        }
        // セッション解放
        state.sessions.deinit(gpa_allocator);
    }

    // TCP リッスン
    const address = std.net.Address.parseIp("127.0.0.1", port) catch unreachable;
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    const actual_port = server.listen_address.getPort();

    // .nrepl-port ファイル書き出し
    {
        var port_buf: [10]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{actual_port}) catch unreachable;
        std.fs.cwd().writeFile(.{ .sub_path = ".nrepl-port", .data = port_str }) catch {};
        state.port_file_written = true;
    }

    stderr.print("nREPL server started on port {d} on host 127.0.0.1 - nrepl://127.0.0.1:{d}\n", .{ actual_port, actual_port }) catch {};
    stderr.flush() catch {};

    // 接続受付ループ
    while (state.running) {
        const conn = server.accept() catch |err| {
            stderr.print("accept error: {s}\n", .{@errorName(err)}) catch {};
            stderr.flush() catch {};
            continue;
        };

        // クライアントスレッド起動
        const thread = std.Thread.spawn(.{}, handleClient, .{ &state, conn }) catch |err| {
            stderr.print("thread spawn error: {s}\n", .{@errorName(err)}) catch {};
            stderr.flush() catch {};
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

/// クライアント接続ハンドラ (スレッドエントリ)
fn handleClient(state: *ServerState, conn: std.net.Server.Connection) void {
    defer conn.stream.close();
    messageLoop(state, conn.stream);
}

/// bencode メッセージループ
fn messageLoop(state: *ServerState, stream: std.net.Stream) void {
    // 受信バッファ
    var recv_buf: [65536]u8 = undefined;
    var pending: std.ArrayListUnmanaged(u8) = .empty;
    defer pending.deinit(state.gpa);

    while (true) {
        // ストリームから読み取り
        const n = stream.read(&recv_buf) catch break;
        if (n == 0) break; // 接続切断

        pending.appendSlice(state.gpa, recv_buf[0..n]) catch break;

        // バッファ内の完全なメッセージを処理
        while (pending.items.len > 0) {
            // デコード試行用 arena
            var arena = std.heap.ArenaAllocator.init(state.gpa);
            defer arena.deinit();

            const result = bencode.decode(arena.allocator(), pending.items) catch |err| {
                switch (err) {
                    error.UnexpectedEof => break, // データ不足 → 次の read を待つ
                    else => {
                        // 不正データ → 接続切断
                        return;
                    },
                }
            };

            // メッセージ処理
            const msg = switch (result.value) {
                .dict => |d| d,
                else => {
                    // dict でなければ無視
                    shiftPending(&pending, result.consumed);
                    continue;
                },
            };

            dispatchOp(state, msg, stream, arena.allocator());

            // 処理済みデータを除去
            shiftPending(&pending, result.consumed);
        }
    }
}

/// pending バッファから先頭 n バイトを除去
fn shiftPending(pending: *std.ArrayListUnmanaged(u8), n: usize) void {
    if (n >= pending.items.len) {
        pending.clearRetainingCapacity();
    } else {
        std.mem.copyForwards(u8, pending.items[0..], pending.items[n..]);
        pending.items.len -= n;
    }
}

/// op を振り分け
fn dispatchOp(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
) void {
    const op = bencode.dictGetString(msg, "op") orelse {
        sendError(stream, msg, "missing-op", "No op specified", allocator);
        return;
    };

    if (std.mem.eql(u8, op, "clone")) {
        opClone(state, msg, stream, allocator);
    } else if (std.mem.eql(u8, op, "close")) {
        opClose(state, msg, stream, allocator);
    } else if (std.mem.eql(u8, op, "describe")) {
        opDescribe(msg, stream, allocator);
    } else if (std.mem.eql(u8, op, "eval")) {
        opEval(state, msg, stream, allocator);
    } else if (std.mem.eql(u8, op, "load-file")) {
        opLoadFile(state, msg, stream, allocator);
    } else if (std.mem.eql(u8, op, "ls-sessions")) {
        opLsSessions(state, msg, stream, allocator);
    } else if (std.mem.eql(u8, op, "completions") or std.mem.eql(u8, op, "complete")) {
        opCompletions(state, msg, stream, allocator);
    } else if (std.mem.eql(u8, op, "info") or std.mem.eql(u8, op, "lookup")) {
        opInfo(state, msg, stream, allocator);
    } else if (std.mem.eql(u8, op, "eldoc")) {
        opEldoc(state, msg, stream, allocator);
    } else if (std.mem.eql(u8, op, "ns-list")) {
        opNsList(state, msg, stream, allocator);
    } else if (std.mem.eql(u8, op, "stdin")) {
        // stdin op はサポートしないが done を返す
        sendDone(stream, msg, allocator);
    } else {
        // 未知の op でも done を返す (CIDER が固まらないように)
        sendDone(stream, msg, allocator);
    }
}

// ====================================================================
// ops 実装
// ====================================================================

/// clone: 新規セッション作成
fn opClone(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
) void {
    const session_id = generateUUID(allocator) catch return;

    // セッション登録
    state.mutex.lock();
    const ns_name = state.gpa.dupe(u8, "user") catch {
        state.mutex.unlock();
        return;
    };
    const id_persistent = state.gpa.dupe(u8, session_id) catch {
        state.mutex.unlock();
        return;
    };
    state.sessions.put(state.gpa, id_persistent, .{
        .id = id_persistent,
        .ns_name = ns_name,
    }) catch {
        state.mutex.unlock();
        return;
    };
    state.mutex.unlock();

    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        .{ .key = "new-session", .value = .{ .string = session_id } },
        statusDone(),
    };
    sendBencode(stream, &entries, allocator);
}

/// close: セッション削除
fn opClose(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
) void {
    if (bencode.dictGetString(msg, "session")) |sid| {
        state.mutex.lock();
        if (state.sessions.fetchRemove(sid)) |entry| {
            state.gpa.free(entry.value.id);
            state.gpa.free(entry.value.ns_name);
        }
        state.mutex.unlock();
    }
    sendDone(stream, msg, allocator);
}

/// describe: サーバー情報
fn opDescribe(
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
) void {
    const ops_entries = [_]BencodeValue.DictEntry{
        .{ .key = "clone", .value = .{ .dict = &.{} } },
        .{ .key = "close", .value = .{ .dict = &.{} } },
        .{ .key = "describe", .value = .{ .dict = &.{} } },
        .{ .key = "eval", .value = .{ .dict = &.{} } },
        .{ .key = "load-file", .value = .{ .dict = &.{} } },
        .{ .key = "ls-sessions", .value = .{ .dict = &.{} } },
        .{ .key = "completions", .value = .{ .dict = &.{} } },
        .{ .key = "complete", .value = .{ .dict = &.{} } },
        .{ .key = "info", .value = .{ .dict = &.{} } },
        .{ .key = "lookup", .value = .{ .dict = &.{} } },
        .{ .key = "eldoc", .value = .{ .dict = &.{} } },
        .{ .key = "ns-list", .value = .{ .dict = &.{} } },
        .{ .key = "stdin", .value = .{ .dict = &.{} } },
    };

    const version_entries = [_]BencodeValue.DictEntry{
        .{ .key = "major", .value = .{ .integer = 0 } },
        .{ .key = "minor", .value = .{ .integer = 1 } },
        .{ .key = "incremental", .value = .{ .integer = 0 } },
    };

    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        .{ .key = "ops", .value = .{ .dict = &ops_entries } },
        .{ .key = "versions", .value = .{ .dict = &.{
            .{ .key = "clojure-wasm", .value = .{ .dict = &version_entries } },
        } } },
        statusDone(),
    };
    sendBencode(stream, &entries, allocator);
}

/// eval: 式を評価
fn opEval(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
) void {
    const code = bencode.dictGetString(msg, "code") orelse {
        sendError(stream, msg, "eval-error", "No code provided", allocator);
        return;
    };

    // セッションの NS を取得
    const session_id = bencode.dictGetString(msg, "session");
    const ns_name = if (bencode.dictGetString(msg, "ns")) |n|
        n
    else if (session_id) |sid| blk: {
        state.mutex.lock();
        defer state.mutex.unlock();
        break :blk if (state.sessions.get(sid)) |s| s.ns_name else "user";
    } else "user";

    // mutex ロック (eval 直列化)
    state.mutex.lock();
    defer state.mutex.unlock();

    // NS 切り替え
    if (state.env.findNs(ns_name)) |ns| {
        state.env.setCurrentNs(ns);
    }

    // output capture セットアップ
    var capture_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer capture_buf.deinit(state.gpa);
    core.setOutputCapture(&capture_buf);
    core.setOutputCaptureAllocator(state.gpa);
    defer {
        core.setOutputCapture(null);
        core.setOutputCaptureAllocator(null);
    }

    // ソーステキスト設定
    base_error.setSourceText(code);
    defer base_error.setSourceText(null);

    // コードを persistent にコピー (scratch リセットで source が消えないように)
    const code_persistent = state.allocs.persistent().dupe(u8, code) catch code;

    // scratch リセット
    state.allocs.resetScratch();

    // マルチフォーム対応: Reader で全フォームを順次評価
    var reader_state = Reader.init(state.allocs.scratch(), code_persistent);
    var had_error = false;

    while (true) {
        const located = reader_state.readLocated() catch |err| {
            sendEvalError(stream, msg, err, allocator);
            had_error = true;
            break;
        } orelse break; // EOF

        var analyzer = Analyzer.init(state.allocs.scratch(), state.env);
        analyzer.source_line = located.line;
        analyzer.source_column = located.column;

        const node = analyzer.analyze(located.form) catch |err| {
            sendEvalError(stream, msg, err, allocator);
            had_error = true;
            break;
        };

        var eng = EvalEngine.init(state.allocs.persistent(), state.env, state.backend);
        const raw_result = eng.run(node) catch |err| {
            sendEvalError(stream, msg, err, allocator);
            had_error = true;
            break;
        };

        const last_value = core.ensureRealized(state.allocs.persistent(), raw_result) catch raw_result;

        // キャプチャ出力があれば送信
        if (capture_buf.items.len > 0) {
            const out_entries = [_]BencodeValue.DictEntry{
                idEntry(msg),
                sessionEntry(msg),
                .{ .key = "out", .value = .{ .string = capture_buf.items } },
            };
            sendBencode(stream, &out_entries, allocator);
            capture_buf.clearRetainingCapacity();
        }

        // 各フォームの結果を送信
        var val_buf: std.ArrayListUnmanaged(u8) = .empty;
        core.printValueToBuf(allocator, &val_buf, last_value) catch {};

        const current_ns_name = if (state.env.getCurrentNs()) |ns| ns.name else "user";

        const val_entries = [_]BencodeValue.DictEntry{
            idEntry(msg),
            sessionEntry(msg),
            .{ .key = "value", .value = .{ .string = val_buf.items } },
            .{ .key = "ns", .value = .{ .string = current_ns_name } },
        };
        sendBencode(stream, &val_entries, allocator);
    }

    // セッションの NS を更新
    if (session_id) |sid| {
        if (state.sessions.getPtr(sid)) |session| {
            if (state.env.getCurrentNs()) |ns| {
                state.gpa.free(session.ns_name);
                session.ns_name = state.gpa.dupe(u8, ns.name) catch session.ns_name;
            }
        }
    }

    // GC
    state.allocs.collectGarbage(state.env, core.getGcGlobals());

    if (!had_error) {
        sendDone(stream, msg, allocator);
    }
}

/// eval エラーをレスポンスとして送信
fn sendEvalError(
    stream: std.net.Stream,
    msg: []const BencodeValue.DictEntry,
    err: anyerror,
    allocator: std.mem.Allocator,
) void {
    var err_msg_buf: [512]u8 = undefined;
    const err_msg = if (base_error.getLastError()) |info|
        info.message
    else
        std.fmt.bufPrint(&err_msg_buf, "{s}", .{@errorName(err)}) catch "unknown error";

    // err レスポンス
    const err_entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        sessionEntry(msg),
        .{ .key = "err", .value = .{ .string = err_msg } },
    };
    sendBencode(stream, &err_entries, allocator);

    // ex レスポンス
    const ex_entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        sessionEntry(msg),
        .{ .key = "ex", .value = .{ .string = err_msg } },
    };
    sendBencode(stream, &ex_entries, allocator);

    // status done + eval-error
    const status_items = [_]BencodeValue{
        .{ .string = "done" },
        .{ .string = "eval-error" },
    };
    const done_entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        sessionEntry(msg),
        .{ .key = "status", .value = .{ .list = &status_items } },
    };
    sendBencode(stream, &done_entries, allocator);
}

/// load-file: ファイルをロード
fn opLoadFile(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
) void {
    const file_content = bencode.dictGetString(msg, "file") orelse {
        sendError(stream, msg, "eval-error", "No file content provided", allocator);
        return;
    };

    // ファイル内容をコードとして eval
    var eval_msg_buf: [8]BencodeValue.DictEntry = undefined;
    var eval_msg_len: usize = 0;

    // 元のメッセージから id/session をコピーし、code をファイル内容に置換
    for (msg) |entry| {
        if (eval_msg_len >= eval_msg_buf.len) break;
        if (std.mem.eql(u8, entry.key, "op")) {
            eval_msg_buf[eval_msg_len] = .{ .key = "op", .value = .{ .string = "eval" } };
        } else if (std.mem.eql(u8, entry.key, "file")) {
            eval_msg_buf[eval_msg_len] = .{ .key = "code", .value = .{ .string = file_content } };
        } else {
            eval_msg_buf[eval_msg_len] = entry;
        }
        eval_msg_len += 1;
    }

    opEval(state, eval_msg_buf[0..eval_msg_len], stream, allocator);
}

/// ls-sessions: セッション一覧
fn opLsSessions(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    var session_list: std.ArrayListUnmanaged(BencodeValue) = .empty;
    var iter = state.sessions.iterator();
    while (iter.next()) |entry| {
        session_list.append(allocator, .{ .string = entry.value_ptr.id }) catch {};
    }

    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        .{ .key = "sessions", .value = .{ .list = session_list.items } },
        statusDone(),
    };
    sendBencode(stream, &entries, allocator);
}

/// completions: 補完候補
fn opCompletions(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
) void {
    const prefix = bencode.dictGetString(msg, "prefix") orelse
        bencode.dictGetString(msg, "symbol") orelse "";

    state.mutex.lock();
    defer state.mutex.unlock();

    var completions: std.ArrayListUnmanaged(BencodeValue) = .empty;

    // 現在の NS の vars
    if (state.env.getCurrentNs()) |ns| {
        collectCompletions(allocator, &completions, ns.getAllVars(), prefix, ns.name);
        // refers
        collectCompletions(allocator, &completions, ns.getAllRefers(), prefix, null);
    }

    // clojure.core の vars
    if (state.env.findNs("clojure.core")) |core_ns| {
        collectCompletions(allocator, &completions, core_ns.getAllVars(), prefix, "clojure.core");
    }

    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        .{ .key = "completions", .value = .{ .list = completions.items } },
        statusDone(),
    };
    sendBencode(stream, &entries, allocator);
}

/// 補完候補を収集
fn collectCompletions(
    allocator: std.mem.Allocator,
    completions: *std.ArrayListUnmanaged(BencodeValue),
    iter: anytype,
    prefix: []const u8,
    ns_name: ?[]const u8,
) void {
    var it = iter;
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (prefix.len == 0 or std.mem.startsWith(u8, name, prefix)) {
            const v: *const var_mod.Var = @ptrCast(@alignCast(entry.value_ptr.*));
            if (v.isPrivate()) continue;

            var comp_entries_buf: [3]BencodeValue.DictEntry = undefined;
            var comp_len: usize = 0;
            comp_entries_buf[comp_len] = .{ .key = "candidate", .value = .{ .string = name } };
            comp_len += 1;
            if (ns_name) |ns| {
                comp_entries_buf[comp_len] = .{ .key = "ns", .value = .{ .string = ns } };
                comp_len += 1;
            }
            comp_entries_buf[comp_len] = .{ .key = "type", .value = .{ .string = "var" } };
            comp_len += 1;

            const comp_dict = allocator.dupe(BencodeValue.DictEntry, comp_entries_buf[0..comp_len]) catch continue;
            completions.append(allocator, .{ .dict = comp_dict }) catch {};
        }
    }
}

/// info / lookup: シンボル情報
fn opInfo(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
) void {
    const sym_name = bencode.dictGetString(msg, "sym") orelse
        bencode.dictGetString(msg, "symbol") orelse {
        sendDone(stream, msg, allocator);
        return;
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    // シンボル解決
    const v = resolveSymbol(state.env, sym_name, bencode.dictGetString(msg, "ns"));
    if (v == null) {
        // no-info status
        const status_items = [_]BencodeValue{
            .{ .string = "done" },
            .{ .string = "no-info" },
        };
        const entries = [_]BencodeValue.DictEntry{
            idEntry(msg),
            .{ .key = "status", .value = .{ .list = &status_items } },
        };
        sendBencode(stream, &entries, allocator);
        return;
    }

    const var_ptr = v.?;
    var info_entries: std.ArrayListUnmanaged(BencodeValue.DictEntry) = .empty;
    info_entries.append(allocator, idEntry(msg)) catch {};
    info_entries.append(allocator, .{ .key = "name", .value = .{ .string = var_ptr.sym.name } }) catch {};
    if (var_ptr.ns_name.len > 0) {
        info_entries.append(allocator, .{ .key = "ns", .value = .{ .string = var_ptr.ns_name } }) catch {};
    }
    if (var_ptr.doc) |doc| {
        info_entries.append(allocator, .{ .key = "doc", .value = .{ .string = doc } }) catch {};
    }
    if (var_ptr.arglists) |arglists| {
        info_entries.append(allocator, .{ .key = "arglists-str", .value = .{ .string = arglists } }) catch {};
    }
    info_entries.append(allocator, statusDone()) catch {};

    sendBencode(stream, info_entries.items, allocator);
}

/// eldoc: 引数リスト
fn opEldoc(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
) void {
    const sym_name = bencode.dictGetString(msg, "sym") orelse
        bencode.dictGetString(msg, "symbol") orelse
        bencode.dictGetString(msg, "ns") orelse {
        sendDone(stream, msg, allocator);
        return;
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    const v = resolveSymbol(state.env, sym_name, bencode.dictGetString(msg, "ns"));
    if (v == null) {
        sendDone(stream, msg, allocator);
        return;
    }

    const var_ptr = v.?;
    var eldoc_entries: std.ArrayListUnmanaged(BencodeValue.DictEntry) = .empty;
    eldoc_entries.append(allocator, idEntry(msg)) catch {};
    eldoc_entries.append(allocator, .{ .key = "name", .value = .{ .string = var_ptr.sym.name } }) catch {};
    if (var_ptr.ns_name.len > 0) {
        eldoc_entries.append(allocator, .{ .key = "ns", .value = .{ .string = var_ptr.ns_name } }) catch {};
    }
    if (var_ptr.arglists) |arglists| {
        // eldoc は docstring リストとして返す
        const eldoc_list = [_]BencodeValue{.{ .string = arglists }};
        eldoc_entries.append(allocator, .{ .key = "eldoc", .value = .{ .list = &eldoc_list } }) catch {};
    }
    if (var_ptr.doc) |doc| {
        eldoc_entries.append(allocator, .{ .key = "docstring", .value = .{ .string = doc } }) catch {};
    }
    eldoc_entries.append(allocator, .{ .key = "type", .value = .{ .string = "function" } }) catch {};
    eldoc_entries.append(allocator, statusDone()) catch {};

    sendBencode(stream, eldoc_entries.items, allocator);
}

/// ns-list: 全名前空間一覧
fn opNsList(
    state: *ServerState,
    msg: []const BencodeValue.DictEntry,
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
) void {
    state.mutex.lock();
    defer state.mutex.unlock();

    var ns_list: std.ArrayListUnmanaged(BencodeValue) = .empty;
    var iter = state.env.getAllNamespaces();
    while (iter.next()) |entry| {
        ns_list.append(allocator, .{ .string = entry.key_ptr.* }) catch {};
    }

    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        .{ .key = "ns-list", .value = .{ .list = ns_list.items } },
        statusDone(),
    };
    sendBencode(stream, &entries, allocator);
}

// ====================================================================
// ヘルパー
// ====================================================================

/// シンボルを現在の環境で解決
fn resolveSymbol(env: *Env, sym_name: []const u8, ns_hint: ?[]const u8) ?*var_mod.Var {
    // qualified name (ns/name)
    if (std.mem.indexOfScalar(u8, sym_name, '/')) |slash| {
        const ns_part = sym_name[0..slash];
        const name_part = sym_name[slash + 1 ..];
        if (env.findNs(ns_part)) |ns| {
            return ns.resolve(name_part);
        }
    }

    // ns_hint で名前空間指定
    if (ns_hint) |ns_name| {
        if (env.findNs(ns_name)) |ns| {
            if (ns.resolve(sym_name)) |v| return v;
        }
    }

    // 現在の NS
    if (env.getCurrentNs()) |ns| {
        if (ns.resolve(sym_name)) |v| return v;
    }

    // clojure.core
    if (env.findNs("clojure.core")) |core_ns| {
        return core_ns.resolve(sym_name);
    }

    return null;
}

/// UUID v4 生成
fn generateUUID(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    // v4: version (bits 48-51) = 0100, variant (bits 64-65) = 10
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0], bytes[1], bytes[2],  bytes[3],
        bytes[4], bytes[5],
        bytes[6], bytes[7],
        bytes[8], bytes[9],
        bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    });
}

/// id エントリ (メッセージの id をコピー)
fn idEntry(msg: []const BencodeValue.DictEntry) BencodeValue.DictEntry {
    return .{
        .key = "id",
        .value = .{ .string = bencode.dictGetString(msg, "id") orelse "" },
    };
}

/// session エントリ
fn sessionEntry(msg: []const BencodeValue.DictEntry) BencodeValue.DictEntry {
    return .{
        .key = "session",
        .value = .{ .string = bencode.dictGetString(msg, "session") orelse "" },
    };
}

/// status done エントリ
fn statusDone() BencodeValue.DictEntry {
    const done_items = [_]BencodeValue{.{ .string = "done" }};
    return .{ .key = "status", .value = .{ .list = &done_items } };
}

/// bencode 辞書をストリームに送信
fn sendBencode(
    stream: std.net.Stream,
    entries: []const BencodeValue.DictEntry,
    allocator: std.mem.Allocator,
) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    bencode.encode(allocator, &buf, .{ .dict = entries }) catch return;
    stream.writeAll(buf.items) catch {};
}

/// done レスポンスを送信
fn sendDone(
    stream: std.net.Stream,
    msg: []const BencodeValue.DictEntry,
    allocator: std.mem.Allocator,
) void {
    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        sessionEntry(msg),
        statusDone(),
    };
    sendBencode(stream, &entries, allocator);
}

/// エラーレスポンスを送信
fn sendError(
    stream: std.net.Stream,
    msg: []const BencodeValue.DictEntry,
    status: []const u8,
    err_msg: []const u8,
    allocator: std.mem.Allocator,
) void {
    const status_items = [_]BencodeValue{
        .{ .string = "done" },
        .{ .string = status },
    };
    const entries = [_]BencodeValue.DictEntry{
        idEntry(msg),
        sessionEntry(msg),
        .{ .key = "err", .value = .{ .string = err_msg } },
        .{ .key = "status", .value = .{ .list = &status_items } },
    };
    sendBencode(stream, &entries, allocator);
}
