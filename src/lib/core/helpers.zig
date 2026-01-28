//! 共通ユーティリティ関数
//!
//! 複数のドメインファイルから参照される共有関数群。

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const Fn = defs.Fn;
const Env = defs.Env;
const Reader = defs.Reader;
const Analyzer = defs.Analyzer;
const tree_walk = defs.tree_walk;
const Context = defs.Context;
const var_mod = defs.var_mod;
const base_err = @import("../../base/error.zig");
const CoreError = defs.CoreError;

const lazy = @import("lazy.zig");

// ============================================================
// コレクション要素取得
// ============================================================

/// コレクション（list, vector）の要素スライスを取得
pub fn getItems(val: Value) ?[]const Value {
    return switch (val) {
        .list => |l| l.items,
        .vector => |v| v.items,
        .nil => &[_]Value{},
        else => null,
    };
}

/// LazySeq 対応版 getItems — force してから items を取得
pub fn getItemsRealized(allocator: std.mem.Allocator, val: Value) anyerror!?[]const Value {
    const realized = try ensureRealized(allocator, val);
    return getItems(realized);
}

/// LazySeq を完全に実体化する
pub fn ensureRealized(allocator: std.mem.Allocator, val: Value) anyerror!Value {
    if (val == .lazy_seq) {
        return lazy.forceLazySeq(allocator, val.lazy_seq);
    }
    return val;
}

/// コレクション（list, vector, set, lazy_seq）の要素をスライスとして取得
/// 呼び出し側で allocator.free が必要
pub fn collectToSlice(allocator: std.mem.Allocator, val: Value) anyerror![]const Value {
    const realized = try ensureRealized(allocator, val);
    return switch (realized) {
        .list => |l| blk: {
            const result = try allocator.alloc(Value, l.items.len);
            @memcpy(result, l.items);
            break :blk result;
        },
        .vector => |v| blk: {
            const result = try allocator.alloc(Value, v.items.len);
            @memcpy(result, v.items);
            break :blk result;
        },
        .set => |s| blk: {
            const result = try allocator.alloc(Value, s.items.len);
            @memcpy(result, s.items);
            break :blk result;
        },
        .nil => try allocator.alloc(Value, 0),
        .string => |s| blk: {
            // 文字列は各文字をcharに変換
            var items = std.ArrayList(Value).empty;
            defer items.deinit(allocator);
            for (s.data) |c| {
                try items.append(allocator, Value{ .char_val = c });
            }
            break :blk try items.toOwnedSlice(allocator);
        },
        else => error.TypeError,
    };
}

// ============================================================
// 出力ユーティリティ
// ============================================================

/// 出力先にデータを書き出す
pub fn writeToOutput(data: []const u8) void {
    if (defs.output_capture) |cap| {
        if (defs.output_capture_allocator) |alloc| {
            cap.appendSlice(alloc, data) catch {};
        }
    } else {
        const stdout = std.fs.File.stdout();
        var buf: [4096]u8 = undefined;
        var file_writer = stdout.writer(&buf);
        const writer = &file_writer.interface;
        writer.writeAll(data) catch {};
        writer.flush() catch {};
    }
}

/// 出力先に 1 バイトを書き出す
pub fn writeByteToOutput(byte: u8) void {
    if (defs.output_capture) |cap| {
        if (defs.output_capture_allocator) |alloc| {
            cap.append(alloc, byte) catch {};
        }
    } else {
        const stdout = std.fs.File.stdout();
        var buf: [4096]u8 = undefined;
        var file_writer = stdout.writer(&buf);
        const writer = &file_writer.interface;
        writer.writeByte(byte) catch {};
        writer.flush() catch {};
    }
}

/// 値をフォーマットして出力先に書き出す (print/println 用: 文字列クォートなし)
pub fn outputValueForPrint(_: std.mem.Allocator, val: Value) void {
    if (defs.output_capture) |cap| {
        if (defs.output_capture_allocator) |alloc| {
            // バッファに書き出す
            switch (val) {
                .string => |s| cap.appendSlice(alloc, s.data) catch {},
                else => {
                    printValueToBuf(alloc, cap, val) catch {};
                },
            }
        }
    } else {
        const stdout = std.fs.File.stdout();
        var buf: [4096]u8 = undefined;
        var file_writer = stdout.writer(&buf);
        const writer = &file_writer.interface;
        printValueForPrint(writer, val) catch {};
        writer.flush() catch {};
    }
}

/// 値をフォーマットして出力先に書き出す (pr/prn 用: 文字列クォート付き)
pub fn outputValueForPr(_: std.mem.Allocator, val: Value) void {
    if (defs.output_capture) |cap| {
        if (defs.output_capture_allocator) |alloc| {
            printValueToBuf(alloc, cap, val) catch {};
        }
    } else {
        const stdout = std.fs.File.stdout();
        var buf: [4096]u8 = undefined;
        var file_writer = stdout.writer(&buf);
        const writer = &file_writer.interface;
        printValue(writer, val) catch {};
        writer.flush() catch {};
    }
}

/// 値を出力（print/println 用 - 文字列はクォートなし）
pub fn printValueForPrint(writer: anytype, val: Value) !void {
    switch (val) {
        .string => |s| try writer.writeAll(s.data), // クォートなし
        else => try printValue(writer, val),
    }
}

/// 値を出力（writer 版）
pub fn printValue(writer: anytype, val: Value) !void {
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
            // 実体化済みなら中身を表示
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

/// 値を出力（ArrayListUnmanaged 版）
pub fn printValueToBuf(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), val: Value) !void {
    const BufWriter = struct {
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
    var ctx = BufWriter{ .buf = buf, .allocator = allocator };
    try printValue(&ctx, val);
}

/// 値を文字列に変換（str 用 - pr-str と違ってクォートなし）
pub fn valueToString(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), val: Value) !void {
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
// 数値比較・変換ユーティリティ
// ============================================================

/// 数値の比較 (-1, 0, 1)
pub fn compareNumbers(a: Value, b: Value) CoreError!i8 {
    const fa: f64 = switch (a) {
        .int => |n| @as(f64, @floatFromInt(n)),
        .float => |f| f,
        else => {
            @branchHint(.cold);
            base_err.setTypeError("number", a.typeName());
            return error.TypeError;
        },
    };
    const fb: f64 = switch (b) {
        .int => |n| @as(f64, @floatFromInt(n)),
        .float => |f| f,
        else => {
            @branchHint(.cold);
            base_err.setTypeError("number", b.typeName());
            return error.TypeError;
        },
    };

    if (fa < fb) return -1;
    if (fa > fb) return 1;
    return 0;
}

/// 数値を float に変換
pub fn numToFloat(v: Value) ?f64 {
    return switch (v) {
        .int => |n| @as(f64, @floatFromInt(n)),
        .float => |f| f,
        else => null,
    };
}

/// 値が関数かどうか
pub fn isFnValue(v: Value) bool {
    return switch (v) {
        .fn_val, .partial_fn, .comp_fn, .fn_proto => true,
        else => false,
    };
}

/// 値の比較 (sort 等で使用)
pub fn compareValues(a: Value, b: Value) i64 {
    if (a == .int and b == .int) {
        if (a.int < b.int) return -1;
        if (a.int > b.int) return 1;
        return 0;
    }
    const af: f64 = if (a == .int) @floatFromInt(a.int) else if (a == .float) a.float else return 0;
    const bf: f64 = if (b == .int) @floatFromInt(b.int) else if (b == .float) b.float else return 0;
    if (af < bf) return -1;
    if (af > bf) return 1;
    return 0;
}

// ============================================================
// デバッグ・ファイルロード
// ============================================================

/// デバッグログ出力（stderr）
pub fn debugLog(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    const stderr = &writer.interface;
    stderr.print(fmt ++ "\n", args) catch {};
    stderr.flush() catch {};
}

/// NS名からファイルパスに変換 (例: "my.lib.core" + ".clj" → "my/lib/core.clj")
pub fn nsNameToPath(allocator: std.mem.Allocator, ns_name: []const u8, ext: []const u8) ![]const u8 {
    // ドットをスラッシュに、ハイフンをアンダースコアに変換
    var path = try allocator.alloc(u8, ns_name.len + ext.len);
    var pi: usize = 0;
    for (ns_name) |c| {
        path[pi] = switch (c) {
            '.' => '/',
            '-' => '_',
            else => c,
        };
        pi += 1;
    }
    @memcpy(path[pi..][0..ext.len], ext);
    return path[0 .. pi + ext.len];
}

/// ファイルをロードして評価する
pub fn loadFileContent(allocator: std.mem.Allocator, content: []const u8) anyerror!Value {
    return loadFileContentWithPath(allocator, content, null);
}

/// ファイルをロードして評価する（ファイルパス付き）
pub fn loadFileContentWithPath(allocator: std.mem.Allocator, content: []const u8, source_file: ?[]const u8) anyerror!Value {
    const env = defs.current_env orelse return error.TypeError;
    var reader = Reader.init(allocator, content);
    reader.source_file = source_file;

    var result: Value = value_mod.nil;
    var fi: usize = 0;
    while (true) : (fi += 1) {
        const located = reader.readLocated() catch |e| {
            const pos = reader.tokenizer.pos;
            const line = reader.tokenizer.line;
            debugLog("[reader-error] line {d} pos {d}: {any}", .{ line, pos, e });
            return error.EvalError;
        };
        const loc = located orelse break;

        var analyzer = Analyzer.init(allocator, env);
        analyzer.source_file = source_file;
        analyzer.source_line = loc.line;
        analyzer.source_column = loc.column;
        const node = analyzer.analyze(loc.form) catch |e| {
            debugLog("[analyze-error] form #{d}: {any}", .{ fi, e });
            return error.EvalError;
        };
        var ctx = Context.init(allocator, env);
        result = tree_walk.run(node, &ctx) catch |e| {
            debugLog("[eval-error] form #{d}: {any}", .{ fi, e });
            return error.EvalError;
        };
    }
    return result;
}

/// キーワードでマップを検索
pub fn lookupKeywordInMap(map: *const value_mod.PersistentMap, name: []const u8) ?Value {
    const entries = map.entries;
    var idx: usize = 0;
    while (idx + 1 < entries.len) : (idx += 2) {
        const key = entries[idx];
        const key_name: []const u8 = switch (key) {
            .keyword => |kw| kw.name,
            else => continue,
        };
        if (std.mem.eql(u8, key_name, name)) {
            return entries[idx + 1];
        }
    }
    return null;
}
