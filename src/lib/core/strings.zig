//! 文字列操作
//!
//! str, subs, join, format, regex 関数

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const BuiltinDef = defs.BuiltinDef;
const regex_mod = defs.regex_mod;
const regex_matcher = defs.regex_matcher;

const helpers = @import("helpers.zig");

// ============================================================
// 文字列操作
// ============================================================

/// str : 引数を連結して文字列を返す
/// lazy-seq は自動的に realize してから出力
pub fn strFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (args) |arg| {
        const realized = helpers.ensureRealized(allocator, arg) catch arg;
        try helpers.valueToString(allocator, &buf, realized);
    }

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = try buf.toOwnedSlice(allocator) };
    return Value{ .string = str_obj };
}

/// pr-str : 文字列表現を返す（print 用）
/// lazy-seq は自動的に realize してから出力
pub fn prStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (args, 0..) |arg, i| {
        if (i > 0) try buf.append(allocator, ' ');
        const realized = try helpers.ensureRealized(allocator, arg);
        try helpers.printValueToBuf(allocator, &buf, realized);
    }

    const str = try allocator.create(value_mod.String);
    str.* = .{ .data = try buf.toOwnedSlice(allocator) };
    return Value{ .string = str };
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
        try helpers.valueToString(allocator, &buf, item);
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

    // Pattern の場合: 正規表現置換
    if (args[1] == .regex) {
        const replacement = switch (args[2]) {
            .string => |str| str.data,
            else => return error.TypeError,
        };
        return regexReplaceAll(allocator, s, args[1].regex, replacement);
    }

    const match_str = switch (args[1]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const replacement = switch (args[2]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };

    if (match_str.len == 0) {
        const str_obj = try allocator.create(value_mod.String);
        str_obj.* = .{ .data = s };
        return Value{ .string = str_obj };
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (i + match_str.len <= s.len and std.mem.eql(u8, s[i..][0..match_str.len], match_str)) {
            try buf.appendSlice(allocator, replacement);
            i += match_str.len;
        } else {
            try buf.append(allocator, s[i]);
            i += 1;
        }
    }

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = try buf.toOwnedSlice(allocator) };
    return Value{ .string = str_obj };
}

/// 正規表現で全置換（内部ヘルパー）
fn regexReplaceAll(allocator: std.mem.Allocator, input: []const u8, pat: *value_mod.Pattern, replacement: []const u8) anyerror!Value {
    const compiled: *const regex_mod.CompiledRegex = @ptrCast(@alignCast(pat.compiled));
    var m = try regex_matcher.Matcher.init(allocator, compiled, input);
    defer m.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    var pos: usize = 0;
    while (pos <= input.len) {
        const result = try m.find(pos) orelse {
            // 残りをコピー
            try buf.appendSlice(allocator, input[pos..]);
            break;
        };
        // マッチ前の部分をコピー
        try buf.appendSlice(allocator, input[pos..result.start]);
        // 置換文字列を展開（$1, $2 等のグループ参照を処理）
        try appendReplacement(allocator, &buf, replacement, result, input);
        // 位置を進める（ゼロ幅マッチのとき無限ループを防ぐ）
        pos = if (result.end > result.start) result.end else result.end + 1;
    }

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = try buf.toOwnedSlice(allocator) };
    return Value{ .string = str_obj };
}

/// 置換文字列を展開（$1, $2 でグループ参照）
fn appendReplacement(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    replacement: []const u8,
    result: regex_matcher.MatchResult,
    input: []const u8,
) !void {
    var i: usize = 0;
    while (i < replacement.len) {
        if (replacement[i] == '\\' and i + 1 < replacement.len) {
            // エスケープ: \$ → $, \\ → \
            try buf.append(allocator, replacement[i + 1]);
            i += 2;
        } else if (replacement[i] == '$' and i + 1 < replacement.len and replacement[i + 1] >= '0' and replacement[i + 1] <= '9') {
            // グループ参照: $0, $1, $2, ...
            const group_idx: usize = replacement[i + 1] - '0';
            if (group_idx < result.groups.len) {
                if (result.groups[group_idx]) |span| {
                    try buf.appendSlice(allocator, input[span.start..span.end]);
                }
            }
            i += 2;
        } else {
            try buf.append(allocator, replacement[i]);
            i += 1;
        }
    }
}

/// string-replace-first : 最初のマッチのみ置換
pub fn stringReplaceFirst(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const s = switch (args[0]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };
    const replacement = switch (args[2]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };

    if (args[1] == .regex) {
        // 正規表現で最初のマッチのみ置換
        const pat = args[1].regex;
        const compiled: *const regex_mod.CompiledRegex = @ptrCast(@alignCast(pat.compiled));
        var m = try regex_matcher.Matcher.init(allocator, compiled, s);
        defer m.deinit();

        const result = try m.find(0) orelse {
            // マッチなし: 元の文字列をそのまま返す
            const str_obj = try allocator.create(value_mod.String);
            str_obj.* = .{ .data = try allocator.dupe(u8, s) };
            return Value{ .string = str_obj };
        };

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, s[0..result.start]);
        try appendReplacement(allocator, &buf, replacement, result, s);
        try buf.appendSlice(allocator, s[result.end..]);

        const str_obj = try allocator.create(value_mod.String);
        str_obj.* = .{ .data = try buf.toOwnedSlice(allocator) };
        return Value{ .string = str_obj };
    }

    // 文字列マッチの場合: 最初のマッチのみ置換
    const match_str = switch (args[1]) {
        .string => |str| str.data,
        else => return error.TypeError,
    };

    if (std.mem.indexOf(u8, s, match_str)) |idx| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, s[0..idx]);
        try buf.appendSlice(allocator, replacement);
        try buf.appendSlice(allocator, s[idx + match_str.len ..]);

        const str_obj = try allocator.create(value_mod.String);
        str_obj.* = .{ .data = try buf.toOwnedSlice(allocator) };
        return Value{ .string = str_obj };
    }

    // マッチなし
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = .{ .data = try allocator.dupe(u8, s) };
    return Value{ .string = str_obj };
}

/// re-quote-replacement : 置換文字列の $ と \ をエスケープ
pub fn reQuoteReplacement(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const s = args[0].string.data;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    for (s) |c| {
        if (c == '$' or c == '\\') {
            try buf.append(allocator, '\\');
        }
        try buf.append(allocator, c);
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

/// string-split : 文字列を区切り文字で分割（clojure.string/split 簡易版）
pub fn stringSplit(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const s = args[0].string.data;

    // Pattern の場合: 正規表現で分割
    if (args[1] == .regex) {
        return regexSplit(allocator, s, args[1].regex);
    }

    if (args[1] != .string) return error.TypeError;
    const sep = args[1].string.data;

    var result_buf: std.ArrayListUnmanaged(Value) = .empty;

    if (sep.len == 0) {
        // 空セパレータ: 1文字ずつ
        for (s) |byte| {
            const char_str = try allocator.alloc(u8, 1);
            char_str[0] = byte;
            const str_obj = try allocator.create(value_mod.String);
            str_obj.* = value_mod.String.init(char_str);
            result_buf.append(allocator, Value{ .string = str_obj }) catch return error.OutOfMemory;
        }
    } else {
        var start: usize = 0;
        while (start <= s.len) {
            if (std.mem.indexOfPos(u8, s, start, sep)) |idx| {
                const part = try allocator.dupe(u8, s[start..idx]);
                const str_obj = try allocator.create(value_mod.String);
                str_obj.* = value_mod.String.init(part);
                result_buf.append(allocator, Value{ .string = str_obj }) catch return error.OutOfMemory;
                start = idx + sep.len;
            } else {
                const part = try allocator.dupe(u8, s[start..]);
                const str_obj = try allocator.create(value_mod.String);
                str_obj.* = value_mod.String.init(part);
                result_buf.append(allocator, Value{ .string = str_obj }) catch return error.OutOfMemory;
                break;
            }
        }
    }

    const result = try allocator.create(value_mod.PersistentVector);
    result.* = .{ .items = result_buf.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return Value{ .vector = result };
}

/// 正規表現で分割（内部ヘルパー）
fn regexSplit(allocator: std.mem.Allocator, input: []const u8, pat: *value_mod.Pattern) anyerror!Value {
    const compiled: *const regex_mod.CompiledRegex = @ptrCast(@alignCast(pat.compiled));
    var m = try regex_matcher.Matcher.init(allocator, compiled, input);
    defer m.deinit();

    var result_buf: std.ArrayListUnmanaged(Value) = .empty;
    var pos: usize = 0;

    while (pos <= input.len) {
        const result = try m.find(pos) orelse {
            // 残りを追加
            const part = try allocator.dupe(u8, input[pos..]);
            const str_obj = try allocator.create(value_mod.String);
            str_obj.* = value_mod.String.init(part);
            try result_buf.append(allocator, Value{ .string = str_obj });
            break;
        };

        // マッチ前の部分を追加
        const part = try allocator.dupe(u8, input[pos..result.start]);
        const str_obj = try allocator.create(value_mod.String);
        str_obj.* = value_mod.String.init(part);
        try result_buf.append(allocator, Value{ .string = str_obj });

        // 位置を進める
        pos = if (result.end > result.start) result.end else result.end + 1;
    }

    const vec = try allocator.create(value_mod.PersistentVector);
    vec.* = .{ .items = try result_buf.toOwnedSlice(allocator) };
    return Value{ .vector = vec };
}

/// format : 簡易フォーマット（%s, %d のみ対応）
pub fn formatFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    const fmt_str = args[0].string.data;
    const fmt_args = args[1..];

    var result_buf: std.ArrayListUnmanaged(u8) = .empty;
    var arg_idx: usize = 0;
    var i: usize = 0;

    while (i < fmt_str.len) {
        if (fmt_str[i] == '%' and i + 1 < fmt_str.len) {
            const spec = fmt_str[i + 1];
            if (spec == 's' or spec == 'd') {
                if (arg_idx < fmt_args.len) {
                    try helpers.valueToString(allocator, &result_buf, fmt_args[arg_idx]);
                    arg_idx += 1;
                }
                i += 2;
                continue;
            } else if (spec == '%') {
                result_buf.append(allocator, '%') catch return error.OutOfMemory;
                i += 2;
                continue;
            }
        }
        result_buf.append(allocator, fmt_str[i]) catch return error.OutOfMemory;
        i += 1;
    }

    const result_str = result_buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = value_mod.String.init(result_str);
    return Value{ .string = str_obj };
}

/// char-escape-string : エスケープ文字の表現マップを返す
pub fn charEscapeStringFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    // {\newline "\\n", \tab "\\t", \return "\\r", \backspace "\\b", \formfeed "\\f", \" "\\\"", \\ "\\\\"}
    const pairs = [_]struct { ch: u21, esc: []const u8 }{
        .{ .ch = '\n', .esc = "\\n" },
        .{ .ch = '\t', .esc = "\\t" },
        .{ .ch = '\r', .esc = "\\r" },
        .{ .ch = 0x08, .esc = "\\b" },   // backspace
        .{ .ch = 0x0C, .esc = "\\f" },   // formfeed
        .{ .ch = '"', .esc = "\\\"" },
        .{ .ch = '\\', .esc = "\\\\" },
    };
    const entries = try allocator.alloc(Value, pairs.len * 2);
    for (pairs, 0..) |pair, idx| {
        entries[idx * 2] = Value{ .char_val = pair.ch };
        const s = try allocator.create(value_mod.String);
        s.* = .{ .data = pair.esc };
        entries[idx * 2 + 1] = Value{ .string = s };
    }
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

/// char-name-string : 名前付き文字のマップを返す
pub fn charNameStringFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    // {\newline "newline", \tab "tab", \space "space", \backspace "backspace",
    //  \formfeed "formfeed", \return "return"}
    const pairs = [_]struct { ch: u21, name: []const u8 }{
        .{ .ch = '\n', .name = "newline" },
        .{ .ch = '\t', .name = "tab" },
        .{ .ch = ' ', .name = "space" },
        .{ .ch = 0x08, .name = "backspace" },
        .{ .ch = 0x0C, .name = "formfeed" },
        .{ .ch = '\r', .name = "return" },
    };
    const entries = try allocator.alloc(Value, pairs.len * 2);
    for (pairs, 0..) |pair, idx| {
        entries[idx * 2] = Value{ .char_val = pair.ch };
        const s = try allocator.create(value_mod.String);
        s.* = .{ .data = pair.name };
        entries[idx * 2 + 1] = Value{ .string = s };
    }
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

// ============================================================
// 出力→文字列変換
// ============================================================

/// print-str : 値を文字列に変換（readably=false）
pub fn printStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    var result_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer result_buf.deinit(allocator);

    for (args, 0..) |arg, i| {
        if (i > 0) result_buf.append(allocator, ' ') catch return error.OutOfMemory;
        try helpers.valueToString(allocator, &result_buf, arg);
    }

    const result_str = result_buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = value_mod.String.init(result_str);
    return Value{ .string = str_obj };
}

/// prn-str : pr-str と同じ（readably=true、改行は含まない）
pub fn prnStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    return prStr(allocator, args);
}

/// println-str : println と同じフォーマットで文字列を返す（出力しない）
pub fn printlnStr(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    var result_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer result_buf.deinit(allocator);

    for (args, 0..) |arg, i| {
        if (i > 0) result_buf.append(allocator, ' ') catch return error.OutOfMemory;
        try helpers.valueToString(allocator, &result_buf, arg);
    }
    result_buf.append(allocator, '\n') catch return error.OutOfMemory;

    const str_obj = try allocator.create(value_mod.String);
    str_obj.* = value_mod.String.init(result_buf.toOwnedSlice(allocator) catch return error.OutOfMemory);
    return Value{ .string = str_obj };
}

// ============================================================
// Regex functions
// ============================================================

/// Pattern を取得（regex Value またはパターン文字列からコンパイル）
fn getPattern(allocator: std.mem.Allocator, val: Value) anyerror!*value_mod.Pattern {
    switch (val) {
        .regex => |pat| return pat,
        .string => |s| {
            // 文字列からコンパイル
            const compiled = try allocator.create(regex_mod.CompiledRegex);
            compiled.* = try regex_matcher.compile(allocator, s.data);
            const pat = try allocator.create(value_mod.Pattern);
            pat.* = .{
                .source = s.data,
                .compiled = @ptrCast(compiled),
                .group_count = compiled.group_count,
            };
            return pat;
        },
        else => return error.TypeError,
    }
}

/// マッチ結果を Clojure 値に変換
/// グループなし: マッチ文字列 (String)
/// グループあり: [全体, group1, group2, ...] (Vector)
fn matchResultToValue(allocator: std.mem.Allocator, result: regex_matcher.MatchResult, input: []const u8) anyerror!Value {
    // キャプチャグループの有無を確認（groups[0] は全体マッチ）
    var has_groups = false;
    if (result.groups.len > 1) {
        for (result.groups[1..]) |g| {
            if (g != null) {
                has_groups = true;
                break;
            }
        }
    }

    if (!has_groups) {
        // グループなし: マッチ文字列を返す
        const match_text = input[result.start..result.end];
        const str = try allocator.create(value_mod.String);
        const data = try allocator.dupe(u8, match_text);
        str.* = .{ .data = data };
        return Value{ .string = str };
    }

    // グループあり: Vector を返す
    const items = try allocator.alloc(Value, result.groups.len);
    for (result.groups, 0..) |group_opt, i| {
        if (group_opt) |span| {
            const text = input[span.start..span.end];
            const str = try allocator.create(value_mod.String);
            const data = try allocator.dupe(u8, text);
            str.* = .{ .data = data };
            items[i] = Value{ .string = str };
        } else {
            items[i] = value_mod.nil;
        }
    }
    const vec = try allocator.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };
    return Value{ .vector = vec };
}

/// re-pattern — 文字列 → Pattern コンパイル。既に Pattern ならそのまま返す。
pub fn rePatternFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    switch (args[0]) {
        .regex => return args[0], // 既に Pattern
        .string => |s| {
            const compiled = try allocator.create(regex_mod.CompiledRegex);
            compiled.* = try regex_matcher.compile(allocator, s.data);
            const pat = try allocator.create(value_mod.Pattern);
            pat.* = .{
                .source = try allocator.dupe(u8, s.data),
                .compiled = @ptrCast(compiled),
                .group_count = compiled.group_count,
            };
            return Value{ .regex = pat };
        },
        else => return error.TypeError,
    }
}

/// re-matcher — Pattern + 文字列 → ステートフル Matcher 生成
pub fn reMatcherFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const pat = try getPattern(allocator, args[0]);
    if (args[1] != .string) return error.TypeError;
    const input = args[1].string.data;

    const m = try allocator.create(value_mod.RegexMatcher);
    m.* = .{
        .pattern = pat,
        .input = input,
        .pos = 0,
        .last_groups = null,
    };
    return Value{ .matcher = m };
}

/// re-find — 2引数: Pattern + 文字列で最初のマッチ。1引数: Matcher を次のマッチに進める。
pub fn reFindFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2) return error.ArityError;

    if (args.len == 1) {
        // 1引数: Matcher のステートフル検索
        if (args[0] != .matcher) return error.TypeError;
        const rm = args[0].matcher;
        const compiled: *const regex_mod.CompiledRegex = @ptrCast(@alignCast(rm.pattern.compiled));

        var m = try regex_matcher.Matcher.init(allocator, compiled, rm.input);
        defer m.deinit();

        const result = try m.find(rm.pos) orelse {
            rm.last_groups = null;
            return value_mod.nil;
        };

        // 位置を進める（ゼロ幅マッチのとき無限ループを防ぐ）
        rm.pos = if (result.end > result.start) result.end else result.end + 1;

        // グループを保存
        const groups = try matchResultToGroups(allocator, result, rm.input);
        rm.last_groups = groups;

        return matchResultToValue(allocator, result, rm.input);
    }

    // 2引数: Pattern + 文字列
    const pat = try getPattern(allocator, args[0]);
    if (args[1] != .string) return error.TypeError;
    const input = args[1].string.data;
    const compiled: *const regex_mod.CompiledRegex = @ptrCast(@alignCast(pat.compiled));

    const result = try regex_matcher.findFirst(allocator, compiled, input) orelse {
        return value_mod.nil;
    };
    return matchResultToValue(allocator, result, input);
}

/// マッチ結果をグループ Value スライスに変換（re-groups 用）
fn matchResultToGroups(allocator: std.mem.Allocator, result: regex_matcher.MatchResult, input: []const u8) anyerror![]const Value {
    const groups = try allocator.alloc(Value, result.groups.len);
    for (result.groups, 0..) |group_opt, i| {
        if (group_opt) |span| {
            const text = input[span.start..span.end];
            const str = try allocator.create(value_mod.String);
            const data = try allocator.dupe(u8, text);
            str.* = .{ .data = data };
            groups[i] = Value{ .string = str };
        } else {
            groups[i] = value_mod.nil;
        }
    }
    return groups;
}

/// re-matches — 文字列全体がパターンに一致するか検証
pub fn reMatchesFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const pat = try getPattern(allocator, args[0]);
    if (args[1] != .string) return error.TypeError;
    const input = args[1].string.data;
    const compiled: *const regex_mod.CompiledRegex = @ptrCast(@alignCast(pat.compiled));

    var m = try regex_matcher.Matcher.init(allocator, compiled, input);
    defer m.deinit();

    const result = try m.fullMatch() orelse {
        return value_mod.nil;
    };
    return matchResultToValue(allocator, result, input);
}

/// re-seq — 全マッチのリストを返す（eager）
pub fn reSeqFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const pat = try getPattern(allocator, args[0]);
    if (args[1] != .string) return error.TypeError;
    const input = args[1].string.data;
    const compiled: *const regex_mod.CompiledRegex = @ptrCast(@alignCast(pat.compiled));

    var results: std.ArrayListUnmanaged(Value) = .empty;

    var m = try regex_matcher.Matcher.init(allocator, compiled, input);
    defer m.deinit();

    var pos: usize = 0;
    while (pos <= input.len) {
        const result = try m.find(pos) orelse break;
        const val = try matchResultToValue(allocator, result, input);
        try results.append(allocator, val);
        // 位置を進める（ゼロ幅マッチのとき無限ループを防ぐ）
        pos = if (result.end > result.start) result.end else result.end + 1;
    }

    const l = try allocator.create(value_mod.PersistentList);
    l.* = .{ .items = try results.toOwnedSlice(allocator) };
    return Value{ .list = l };
}

/// re-groups — Matcher の最後のマッチのキャプチャグループを返す
pub fn reGroupsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (args[0] != .matcher) return error.TypeError;
    const rm = args[0].matcher;

    const groups = rm.last_groups orelse return value_mod.nil;

    // グループが1つ（全体マッチのみ）なら文字列を返す
    if (groups.len <= 1) {
        return if (groups.len == 1) groups[0] else value_mod.nil;
    }

    // 複数グループなら [全体, group1, group2, ...] の Vector を返す
    const items = try allocator.dupe(Value, groups);
    const vec = try allocator.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };
    return Value{ .vector = vec };
}

// ============================================================
// builtins 登録
// ============================================================

pub const builtins = [_]BuiltinDef{
    // 文字列
    .{ .name = "str", .func = strFn },
    .{ .name = "pr-str", .func = prStr },
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
    .{ .name = "string-replace-first", .func = stringReplaceFirst },
    .{ .name = "re-quote-replacement", .func = reQuoteReplacement },
    .{ .name = "char-at", .func = charAt },
    .{ .name = "string-split", .func = stringSplit },
    .{ .name = "format", .func = formatFn },
    .{ .name = "char-escape-string", .func = charEscapeStringFn },
    .{ .name = "char-name-string", .func = charNameStringFn },
    // 出力→文字列
    .{ .name = "print-str", .func = printStr },
    .{ .name = "prn-str", .func = prnStr },
    .{ .name = "println-str", .func = printlnStr },
    // 正規表現
    .{ .name = "re-pattern", .func = rePatternFn },
    .{ .name = "re-matcher", .func = reMatcherFn },
    .{ .name = "re-find", .func = reFindFn },
    .{ .name = "re-matches", .func = reMatchesFn },
    .{ .name = "re-seq", .func = reSeqFn },
    .{ .name = "re-groups", .func = reGroupsFn },
};
