//! Runtime値 (Value)
//!
//! 評価器が返す実行時の値。
//! GC管理対象（将来）、永続データ構造。
//!
//! 3フェーズアーキテクチャ:
//!   Form (Reader) → Node (Analyzer) → Value (Runtime)
//!
//! 詳細: docs/reference/type_design.md

const std = @import("std");

// === シンボル・キーワード ===

/// シンボル（インターン済み識別子）
pub const Symbol = struct {
    namespace: ?[]const u8,
    name: []const u8,

    pub fn init(name: []const u8) Symbol {
        return .{ .namespace = null, .name = name };
    }

    pub fn initNs(namespace: []const u8, name: []const u8) Symbol {
        return .{ .namespace = namespace, .name = name };
    }

    pub fn eql(self: Symbol, other: Symbol) bool {
        if (self.namespace) |ns1| {
            if (other.namespace) |ns2| {
                return std.mem.eql(u8, ns1, ns2) and std.mem.eql(u8, self.name, other.name);
            }
            return false;
        } else {
            return other.namespace == null and std.mem.eql(u8, self.name, other.name);
        }
    }

    /// ハッシュ値を計算
    pub fn hash(self: Symbol) u64 {
        var h = std.hash.Wyhash.init(0);
        if (self.namespace) |ns| {
            h.update(ns);
            h.update("/");
        }
        h.update(self.name);
        return h.final();
    }
};

/// キーワード（インターン済み、ハッシュキャッシュ付き）
pub const Keyword = struct {
    namespace: ?[]const u8,
    name: []const u8,

    pub fn init(name: []const u8) Keyword {
        return .{ .namespace = null, .name = name };
    }

    pub fn initNs(namespace: []const u8, name: []const u8) Keyword {
        return .{ .namespace = namespace, .name = name };
    }

    pub fn eql(self: Keyword, other: Keyword) bool {
        if (self.namespace) |ns1| {
            if (other.namespace) |ns2| {
                return std.mem.eql(u8, ns1, ns2) and std.mem.eql(u8, self.name, other.name);
            }
            return false;
        } else {
            return other.namespace == null and std.mem.eql(u8, self.name, other.name);
        }
    }
};

// === 文字列 ===

/// 不変文字列
pub const String = struct {
    data: []const u8,
    cached_hash: ?u64 = null,

    pub fn init(data: []const u8) String {
        return .{ .data = data };
    }

    pub fn eql(self: String, other: String) bool {
        return std.mem.eql(u8, self.data, other.data);
    }

    pub fn hash(self: *String) u64 {
        if (self.cached_hash) |h| return h;
        const h = std.hash.Wyhash.hash(0, self.data);
        self.cached_hash = h;
        return h;
    }
};

// === コレクション ===

/// 永続リスト（Cons cell ベース）
/// 初期実装: スライスベース、将来は真の永続リストに
pub const PersistentList = struct {
    items: []const Value,
    meta: ?*const Value = null,

    /// 空のリストを返す（値）
    pub fn emptyVal() PersistentList {
        return .{ .items = &[_]Value{} };
    }

    /// 空のリストを作成してポインタを返す
    pub fn empty(allocator: std.mem.Allocator) !*PersistentList {
        const list = try allocator.create(PersistentList);
        list.* = .{ .items = &[_]Value{} };
        return list;
    }

    /// スライスから作成
    pub fn fromSlice(allocator: std.mem.Allocator, items: []const Value) !*PersistentList {
        const list = try allocator.create(PersistentList);
        const new_items = try allocator.dupe(Value, items);
        list.* = .{ .items = new_items };
        return list;
    }

    pub fn count(self: PersistentList) usize {
        return self.items.len;
    }

    pub fn first(self: PersistentList) ?Value {
        if (self.items.len == 0) return null;
        return self.items[0];
    }

    pub fn rest(self: PersistentList, allocator: std.mem.Allocator) !PersistentList {
        if (self.items.len <= 1) return emptyVal();
        const new_items = try allocator.dupe(Value, self.items[1..]);
        return .{ .items = new_items };
    }
};

/// 永続ベクター
/// 初期実装: スライスベース、将来は32分木に
pub const PersistentVector = struct {
    items: []const Value,
    meta: ?*const Value = null,

    pub fn empty() PersistentVector {
        return .{ .items = &[_]Value{} };
    }

    pub fn count(self: PersistentVector) usize {
        return self.items.len;
    }

    pub fn nth(self: PersistentVector, index: usize) ?Value {
        if (index >= self.items.len) return null;
        return self.items[index];
    }

    pub fn conj(self: PersistentVector, allocator: std.mem.Allocator, val: Value) !PersistentVector {
        var new_items = try allocator.alloc(Value, self.items.len + 1);
        @memcpy(new_items[0..self.items.len], self.items);
        new_items[self.items.len] = val;
        return .{ .items = new_items };
    }
};

/// 永続マップ
/// 初期実装: 配列ベース（キー値ペア）、将来はHAMTに
pub const PersistentMap = struct {
    /// キー値ペアのフラットな配列 [k1, v1, k2, v2, ...]
    entries: []const Value,
    meta: ?*const Value = null,

    pub fn empty() PersistentMap {
        return .{ .entries = &[_]Value{} };
    }

    pub fn count(self: PersistentMap) usize {
        return self.entries.len / 2;
    }

    pub fn get(self: PersistentMap, key: Value) ?Value {
        var i: usize = 0;
        while (i < self.entries.len) : (i += 2) {
            if (key.eql(self.entries[i])) {
                return self.entries[i + 1];
            }
        }
        return null;
    }

    pub fn assoc(self: PersistentMap, allocator: std.mem.Allocator, key: Value, val: Value) !PersistentMap {
        // 既存キーを探す
        var i: usize = 0;
        while (i < self.entries.len) : (i += 2) {
            if (key.eql(self.entries[i])) {
                // 既存キーを更新
                var new_entries = try allocator.dupe(Value, self.entries);
                new_entries[i + 1] = val;
                return .{ .entries = new_entries };
            }
        }
        // 新規キーを追加
        var new_entries = try allocator.alloc(Value, self.entries.len + 2);
        @memcpy(new_entries[0..self.entries.len], self.entries);
        new_entries[self.entries.len] = key;
        new_entries[self.entries.len + 1] = val;
        return .{ .entries = new_entries };
    }

    pub fn dissoc(self: PersistentMap, allocator: std.mem.Allocator, key: Value) !PersistentMap {
        // キーを探す
        var i: usize = 0;
        while (i < self.entries.len) : (i += 2) {
            if (key.eql(self.entries[i])) {
                // キーを削除
                if (self.entries.len == 2) {
                    return .{ .entries = &[_]Value{} };
                }
                var new_entries = try allocator.alloc(Value, self.entries.len - 2);
                @memcpy(new_entries[0..i], self.entries[0..i]);
                @memcpy(new_entries[i..], self.entries[i + 2 ..]);
                return .{ .entries = new_entries };
            }
        }
        // キーが見つからなければそのまま返す
        return self;
    }
};

/// 永続セット
/// 初期実装: 配列ベース、将来はHAMTに
pub const PersistentSet = struct {
    items: []const Value,
    meta: ?*const Value = null,

    pub fn empty() PersistentSet {
        return .{ .items = &[_]Value{} };
    }

    pub fn count(self: PersistentSet) usize {
        return self.items.len;
    }

    pub fn contains(self: PersistentSet, val: Value) bool {
        for (self.items) |item| {
            if (val.eql(item)) return true;
        }
        return false;
    }

    pub fn conj(self: PersistentSet, allocator: std.mem.Allocator, val: Value) !PersistentSet {
        // 重複チェック
        if (self.contains(val)) return self;
        var new_items = try allocator.alloc(Value, self.items.len + 1);
        @memcpy(new_items[0..self.items.len], self.items);
        new_items[self.items.len] = val;
        return .{ .items = new_items };
    }
};

// === 遅延シーケンス ===

/// 遅延シーケンス（lazy-seq）
/// サンク（引数0の関数）を保持し、初回アクセスで実体化してキャッシュ。
/// 実体化後は cons セル（first + rest）または nil。
pub const LazySeq = struct {
    /// サンク: 実体化前は fn_val (呼び出すと seq の値を返す)、実体化後は null
    body_fn: ?Value,
    /// キャッシュ: 実体化後の値（nil or list）
    realized: ?Value,
    /// cons 構造: (cons head tail) の head 要素（tail は body_fn=null, realized=lazy_seq の tail）
    cons_head: ?Value,
    /// cons 構造の tail（lazy-seq または nil/list）
    cons_tail: ?Value,
    /// 遅延変換: map/filter の lazy 版
    transform: ?Transform,
    /// 遅延 concat: 残りのコレクション列
    concat_sources: ?[]const Value,
    /// 遅延ジェネレータ: 無限シーケンス生成器
    generator: ?Generator,

    pub const TransformKind = enum { map, filter, mapcat };
    pub const Transform = struct {
        kind: TransformKind,
        fn_val: Value,    // 変換関数（map の f、filter の pred）
        source: Value,    // 変換元シーケンス（lazy-seq or list/vector）
    };

    /// 遅延ジェネレータ: iterate, repeat, cycle, range 等の無限シーケンス
    pub const GeneratorKind = enum { iterate, repeat_infinite, cycle, range_infinite };
    pub const Generator = struct {
        kind: GeneratorKind,
        fn_val: ?Value,   // iterate の f
        current: Value,   // 現在の値（iterate の x、repeat の値、range の n）
        source: ?[]const Value, // cycle の元コレクション
        source_idx: usize,     // cycle の現在位置
    };

    const empty_fields = LazySeq{
        .body_fn = null, .realized = null, .cons_head = null, .cons_tail = null,
        .transform = null, .concat_sources = null, .generator = null,
    };

    /// 未実体化の LazySeq を作成（サンク形式）
    pub fn init(body_fn: Value) LazySeq {
        var ls = empty_fields;
        ls.body_fn = body_fn;
        return ls;
    }

    /// cons 形式の LazySeq を作成: (cons head lazy-tail)
    /// head は即値、tail は遅延のまま
    pub fn initCons(head: Value, tail: Value) LazySeq {
        var ls = empty_fields;
        ls.cons_head = head;
        ls.cons_tail = tail;
        return ls;
    }

    /// 遅延変換の LazySeq を作成（lazy map/filter）
    pub fn initTransform(kind: TransformKind, fn_val: Value, source: Value) LazySeq {
        var ls = empty_fields;
        ls.transform = .{ .kind = kind, .fn_val = fn_val, .source = source };
        return ls;
    }

    /// 遅延 concat の LazySeq を作成
    pub fn initConcat(sources: []const Value) LazySeq {
        var ls = empty_fields;
        ls.concat_sources = sources;
        return ls;
    }

    /// iterate ジェネレータ: (iterate f x) → (x (f x) (f (f x)) ...)
    pub fn initIterate(fn_val: Value, initial: Value) LazySeq {
        var ls = empty_fields;
        ls.generator = .{ .kind = .iterate, .fn_val = fn_val, .current = initial, .source = null, .source_idx = 0 };
        return ls;
    }

    /// repeat 無限ジェネレータ: (repeat x) → (x x x ...)
    pub fn initRepeatInfinite(val: Value) LazySeq {
        var ls = empty_fields;
        ls.generator = .{ .kind = .repeat_infinite, .fn_val = null, .current = val, .source = null, .source_idx = 0 };
        return ls;
    }

    /// cycle ジェネレータ: (cycle coll) → 元コレクションを無限に繰り返す
    pub fn initCycle(items: []const Value, start_idx: usize) LazySeq {
        var ls = empty_fields;
        ls.generator = .{ .kind = .cycle, .fn_val = null, .current = nil, .source = items, .source_idx = start_idx };
        return ls;
    }

    /// range 無限ジェネレータ: (range) → (0 1 2 3 ...)
    pub fn initRangeInfinite(start: Value) LazySeq {
        var ls = empty_fields;
        ls.generator = .{ .kind = .range_infinite, .fn_val = null, .current = start, .source = null, .source_idx = 0 };
        return ls;
    }

    /// 既に実体化済みかどうか
    pub fn isRealized(self: *const LazySeq) bool {
        return self.realized != null;
    }
};

// === マルチメソッド ===

/// マルチメソッド（defmulti/defmethod）
pub const MultiFn = struct {
    name: ?Symbol,
    dispatch_fn: Value, // ディスパッチ関数
    methods: *PersistentMap, // dispatch-value → fn のマップ
    default_method: ?Value, // :default メソッド
};

// === プロトコル ===

/// プロトコル（defprotocol）
pub const Protocol = struct {
    name: Symbol,
    method_sigs: []const MethodSig,
    /// type_keyword_string → メソッドマップ（method_name → fn Value）
    impls: *PersistentMap,

    pub const MethodSig = struct {
        name: []const u8,
        arity: u8, // this を含む
    };
};

/// プロトコル関数（各メソッドの Var に格納される値）
pub const ProtocolFn = struct {
    protocol: *Protocol,
    method_name: []const u8,
};

// === 参照型 ===

/// Atom（ミュータブルな参照）
pub const Atom = struct {
    value: Value,
    /// バリデーション関数（set 前に呼ばれる）
    validator: ?Value = null,
    /// ウォッチャー: [key1, fn1, key2, fn2, ...] の配列
    watches: ?[]const Value = null,
    /// メタデータ
    meta: ?Value = null,

    pub fn init(val: Value) Atom {
        return .{ .value = val };
    }
};

/// Delay（遅延評価サンク）
/// delay はボディ関数を保持し、初回 force 時に評価してキャッシュする
pub const Delay = struct {
    fn_val: ?Value, // 評価関数（(fn [] body) 形式）— 評価済みなら null
    cached: ?Value, // キャッシュされた結果
    realized: bool, // 評価済みフラグ

    pub fn init(fn_val: Value) Delay {
        return .{ .fn_val = fn_val, .cached = null, .realized = false };
    }
};

/// Volatile（ミュータブルボックス — 同期なし）
pub const Volatile = struct {
    value: Value,

    pub fn init(val: Value) Volatile {
        return .{ .value = val };
    }
};

/// Reduced（reduce 早期終了ラッパー）
pub const Reduced = struct {
    value: Value,

    pub fn init(val: Value) Reduced {
        return .{ .value = val };
    }
};

/// Promise（1回だけ deliver 可能なボックス）
pub const Promise = struct {
    value: ?Value,
    delivered: bool,

    pub fn init() Promise {
        return .{ .value = null, .delivered = false };
    }
};

/// Transient（一時的ミュータブルコレクション）
/// transient で永続コレクションからミュータブルコピーを作成し、
/// conj!/assoc!/dissoc!/disj!/pop! でインプレース操作、
/// persistent! で永続コレクションに戻す。
pub const Transient = struct {
    /// 元のコレクション種別
    kind: Kind,
    /// ミュータブルな要素配列（vector/list/set 用）
    items: ?std.ArrayList(Value),
    /// ミュータブルなエントリ配列（map 用: [k1,v1,k2,v2,...]）
    entries: ?std.ArrayList(Value),
    /// persistent! 済みかどうか（二重 persistent! を防止）
    persisted: bool,

    pub const Kind = enum {
        vector,
        map,
        set,
    };

    /// ベクター/リストから Transient を作成
    pub fn initVector(allocator: std.mem.Allocator, source_items: []const Value) error{OutOfMemory}!Transient {
        var list: std.ArrayList(Value) = .empty;
        try list.appendSlice(allocator, source_items);
        return .{
            .kind = .vector,
            .items = list,
            .entries = null,
            .persisted = false,
        };
    }

    /// マップから Transient を作成
    pub fn initMap(allocator: std.mem.Allocator, source_entries: []const Value) error{OutOfMemory}!Transient {
        var list: std.ArrayList(Value) = .empty;
        try list.appendSlice(allocator, source_entries);
        return .{
            .kind = .map,
            .items = null,
            .entries = list,
            .persisted = false,
        };
    }

    /// セットから Transient を作成
    pub fn initSet(allocator: std.mem.Allocator, source_items: []const Value) error{OutOfMemory}!Transient {
        var list: std.ArrayList(Value) = .empty;
        try list.appendSlice(allocator, source_items);
        return .{
            .kind = .set,
            .items = list,
            .entries = null,
            .persisted = false,
        };
    }
};

// === 関数プロトタイプ（コンパイル済み）===
// 循環依存を避けるため、ここで前方宣言
// 実際の定義は compiler/bytecode.zig

/// コンパイル済み関数プロトタイプへのポインタ
pub const FnProtoPtr = *anyopaque;

// === 関数 ===

/// ユーザー定義関数のアリティ
pub const FnArityRuntime = struct {
    params: []const []const u8,
    variadic: bool,
    body: *anyopaque, // *Node（循環依存を避けるため anyopaque）
};

/// 関数オブジェクト
pub const Fn = struct {
    name: ?Symbol = null,
    /// 組み込み関数へのポインタ（型安全性のため anyopaque を使用、
    /// 実際の型は lib/core.zig の BuiltinFn）
    builtin: ?*const anyopaque = null,
    // ユーザー定義関数用
    arities: ?[]const FnArityRuntime = null,
    closure_bindings: ?[]const Value = null, // クロージャ環境（遅延解決）
    meta: ?*const Value = null,

    pub fn initBuiltin(name: []const u8, f: *const anyopaque) Fn {
        return .{
            .name = Symbol.init(name),
            .builtin = f,
        };
    }

    /// ユーザー定義関数を作成
    pub fn initUser(
        name: ?[]const u8,
        fn_arities: []const FnArityRuntime,
        closure_binds: ?[]const Value,
    ) Fn {
        return .{
            .name = if (name) |n| Symbol.init(n) else null,
            .arities = fn_arities,
            .closure_bindings = closure_binds,
        };
    }

    /// 組み込み関数かどうか
    pub fn isBuiltin(self: *const Fn) bool {
        return self.builtin != null;
    }

    /// 引数の数に合ったアリティを検索
    pub fn findArity(self: *const Fn, arg_count: usize) ?*const FnArityRuntime {
        const fn_arities = self.arities orelse return null;

        // 固定アリティを優先検索
        for (fn_arities) |*arity| {
            if (!arity.variadic and arity.params.len == arg_count) {
                return arity;
            }
        }

        // 可変長アリティを検索
        for (fn_arities) |*arity| {
            if (arity.variadic and arg_count >= arity.params.len - 1) {
                return arity;
            }
        }

        return null;
    }
};

/// 部分適用された関数
pub const PartialFn = struct {
    fn_val: Value, // 元の関数（fn_val または partial_fn）
    args: []const Value, // 部分適用された引数
};

/// 合成された関数
pub const CompFn = struct {
    fns: []const Value, // 合成される関数（左から右の順、実行は右から左）
};

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

    /// 等価性判定
    pub fn eql(self: Value, other: Value) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);
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
            .list => |a| blk: {
                const b = other.list;
                if (a.items.len != b.items.len) break :blk false;
                for (a.items, b.items) |ai, bi| {
                    if (!ai.eql(bi)) break :blk false;
                }
                break :blk true;
            },
            .vector => |a| blk: {
                const b = other.vector;
                if (a.items.len != b.items.len) break :blk false;
                for (a.items, b.items) |ai, bi| {
                    if (!ai.eql(bi)) break :blk false;
                }
                break :blk true;
            },
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
                new_m.* = .{ .entries = entries };
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
            // Transient/Promise は参照をそのまま保持（ミュータブルなので deepClone は意味がない）
            .transient => self,
            .promise => self,
        };
    }

    /// Value スライスを再帰的に深コピー
    fn deepCloneValues(allocator: std.mem.Allocator, values: []const Value) error{OutOfMemory}![]const Value {
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
