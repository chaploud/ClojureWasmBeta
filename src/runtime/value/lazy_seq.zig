//! 遅延シーケンス — LazySeq, Transform, Generator
//!
//! value.zig (facade) から re-export される。

const Value = @import("../value.zig").Value;
const nil = @import("../value.zig").nil;

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
    /// 遅延 take: (take n coll) を遅延評価
    take: ?Take,

    pub const Take = struct {
        source: Value, // 元シーケンス
        n: usize,      // 残り取得数
    };

    pub const TransformKind = enum { map, filter, mapcat, take_while, drop_while, map_indexed };
    pub const Transform = struct {
        kind: TransformKind,
        fn_val: Value,    // 変換関数（map の f、filter の pred）
        source: Value,    // 変換元シーケンス（lazy-seq or list/vector）
        index: usize,     // map_indexed 用の現在インデックス
    };

    /// 遅延ジェネレータ: iterate, repeat, cycle, range 等の無限/有限シーケンス
    pub const GeneratorKind = enum { iterate, repeat_infinite, cycle, range_infinite, range_finite };
    pub const Generator = struct {
        kind: GeneratorKind,
        fn_val: ?Value,   // iterate の f
        current: Value,   // 現在の値（iterate の x、repeat の値、range の n）
        source: ?[]const Value, // cycle の元コレクション
        source_idx: usize,     // cycle の現在位置
    };

    const empty_fields = LazySeq{
        .body_fn = null, .realized = null, .cons_head = null, .cons_tail = null,
        .transform = null, .concat_sources = null, .generator = null, .take = null,
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
        ls.transform = .{ .kind = kind, .fn_val = fn_val, .source = source, .index = 0 };
        return ls;
    }

    /// map-indexed 用: インデックス付き Transform 作成
    pub fn initTransformIndexed(fn_val: Value, source: Value, start_index: usize) LazySeq {
        var ls = empty_fields;
        ls.transform = .{ .kind = .map_indexed, .fn_val = fn_val, .source = source, .index = start_index };
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

    /// range 有限ジェネレータ: (range start end step)
    /// end を fn_val に、step を source_idx に格納
    pub fn initRangeFinite(start: i64, end: i64, step: i64) LazySeq {
        var ls = empty_fields;
        ls.generator = .{
            .kind = .range_finite,
            .fn_val = @import("../value.zig").intVal(end),
            .current = @import("../value.zig").intVal(start),
            .source = null,
            .source_idx = @bitCast(@as(i64, step)), // step を source_idx に格納 (i64→usize bit cast)
        };
        return ls;
    }

    /// 遅延 take: (take n coll) を遅延評価
    pub fn initTake(source: Value, n: usize) LazySeq {
        var ls = empty_fields;
        ls.take = .{ .source = source, .n = n };
        return ls;
    }

    /// 既に実体化済みかどうか
    pub fn isRealized(self: *const LazySeq) bool {
        return self.realized != null;
    }
};
