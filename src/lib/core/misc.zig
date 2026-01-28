//! 雑多な関数
//!
//! gensym, random-uuid, ex-info/ex-cause, tap, test, tagged-literal, etc.

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const BuiltinDef = defs.BuiltinDef;

const helpers = @import("helpers.zig");
const sequences = @import("sequences.zig");

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

/// ex-cause : 例外のcauseを返す（簡易実装: 常に nil）
pub fn exCauseFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.nil;
}

/// Throwable->map : エラーを map に変換（簡易実装）
pub fn throwableToMapFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    // {:cause "error"} を返す
    const entries = try allocator.alloc(Value, 2);
    const kw = try allocator.create(value_mod.Keyword);
    kw.* = value_mod.Keyword.init("cause");
    entries[0] = Value{ .keyword = kw };
    entries[1] = if (args[0] == .string) args[0] else blk: {
        const s = try allocator.create(value_mod.String);
        s.* = .{ .data = "unknown error" };
        break :blk Value{ .string = s };
    };
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

// ============================================================
// gensym
// ============================================================

/// gensym : ユニークシンボルを生成
pub fn gensymFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    const prefix = if (args.len >= 1)
        switch (args[0]) {
            .string => |s| s.data,
            else => "G__",
        }
    else
        "G__";

    defs.gensym_counter += 1;
    var buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, defs.gensym_counter }) catch return error.TypeError;
    const owned = try allocator.alloc(u8, name.len);
    @memcpy(owned, name);
    const sym = try allocator.create(value_mod.Symbol);
    sym.* = value_mod.Symbol.init(owned);
    return Value{ .symbol = sym };
}

// ============================================================
// UUID
// ============================================================

/// random-uuid : ランダム UUID 文字列を返す（v4 簡易版）
pub fn randomUuidFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    // 疑似ランダム UUID v4 生成（timestamp ベース）
    const ts: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var buf: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    // 128ビットを timestamp から生成
    var hash: u64 = ts;
    for (0..36) |i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            buf[i] = '-';
        } else {
            hash = hash *% 6364136223846793005 +% 1442695040888963407;
            buf[i] = hex[@as(usize, @intCast((hash >> 32) & 0xf))];
        }
    }
    // v4 マーカー
    buf[14] = '4';
    // variant マーカー (8, 9, a, b)
    buf[19] = hex[8 + @as(usize, @intCast((ts >> 4) & 0x3))];

    const str_data = try allocator.dupe(u8, &buf);
    const s = try allocator.create(value_mod.String);
    s.* = .{ .data = str_data };
    return Value{ .string = s };
}

/// parse-uuid : UUID 文字列をバリデーション（簡易: 文字列をそのまま返す）
pub fn parseUuidFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    if (args[0] != .string) return error.TypeError;
    // UUID 形式チェック: 8-4-4-4-12
    const s = args[0].string.data;
    if (s.len != 36) return error.TypeError;
    if (s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-') return error.TypeError;
    return args[0]; // UUID 文字列をそのまま返す
}

// ============================================================
// tagged-literal / inst-ms
// ============================================================

/// tagged-literal : タグ付きリテラルを作成
/// (tagged-literal tag form) → {:tag tag :form form}
pub fn taggedLiteralFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .symbol) return error.TypeError;
    const entries = try allocator.alloc(Value, 4);
    const kw_tag = try allocator.create(value_mod.Keyword);
    kw_tag.* = value_mod.Keyword.init("tag");
    const kw_form = try allocator.create(value_mod.Keyword);
    kw_form.* = value_mod.Keyword.init("form");
    entries[0] = Value{ .keyword = kw_tag };
    entries[1] = args[0];
    entries[2] = Value{ .keyword = kw_form };
    entries[3] = args[1];
    const m = try allocator.create(value_mod.PersistentMap);
    m.* = .{ .entries = entries };
    return Value{ .map = m };
}

/// inst-ms : inst（文字列 ISO 日時）からミリ秒を返す（簡易実装: 文字列を返す）
pub fn instMsFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    // 簡易: inst 文字列がない場合は 0 を返す
    return Value{ .int = 0 };
}

// ============================================================
// partitionv / splitv-at / vector-of
// ============================================================

/// partitionv : partition のベクター版（各パーティションをベクターで返す）
pub fn partitionvFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    // (partitionv n coll) — partition と同じだがベクターで返す
    if (args.len < 2 or args.len > 3) return error.ArityError;
    // partition を呼んでからリスト→ベクター変換
    const result = try sequences.partition(allocator, args);
    return listOfListsToListOfVectors(allocator, result);
}

/// partitionv-all : partition-all のベクター版
pub fn partitionvAllFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const result = try sequences.partitionAll(allocator, args);
    return listOfListsToListOfVectors(allocator, result);
}

/// リストのリストをリストのベクターに変換（partitionv 用）
fn listOfListsToListOfVectors(allocator: std.mem.Allocator, val: Value) !Value {
    if (val == .list) {
        var converted = std.ArrayList(Value).empty;
        defer converted.deinit(allocator);
        for (val.list.items) |item| {
            const vec_val = try toVector(allocator, item);
            try converted.append(allocator, vec_val);
        }
        const items = try allocator.alloc(Value, converted.items.len);
        @memcpy(items, converted.items);
        const new_list = try allocator.create(value_mod.PersistentList);
        new_list.* = .{ .items = items };
        return Value{ .list = new_list };
    }
    return val;
}

/// Value をベクターに変換
fn toVector(allocator: std.mem.Allocator, val: Value) !Value {
    if (val == .vector) return val;
    if (val == .list) {
        const arr = try allocator.alloc(Value, val.list.items.len);
        @memcpy(arr, val.list.items);
        const vec = try allocator.create(value_mod.PersistentVector);
        vec.* = .{ .items = arr };
        return Value{ .vector = vec };
    }
    return val;
}

/// splitv-at : split-at のベクター版
pub fn splitvAtFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .int) return error.TypeError;
    const n: usize = if (args[0].int >= 0) @intCast(args[0].int) else 0;
    // コレクションの要素を取得
    const coll_items = try helpers.collectToSlice(allocator, args[1]);
    defer allocator.free(coll_items);
    const split_at = @min(n, coll_items.len);

    // 前半ベクター
    const first_items = try allocator.alloc(Value, split_at);
    @memcpy(first_items, coll_items[0..split_at]);
    const first_vec = try allocator.create(value_mod.PersistentVector);
    first_vec.* = .{ .items = first_items };

    // 後半ベクター
    const second_items = try allocator.alloc(Value, coll_items.len - split_at);
    @memcpy(second_items, coll_items[split_at..]);
    const second_vec = try allocator.create(value_mod.PersistentVector);
    second_vec.* = .{ .items = second_items };

    // [first second] ベクターで返す
    const result_items = try allocator.alloc(Value, 2);
    result_items[0] = Value{ .vector = first_vec };
    result_items[1] = Value{ .vector = second_vec };
    const result_vec = try allocator.create(value_mod.PersistentVector);
    result_vec.* = .{ .items = result_items };
    return Value{ .vector = result_vec };
}

/// vector-of : 型ヒント付きベクター（Zig では型は単一なので vector と同等）
pub fn vectorOfFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    // 最初の引数は型キーワード（無視）、残りは要素
    // (vector-of :int 1 2 3) → [1 2 3]
    const items = try allocator.alloc(Value, args.len - 1);
    @memcpy(items, args[1..]);
    const vec = try allocator.create(value_mod.PersistentVector);
    vec.* = .{ .items = items };
    return Value{ .vector = vec };
}

// ============================================================
// タップシステム
// ============================================================

/// add-tap : タップ関数を登録
pub fn addTapFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (defs.global_taps == null) {
        defs.global_taps = std.ArrayList(Value).empty;
    }
    try defs.global_taps.?.append(allocator, args[0]);
    return value_mod.nil;
}

/// remove-tap : タップ関数を削除
pub fn removeTapFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    if (defs.global_taps) |*taps| {
        for (taps.items, 0..) |t, i| {
            if (t.eql(args[0])) {
                _ = taps.orderedRemove(i);
                break;
            }
        }
    }
    return value_mod.nil;
}

/// tap> : 値をタップ関数に送信
pub fn tapSendFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    if (defs.global_taps) |taps| {
        for (taps.items) |tap_fn| {
            if (defs.call_fn) |cfn| {
                _ = cfn(tap_fn, &[_]Value{args[0]}, allocator) catch {};
            }
        }
    }
    return value_mod.true_val;
}

// ============================================================
// test
// ============================================================

/// test : Var のテスト関数を実行（簡易: テストメタデータを探して呼ぶ）
pub fn testFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    // 簡易実装: :test メタデータがなければ :ok
    return value_mod.nil;
}

// ============================================================
// doc / dir（REPL ドキュメント）
// ============================================================

/// __doc: シンボル名を受け取り、Var のドキュメントを stdout に表示
pub fn docFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const name = switch (args[0]) {
        .string => |s| s.data,
        else => return value_mod.nil,
    };

    const env = defs.current_env orelse return value_mod.nil;
    const ns = env.getCurrentNs() orelse return value_mod.nil;

    // Var を解決 (現在 NS → refers → clojure.core)
    const v = ns.resolve(name) orelse return value_mod.nil;

    // 出力
    helpers.writeToOutput("-------------------------\n");
    helpers.writeToOutput(v.ns_name);
    helpers.writeToOutput("/");
    helpers.writeToOutput(name);
    helpers.writeToOutput("\n");

    // arglists
    if (v.arglists) |arglists| {
        helpers.writeToOutput(arglists);
        helpers.writeToOutput("\n");
    }

    // docstring
    if (v.doc) |doc| {
        helpers.writeToOutput("  ");
        helpers.writeToOutput(doc);
        helpers.writeToOutput("\n");
    }

    return value_mod.nil;
}

/// __dir: 名前空間名を受け取り、public var の一覧を stdout に表示
pub fn dirFn(_: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const ns_name = switch (args[0]) {
        .string => |s| s.data,
        else => return value_mod.nil,
    };

    const env = defs.current_env orelse return value_mod.nil;
    const ns = env.findNs(ns_name) orelse return value_mod.nil;

    // var 名をソートして表示
    var names: [1024][]const u8 = undefined;
    var count: usize = 0;
    var iter = ns.getAllVars();
    while (iter.next()) |entry| {
        if (count >= names.len) break;
        const v = entry.value_ptr.*;
        // private はスキップ
        if (v.private) continue;
        names[count] = entry.key_ptr.*;
        count += 1;
    }

    // ソート
    std.mem.sort([]const u8, names[0..count], {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // 出力
    for (names[0..count]) |n| {
        helpers.writeToOutput(n);
        helpers.writeToOutput("\n");
    }

    return value_mod.nil;
}

// ============================================================
// builtins
// ============================================================

pub const builtins = [_]BuiltinDef{
    // 例外処理
    .{ .name = "ex-info", .func = exInfo },
    .{ .name = "ex-message", .func = exMessage },
    .{ .name = "ex-data", .func = exData },
    .{ .name = "ex-cause", .func = exCauseFn },
    .{ .name = "Throwable->map", .func = throwableToMapFn },
    // gensym
    .{ .name = "gensym", .func = gensymFn },
    // UUID
    .{ .name = "random-uuid", .func = randomUuidFn },
    .{ .name = "parse-uuid", .func = parseUuidFn },
    // tagged-literal / inst-ms
    .{ .name = "tagged-literal", .func = taggedLiteralFn },
    .{ .name = "inst-ms", .func = instMsFn },
    // partitionv / splitv-at / vector-of
    .{ .name = "partitionv", .func = partitionvFn },
    .{ .name = "partitionv-all", .func = partitionvAllFn },
    .{ .name = "splitv-at", .func = splitvAtFn },
    .{ .name = "vector-of", .func = vectorOfFn },
    // タップ
    .{ .name = "add-tap", .func = addTapFn },
    .{ .name = "remove-tap", .func = removeTapFn },
    .{ .name = "tap>", .func = tapSendFn },
    // test
    .{ .name = "test", .func = testFn },
    // doc / dir
    .{ .name = "__doc", .func = docFn },
    .{ .name = "__dir", .func = dirFn },
};
