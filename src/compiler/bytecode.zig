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
///
/// Clojure 意味論ベースの命令セット。
/// JVM bytecode ではなく、Clojure が必要とする操作を直接表現。
///
/// カテゴリ別に範囲を予約:
///   0x00-0x0F: 定数・リテラル
///   0x10-0x1F: スタック操作
///   0x20-0x2F: ローカル変数
///   0x30-0x3F: クロージャ変数（upvalue）
///   0x40-0x4F: Var 操作
///   0x50-0x5F: 制御フロー
///   0x60-0x6F: 関数
///   0x70-0x7F: loop/recur
///   0x80-0x8F: コレクション生成
///   0x90-0x9F: コレクション操作（将来最適化）
///   0xA0-0xAF: 例外処理
///   0xC0-0xCF: メタデータ
///   0xF0-0xFF: 予約・デバッグ
pub const OpCode = enum(u8) {
    // ═══════════════════════════════════════════════════════
    // [A] 定数・リテラル (0x00-0x0F)
    // ═══════════════════════════════════════════════════════
    /// 定数をスタックにプッシュ（オペランド: 定数インデックス u16）
    const_load = 0x00,
    /// nil をプッシュ
    nil = 0x01,
    /// true をプッシュ
    true_val = 0x02,
    /// false をプッシュ
    false_val = 0x03,
    /// 整数 0 をプッシュ（最適化）
    int_0 = 0x04,
    /// 整数 1 をプッシュ（最適化）
    int_1 = 0x05,
    /// 整数 -1 をプッシュ（最適化）
    int_neg1 = 0x06,
    // 0x07-0x0F: 予約

    // ═══════════════════════════════════════════════════════
    // [B] スタック操作 (0x10-0x1F)
    // ═══════════════════════════════════════════════════════
    /// スタックトップを破棄
    pop = 0x10,
    /// スタックトップを複製
    dup = 0x11,
    /// スタックトップ2つを交換
    swap = 0x12,
    // 0x13-0x1F: 予約

    // ═══════════════════════════════════════════════════════
    // [C] ローカル変数 (0x20-0x2F)
    // ═══════════════════════════════════════════════════════
    /// ローカル変数をプッシュ（オペランド: スロット番号 u16）
    local_load = 0x20,
    /// ローカル変数に格納（オペランド: スロット番号 u16）
    local_store = 0x21,
    /// ローカル変数 0 をプッシュ（最適化: 引数0）
    local_load_0 = 0x22,
    /// ローカル変数 1 をプッシュ（最適化）
    local_load_1 = 0x23,
    /// ローカル変数 2 をプッシュ（最適化）
    local_load_2 = 0x24,
    /// ローカル変数 3 をプッシュ（最適化）
    local_load_3 = 0x25,
    // 0x26-0x2F: 予約

    // ═══════════════════════════════════════════════════════
    // [D] クロージャ変数 (0x30-0x3F)
    // ═══════════════════════════════════════════════════════
    /// クロージャ変数（外側スコープ）をプッシュ（オペランド: upvalue インデックス u16）
    upvalue_load = 0x30,
    /// クロージャ変数に格納（オペランド: upvalue インデックス u16）
    upvalue_store = 0x31,
    // 0x32-0x3F: 予約

    // ═══════════════════════════════════════════════════════
    // [E] Var 操作 (0x40-0x4F)
    // ═══════════════════════════════════════════════════════
    /// Var の root 値をプッシュ（オペランド: 定数インデックス u16 → Var ポインタ）
    var_load = 0x40,
    /// 動的 Var の値をプッシュ（binding マクロ対応）
    var_load_dynamic = 0x41,
    /// def（オペランド: 定数インデックス u16 → シンボル名）
    def = 0x42,
    /// defmacro（オペランド: 定数インデックス u16 → シンボル名）
    def_macro = 0x43,
    // 0x44-0x4F: 予約

    // ═══════════════════════════════════════════════════════
    // [F] 制御フロー (0x50-0x5F)
    // ═══════════════════════════════════════════════════════
    /// 無条件ジャンプ（オペランド: オフセット i16）
    jump = 0x50,
    /// false/nil ならジャンプ（オペランド: オフセット i16）
    jump_if_false = 0x51,
    /// true ならジャンプ（オペランド: オフセット i16）
    jump_if_true = 0x52,
    /// nil のみでジャンプ（最適化）
    jump_if_nil = 0x53,
    /// 後方ジャンプ専用（loop 用、オペランド: 負のオフセット）
    jump_back = 0x54,
    // 0x55-0x5F: 予約

    // ═══════════════════════════════════════════════════════
    // [G] 関数 (0x60-0x6F)
    // ═══════════════════════════════════════════════════════
    /// 関数呼び出し（オペランド: 引数の数 u16）
    call = 0x60,
    /// 引数 0 の呼び出し（最適化）
    call_0 = 0x61,
    /// 引数 1 の呼び出し（最適化）
    call_1 = 0x62,
    /// 引数 2 の呼び出し（最適化）
    call_2 = 0x63,
    /// 引数 3 の呼び出し（最適化）
    call_3 = 0x64,
    /// 末尾呼び出し最適化（オペランド: 引数の数 u16）
    tail_call = 0x65,
    /// apply 関数用（オペランド: 固定引数の数 u16）
    apply = 0x66,
    /// return（スタックトップを返す）
    ret = 0x67,
    /// クロージャ作成（オペランド: 定数インデックス u16 → FnProto）
    closure = 0x68,
    // 0x69-0x6F: 予約

    // ═══════════════════════════════════════════════════════
    // [H] loop/recur (0x70-0x7F)
    // ═══════════════════════════════════════════════════════
    /// loop 開始位置マーカー（スタック深度記録）
    loop_start = 0x70,
    /// recur（オペランド: 引数の数 u16、引数再バインド + jump_back）
    recur = 0x71,
    // 0x72-0x7F: 予約

    // ═══════════════════════════════════════════════════════
    // [I] コレクション生成 (0x80-0x8F)
    // ═══════════════════════════════════════════════════════
    /// リストリテラル生成（オペランド: 要素数 u16）
    list_new = 0x80,
    /// ベクタリテラル生成（オペランド: 要素数 u16）
    vec_new = 0x81,
    /// マップリテラル生成（オペランド: ペア数 u16）
    map_new = 0x82,
    /// セットリテラル生成（オペランド: 要素数 u16）
    set_new = 0x83,
    // 0x84-0x8F: 予約

    // ═══════════════════════════════════════════════════════
    // [J] コレクション操作 (0x90-0x9F) - 将来最適化用
    // ═══════════════════════════════════════════════════════
    /// (nth coll idx) - インデックスアクセス
    nth = 0x90,
    /// (get map key) - キーアクセス
    get = 0x91,
    /// (first coll) - 先頭要素
    first = 0x92,
    /// (rest coll) - 残りのシーケンス
    rest = 0x93,
    /// (conj coll val) - 要素追加
    conj = 0x94,
    /// (assoc map k v) - 関連付け更新
    assoc = 0x95,
    /// (count coll) - 要素数
    count = 0x96,
    // 0x97-0x9F: 予約

    // ═══════════════════════════════════════════════════════
    // [K] 例外処理 (0xA0-0xAF)
    // ═══════════════════════════════════════════════════════
    /// try ブロック開始（オペランド: catch/finally へのオフセット）
    try_begin = 0xA0,
    /// catch 節開始（オペランド: 例外型の定数インデックス）
    catch_begin = 0xA1,
    /// finally 節開始
    finally_begin = 0xA2,
    /// try ブロック終了
    try_end = 0xA3,
    /// throw（スタックトップを例外として投げる）
    throw_ex = 0xA4,
    // 0xA5-0xAF: 予約

    // ═══════════════════════════════════════════════════════
    // [L] メタデータ (0xC0-0xCF)
    // ═══════════════════════════════════════════════════════
    /// (with-meta obj meta) - メタデータ付与
    with_meta = 0xC0,
    /// (meta obj) - メタデータ取得
    meta = 0xC1,
    // 0xC2-0xCF: 予約

    // ═══════════════════════════════════════════════════════
    // [Z] 予約・デバッグ (0xF0-0xFF)
    // ═══════════════════════════════════════════════════════
    /// 何もしない
    nop = 0xF0,
    /// デバッグ用（スタックトップを表示）
    debug_print = 0xF1,
    // 0xF2-0xFF: 予約
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
