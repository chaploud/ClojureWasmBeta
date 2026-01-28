//! 型定義 — Symbol, Keyword, String, 関数型, 参照型, 特殊型
//!
//! value.zig (facade) から re-export される。

const std = @import("std");
const Value = @import("../value.zig").Value;

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

// === マルチメソッド ===

/// マルチメソッド（defmulti/defmethod）
pub const MultiFn = struct {
    name: ?Symbol,
    dispatch_fn: Value, // ディスパッチ関数
    methods: *@import("collections.zig").PersistentMap, // dispatch-value → fn のマップ
    default_method: ?Value, // :default メソッド
    prefer_table: ?*@import("collections.zig").PersistentMap, // prefer-method テーブル
};

// === プロトコル ===

/// プロトコル（defprotocol）
pub const Protocol = struct {
    name: Symbol,
    method_sigs: []const MethodSig,
    /// type_keyword_string → メソッドマップ（method_name → fn Value）
    impls: *@import("collections.zig").PersistentMap,

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

/// コンパイル済み正規表現パターン
pub const Pattern = struct {
    source: []const u8, // 元のパターン文字列
    compiled: *const anyopaque, // *regex.CompiledRegex（循環依存を避ける）
    group_count: u16, // キャプチャグループ数
};

/// ステートフル正規表現マッチャー（re-matcher で生成）
pub const RegexMatcher = struct {
    pattern: *Pattern, // パターン参照
    input: []const u8, // 入力文字列
    pos: usize, // 次の検索開始位置
    last_groups: ?[]const Value, // 最後のマッチのグループ（re-groups 用）
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

        // 単一アリティ fast path (大多数の関数)
        if (fn_arities.len == 1) {
            const arity = &fn_arities[0];
            if (!arity.variadic) {
                return if (arity.params.len == arg_count) arity else null;
            }
            return if (arg_count >= arity.params.len - 1) arity else null;
        }

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

// === Wasm ===

/// ロード済み Wasm モジュール
pub const WasmModule = struct {
    path: ?[]const u8, // ファイルパス (デバッグ用)
    store: *anyopaque, // *zware.Store
    instance: *anyopaque, // *zware.Instance
    module_ptr: *anyopaque, // *zware.Module
    closed: bool,
};
