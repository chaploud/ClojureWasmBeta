//! 並行性・状態管理
//!
//! atom, deref, delay, promise, volatile, reduced, var ops

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const var_mod = defs.var_mod;
const Env = defs.Env;
const BuiltinDef = defs.BuiltinDef;

const helpers = @import("helpers.zig");

// ============================================================
// Atom 操作
// ============================================================

/// atom: Atom を生成
/// (atom val) → #<atom val>
pub fn atomFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const a = try allocator.create(value_mod.Atom);
    a.* = value_mod.Atom.init(args[0]);
    return Value{ .atom = a };
}

/// deref: Atom の現在値を返す
/// (deref atom) → val
pub fn derefFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .atom => |a| a.value,
        .volatile_val => |v| v.value,
        .delay_val => |d| {
            if (d.realized) {
                return d.cached orelse Value.nil;
            }
            return forceFn(allocator, args);
        },
        .promise => |p| p.value orelse value_mod.nil,
        else => error.TypeError,
    };
}

/// reset!: Atom の値を新しい値に置換
/// (reset! atom new-val) → new-val
pub fn resetBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    return switch (args[0]) {
        .atom => |a| {
            // scratch 参照を排除するためディープクローン
            const cloned = try args[1].deepClone(allocator);
            a.value = cloned;
            return cloned;
        },
        else => error.TypeError,
    };
}

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
// Phase 13: delay/volatile/reduced
// ============================================================

/// __delay-create : Delay オブジェクトを作成（内部用）
/// (delay expr) マクロから呼ばれる: (__delay-create (fn [] expr))
pub fn delayCreate(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    // 引数は (fn [] expr) 形式の関数
    if (!helpers.isFnValue(args[0])) return error.TypeError;
    const d = try allocator.create(value_mod.Delay);
    d.* = value_mod.Delay.init(args[0]);
    return Value{ .delay_val = d };
}

/// force : delay の値を取得（未評価なら評価してキャッシュ）
pub fn forceFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .delay_val => |d| {
            if (d.realized) {
                return d.cached orelse value_mod.nil;
            }
            // 関数を呼び出して結果をキャッシュ
            const call = defs.call_fn orelse return error.TypeError;
            const result = try call(d.fn_val.?, &[_]Value{}, allocator);
            d.cached = result;
            d.fn_val = null;
            d.realized = true;
            return result;
        },
        else => args[0], // delay でない値はそのまま返す
    };
}

/// delay? : Delay オブジェクトかどうか
pub fn isDelayFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .delay_val) value_mod.true_val else value_mod.false_val;
}

/// volatile! : Volatile ボックスを作成
pub fn volatileBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const v = try allocator.create(value_mod.Volatile);
    v.* = value_mod.Volatile.init(args[0]);
    return Value{ .volatile_val = v };
}

/// volatile? : Volatile かどうか
pub fn isVolatileFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .volatile_val) value_mod.true_val else value_mod.false_val;
}

/// vreset! : Volatile の値をリセット
pub fn vresetBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const v = switch (args[0]) {
        .volatile_val => |vol| vol,
        else => return error.TypeError,
    };
    v.value = args[1];
    return args[1];
}

/// vswap! : Volatile の値を関数で更新 (vswap! vol f & args)
pub fn vswapBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const v = switch (args[0]) {
        .volatile_val => |vol| vol,
        else => return error.TypeError,
    };
    const call = defs.call_fn orelse return error.TypeError;
    // (f current-val & extra-args)
    var call_args = std.ArrayList(Value).empty;
    defer call_args.deinit(allocator);
    try call_args.append(allocator, v.value);
    for (args[2..]) |extra| {
        try call_args.append(allocator, extra);
    }
    const new_val = try call(args[1], call_args.items, allocator);
    v.value = new_val;
    return new_val;
}

// ============================================================
// reduced
// ============================================================

/// reduced : 値を Reduced でラップ（reduce の早期終了用）
pub fn reducedFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const r = try allocator.create(value_mod.Reduced);
    r.* = value_mod.Reduced.init(args[0]);
    return Value{ .reduced_val = r };
}

/// reduced? : Reduced かどうか
pub fn isReducedFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return if (args[0] == .reduced_val) value_mod.true_val else value_mod.false_val;
}

/// unreduced : Reduced の内部値を取得（Reduced でなければそのまま）
pub fn unreducedFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .reduced_val => |r| r.value,
        else => args[0],
    };
}

/// ensure-reduced : Reduced でなければ Reduced でラップ
pub fn ensureReducedFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .reduced_val => args[0], // 既に Reduced
        else => {
            const r = try allocator.create(value_mod.Reduced);
            r.* = value_mod.Reduced.init(args[0]);
            return Value{ .reduced_val = r };
        },
    };
}

// ============================================================
// Phase 15: Atom 拡張・Var 操作
// ============================================================

/// add-watch : Atom にウォッチャーを登録
/// (add-watch atom key fn) → atom
/// fn は (fn [key atom old-val new-val] ...) 形式
pub fn addWatchFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const a = switch (args[0]) {
        .atom => |atom| atom,
        else => return error.TypeError,
    };
    const key = args[1];
    const watch_fn = args[2];
    // watches 配列に [key, fn] を追加
    var new_watches = std.ArrayList(Value).empty;
    if (a.watches) |ws| {
        try new_watches.appendSlice(allocator, ws);
    }
    try new_watches.append(allocator, key);
    try new_watches.append(allocator, watch_fn);
    a.watches = new_watches.items;
    return args[0];
}

/// remove-watch : Atom からウォッチャーを削除
/// (remove-watch atom key) → atom
pub fn removeWatchFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const a = switch (args[0]) {
        .atom => |atom| atom,
        else => return error.TypeError,
    };
    const key = args[1];
    if (a.watches) |ws| {
        // [key1, fn1, key2, fn2, ...] からキーを検索して削除
        var i: usize = 0;
        while (i + 1 < ws.len) {
            if (ws[i].eql(key)) {
                // 見つかった: key, fn の2要素を除去した新配列を作成
                // 簡易版: null 化（GC で回収）
                // TODO: 配列を再構築
                break;
            }
            i += 2;
        }
    }
    return args[0];
}

/// get-validator : Atom のバリデータを取得
/// (get-validator atom) → fn or nil
pub fn getValidatorFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const a = switch (args[0]) {
        .atom => |atom| atom,
        else => return error.TypeError,
    };
    return a.validator orelse value_mod.nil;
}

/// set-validator! : Atom にバリデータを設定
/// (set-validator! atom fn) → nil
pub fn setValidatorBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const a = switch (args[0]) {
        .atom => |atom| atom,
        else => return error.TypeError,
    };
    a.validator = if (args[1].isNil()) null else args[1];
    return value_mod.nil;
}

/// compare-and-set! : Atom の値を CAS で更新
/// (compare-and-set! atom oldval newval) → bool
pub fn compareAndSetBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 3) return error.ArityError;
    const a = switch (args[0]) {
        .atom => |atom| atom,
        else => return error.TypeError,
    };
    if (a.value.eql(args[1])) {
        const cloned = try args[2].deepClone(allocator);
        a.value = cloned;
        return value_mod.true_val;
    }
    return value_mod.false_val;
}

/// reset-vals! : Atom を新値に設定し [old new] を返す
/// (reset-vals! atom newval) → [old-val new-val]
pub fn resetValsBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const a = switch (args[0]) {
        .atom => |atom| atom,
        else => return error.TypeError,
    };
    const old_val = a.value;
    const cloned = try args[1].deepClone(allocator);
    a.value = cloned;
    // [old new] ベクターを返す
    const items = try allocator.alloc(Value, 2);
    items[0] = old_val;
    items[1] = cloned;
    const v = try allocator.create(value_mod.PersistentVector);
    v.* = .{ .items = items };
    return Value{ .vector = v };
}

/// swap-vals! : Atom に関数を適用し [old new] を返す
/// (swap-vals! atom f & args) → [old-val new-val]
pub fn swapValsBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const a = switch (args[0]) {
        .atom => |atom| atom,
        else => return error.TypeError,
    };
    const call = defs.call_fn orelse return error.TypeError;
    const old_val = a.value;
    // (f current-val extra-args...)
    var call_args = std.ArrayList(Value).empty;
    defer call_args.deinit(allocator);
    try call_args.append(allocator, a.value);
    for (args[2..]) |extra| {
        try call_args.append(allocator, extra);
    }
    const new_val = try call(args[1], call_args.items, allocator);
    const cloned = try new_val.deepClone(allocator);
    a.value = cloned;
    // [old new] ベクターを返す
    const items = try allocator.alloc(Value, 2);
    items[0] = old_val;
    items[1] = cloned;
    const v = try allocator.create(value_mod.PersistentVector);
    v.* = .{ .items = items };
    return Value{ .vector = v };
}

// ============================================================
// Var 操作
// ============================================================

/// var-get : Var の値を取得
/// (var-get var) → val
pub fn varGetFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const v = switch (args[0]) {
        .var_val => |vp| @as(*defs.Var, @ptrCast(@alignCast(vp))),
        else => return error.TypeError,
    };
    return v.deref();
}

/// var-set : スレッドバインディングの値を設定 (binding 内でのみ有効)
/// (var-set var val) → val
pub fn varSetFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 2) return error.ArityError;
    const v = switch (args[0]) {
        .var_val => |vp| @as(*defs.Var, @ptrCast(@alignCast(vp))),
        else => return error.TypeError,
    };
    try var_mod.setThreadBinding(v, args[1]);
    return args[1];
}

/// alter-var-root : Var の root 値を関数で更新
/// (alter-var-root var f & args) → new-val
pub fn alterVarRootFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const v = switch (args[0]) {
        .var_val => |vp| @as(*defs.Var, @ptrCast(@alignCast(vp))),
        else => return error.TypeError,
    };
    const call = defs.call_fn orelse return error.TypeError;
    // (f current-val extra-args...)
    var call_args = std.ArrayList(Value).empty;
    defer call_args.deinit(allocator);
    try call_args.append(allocator, v.getRawRoot());
    for (args[2..]) |extra| {
        try call_args.append(allocator, extra);
    }
    const new_val = try call(args[1], call_args.items, allocator);
    v.bindRoot(new_val);
    return new_val;
}

/// find-var : 名前空間修飾シンボルから Var を検索
/// (find-var 'ns/name) → var or nil
pub fn findVarFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const sym = switch (args[0]) {
        .symbol => |s| s,
        else => return error.TypeError,
    };
    const env = defs.current_env orelse return error.TypeError;
    const ns_name = sym.namespace orelse return value_mod.nil;
    const ns = env.findNs(ns_name) orelse return value_mod.nil;
    const v = ns.resolve(sym.name) orelse return value_mod.nil;
    return Value{ .var_val = @ptrCast(v) };
}

/// intern : 名前空間に Var を定義
/// (intern ns-sym name-sym) or (intern ns-sym name-sym val)
pub fn internFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2 or args.len > 3) return error.ArityError;
    const env = defs.current_env orelse return error.TypeError;
    const ns_name = switch (args[0]) {
        .symbol => |s| s.name,
        .string => |s| s.data,
        else => return error.TypeError,
    };
    const sym_name = switch (args[1]) {
        .symbol => |s| s.name,
        .string => |s| s.data,
        else => return error.TypeError,
    };
    const ns = try env.findOrCreateNs(ns_name);
    const v = try ns.intern(sym_name);
    if (args.len == 3) {
        const cloned = try args[2].deepClone(allocator);
        v.bindRoot(cloned);
    }
    return Value{ .var_val = @ptrCast(v) };
}

/// bound? : Var が束縛されているか（root が nil でない）
/// (bound? var) → bool
pub fn boundPred(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len < 1) return error.ArityError;
    // 全引数が bound であれば true
    for (args) |arg| {
        const v = switch (arg) {
            .var_val => |vp| @as(*defs.Var, @ptrCast(@alignCast(vp))),
            else => return error.TypeError,
        };
        if (v.deref().isNil()) return value_mod.false_val;
    }
    return value_mod.true_val;
}

// ============================================================
// Phase 18: promise/deliver
// ============================================================

/// promise : 空の promise を作成
/// (promise) → #<promise (pending)>
pub fn promiseFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return error.ArityError;
    const p = try allocator.create(value_mod.Promise);
    p.* = value_mod.Promise.init();
    return Value{ .promise = p };
}

/// deliver : promise に値を配送（1回だけ）
/// (deliver p val) → p
pub fn deliverFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[0] != .promise) return error.TypeError;
    const p = args[0].promise;
    if (!p.delivered) {
        p.value = try args[1].deepClone(allocator);
        p.delivered = true;
    }
    return args[0];
}

/// realized? : delay/promise/lazy-seq が実体化済みか
/// (realized? x) → bool
pub fn realizedPred(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    return switch (args[0]) {
        .delay_val => |d| if (d.realized) value_mod.true_val else value_mod.false_val,
        .promise => |p| if (p.delivered) value_mod.true_val else value_mod.false_val,
        .lazy_seq => |ls| if (ls.realized != null) value_mod.true_val else value_mod.false_val,
        else => error.TypeError,
    };
}

// ============================================================
// builtins
// ============================================================

pub const builtins = [_]BuiltinDef{
    // Atom
    .{ .name = "atom", .func = atomFn },
    .{ .name = "deref", .func = derefFn },
    .{ .name = "reset!", .func = resetBang },
    // atom? は predicates.zig に移動済み
    // delay/force
    .{ .name = "__delay-create", .func = delayCreate },
    .{ .name = "force", .func = forceFn },
    .{ .name = "delay?", .func = isDelayFn },
    // volatile
    .{ .name = "volatile!", .func = volatileBang },
    .{ .name = "volatile?", .func = isVolatileFn },
    .{ .name = "vreset!", .func = vresetBang },
    .{ .name = "vswap!", .func = vswapBang },
    // reduced
    .{ .name = "reduced", .func = reducedFn },
    .{ .name = "reduced?", .func = isReducedFn },
    .{ .name = "unreduced", .func = unreducedFn },
    .{ .name = "ensure-reduced", .func = ensureReducedFn },
    // Atom 拡張
    .{ .name = "add-watch", .func = addWatchFn },
    .{ .name = "remove-watch", .func = removeWatchFn },
    .{ .name = "get-validator", .func = getValidatorFn },
    .{ .name = "set-validator!", .func = setValidatorBang },
    .{ .name = "compare-and-set!", .func = compareAndSetBang },
    .{ .name = "reset-vals!", .func = resetValsBang },
    .{ .name = "swap-vals!", .func = swapValsBang },
    // Var 操作
    .{ .name = "var-get", .func = varGetFn },
    .{ .name = "var-set", .func = varSetFn },
    .{ .name = "alter-var-root", .func = alterVarRootFn },
    .{ .name = "find-var", .func = findVarFn },
    .{ .name = "intern", .func = internFn },
    .{ .name = "bound?", .func = boundPred },
    // promise
    .{ .name = "promise", .func = promiseFn },
    .{ .name = "deliver", .func = deliverFn },
    // realized? は predicates.zig に移動済み
};
