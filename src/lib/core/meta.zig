//! メタデータ操作
//!
//! with-meta, meta, vary-meta, alter-meta!, reset-meta!

const std = @import("std");
const defs = @import("defs.zig");
const Value = defs.Value;
const value_mod = defs.value_mod;
const BuiltinDef = defs.BuiltinDef;

const Var = defs.Var;

/// with-meta : 値にメタデータを付与（簡易版）
/// ※ 実際にはコレクションの meta フィールドを設定する
pub fn withMeta(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    if (args[1] != .map) return error.TypeError;
    const meta = args[1];

    // メタデータをヒープに確保
    const meta_ptr = try allocator.create(Value);
    meta_ptr.* = meta;

    return switch (args[0]) {
        .list => |l| blk: {
            const new_list = try allocator.create(value_mod.PersistentList);
            new_list.* = .{ .items = l.items, .meta = meta_ptr };
            break :blk Value{ .list = new_list };
        },
        .vector => |v| blk: {
            const new_vec = try allocator.create(value_mod.PersistentVector);
            new_vec.* = .{ .items = v.items, .meta = meta_ptr };
            break :blk Value{ .vector = new_vec };
        },
        .map => |m| blk: {
            const new_map = try allocator.create(value_mod.PersistentMap);
            new_map.* = .{ .entries = m.entries, .meta = meta_ptr };
            break :blk Value{ .map = new_map };
        },
        .set => |s| blk: {
            const new_set = try allocator.create(value_mod.PersistentSet);
            new_set.* = .{ .items = s.items, .meta = meta_ptr };
            break :blk Value{ .set = new_set };
        },
        else => error.TypeError,
    };
}

/// meta : 値のメタデータを取得
pub fn metaFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    _ = allocator;
    if (args.len != 1) return error.ArityError;
    const m: ?*const Value = switch (args[0]) {
        .list => |l| l.meta,
        .vector => |v| v.meta,
        .map => |mp| mp.meta,
        .set => |s| s.meta,
        else => null,
    };
    return if (m) |ptr| ptr.* else value_mod.nil;
}

/// alter-meta! : 参照のメタデータを関数で更新
/// (alter-meta! ref f & args) → new-meta
pub fn alterMetaBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    const call = defs.call_fn orelse return error.TypeError;

    // 現在のメタを取得
    const current_meta: Value = switch (args[0]) {
        .atom => |a| a.meta orelse value_mod.nil,
        .var_val => |vp| blk: {
            const v: *Var = @ptrCast(@alignCast(vp));
            break :blk if (v.meta) |m| m.* else value_mod.nil;
        },
        else => return error.TypeError,
    };

    // (f current-meta extra-args...)
    var call_args = std.ArrayList(Value).empty;
    defer call_args.deinit(allocator);
    try call_args.append(allocator, current_meta);
    for (args[2..]) |extra| {
        try call_args.append(allocator, extra);
    }
    const new_meta = try call(args[1], call_args.items, allocator);

    // メタを更新
    switch (args[0]) {
        .atom => |a| {
            a.meta = new_meta;
        },
        .var_val => |vp| {
            const v: *Var = @ptrCast(@alignCast(vp));
            const meta_ptr = try allocator.create(Value);
            meta_ptr.* = new_meta;
            v.meta = meta_ptr;
        },
        else => return error.TypeError,
    }
    return new_meta;
}

/// reset-meta! : 参照のメタデータを新値に置換
/// (reset-meta! ref new-meta) → new-meta
pub fn resetMetaBang(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    switch (args[0]) {
        .atom => |a| {
            a.meta = args[1];
        },
        .var_val => |vp| {
            const v: *Var = @ptrCast(@alignCast(vp));
            const meta_ptr = try allocator.create(Value);
            meta_ptr.* = args[1];
            v.meta = meta_ptr;
        },
        else => return error.TypeError,
    }
    return args[1];
}

/// vary-meta : オブジェクトのメタデータを関数で変更した新オブジェクトを返す
/// (vary-meta obj f & args) → obj-with-new-meta
/// 簡易実装: alter-meta! と同等（永続オブジェクトのメタ変更）
pub fn varyMetaFn(allocator: std.mem.Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    // vary-meta は immutable オブジェクトのメタを変更する
    // 現時点では alter-meta! と同等に処理
    _ = try alterMetaBang(allocator, args);
    return args[0];
}

pub const builtins = [_]BuiltinDef{
    .{ .name = "with-meta", .func = withMeta },
    .{ .name = "meta", .func = metaFn },
    .{ .name = "alter-meta!", .func = alterMetaBang },
    .{ .name = "reset-meta!", .func = resetMetaBang },
    .{ .name = "vary-meta", .func = varyMetaFn },
};
