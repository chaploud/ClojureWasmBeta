//! エラー型定義
//!
//! sci/babashka のエラー処理パターンを参考に設計。
//! 詳細は docs/reference/error_design.md を参照。

const std = @import("std");

/// エラーが発生したフェーズ
pub const Phase = enum {
    parse, // Reader/パーサー段階
    analysis, // 解析/コンパイル段階
    macroexpand, // マクロ展開段階
    eval, // 実行時
};

/// エラー種別
pub const Kind = enum {
    // Parse phase
    unexpected_eof,
    invalid_token,
    unmatched_delimiter,
    invalid_number,
    invalid_character,
    invalid_string,
    invalid_regex,
    invalid_keyword,

    // Analysis phase
    undefined_symbol,
    invalid_arity,
    invalid_binding,
    duplicate_key,

    // Macroexpand phase
    macro_error,

    // Eval phase
    division_by_zero,
    index_out_of_bounds,
    type_error,
    assertion_error,

    // General
    internal_error,
    out_of_memory,
};

/// ソースコード上の位置
pub const SourceLocation = struct {
    file: ?[]const u8 = null, // null = unknown
    line: u32 = 0, // 1-based, 0 = unknown
    column: u32 = 0, // 0-based

    pub const unknown: SourceLocation = .{};

    /// "file:line:column" 形式でフォーマット
    pub fn format(
        self: SourceLocation,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const file = self.file orelse "NO_SOURCE_PATH";
        if (self.line > 0) {
            try writer.print("{s}:{d}:{d}", .{ file, self.line, self.column });
        } else {
            try writer.writeAll(file);
        }
    }
};

/// スタックフレーム（評価時のコールスタック用）
pub const StackFrame = struct {
    name: []const u8, // 関数名
    ns: ?[]const u8 = null, // 名前空間
    location: SourceLocation = .{},
    is_builtin: bool = false,
};

/// エラー詳細情報
pub const Info = struct {
    kind: Kind,
    phase: Phase,
    message: []const u8,
    location: SourceLocation = .{},

    // スタックトレース（評価時のみ、初期実装では未使用）
    callstack: ?[]const StackFrame = null,

    // 原因となったエラー（ラップ時、初期実装では未使用）
    cause: ?*const Info = null,

    /// エラーメッセージをフォーマット
    pub fn format(
        self: Info,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{s}: {s}", .{ @tagName(self.kind), self.message });
        if (self.location.line > 0) {
            try writer.writeAll(" at ");
            try self.location.format("", .{}, writer);
        }
    }
};

/// Zig エラー型（error union で使用）
pub const Error = error{
    // Parse
    UnexpectedEof,
    InvalidToken,
    UnmatchedDelimiter,
    InvalidNumber,
    InvalidCharacter,
    InvalidString,
    InvalidKeyword,

    // Analysis
    UndefinedSymbol,
    InvalidArity,
    InvalidBinding,

    // Eval
    DivisionByZero,
    IndexOutOfBounds,
    TypeError,

    // 例外（ユーザー throw）
    UserException,

    // Memory
    OutOfMemory,
};

/// スレッドローカルなエラー詳細格納用
/// Zig の error は情報を持てないため、詳細はここに格納
pub threadlocal var last_error: ?Info = null;

/// ユーザー throw で投げられた値（anyopaque でレイヤリング維持）
/// evaluator/vm 側で Value* にキャストして使用
pub threadlocal var thrown_value: ?*anyopaque = null;

/// ユーザー例外を設定し UserException エラーを返す
pub fn throwValue(val_ptr: *anyopaque) Error {
    thrown_value = val_ptr;
    return error.UserException;
}

/// ユーザー例外の値を取得してクリア
pub fn getThrownValue() ?*anyopaque {
    const val = thrown_value;
    thrown_value = null;
    return val;
}

/// エラー詳細を設定し、対応する Zig error を返す
pub fn setError(info: Info) Error {
    last_error = info;
    return kindToError(info.kind);
}

/// Kind から Zig Error へ変換
fn kindToError(kind: Kind) Error {
    return switch (kind) {
        .unexpected_eof => error.UnexpectedEof,
        .invalid_token => error.InvalidToken,
        .unmatched_delimiter => error.UnmatchedDelimiter,
        .invalid_number => error.InvalidNumber,
        .invalid_character => error.InvalidCharacter,
        .invalid_string => error.InvalidString,
        .invalid_regex => error.InvalidToken, // regex は token として扱う
        .invalid_keyword => error.InvalidKeyword,
        .undefined_symbol => error.UndefinedSymbol,
        .invalid_arity => error.InvalidArity,
        .invalid_binding => error.InvalidBinding,
        .duplicate_key => error.InvalidBinding,
        .macro_error => error.TypeError,
        .division_by_zero => error.DivisionByZero,
        .index_out_of_bounds => error.IndexOutOfBounds,
        .type_error => error.TypeError,
        .assertion_error => error.TypeError,
        .internal_error => error.TypeError,
        .out_of_memory => error.OutOfMemory,
    };
}

/// 直前のエラー詳細を取得してクリア
pub fn getLastError() ?Info {
    const err = last_error;
    last_error = null;
    return err;
}

// === ヘルパー関数 ===

/// Parse エラーを簡易作成
pub fn parseError(kind: Kind, message: []const u8, location: SourceLocation) Error {
    return setError(.{
        .kind = kind,
        .phase = .parse,
        .message = message,
        .location = location,
    });
}

/// フォーマット付き Parse エラー
pub fn parseErrorFmt(kind: Kind, comptime fmt: []const u8, args: anytype) Error {
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "error message too long";
    return setError(.{
        .kind = kind,
        .phase = .parse,
        .message = msg,
    });
}

/// フォーマット付きメッセージ設定（Zig error は呼び出し元で返す）
pub fn setEvalErrorFmt(kind: Kind, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "error message too long";
    last_error = .{
        .kind = kind,
        .phase = .eval,
        .message = msg,
    };
}

/// Eval エラーを簡易作成
pub fn evalError(kind: Kind, message: []const u8) Error {
    return setError(.{
        .kind = kind,
        .phase = .eval,
        .message = message,
    });
}

/// 動的メッセージ用の threadlocal バッファ
threadlocal var msg_buf: [512]u8 = undefined;

/// フォーマット付き Eval エラー
pub fn evalErrorFmt(kind: Kind, comptime fmt: []const u8, args: anytype) Error {
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "error message too long";
    return setError(.{
        .kind = kind,
        .phase = .eval,
        .message = msg,
    });
}

/// フォーマット付き Parse エラー（ソース位置付き）
pub fn parseErrorFmtLoc(kind: Kind, location: SourceLocation, comptime fmt: []const u8, args: anytype) Error {
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "error message too long";
    return setError(.{
        .kind = kind,
        .phase = .parse,
        .message = msg,
        .location = location,
    });
}

/// ArityError メッセージを設定（Zig error は呼び出し元で返す）
pub fn setArityError(got: usize, name: []const u8) void {
    const msg = std.fmt.bufPrint(&msg_buf, "Wrong number of args ({d}) passed to: {s}", .{ got, name }) catch "arity error";
    last_error = .{
        .kind = .invalid_arity,
        .phase = .eval,
        .message = msg,
    };
}

/// TypeError メッセージを設定（Zig error は呼び出し元で返す）
pub fn setTypeError(expected: []const u8, got: []const u8) void {
    const msg = std.fmt.bufPrint(&msg_buf, "Expected {s}, got {s}", .{ expected, got }) catch "type error";
    last_error = .{
        .kind = .type_error,
        .phase = .eval,
        .message = msg,
    };
}

/// DivisionByZero メッセージを設定
pub fn setDivisionByZero() void {
    last_error = .{
        .kind = .division_by_zero,
        .phase = .eval,
        .message = "Divide by zero",
    };
}

/// last_error にソース位置を追加設定（既にメッセージ設定済みの場合に使用）
/// Node.stack の情報を error.Info.location に伝播する
pub fn setErrorLocation(location: SourceLocation) void {
    if (last_error) |*info| {
        if (info.location.line == 0) {
            info.location = location;
        }
    }
}

// === テスト ===

test "SourceLocation format" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    const loc = SourceLocation{ .file = "test.clj", .line = 42, .column = 10 };
    try loc.format("", .{}, writer);

    try std.testing.expectEqualStrings("test.clj:42:10", stream.getWritten());
}

test "setError と getLastError" {
    const err = parseError(.invalid_number, "Invalid number: 123abc", .{ .line = 5, .column = 3 });
    try std.testing.expectEqual(error.InvalidNumber, err);

    const info = getLastError();
    try std.testing.expect(info != null);
    try std.testing.expectEqual(Kind.invalid_number, info.?.kind);
    try std.testing.expectEqual(Phase.parse, info.?.phase);

    // 2回目は null
    try std.testing.expect(getLastError() == null);
}

test "Info format" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    const info = Info{
        .kind = .unexpected_eof,
        .phase = .parse,
        .message = "EOF while reading string",
        .location = .{ .file = "test.clj", .line = 10, .column = 5 },
    };
    try info.format("", .{}, writer);

    try std.testing.expectEqualStrings(
        "unexpected_eof: EOF while reading string at test.clj:10:5",
        stream.getWritten(),
    );
}
