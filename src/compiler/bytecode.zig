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
    /// スコープ終了: N個のローカルを除去し結果を保持（オペランド: 除去する数 u16）
    scope_exit = 0x13,
    // 0x14-0x1F: 予約

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
    /// defmulti（オペランド: 定数インデックス u16 → シンボル名）
    /// スタック: [dispatch_fn] → [nil]
    defmulti = 0x44,
    /// defmethod（オペランド: 定数インデックス u16 → シンボル名）
    /// スタック: [dispatch_val, method_fn] → [nil]
    defmethod = 0x45,
    /// defprotocol（オペランド: 定数インデックス u16 → プロトコルメタデータ）
    /// スタック: [] → [nil]
    defprotocol = 0x46,
    /// extend-type メソッド登録（オペランド: 定数インデックス u16 → [type, proto, method] 情報）
    /// スタック: [method_fn] → [nil]
    extend_type_method = 0x47,
    /// def_doc: def 直後に doc/arglists を Var に設定
    /// オペランド: 定数インデックス u16 → [doc_string, arglists_string] (nil の場合は設定しない)
    /// スタック変化なし (直前の def の戻り値 Var を peek して設定)
    def_doc = 0x48,
    // 0x49-0x4F: 予約

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
    /// return（スタックトップを返す）
    ret = 0x67,
    /// クロージャ作成（オペランド: 定数インデックス u16 → FnProto）
    closure = 0x68,
    /// 複数アリティクロージャ作成（オペランド: アリティ数 u16）
    /// スタック上に FnProto が アリティ数 個あることを期待
    closure_multi = 0x69,

    // ═══════════════════════════════════════════════════════
    // [H] loop/recur (0x70-0x7F)
    // ═══════════════════════════════════════════════════════
    /// loop 開始位置マーカー（スタック深度記録）
    loop_start = 0x70,
    /// recur（オペランド: 引数の数 u16、引数再バインド + jump_back）
    recur = 0x71,
    /// letfn fixup（オペランド: 関数の数 u16）
    /// スタック上に N 個のクロージャがある状態で、
    /// 各クロージャの closure_bindings を相互参照に更新
    letfn_fixup = 0x72,
    // 0x73-0x7F: 予約

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
    /// lazy-seq 作成（スタック: [fn] → [lazy_seq]）
    lazy_seq = 0x9B,
    // 0x9C-0x9F: 予約

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

    // ═══════════════════════════════════════════════════════════
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
    /// 親スコープからキャプチャするローカル変数の数
    /// 0 の場合は従来通り frame.base > 0 でキャプチャ判定
    capture_count: u16 = 0,
    /// キャプチャ開始のスタックオフセット（frame.base からの相対位置）
    /// let がネストされた式内にある場合、先行する値をスキップ
    capture_offset: u16 = 0,
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
    /// Value を永続アロケータに深コピーする（scratch arena 解放後も安全にするため）
    pub fn addConstant(self: *Chunk, val: Value) !u16 {
        const idx = self.constants.items.len;
        if (idx > std.math.maxInt(u16)) return error.TooManyConstants;
        const cloned = try val.deepClone(self.allocator);
        try self.constants.append(self.allocator, cloned);
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

/// バイトコードダンプ（デバッグ用）
pub fn dumpChunk(chunk: *const Chunk, writer: *std.Io.Writer) !void {
    try writer.writeAll("=== Bytecode Dump ===\n");

    // 定数テーブル
    if (chunk.constants.items.len > 0) {
        try writer.writeAll("\n--- Constants ---\n");
        for (chunk.constants.items, 0..) |c, ci| {
            try writer.print("  [{d:>3}] ", .{ci});
            try dumpValue(c, writer);
            try writer.writeByte('\n');
        }
    }

    // 命令列
    try writer.writeAll("\n--- Instructions ---\n");
    for (chunk.code.items, 0..) |instr, ip| {
        try writer.print("  {d:>4}: ", .{ip});
        try dumpInstruction(instr, chunk.constants.items, writer);
        try writer.writeByte('\n');
    }

    try writer.print("\n({d} instructions, {d} constants)\n", .{ chunk.code.items.len, chunk.constants.items.len });
}

/// FnProto のバイトコードをダンプ
pub fn dumpFnProto(proto: *const FnProto, writer: *std.Io.Writer) !void {
    try writer.print("\n--- fn {s} (arity={d}{s}) ---\n", .{
        proto.name orelse "<anonymous>",
        proto.arity,
        if (proto.variadic) " variadic" else "",
    });

    // 定数テーブル
    if (proto.constants.len > 0) {
        try writer.writeAll("  Constants:\n");
        for (proto.constants, 0..) |c, ci| {
            try writer.print("    [{d:>3}] ", .{ci});
            try dumpValue(c, writer);
            try writer.writeByte('\n');
        }
    }

    // 命令列
    for (proto.code, 0..) |instr, ip| {
        try writer.print("    {d:>4}: ", .{ip});
        try dumpInstruction(instr, proto.constants, writer);
        try writer.writeByte('\n');
    }
}

/// 1命令をダンプ
fn dumpInstruction(instr: Instruction, constants: []const Value, writer: *std.Io.Writer) !void {
    const op_name = @tagName(instr.op);
    try writer.print("{s:<20}", .{op_name});

    // オペランド付きの opcode
    switch (instr.op) {
        .const_load => {
            try writer.print(" #{d}", .{instr.operand});
            if (instr.operand < constants.len) {
                try writer.writeAll("  ; ");
                try dumpValue(constants[instr.operand], writer);
            }
        },
        .local_load, .local_store, .upvalue_load, .upvalue_store => {
            try writer.print(" slot={d}", .{instr.operand});
        },
        .var_load, .var_load_dynamic, .def, .def_macro, .defmulti, .defmethod, .defprotocol, .extend_type_method, .def_doc => {
            try writer.print(" #{d}", .{instr.operand});
            if (instr.operand < constants.len) {
                try writer.writeAll("  ; ");
                try dumpValue(constants[instr.operand], writer);
            }
        },
        .jump, .jump_if_false, .jump_if_true, .jump_if_nil, .jump_back => {
            const signed: i16 = @bitCast(instr.operand);
            try writer.print(" {d}", .{signed});
        },
        .call, .tail_call, .recur, .letfn_fixup => {
            try writer.print(" {d}", .{instr.operand});
        },
        .scope_exit => {
            try writer.print(" pop={d}", .{instr.operand});
        },
        .list_new, .vec_new, .set_new => {
            try writer.print(" n={d}", .{instr.operand});
        },
        .map_new => {
            try writer.print(" pairs={d}", .{instr.operand});
        },
        .closure, .closure_multi => {
            try writer.print(" #{d}", .{instr.operand});
        },
        else => {
            // オペランドなし or 不明
            if (instr.operand != 0) {
                try writer.print(" {d}", .{instr.operand});
            }
        },
    }
}

/// Value を簡潔にダンプ
fn dumpValue(val: Value, writer: *std.Io.Writer) !void {
    switch (val) {
        .nil => try writer.writeAll("nil"),
        .bool_val => |b| try writer.print("{}", .{b}),
        .int => |n| try writer.print("{d}", .{n}),
        .float => |f| try writer.print("{d}", .{f}),
        .string => |s| try writer.print("\"{s}\"", .{s.data}),
        .keyword => |k| {
            try writer.writeByte(':');
            if (k.namespace) |ns| {
                try writer.print("{s}/", .{ns});
            }
            try writer.print("{s}", .{k.name});
        },
        .symbol => |s| {
            if (s.namespace) |ns| {
                try writer.print("{s}/", .{ns});
            }
            try writer.print("{s}", .{s.name});
        },
        .var_val => try writer.writeAll("<var>"),
        .fn_val => |f| try writer.print("<fn {s}>", .{if (f.name) |n| n.name else "?"}),
        .fn_proto => try writer.writeAll("<fn-proto>"),
        else => try writer.print("<{s}>", .{@tagName(val)}),
    }
}

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
