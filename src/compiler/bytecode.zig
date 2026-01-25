//! バイトコード定義
//!
//! スタックベースVMのための命令セット。
//! Node からコンパイルされ、VM で実行される。
//!
//! 処理フロー:
//!   Form (Reader) → Node (Analyzer) → Bytecode (Compiler) → Value (VM)

const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;

/// オペコード
pub const OpCode = enum(u8) {
    // === スタック操作 ===
    /// 定数をスタックにプッシュ（オペランド: 定数インデックス u16）
    const_load,
    /// nil をプッシュ
    nil,
    /// true をプッシュ
    true_val,
    /// false をプッシュ
    false_val,
    /// スタックトップを複製
    dup,
    /// スタックトップを破棄
    pop,

    // === 変数参照 ===
    /// Var の値をプッシュ（オペランド: 定数インデックス u16 → Var ポインタ）
    var_load,
    /// ローカル変数をプッシュ（オペランド: スロット番号 u16）
    local_load,
    /// ローカル変数に格納（オペランド: スロット番号 u16）
    local_store,

    // === 制御フロー ===
    /// 無条件ジャンプ（オペランド: オフセット i16）
    jump,
    /// false/nil ならジャンプ（オペランド: オフセット i16）
    jump_if_false,
    /// true ならジャンプ（オペランド: オフセット i16）
    jump_if_true,

    // === 関数 ===
    /// 関数呼び出し（オペランド: 引数の数 u8）
    call,
    /// return（スタックトップを返す）
    ret,
    /// クロージャ作成（オペランド: 定数インデックス u16 → FnProto）
    closure,

    // === 定義 ===
    /// def（オペランド: 定数インデックス u16 → シンボル名）
    def,
    /// defmacro（オペランド: 定数インデックス u16 → シンボル名）
    def_macro,

    // === recur/loop ===
    /// loop 開始位置マーカー（スタック深度記録）
    loop_start,
    /// recur（オペランド: 引数の数 u8、ジャンプ先は別オペランド）
    recur,

    // === その他 ===
    /// 何もしない
    nop,
};

/// 命令（オペコード + オペランド）
pub const Instruction = struct {
    op: OpCode,
    /// オペランド（用途はオペコード依存）
    operand: u16 = 0,

    /// 符号付きオペランドとして取得
    pub fn signedOperand(self: Instruction) i16 {
        return @bitCast(self.operand);
    }
};

/// 関数プロトタイプ（コンパイル済み関数）
pub const FnProto = struct {
    name: ?[]const u8,
    arity: u8,
    variadic: bool,
    /// ローカル変数の数（引数含む）
    local_count: u16,
    /// 命令列
    code: []const Instruction,
    /// 定数テーブル
    constants: []const Value,
};

/// コンパイル済みコード（トップレベル）
pub const Chunk = struct {
    allocator: std.mem.Allocator,
    /// 命令列
    code: std.ArrayListUnmanaged(Instruction),
    /// 定数テーブル
    constants: std.ArrayListUnmanaged(Value),

    /// 初期化
    pub fn init(allocator: std.mem.Allocator) Chunk {
        return .{
            .allocator = allocator,
            .code = .empty,
            .constants = .empty,
        };
    }

    /// 解放
    pub fn deinit(self: *Chunk) void {
        self.code.deinit(self.allocator);
        self.constants.deinit(self.allocator);
    }

    /// 定数テーブルに追加し、インデックスを返す
    pub fn addConstant(self: *Chunk, val: Value) !u16 {
        const idx = self.constants.items.len;
        if (idx > std.math.maxInt(u16)) return error.TooManyConstants;
        try self.constants.append(self.allocator, val);
        return @intCast(idx);
    }

    /// 命令を追加
    pub fn emit(self: *Chunk, op: OpCode, operand: u16) !void {
        try self.code.append(self.allocator, .{ .op = op, .operand = operand });
    }

    /// オペランドなし命令を追加
    pub fn emitOp(self: *Chunk, op: OpCode) !void {
        try self.code.append(self.allocator, .{ .op = op, .operand = 0 });
    }

    /// 現在の命令インデックスを返す
    pub fn currentOffset(self: *const Chunk) usize {
        return self.code.items.len;
    }

    /// ジャンプ命令を追加（後でパッチ）
    pub fn emitJump(self: *Chunk, op: OpCode) !usize {
        const offset = self.code.items.len;
        try self.code.append(self.allocator, .{ .op = op, .operand = 0xFFFF });
        return offset;
    }

    /// ジャンプ先をパッチ（現在位置へのジャンプ）
    pub fn patchJump(self: *Chunk, offset: usize) void {
        const jump_dist = self.code.items.len - offset - 1;
        self.code.items[offset].operand = @intCast(jump_dist);
    }

    /// バックジャンプ（ループ用）を発行
    pub fn emitLoop(self: *Chunk, loop_start: usize) !void {
        // 後方ジャンプの距離を計算
        const dist = self.code.items.len - loop_start + 1;
        // 負の値を u16 として格納
        const operand: u16 = @bitCast(-@as(i16, @intCast(dist)));
        try self.emit(.jump, operand);
    }
};

// === テスト ===

test "Chunk basic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    // 定数を追加
    const idx = try chunk.addConstant(value_mod.intVal(42));
    try std.testing.expectEqual(@as(u16, 0), idx);

    // 命令を追加
    try chunk.emit(.const_load, idx);
    try chunk.emitOp(.ret);

    try std.testing.expectEqual(@as(usize, 2), chunk.code.items.len);
    try std.testing.expectEqual(OpCode.const_load, chunk.code.items[0].op);
    try std.testing.expectEqual(@as(u16, 0), chunk.code.items[0].operand);
}

test "Chunk jump patching" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    // jump_if_false を発行（後でパッチ）
    const jump_offset = try chunk.emitJump(.jump_if_false);

    // then 部分
    try chunk.emitOp(.nil);
    try chunk.emitOp(.nil);

    // ジャンプ先をパッチ
    chunk.patchJump(jump_offset);

    // else 部分
    try chunk.emitOp(.nil);

    // ジャンプ距離は 2（nil, nil をスキップ）
    try std.testing.expectEqual(@as(u16, 2), chunk.code.items[jump_offset].operand);
}
