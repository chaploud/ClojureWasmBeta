//! Runtime値 (Value)
//!
//! 評価器が返す実行時の値。
//! GC管理対象（将来）、永続データ構造。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! サブモジュール構成:
//!   value/types.zig       — Symbol, Keyword, String, 関数型, 参照型, 特殊型
//!   value/collections.zig — PersistentList, PersistentVector, PersistentMap, PersistentSet
//!   value/lazy_seq.zig    — LazySeq, Transform, Generator
//!
//! 詳細: docs/reference/type_design.md

const std = @import("std");

// === サブモジュールからの re-export ===

const types = @import("value/types.zig");
const collections = @import("value/collections.zig");
const lazy_seq_mod = @import("value/lazy_seq.zig");

// 型定義
pub const Symbol = types.Symbol;
pub const Keyword = types.Keyword;
pub const String = types.String;
pub const MultiFn = types.MultiFn;
pub const Protocol = types.Protocol;
pub const ProtocolFn = types.ProtocolFn;
pub const Atom = types.Atom;
pub const Delay = types.Delay;
pub const Volatile = types.Volatile;
pub const Reduced = types.Reduced;
pub const Pattern = types.Pattern;
pub const RegexMatcher = types.RegexMatcher;
pub const Promise = types.Promise;
pub const Transient = types.Transient;
pub const FnProtoPtr = types.FnProtoPtr;
pub const FnArityRuntime = types.FnArityRuntime;
pub const Fn = types.Fn;
pub const PartialFn = types.PartialFn;
pub const CompFn = types.CompFn;
pub const WasmModule = types.WasmModule;

// コレクション
pub const PersistentList = collections.PersistentList;
pub const PersistentVector = collections.PersistentVector;
pub const PersistentMap = collections.PersistentMap;
pub const PersistentSet = collections.PersistentSet;

// 遅延シーケンス
pub const LazySeq = lazy_seq_mod.LazySeq;

// === Value 本体 ===

/// Runtime値
pub const Value = union(enum) {

    // === 基本型 ===
    nil,
    bool_val: bool,
    int: i64,
    float: f64,
    char_val: u21,

    // === 文字列・識別子 ===
    string: *String,
    keyword: *Keyword,
    symbol: *Symbol,

    // === コレクション ===
    list: *PersistentList,
    vector: *PersistentVector,
    map: *PersistentMap,
    set: *PersistentSet,

    // === 関数 ===
    fn_val: *Fn,
    partial_fn: *PartialFn, // 部分適用された関数
    comp_fn: *CompFn, // 合成された関数
    multi_fn: *MultiFn, // マルチメソッド
    protocol: *Protocol, // プロトコル
    protocol_fn: *ProtocolFn, // プロトコル関数

    // === VM用 ===
    fn_proto: FnProtoPtr, // コンパイル済み関数プロトタイプ

    // === 遅延シーケンス ===
    lazy_seq: *LazySeq, // 遅延シーケンス

    // === 参照 ===
    var_val: *anyopaque, // *Var（循環依存を避けるため anyopaque）
    atom: *Atom, // Atom（ミュータブルな参照）

    // === Phase 13: delay/volatile/reduced ===
    delay_val: *Delay, // 遅延評価サンク
    volatile_val: *Volatile, // ミュータブルボックス
    reduced_val: *Reduced, // reduce 早期終了ラッパー

    // === Phase 14: transient ===
    transient: *Transient, // 一時的ミュータブルコレクション

    // === Phase 18: promise ===
    promise: *Promise, // 1回だけ deliver 可能

    // === Phase 22: regex ===
    regex: *Pattern, // コンパイル済み正規表現パターン
    matcher: *RegexMatcher, // ステートフルマッチャー

    // === Phase LAST: wasm ===
    wasm_module: *WasmModule, // ロード済み Wasm モジュール

    // === ヘルパー関数 ===

    /// nil かどうか
    pub fn isNil(self: Value) bool {
        return switch (self) {
            .nil => true,
            else => false,
        };
    }

    /// 真偽値として評価（nil と false のみ falsy）
    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .nil => false,
            .bool_val => |b| b,
            else => true,
        };
    }

    /// 順序付きコレクション判定 (list, vector)
    fn isSequential(v: Value) bool {
        return v == .list or v == .vector;
    }

    /// 順序付きコレクションの要素配列を取得
    fn sequentialItems(v: Value) []const Value {
        return switch (v) {
            .list => |l| l.items,
            .vector => |ve| ve.items,
            else => &[_]Value{},
        };
    }

    /// ハッシュ値を計算 (PersistentMap/PersistentSet の高速ルックアップ用)
    /// Clojure の hash 互換ではなく、内部利用向けの高速ハッシュ。
    /// 不変条件: a.eql(b) → a.valueHash() == b.valueHash()
    pub fn valueHash(self: Value) u32 {
        var h = std.hash.Wyhash.init(0);
        switch (self) {
            .nil => h.update("nil"),
            .bool_val => |b| h.update(if (b) "true" else "false"),
            .int => |n| {
                // int/float 互換: 整数値の float は同じハッシュを返す
                const bytes: [8]u8 = @bitCast(n);
                h.update(&bytes);
            },
            .float => |f| {
                // 整数と等しい float は int と同じハッシュを返す
                const int_val: i64 = @intFromFloat(f);
                if (@as(f64, @floatFromInt(int_val)) == f) {
                    const bytes: [8]u8 = @bitCast(int_val);
                    h.update(&bytes);
                } else {
                    h.update("f");
                    const bytes: [8]u8 = @bitCast(f);
                    h.update(&bytes);
                }
            },
            .char_val => |c| {
                h.update("c");
                const val: u32 = @intCast(c);
                const bytes: [4]u8 = @bitCast(val);
                h.update(&bytes);
            },
            .string => |s| {
                h.update("s");
                h.update(s.data);
            },
            .keyword => |kw| {
                h.update("k");
                if (kw.namespace) |ns| {
                    h.update(ns);
                    h.update("/");
                }
                h.update(kw.name);
            },
            .symbol => |sym| {
                h.update("y");
                if (sym.namespace) |ns| {
                    h.update(ns);
                    h.update("/");
                }
                h.update(sym.name);
            },
            // 順序付きコレクション: 要素のハッシュを順に混合
            // list と vector は eql で等価なので同じハッシュを返す
            .list, .vector => {
                h.update("seq");
                const items = sequentialItems(self);
                for (items) |item| {
                    const item_hash = item.valueHash();
                    const item_bytes: [4]u8 = @bitCast(item_hash);
                    h.update(&item_bytes);
                }
            },
            // マップ: 各ペアのハッシュを XOR で結合 (順序非依存)
            .map => |m| {
                h.update("m");
                var map_hash: u32 = 0;
                var i: usize = 0;
                while (i < m.entries.len) : (i += 2) {
                    map_hash ^= m.entries[i].valueHash() *% 31 +% m.entries[i + 1].valueHash();
                }
                const map_bytes: [4]u8 = @bitCast(map_hash);
                h.update(&map_bytes);
            },
            // セット: 各要素のハッシュを XOR で結合 (順序非依存)
            .set => |s| {
                h.update("S");
                var set_hash: u32 = 0;
                for (s.items) |item| {
                    set_hash ^= item.valueHash();
                }
                const set_bytes: [4]u8 = @bitCast(set_hash);
                h.update(&set_bytes);
            },
            else => {
                // 関数・参照等はポインタベースのハッシュ
                h.update("p");
                const ptr_int: usize = switch (self) {
                    .fn_val => |p| @intFromPtr(p),
                    else => 0,
                };
                const bytes: [8]u8 = @bitCast(ptr_int);
                h.update(&bytes);
            },
        }
        return @truncate(h.final());
    }

    /// 等価性判定
    pub fn eql(self: Value, other: Value) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);

        // Clojure 互換: list と vector は順序付きコレクションとして等価比較
        if (isSequential(self) and isSequential(other)) {
            const a_items = sequentialItems(self);
            const b_items = sequentialItems(other);
            if (a_items.len != b_items.len) return false;
            for (a_items, b_items) |ai, bi| {
                if (!ai.eql(bi)) return false;
            }
            return true;
        }

        // int と float の比較 (1 == 1.0)
        if ((self_tag == .int and other_tag == .float) or
            (self_tag == .float and other_tag == .int))
        {
            const a_f: f64 = if (self == .int) @floatFromInt(self.int) else self.float;
            const b_f: f64 = if (other == .int) @floatFromInt(other.int) else other.float;
            return a_f == b_f;
        }

        if (self_tag != other_tag) return false;

        return switch (self) {
            .nil => true,
            .bool_val => |a| a == other.bool_val,
            .int => |a| a == other.int,
            .float => |a| a == other.float,
            .char_val => |a| a == other.char_val,
            .string => |a| a.eql(other.string.*),
            .keyword => |a| a.eql(other.keyword.*),
            .symbol => |a| a.eql(other.symbol.*),
            .list, .vector => unreachable, // isSequential で処理済み
            .map => |a| blk: {
                const b = other.map;
                if (a.count() != b.count()) break :blk false;
                var i: usize = 0;
                while (i < a.entries.len) : (i += 2) {
                    const key = a.entries[i];
                    const val = a.entries[i + 1];
                    if (b.get(key)) |bval| {
                        if (!val.eql(bval)) break :blk false;
                    } else {
                        break :blk false;
                    }
                }
                break :blk true;
            },
            .set => |a| blk: {
                const b = other.set;
                if (a.items.len != b.items.len) break :blk false;
                for (a.items) |item| {
                    if (!b.contains(item)) break :blk false;
                }
                break :blk true;
            },
            .lazy_seq => |a| a == other.lazy_seq, // 参照等価
            .fn_val => |a| a == other.fn_val, // 関数は参照等価
            .partial_fn => |a| a == other.partial_fn, // 参照等価
            .comp_fn => |a| a == other.comp_fn, // 参照等価
            .multi_fn => |a| a == other.multi_fn, // 参照等価
            .protocol => |a| a == other.protocol, // 参照等価
            .protocol_fn => |a| a == other.protocol_fn, // 参照等価
            .fn_proto => |a| a == other.fn_proto, // 参照等価
            .var_val => |a| a == other.var_val, // 参照等価
            .atom => |a| a == other.atom, // 参照等価
            .delay_val => |a| a == other.delay_val, // 参照等価
            .volatile_val => |a| a == other.volatile_val, // 参照等価
            .reduced_val => |a| a.value.eql(other.reduced_val.value), // 内部値で比較
            .transient => |a| a == other.transient, // 参照等価
            .promise => |a| a == other.promise, // 参照等価
            .regex => |a| a == other.regex, // 参照等価
            .matcher => |a| a == other.matcher, // 参照等価
            .wasm_module => |a| a == other.wasm_module, // 参照等価
        };
    }

    /// 型名を返す（デバッグ用）
    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .nil => "nil",
            .bool_val => "boolean",
            .int => "integer",
            .float => "float",
            .char_val => "character",
            .string => "string",
            .keyword => "keyword",
            .symbol => "symbol",
            .list => "list",
            .vector => "vector",
            .map => "map",
            .set => "set",
            .lazy_seq => "lazy-seq",
            .fn_val => "function",
            .partial_fn => "function", // partial も関数として表示
            .comp_fn => "function", // comp も関数として表示
            .multi_fn => "multi-fn",
            .protocol => "protocol",
            .protocol_fn => "protocol-fn",
            .fn_proto => "fn-proto",
            .var_val => "var",
            .atom => "atom",
            .delay_val => "delay",
            .volatile_val => "volatile",
            .reduced_val => "reduced",
            .transient => "transient",
            .promise => "promise",
            .regex => "regex",
            .matcher => "matcher",
            .wasm_module => "wasm-module",
        };
    }

    /// プロトコルディスパッチ用の型キーワード文字列を返す
    pub fn typeKeyword(self: Value) []const u8 {
        return switch (self) {
            .nil => "nil",
            .bool_val => "boolean",
            .int => "integer",
            .float => "float",
            .char_val => "character",
            .string => "string",
            .keyword => "keyword",
            .symbol => "symbol",
            .list => "list",
            .vector => "vector",
            .map => "map",
            .set => "set",
            .lazy_seq => "lazy-seq",
            .fn_val, .partial_fn, .comp_fn => "function",
            .multi_fn => "multi-fn",
            .protocol => "protocol",
            .protocol_fn => "protocol-fn",
            .fn_proto => "fn-proto",
            .var_val => "var",
            .atom => "atom",
            .delay_val => "delay",
            .volatile_val => "volatile",
            .reduced_val => "reduced",
            .transient => "transient",
            .promise => "promise",
            .regex => "regex",
            .matcher => "matcher",
            .wasm_module => "wasm-module",
        };
    }

    /// デバッグ表示用（pr-str 相当）
    pub fn format(
        self: Value,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .nil => try writer.writeAll("nil"),
            .bool_val => |b| try writer.writeAll(if (b) "true" else "false"),
            .int => |n| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "?";
                try writer.writeAll(s);
            },
            .float => |n| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "?";
                try writer.writeAll(s);
            },
            .char_val => |c| {
                try writer.writeAll("\\");
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &buf) catch 0;
                try writer.writeAll(buf[0..len]);
            },
            .string => |s| try writer.print("\"{s}\"", .{s.data}),
            .keyword => |k| {
                if (k.namespace) |ns| {
                    try writer.print(":{s}/{s}", .{ ns, k.name });
                } else {
                    try writer.print(":{s}", .{k.name});
                }
            },
            .symbol => |sym| {
                if (sym.namespace) |ns| {
                    try writer.print("{s}/{s}", .{ ns, sym.name });
                } else {
                    try writer.writeAll(sym.name);
                }
            },
            .list => |lst| {
                try writer.writeByte('(');
                for (lst.items, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try item.format("", .{}, writer);
                }
                try writer.writeByte(')');
            },
            .vector => |vec| {
                try writer.writeByte('[');
                for (vec.items, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try item.format("", .{}, writer);
                }
                try writer.writeByte(']');
            },
            .map => |m| {
                try writer.writeByte('{');
                var i: usize = 0;
                var first = true;
                while (i < m.entries.len) : (i += 2) {
                    if (!first) try writer.writeAll(", ");
                    first = false;
                    try m.entries[i].format("", .{}, writer);
                    try writer.writeByte(' ');
                    try m.entries[i + 1].format("", .{}, writer);
                }
                try writer.writeByte('}');
            },
            .set => |s| {
                try writer.writeAll("#{");
                for (s.items, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try item.format("", .{}, writer);
                }
                try writer.writeByte('}');
            },
            .lazy_seq => |ls| {
                // 実体化済みなら中身を表示
                if (ls.realized) |realized| {
                    try realized.format("", .{}, writer);
                } else if (ls.cons_head != null) {
                    // cons 形式: 部分的に評価済み
                    try writer.writeAll("#<lazy-seq:cons>");
                } else {
                    try writer.writeAll("#<lazy-seq>");
                }
            },
            .fn_val => |f| {
                if (f.name) |name| {
                    if (name.namespace) |ns| {
                        try writer.print("#<fn {s}/{s}>", .{ ns, name.name });
                    } else {
                        try writer.print("#<fn {s}>", .{name.name});
                    }
                } else {
                    try writer.writeAll("#<fn>");
                }
            },
            .partial_fn => try writer.writeAll("#<partial-fn>"),
            .comp_fn => try writer.writeAll("#<comp-fn>"),
            .multi_fn => |mf| {
                if (mf.name) |name| {
                    try writer.print("#<multi-fn {s}>", .{name.name});
                } else {
                    try writer.writeAll("#<multi-fn>");
                }
            },
            .protocol => |p| {
                try writer.print("#<protocol {s}>", .{p.name.name});
            },
            .protocol_fn => |pf| {
                try writer.print("#<protocol-fn {s}>", .{pf.method_name});
            },
            .fn_proto => try writer.writeAll("#<fn-proto>"),
            .var_val => try writer.writeAll("#<var>"),
            .atom => |a| {
                try writer.writeAll("#<atom ");
                try a.value.format("", .{}, writer);
                try writer.writeByte('>');
            },
            .delay_val => |d| {
                if (d.realized) {
                    try writer.writeAll("#<delay ");
                    if (d.cached) |cached| {
                        try cached.format("", .{}, writer);
                    }
                    try writer.writeByte('>');
                } else {
                    try writer.writeAll("#<delay :pending>");
                }
            },
            .volatile_val => |v| {
                try writer.writeAll("#<volatile ");
                try v.value.format("", .{}, writer);
                try writer.writeByte('>');
            },
            .reduced_val => |r| {
                try writer.writeAll("#<reduced ");
                try r.value.format("", .{}, writer);
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
            .matcher => {
                try writer.writeAll("#<matcher>");
            },
            .wasm_module => |wm| {
                if (wm.path) |path| {
                    try writer.print("#<wasm-module {s}>", .{path});
                } else {
                    try writer.writeAll("#<wasm-module>");
                }
            },
        }
    }

    /// Value を指定アロケータに深コピー（scratch → persistent 移行用）
    /// ヒープ確保されたデータ（String, Keyword, Symbol, コレクション）を複製する。
    /// fn_val, partial_fn, comp_fn, fn_proto, var_val, atom はそのままコピー
    /// （これらは persistent アロケータで作成されるため）。
    pub fn deepClone(self: Value, allocator: std.mem.Allocator) error{OutOfMemory}!Value {
        return switch (self) {
            // インライン値はそのまま
            .nil, .bool_val, .int, .float, .char_val => self,
            // ヒープ確保の識別子/文字列を複製
            .string => |s| blk: {
                const new_s = try allocator.create(String);
                new_s.* = .{
                    .data = try allocator.dupe(u8, s.data),
                    .cached_hash = s.cached_hash,
                };
                break :blk .{ .string = new_s };
            },
            .keyword => |k| blk: {
                const new_k = try allocator.create(Keyword);
                new_k.* = .{
                    .name = try allocator.dupe(u8, k.name),
                    .namespace = if (k.namespace) |ns| try allocator.dupe(u8, ns) else null,
                };
                break :blk .{ .keyword = new_k };
            },
            .symbol => |sym| blk: {
                const new_sym = try allocator.create(Symbol);
                new_sym.* = .{
                    .name = try allocator.dupe(u8, sym.name),
                    .namespace = if (sym.namespace) |ns| try allocator.dupe(u8, ns) else null,
                };
                break :blk .{ .symbol = new_sym };
            },
            // コレクションを再帰的に複製
            .list => |l| blk: {
                const new_l = try allocator.create(PersistentList);
                const items = try deepCloneValues(allocator, l.items);
                new_l.* = .{ .items = items };
                break :blk .{ .list = new_l };
            },
            .vector => |v| blk: {
                const new_v = try allocator.create(PersistentVector);
                const items = try deepCloneValues(allocator, v.items);
                new_v.* = .{ .items = items };
                break :blk .{ .vector = new_v };
            },
            .map => |m| blk: {
                const new_m = try allocator.create(PersistentMap);
                const entries = try deepCloneValues(allocator, m.entries);
                const hv = if (m.hash_values.len > 0)
                    try allocator.dupe(u32, m.hash_values)
                else
                    &[_]u32{};
                const hi = if (m.hash_index.len > 0)
                    try allocator.dupe(u32, m.hash_index)
                else
                    &[_]u32{};
                new_m.* = .{ .entries = entries, .hash_values = hv, .hash_index = hi };
                break :blk .{ .map = new_m };
            },
            .set => |s| blk: {
                const new_s = try allocator.create(PersistentSet);
                const items = try deepCloneValues(allocator, s.items);
                new_s.* = .{ .items = items };
                break :blk .{ .set = new_s };
            },
            // Atom は内部値を深コピー（scratch 参照を排除）
            .atom => |a| blk: {
                const new_a = try allocator.create(Atom);
                new_a.* = .{ .value = try a.value.deepClone(allocator) };
                break :blk .{ .atom = new_a };
            },
            // LazySeq はサンクと実体化済み値を深コピー
            .lazy_seq => |ls| blk: {
                const new_ls = try allocator.create(LazySeq);
                new_ls.* = .{
                    .body_fn = if (ls.body_fn) |bf| try bf.deepClone(allocator) else null,
                    .realized = if (ls.realized) |r| try r.deepClone(allocator) else null,
                    .cons_head = if (ls.cons_head) |ch| try ch.deepClone(allocator) else null,
                    .cons_tail = if (ls.cons_tail) |ct| try ct.deepClone(allocator) else null,
                    .transform = if (ls.transform) |t| LazySeq.Transform{
                        .kind = t.kind,
                        .fn_val = try t.fn_val.deepClone(allocator),
                        .source = try t.source.deepClone(allocator),
                        .index = t.index,
                    } else null,
                    .concat_sources = if (ls.concat_sources) |cs| try deepCloneValues(allocator, cs) else null,
                    .generator = if (ls.generator) |g| LazySeq.Generator{
                        .kind = g.kind,
                        .fn_val = if (g.fn_val) |fv| try fv.deepClone(allocator) else null,
                        .current = try g.current.deepClone(allocator),
                        .source = if (g.source) |s| try deepCloneValues(allocator, s) else null,
                        .source_idx = g.source_idx,
                    } else null,
                };
                break :blk .{ .lazy_seq = new_ls };
            },
            // MultiFn, Protocol, ProtocolFn は参照をそのまま保持（persistent で作成済み）
            .multi_fn, .protocol, .protocol_fn => self,
            // 他のランタイムオブジェクトはそのまま（persistent で作成済み）
            .fn_val, .partial_fn, .comp_fn, .fn_proto, .var_val => self,
            // Phase 13: delay/volatile/reduced
            .delay_val => |d| blk: {
                const new_d = try allocator.create(Delay);
                new_d.* = .{
                    .fn_val = d.fn_val,
                    .cached = if (d.cached) |c| try c.deepClone(allocator) else null,
                    .realized = d.realized,
                };
                break :blk .{ .delay_val = new_d };
            },
            .volatile_val => |v| blk: {
                const new_v = try allocator.create(Volatile);
                new_v.* = .{ .value = try v.value.deepClone(allocator) };
                break :blk .{ .volatile_val = new_v };
            },
            .reduced_val => |r| blk: {
                const new_r = try allocator.create(Reduced);
                new_r.* = .{ .value = try r.value.deepClone(allocator) };
                break :blk .{ .reduced_val = new_r };
            },
            // Transient/Promise/Regex/Matcher/WasmModule は参照をそのまま保持
            .transient => self,
            .promise => self,
            .regex => self,
            .matcher => self,
            .wasm_module => self,
        };
    }

    /// Value スライスを再帰的に深コピー
    pub fn deepCloneValues(allocator: std.mem.Allocator, values: []const Value) error{OutOfMemory}![]const Value {
        const cloned = try allocator.alloc(Value, values.len);
        for (values, 0..) |v, i| {
            cloned[i] = try v.deepClone(allocator);
        }
        return cloned;
    }
};

// === ヘルパー関数 ===

/// nil 定数
pub const nil: Value = .nil;

/// true 定数
pub const true_val: Value = .{ .bool_val = true };

/// false 定数
pub const false_val: Value = .{ .bool_val = false };

/// 整数 Value を作成
pub fn intVal(n: i64) Value {
    return .{ .int = n };
}

/// 浮動小数点 Value を作成
pub fn floatVal(n: f64) Value {
    return .{ .float = n };
}

// === テスト ===

test "nil と boolean" {
    try std.testing.expect(nil.isNil());
    try std.testing.expect(!true_val.isNil());

    try std.testing.expect(!nil.isTruthy());
    try std.testing.expect(!false_val.isTruthy());
    try std.testing.expect(true_val.isTruthy());
    try std.testing.expect(intVal(0).isTruthy()); // 0 は truthy
}

test "数値" {
    const i = intVal(42);
    const f = floatVal(3.14);

    try std.testing.expectEqualStrings("integer", i.typeName());
    try std.testing.expectEqualStrings("float", f.typeName());

    try std.testing.expect(i.eql(intVal(42)));
    try std.testing.expect(!i.eql(intVal(43)));
}

test "等価性" {
    try std.testing.expect(nil.eql(nil));
    try std.testing.expect(true_val.eql(true_val));
    try std.testing.expect(!true_val.eql(false_val));
    try std.testing.expect(intVal(42).eql(intVal(42)));
    try std.testing.expect(!intVal(42).eql(intVal(43)));
}

test "Symbol" {
    const s1 = Symbol.init("foo");
    const s2 = Symbol.initNs("clojure.core", "map");

    try std.testing.expect(s1.eql(Symbol.init("foo")));
    try std.testing.expect(!s1.eql(s2));
    try std.testing.expectEqualStrings("foo", s1.name);
    try std.testing.expectEqualStrings("clojure.core", s2.namespace.?);
}

test "Keyword" {
    const k1 = Keyword.init("foo");
    const k2 = Keyword.initNs("ns", "bar");

    try std.testing.expect(k1.eql(Keyword.init("foo")));
    try std.testing.expect(!k1.eql(k2));
}

test "PersistentVector" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var vec = PersistentVector.empty();
    vec = try vec.conj(allocator, intVal(1));
    vec = try vec.conj(allocator, intVal(2));
    vec = try vec.conj(allocator, intVal(3));

    try std.testing.expectEqual(@as(usize, 3), vec.count());
    try std.testing.expect(vec.nth(0).?.eql(intVal(1)));
    try std.testing.expect(vec.nth(1).?.eql(intVal(2)));
    try std.testing.expect(vec.nth(2).?.eql(intVal(3)));
    try std.testing.expect(vec.nth(3) == null);
}

test "PersistentMap" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var m = PersistentMap.empty();

    // キーワードを作成
    var k1 = Keyword.init("a");
    var k2 = Keyword.init("b");
    const key1 = Value{ .keyword = &k1 };
    const key2 = Value{ .keyword = &k2 };

    m = try m.assoc(allocator, key1, intVal(1));
    m = try m.assoc(allocator, key2, intVal(2));

    try std.testing.expectEqual(@as(usize, 2), m.count());
    try std.testing.expect(m.get(key1).?.eql(intVal(1)));
    try std.testing.expect(m.get(key2).?.eql(intVal(2)));
}

test "format 出力" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try nil.format("", .{}, writer);
    try writer.writeByte(' ');
    try true_val.format("", .{}, writer);
    try writer.writeByte(' ');
    try intVal(42).format("", .{}, writer);

    try std.testing.expectEqualStrings("nil true 42", stream.getWritten());
}
