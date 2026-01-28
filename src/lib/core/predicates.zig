//! 型述語
//!
//! nil?, number?, string?, coll?, seq?, etc.

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const var_mod = defs.var_mod;
const BuiltinDef = defs.BuiltinDef;

// ============================================================
// 数値述語
// ============================================================

/// some? : nil でないかどうか
pub fn isSome(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0].isNil()) value_mod.false_val else value_mod.true_val;
}

/// zero? : 0 かどうか
pub fn isZero(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| if (n == 0) value_mod.true_val else value_mod.false_val,
        .float => |n| if (n == 0.0) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// pos? : 正数かどうか
pub fn isPos(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| if (n > 0) value_mod.true_val else value_mod.false_val,
        .float => |n| if (n > 0.0) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// neg? : 負数かどうか
pub fn isNeg(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| if (n < 0) value_mod.true_val else value_mod.false_val,
        .float => |n| if (n < 0.0) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// even? : 偶数かどうか
pub fn isEven(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| if (@mod(n, 2) == 0) value_mod.true_val else value_mod.false_val,
        else => error.TypeError,
    };
}

/// odd? : 奇数かどうか
pub fn isOdd(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |n| if (@mod(n, 2) != 0) value_mod.true_val else value_mod.false_val,
        else => error.TypeError,
    };
}

// ============================================================
// 述語
// ============================================================

/// nil? : nil かどうか
pub fn isNil(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .nil => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// number? : 数値かどうか
pub fn isNumber(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .int, .float => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// integer? : 整数かどうか
pub fn isInteger(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .int => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// float? : 浮動小数点かどうか
pub fn isFloat(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .float => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// string? : 文字列かどうか
pub fn isString(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .string => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// keyword? : キーワードかどうか
pub fn isKeyword(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .keyword => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// symbol? : シンボルかどうか
pub fn isSymbol(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .symbol => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// fn? : 関数かどうか
pub fn isFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .fn_val => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// coll? : コレクションかどうか
pub fn isColl(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .list, .vector, .map, .set => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// list? : リストかどうか
pub fn isList(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .list => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// vector? : ベクタかどうか
pub fn isVector(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .vector => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// map? : マップかどうか
pub fn isMap(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .map => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// set? : セットかどうか
pub fn isSet(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;

    return switch (args[0]) {
        .set => value_mod.true_val,
        else => value_mod.false_val,
    };
}

// ============================================================
// Atom 述語
// ============================================================

/// atom?: Atom かどうか
pub fn isAtom(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .atom => value_mod.true_val,
        else => value_mod.false_val,
    };
}

// ============================================================
// プロトコル述語
// ============================================================

/// satisfies?: 型がプロトコルを実装しているか
/// (satisfies? Protocol value) → bool
pub fn satisfiesPred(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;

    // 第1引数はプロトコル
    const proto = switch (args[0]) {
        .protocol => |p| p,
        else => return error.TypeError,
    };

    // 第2引数の型キーワード
    const type_key_str = args[1].typeKeyword();
    const type_key_s = try allocator.create(value_mod.String);
    type_key_s.* = value_mod.String.init(type_key_str);
    const type_key = Value{ .string = type_key_s };

    // impls に型があるか検索
    if (proto.impls.get(type_key)) |_| {
        return value_mod.true_val;
    }
    return value_mod.false_val;
}

// ============================================================
// シーケンス述語
// ============================================================

/// seq? : シーケンスかどうか（list のみ）
pub fn isSeq(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .list => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// seqable? : シーケンスにできるかどうか
pub fn isSeqable(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .nil, .list, .vector, .map, .set, .string => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// sequential? : 順序付きコレクションかどうか
pub fn isSequential(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .list, .vector => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// associative? : 連想コレクションかどうか
pub fn isAssociative(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .map, .vector => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// counted? : 要素数を O(1) で取得可能かどうか
pub fn isCounted(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .list, .vector, .map, .set => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// reversible? : reverse 可能かどうか
pub fn isReversible(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .vector => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// sorted? : ソート済みかどうか（常に false — sorted-set/sorted-map 未実装）
pub fn isSorted(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

// ============================================================
// Phase 11: PURE 述語バッチ
// ============================================================

/// any? : 常に true を返す（任意の値に対して true）
pub fn isAny(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.true_val;
}

/// boolean? : 真偽値かどうか
pub fn isBoolean(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .bool_val) value_mod.true_val else value_mod.false_val;
}

/// int? : 整数かどうか（integer? と同じ）
pub fn isInt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .int) value_mod.true_val else value_mod.false_val;
}

/// double? : 浮動小数点かどうか（float? と同じ）
pub fn isDouble(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .float) value_mod.true_val else value_mod.false_val;
}

/// char? : 文字かどうか
pub fn isChar(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .char_val) value_mod.true_val else value_mod.false_val;
}

/// ident? : 識別子（キーワードまたはシンボル）かどうか
pub fn isIdent(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .keyword, .symbol => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// simple-ident? : 名前空間なしの識別子かどうか
pub fn isSimpleIdent(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .keyword => |k| if (k.namespace == null) value_mod.true_val else value_mod.false_val,
        .symbol => |s| if (s.namespace == null) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// simple-keyword? : 名前空間なしのキーワードかどうか
pub fn isSimpleKeyword(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .keyword => |k| if (k.namespace == null) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// simple-symbol? : 名前空間なしのシンボルかどうか
pub fn isSimpleSymbol(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .symbol => |s| if (s.namespace == null) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// qualified-ident? : 名前空間付きの識別子かどうか
pub fn isQualifiedIdent(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .keyword => |k| if (k.namespace != null) value_mod.true_val else value_mod.false_val,
        .symbol => |s| if (s.namespace != null) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// qualified-keyword? : 名前空間付きのキーワードかどうか
pub fn isQualifiedKeyword(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .keyword => |k| if (k.namespace != null) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// qualified-symbol? : 名前空間付きのシンボルかどうか
pub fn isQualifiedSymbol(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .symbol => |s| if (s.namespace != null) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// indexed? : インデックスアクセス可能かどうか（vector）
pub fn isIndexed(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .vector) value_mod.true_val else value_mod.false_val;
}

/// ifn? : 関数として呼び出し可能かどうか
pub fn isIFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .fn_val, .partial_fn, .comp_fn, .multi_fn, .protocol_fn,
        .keyword, .symbol, .vector, .map, .set,
        => value_mod.true_val,
        else => value_mod.false_val,
    };
}

/// identical? : 参照同一性（同一オブジェクト）かどうか
pub fn isIdentical(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const a = args[0];
    const b = args[1];
    // タグが異なれば false
    const a_tag = std.meta.activeTag(a);
    const b_tag = std.meta.activeTag(b);
    if (a_tag != b_tag) return value_mod.false_val;
    // 値型はビット一致で判定
    return switch (a) {
        .nil => value_mod.true_val,
        .bool_val => |av| if (av == b.bool_val) value_mod.true_val else value_mod.false_val,
        .int => |av| if (av == b.int) value_mod.true_val else value_mod.false_val,
        .float => |av| if (av == b.float) value_mod.true_val else value_mod.false_val,
        .char_val => |av| if (av == b.char_val) value_mod.true_val else value_mod.false_val,
        // ポインタ型はポインタ比較
        .string => |av| if (av == b.string) value_mod.true_val else value_mod.false_val,
        .keyword => |av| blk: {
            // キーワードは Clojure では intern されるため名前比較で identical? = true
            const bk = b.keyword;
            const name_eq = std.mem.eql(u8, av.name, bk.name);
            const ns_eq = if (av.namespace) |ans|
                (if (bk.namespace) |bns| std.mem.eql(u8, ans, bns) else false)
            else
                bk.namespace == null;
            break :blk if (name_eq and ns_eq) value_mod.true_val else value_mod.false_val;
        },
        .symbol => |av| if (av == b.symbol) value_mod.true_val else value_mod.false_val,
        .list => |av| if (av == b.list) value_mod.true_val else value_mod.false_val,
        .vector => |av| if (av == b.vector) value_mod.true_val else value_mod.false_val,
        .map => |av| if (av == b.map) value_mod.true_val else value_mod.false_val,
        .set => |av| if (av == b.set) value_mod.true_val else value_mod.false_val,
        .fn_val => |av| if (av == b.fn_val) value_mod.true_val else value_mod.false_val,
        .atom => |av| if (av == b.atom) value_mod.true_val else value_mod.false_val,
        .lazy_seq => |av| if (av == b.lazy_seq) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// NaN? : NaN かどうか
pub fn isNaN(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .float => |f| if (std.math.isNan(f)) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// infinite? : 無限大かどうか
pub fn isInfinite(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .float => |f| if (std.math.isInf(f)) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// nat-int? : 非負整数（0以上の整数）かどうか
pub fn isNatInt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |i| if (i >= 0) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// neg-int? : 負の整数かどうか
pub fn isNegInt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |i| if (i < 0) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// pos-int? : 正の整数（1以上）かどうか
pub fn isPosInt(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .int => |i| if (i > 0) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

/// special-symbol? : 特殊形式のシンボルかどうか
pub fn isSpecialSymbol(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .symbol => |s| {
            if (s.namespace != null) return value_mod.false_val;
            const name = s.name;
            // Clojure の特殊形式一覧
            const specials = [_][]const u8{
                "def", "if", "do", "let*", "fn*", "quote", "var",
                "loop*", "recur", "throw", "try", "catch", "finally",
                "monitor-enter", "monitor-exit", "new", "set!", ".",
                "&", "deftype*", "reify*", "case*", "import*",
                "letfn*",
            };
            for (specials) |sp| {
                if (std.mem.eql(u8, name, sp)) return value_mod.true_val;
            }
            return value_mod.false_val;
        },
        else => value_mod.false_val,
    };
}

/// var? : Var かどうか
pub fn isVar(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .var_val) value_mod.true_val else value_mod.false_val;
}

/// map-entry? : マップエントリ（2要素ベクタ）かどうか
pub fn isMapEntry(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .vector => |v| if (v.items.len == 2) value_mod.true_val else value_mod.false_val,
        else => value_mod.false_val,
    };
}

// ============================================================
// distinct? / realized? / lazy-seq?
// ============================================================

/// distinct? : 全要素が異なるかどうか
/// (distinct? 1 2 3) => true
pub fn isDistinctValues(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1) return error.ArityError;
    for (args, 0..) |a, i| {
        for (args[i + 1 ..]) |b| {
            if (a.eql(b)) return value_mod.false_val;
        }
    }
    return value_mod.true_val;
}

/// realized? : LazySeq が実体化済みかどうか
pub fn isRealized(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .delay_val => |d| if (d.realized) value_mod.true_val else value_mod.false_val,
        .promise => |p| if (p.delivered) value_mod.true_val else value_mod.false_val,
        .lazy_seq => |ls| if (ls.realized != null) value_mod.true_val else value_mod.false_val,
        else => error.TypeError,
    };
}

/// lazy-seq? : LazySeq かどうか
pub fn isLazySeq(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .lazy_seq) value_mod.true_val else value_mod.false_val;
}

// ============================================================
// Phase 12: PURE 述語・型チェック
// ============================================================

/// bytes? : バイト配列かどうか（Zig実装では常に false）
pub fn isBytes(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// class? : クラスかどうか（JVMなし、常に false）
pub fn isClass(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// decimal? : BigDecimalかどうか（Zig実装では常に false）
pub fn isDecimal(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// ratio? : 有理数かどうか（Ratio型未実装、常に false）
pub fn isRatio(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// rational? : 有理数的かどうか（整数は rational）
pub fn isRational(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .int) value_mod.true_val else value_mod.false_val;
}

/// record? : レコードかどうか（defrecord未実装、常に false）
pub fn isRecord(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// inst? : インスタントかどうか（常に false）
pub fn isInst(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// uri? : URIかどうか（常に false）
pub fn isUri(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// uuid? : UUIDかどうか（常に false — uuid型未実装）
pub fn isUuid(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// tagged-literal? : タグ付きリテラルかどうか（常に false）
pub fn isTaggedLiteral(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// reader-conditional? : リーダー条件式かどうか（常に false）
pub fn isReaderConditional(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return value_mod.false_val;
}

/// instance? : 型チェック（内部タグ検査で簡略実装）
pub fn instanceCheck(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    // (instance? type-name val) — type-name はキーワード/文字列/シンボルで型名を指定
    const type_name = switch (args[0]) {
        .keyword => |kw| kw.name,
        .string => |s| s.data,
        .symbol => |s| s.name,
        else => return value_mod.false_val,
    };
    const val = args[1];
    const is_match =
        if (std.mem.eql(u8, type_name, "Integer") or
        std.mem.eql(u8, type_name, "Long") or
        std.mem.eql(u8, type_name, "java.lang.Long") or
        std.mem.eql(u8, type_name, "java.lang.Integer") or
        std.mem.eql(u8, type_name, "Number") or
        std.mem.eql(u8, type_name, "java.lang.Number"))
        val == .int or val == .float
    else if (std.mem.eql(u8, type_name, "Double") or
        std.mem.eql(u8, type_name, "Float") or
        std.mem.eql(u8, type_name, "java.lang.Double") or
        std.mem.eql(u8, type_name, "java.lang.Float"))
        val == .float
    else if (std.mem.eql(u8, type_name, "String") or
        std.mem.eql(u8, type_name, "java.lang.String") or
        std.mem.eql(u8, type_name, "CharSequence") or
        std.mem.eql(u8, type_name, "java.lang.CharSequence"))
        val == .string
    else if (std.mem.eql(u8, type_name, "Boolean") or
        std.mem.eql(u8, type_name, "java.lang.Boolean"))
        val == .bool_val
    else if (std.mem.eql(u8, type_name, "Keyword") or
        std.mem.eql(u8, type_name, "clojure.lang.Keyword"))
        val == .keyword
    else if (std.mem.eql(u8, type_name, "Symbol") or
        std.mem.eql(u8, type_name, "clojure.lang.Symbol"))
        val == .symbol
    else if (std.mem.eql(u8, type_name, "clojure.lang.IEditableCollection"))
        val == .vector or val == .map or val == .set
    else if (std.mem.eql(u8, type_name, "Throwable") or
        std.mem.eql(u8, type_name, "java.lang.Throwable") or
        std.mem.eql(u8, type_name, "Exception") or
        std.mem.eql(u8, type_name, "java.lang.Exception"))
        // エラーは ex-info マップとして表現される（特別なタグなし）
        false
    else if (std.mem.eql(u8, type_name, "java.util.UUID"))
        // UUID はシンボルに false (未実装なら)
        false
    else if (std.mem.eql(u8, type_name, "java.util.regex.Pattern") or
        std.mem.eql(u8, type_name, "Pattern"))
        val == .regex
    else if (std.mem.eql(u8, type_name, "clojure.lang.PersistentVector") or
        std.mem.eql(u8, type_name, "clojure.lang.IPersistentVector"))
        val == .vector
    else if (std.mem.eql(u8, type_name, "clojure.lang.PersistentHashMap") or
        std.mem.eql(u8, type_name, "clojure.lang.IPersistentMap") or
        std.mem.eql(u8, type_name, "clojure.lang.PersistentArrayMap"))
        val == .map
    else if (std.mem.eql(u8, type_name, "clojure.lang.PersistentHashSet") or
        std.mem.eql(u8, type_name, "clojure.lang.IPersistentSet"))
        val == .set
    else if (std.mem.eql(u8, type_name, "clojure.lang.PersistentList") or
        std.mem.eql(u8, type_name, "clojure.lang.IPersistentList") or
        std.mem.eql(u8, type_name, "clojure.lang.ISeq"))
        val == .list or val == .lazy_seq
    else if (std.mem.eql(u8, type_name, "clojure.lang.IFn"))
        val == .fn_val or val == .partial_fn or val == .comp_fn or val == .multi_fn or val == .keyword or val == .map or val == .set or val == .vector
    else if (std.mem.eql(u8, type_name, "clojure.lang.Atom") or
        std.mem.eql(u8, type_name, "clojure.lang.IAtom"))
        val == .atom
    else if (std.mem.eql(u8, type_name, "clojure.lang.Var"))
        val == .var_val
    else if (std.mem.eql(u8, type_name, "clojure.lang.PersistentQueue"))
        false // 未実装型
    else if (std.mem.eql(u8, type_name, "Character") or
        std.mem.eql(u8, type_name, "java.lang.Character"))
        val == .char_val
    else
        false;
    return if (is_match) value_mod.true_val else value_mod.false_val;
}

// ============================================================
// builtins 登録テーブル
// ============================================================

pub const builtins = [_]BuiltinDef{
    // 述語
    .{ .name = "nil?", .func = isNil },
    .{ .name = "number?", .func = isNumber },
    .{ .name = "integer?", .func = isInteger },
    .{ .name = "float?", .func = isFloat },
    .{ .name = "string?", .func = isString },
    .{ .name = "keyword?", .func = isKeyword },
    .{ .name = "symbol?", .func = isSymbol },
    .{ .name = "fn?", .func = isFn },
    .{ .name = "coll?", .func = isColl },
    .{ .name = "list?", .func = isList },
    .{ .name = "vector?", .func = isVector },
    .{ .name = "map?", .func = isMap },
    .{ .name = "set?", .func = isSet },
    .{ .name = "some?", .func = isSome },
    .{ .name = "zero?", .func = isZero },
    .{ .name = "pos?", .func = isPos },
    .{ .name = "neg?", .func = isNeg },
    .{ .name = "even?", .func = isEven },
    .{ .name = "odd?", .func = isOdd },
    // Phase 11 述語
    .{ .name = "any?", .func = isAny },
    .{ .name = "boolean?", .func = isBoolean },
    .{ .name = "int?", .func = isInt },
    .{ .name = "double?", .func = isDouble },
    .{ .name = "char?", .func = isChar },
    .{ .name = "ident?", .func = isIdent },
    .{ .name = "simple-ident?", .func = isSimpleIdent },
    .{ .name = "simple-keyword?", .func = isSimpleKeyword },
    .{ .name = "simple-symbol?", .func = isSimpleSymbol },
    .{ .name = "qualified-ident?", .func = isQualifiedIdent },
    .{ .name = "qualified-keyword?", .func = isQualifiedKeyword },
    .{ .name = "qualified-symbol?", .func = isQualifiedSymbol },
    .{ .name = "indexed?", .func = isIndexed },
    .{ .name = "ifn?", .func = isIFn },
    .{ .name = "identical?", .func = isIdentical },
    .{ .name = "NaN?", .func = isNaN },
    .{ .name = "infinite?", .func = isInfinite },
    .{ .name = "nat-int?", .func = isNatInt },
    .{ .name = "neg-int?", .func = isNegInt },
    .{ .name = "pos-int?", .func = isPosInt },
    .{ .name = "special-symbol?", .func = isSpecialSymbol },
    .{ .name = "var?", .func = isVar },
    .{ .name = "map-entry?", .func = isMapEntry },
    // Atom
    .{ .name = "atom?", .func = isAtom },
    // プロトコル
    .{ .name = "satisfies?", .func = satisfiesPred },
    // distinct?
    .{ .name = "distinct?", .func = isDistinctValues },
    // シーケンス述語
    .{ .name = "seq?", .func = isSeq },
    .{ .name = "seqable?", .func = isSeqable },
    .{ .name = "sequential?", .func = isSequential },
    .{ .name = "associative?", .func = isAssociative },
    .{ .name = "counted?", .func = isCounted },
    .{ .name = "reversible?", .func = isReversible },
    .{ .name = "sorted?", .func = isSorted },
    // 遅延シーケンス述語
    .{ .name = "realized?", .func = isRealized },
    .{ .name = "lazy-seq?", .func = isLazySeq },
    // Phase 12: 述語
    .{ .name = "bytes?", .func = isBytes },
    .{ .name = "class?", .func = isClass },
    .{ .name = "decimal?", .func = isDecimal },
    .{ .name = "ratio?", .func = isRatio },
    .{ .name = "rational?", .func = isRational },
    .{ .name = "record?", .func = isRecord },
    .{ .name = "inst?", .func = isInst },
    .{ .name = "uri?", .func = isUri },
    .{ .name = "uuid?", .func = isUuid },
    .{ .name = "tagged-literal?", .func = isTaggedLiteral },
    .{ .name = "reader-conditional?", .func = isReaderConditional },
    .{ .name = "instance?", .func = instanceCheck },
};

// ============================================================
// テスト
// ============================================================

test "isNil" {
    const alloc = std.testing.allocator;
    const args_nil = [_]Value{value_mod.nil};
    const result_nil = try isNil(alloc, &args_nil);
    try std.testing.expect(result_nil.eql(value_mod.true_val));

    const args_not_nil = [_]Value{value_mod.intVal(1)};
    const result_not_nil = try isNil(alloc, &args_not_nil);
    try std.testing.expect(result_not_nil.eql(value_mod.false_val));
}
