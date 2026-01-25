//! Clojure トークナイザー
//!
//! tools.reader のトークン処理を Zig で実装。
//! 処理の流れ:
//! 1. ホワイトスペースをスキップ
//! 2. 数値リテラルか判定（先頭が数字、または +/- の後に数字）
//! 3. マクロ文字をチェック
//! 4. それ以外はシンボルとして読む

const std = @import("std");
const err = @import("../error.zig");

/// トークン種別
pub const TokenKind = enum(u8) {
    // 特殊
    eof,
    invalid,

    // リテラル
    nil,
    true_lit,
    false_lit,
    integer,
    float,
    ratio,
    string,
    character,
    regex,
    symbol,
    keyword,

    // 区切り
    lparen, // (
    rparen, // )
    lbracket, // [
    rbracket, // ]
    lbrace, // {
    rbrace, // }

    // マクロ文字
    quote, // '
    deref, // @
    meta, // ^
    syntax_quote, // `
    unquote, // ~
    unquote_splicing, // ~@

    // ディスパッチ
    dispatch, // #
    discard, // #_
    var_quote, // #'
    fn_lit, // #(
    set_lit, // #{
    regex_start, // #"
    symbolic, // ##
    reader_cond, // #?
    ns_map, // #:
    meta_deprecated, // #^ (非推奨)
    unreadable, // #< (常にエラー)

    // コメント（スキップされるので通常返されない）
    comment,
};

/// トークン
pub const Token = struct {
    kind: TokenKind,
    start: u32,
    len: u16,
    line: u32, // 1-based
    column: u16, // 0-based

    /// トークンのソーステキストを取得
    pub fn text(self: Token, source: []const u8) []const u8 {
        return source[self.start..][0..self.len];
    }
};

/// トークナイザー
pub const Tokenizer = struct {
    source: []const u8,
    pos: u32 = 0,
    line: u32 = 1,
    column: u16 = 0,
    line_start: u32 = 0, // 現在行の開始位置

    /// 初期化
    pub fn init(source: []const u8) Tokenizer {
        return .{ .source = source };
    }

    /// 次のトークンを取得
    pub fn next(self: *Tokenizer) Token {
        self.skipWhitespaceAndComments();

        if (self.isEof()) {
            return self.makeToken(.eof, 0);
        }

        const start_pos = self.pos;
        const start_line = self.line;
        const start_column = self.column;
        const c = self.peek();

        // マクロ文字をチェック
        const kind: TokenKind = switch (c) {
            '(' => blk: {
                self.advance();
                break :blk .lparen;
            },
            ')' => blk: {
                self.advance();
                break :blk .rparen;
            },
            '[' => blk: {
                self.advance();
                break :blk .lbracket;
            },
            ']' => blk: {
                self.advance();
                break :blk .rbracket;
            },
            '{' => blk: {
                self.advance();
                break :blk .lbrace;
            },
            '}' => blk: {
                self.advance();
                break :blk .rbrace;
            },
            '\'' => blk: {
                self.advance();
                break :blk .quote;
            },
            '@' => blk: {
                self.advance();
                break :blk .deref;
            },
            '^' => blk: {
                self.advance();
                break :blk .meta;
            },
            '`' => blk: {
                self.advance();
                break :blk .syntax_quote;
            },
            '~' => blk: {
                self.advance();
                if (!self.isEof() and self.peek() == '@') {
                    self.advance();
                    break :blk .unquote_splicing;
                }
                break :blk .unquote;
            },
            '"' => return self.readString(start_pos, start_line, start_column),
            ':' => return self.readKeyword(start_pos, start_line, start_column),
            '#' => return self.readDispatch(start_pos, start_line, start_column),
            '\\' => return self.readCharacter(start_pos, start_line, start_column),
            '+', '-' => {
                // +/- の後に数字があれば数値、なければシンボル
                if (self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
                    return self.readNumber(start_pos, start_line, start_column);
                }
                return self.readSymbol(start_pos, start_line, start_column);
            },
            '0'...'9' => return self.readNumber(start_pos, start_line, start_column),
            else => return self.readSymbol(start_pos, start_line, start_column),
        };

        const len: u16 = @intCast(self.pos - start_pos);
        return .{
            .kind = kind,
            .start = start_pos,
            .len = len,
            .line = start_line,
            .column = start_column,
        };
    }

    // === 内部ヘルパー ===

    fn makeToken(self: *Tokenizer, kind: TokenKind, len: u16) Token {
        return .{
            .kind = kind,
            .start = self.pos,
            .len = len,
            .line = self.line,
            .column = self.column,
        };
    }

    fn isEof(self: *Tokenizer) bool {
        return self.pos >= self.source.len;
    }

    fn peek(self: *Tokenizer) u8 {
        return self.source[self.pos];
    }

    fn peekAhead(self: *Tokenizer, offset: u32) ?u8 {
        const idx = self.pos + offset;
        if (idx >= self.source.len) return null;
        return self.source[idx];
    }

    fn advance(self: *Tokenizer) void {
        if (self.pos < self.source.len) {
            if (self.source[self.pos] == '\n') {
                self.line += 1;
                self.column = 0;
                self.line_start = self.pos + 1;
            } else {
                self.column += 1;
            }
            self.pos += 1;
        }
    }

    fn skipWhitespaceAndComments(self: *Tokenizer) void {
        while (!self.isEof()) {
            const c = self.peek();
            if (isWhitespace(c)) {
                self.advance();
            } else if (c == ';') {
                // 行末までスキップ
                while (!self.isEof() and self.peek() != '\n') {
                    self.advance();
                }
            } else {
                break;
            }
        }
    }

    fn readString(self: *Tokenizer, start_pos: u32, start_line: u32, start_column: u16) Token {
        self.advance(); // 開き引用符をスキップ

        while (!self.isEof()) {
            const c = self.peek();
            if (c == '"') {
                self.advance();
                const len: u16 = @intCast(self.pos - start_pos);
                return .{
                    .kind = .string,
                    .start = start_pos,
                    .len = len,
                    .line = start_line,
                    .column = start_column,
                };
            } else if (c == '\\') {
                self.advance();
                if (!self.isEof()) {
                    self.advance(); // エスケープ文字をスキップ
                }
            } else {
                self.advance();
            }
        }

        // EOF - 閉じ引用符なし
        const len: u16 = @intCast(self.pos - start_pos);
        return .{
            .kind = .invalid,
            .start = start_pos,
            .len = len,
            .line = start_line,
            .column = start_column,
        };
    }

    fn readKeyword(self: *Tokenizer, start_pos: u32, start_line: u32, start_column: u16) Token {
        self.advance(); // : をスキップ

        // :: の場合（自動解決キーワード）
        if (!self.isEof() and self.peek() == ':') {
            self.advance();
        }

        // キーワード名を読む
        while (!self.isEof() and isSymbolChar(self.peek())) {
            self.advance();
        }

        const len: u16 = @intCast(self.pos - start_pos);
        if (len <= 1 or (len == 2 and self.source[start_pos + 1] == ':')) {
            // : のみ、または :: のみは無効
            return .{
                .kind = .invalid,
                .start = start_pos,
                .len = len,
                .line = start_line,
                .column = start_column,
            };
        }

        return .{
            .kind = .keyword,
            .start = start_pos,
            .len = len,
            .line = start_line,
            .column = start_column,
        };
    }

    fn readDispatch(self: *Tokenizer, start_pos: u32, start_line: u32, start_column: u16) Token {
        self.advance(); // # をスキップ

        if (self.isEof()) {
            return .{
                .kind = .invalid,
                .start = start_pos,
                .len = 1,
                .line = start_line,
                .column = start_column,
            };
        }

        const c = self.peek();
        const kind: TokenKind = switch (c) {
            '_' => blk: {
                self.advance();
                break :blk .discard;
            },
            '\'' => blk: {
                self.advance();
                break :blk .var_quote;
            },
            '(' => blk: {
                self.advance();
                break :blk .fn_lit;
            },
            '{' => blk: {
                self.advance();
                break :blk .set_lit;
            },
            '"' => blk: {
                // 正規表現リテラル開始（中身は別途読む）
                break :blk .regex_start;
            },
            '#' => blk: {
                self.advance();
                break :blk .symbolic;
            },
            '?' => blk: {
                self.advance();
                break :blk .reader_cond;
            },
            ':' => blk: {
                self.advance();
                break :blk .ns_map;
            },
            '^' => blk: {
                // #^ 非推奨メタデータ構文
                self.advance();
                break :blk .meta_deprecated;
            },
            '<' => blk: {
                // #< 読み込み不可（常にエラー）
                self.advance();
                break :blk .unreadable;
            },
            '!' => blk: {
                // シェバン/コメント - 行末まで
                while (!self.isEof() and self.peek() != '\n') {
                    self.advance();
                }
                break :blk .comment;
            },
            else => .dispatch,
        };

        const len: u16 = @intCast(self.pos - start_pos);
        return .{
            .kind = kind,
            .start = start_pos,
            .len = len,
            .line = start_line,
            .column = start_column,
        };
    }

    fn readCharacter(self: *Tokenizer, start_pos: u32, start_line: u32, start_column: u16) Token {
        self.advance(); // \ をスキップ

        if (self.isEof()) {
            return .{
                .kind = .invalid,
                .start = start_pos,
                .len = 1,
                .line = start_line,
                .column = start_column,
            };
        }

        // 名前付き文字リテラル（newline, space 等）か単一文字
        while (!self.isEof() and !isTerminator(self.peek())) {
            self.advance();
        }

        const len: u16 = @intCast(self.pos - start_pos);
        return .{
            .kind = .character,
            .start = start_pos,
            .len = len,
            .line = start_line,
            .column = start_column,
        };
    }

    fn readNumber(self: *Tokenizer, start_pos: u32, start_line: u32, start_column: u16) Token {
        // 符号
        if (!self.isEof() and (self.peek() == '+' or self.peek() == '-')) {
            self.advance();
        }

        var has_dot = false;
        var has_exp = false;
        var has_ratio = false;

        // 0x などのプレフィックス
        if (!self.isEof() and self.peek() == '0') {
            self.advance();
            if (!self.isEof()) {
                const next_char = self.peek();
                if (next_char == 'x' or next_char == 'X') {
                    // 16進数
                    self.advance();
                    while (!self.isEof() and isHexDigit(self.peek())) {
                        self.advance();
                    }
                    // N サフィックス
                    if (!self.isEof() and self.peek() == 'N') {
                        self.advance();
                    }
                    const len: u16 = @intCast(self.pos - start_pos);
                    return .{
                        .kind = .integer,
                        .start = start_pos,
                        .len = len,
                        .line = start_line,
                        .column = start_column,
                    };
                }
            }
        }

        // 整数部（基数プレフィックスの可能性あり: 2r, 8r, 16r, 36r 等）
        while (!self.isEof() and isDigit(self.peek())) {
            self.advance();
        }

        // 基数 (radix): NNrXXX or NNRxxx (例: 2r101, 16rFF, 36rZZ)
        if (!self.isEof() and (self.peek() == 'r' or self.peek() == 'R')) {
            self.advance();
            // 基数の数字部分（0-9, a-z, A-Z）
            while (!self.isEof() and isRadixDigit(self.peek())) {
                self.advance();
            }
            // N サフィックス
            if (!self.isEof() and self.peek() == 'N') {
                self.advance();
            }
            const len: u16 = @intCast(self.pos - start_pos);
            return .{
                .kind = .integer,
                .start = start_pos,
                .len = len,
                .line = start_line,
                .column = start_column,
            };
        }

        // 有理数 (/)
        if (!self.isEof() and self.peek() == '/') {
            const next_pos = self.pos + 1;
            if (next_pos < self.source.len and isDigit(self.source[next_pos])) {
                has_ratio = true;
                self.advance(); // /
                while (!self.isEof() and isDigit(self.peek())) {
                    self.advance();
                }
            }
        }

        // 小数部
        if (!has_ratio and !self.isEof() and self.peek() == '.') {
            const next_pos = self.pos + 1;
            if (next_pos < self.source.len and isDigit(self.source[next_pos])) {
                has_dot = true;
                self.advance(); // .
                while (!self.isEof() and isDigit(self.peek())) {
                    self.advance();
                }
            }
        }

        // 指数部
        if (!has_ratio and !self.isEof()) {
            const c = self.peek();
            if (c == 'e' or c == 'E') {
                has_exp = true;
                self.advance();
                if (!self.isEof() and (self.peek() == '+' or self.peek() == '-')) {
                    self.advance();
                }
                while (!self.isEof() and isDigit(self.peek())) {
                    self.advance();
                }
            }
        }

        // サフィックス (N, M)
        if (!self.isEof()) {
            const c = self.peek();
            if (c == 'N' or c == 'M') {
                self.advance();
            }
        }

        const len: u16 = @intCast(self.pos - start_pos);
        const kind: TokenKind = if (has_ratio) .ratio else if (has_dot or has_exp) .float else .integer;

        return .{
            .kind = kind,
            .start = start_pos,
            .len = len,
            .line = start_line,
            .column = start_column,
        };
    }

    fn readSymbol(self: *Tokenizer, start_pos: u32, start_line: u32, start_column: u16) Token {
        while (!self.isEof() and isSymbolChar(self.peek())) {
            self.advance();
        }

        const len: u16 = @intCast(self.pos - start_pos);
        const text = self.source[start_pos..][0..len];

        // 特殊シンボル
        const kind: TokenKind = if (std.mem.eql(u8, text, "nil"))
            .nil
        else if (std.mem.eql(u8, text, "true"))
            .true_lit
        else if (std.mem.eql(u8, text, "false"))
            .false_lit
        else
            .symbol;

        return .{
            .kind = kind,
            .start = start_pos,
            .len = len,
            .line = start_line,
            .column = start_column,
        };
    }
};

// === ヘルパー関数 ===

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0C' or c == ',';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isRadixDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isTerminator(c: u8) bool {
    return isWhitespace(c) or c == '"' or c == ';' or c == '@' or c == '^' or
        c == '`' or c == '~' or c == '(' or c == ')' or c == '[' or c == ']' or
        c == '{' or c == '}' or c == '\\';
}

fn isSymbolChar(c: u8) bool {
    return !isWhitespace(c) and !isTerminator(c) and c != '#' and c != '\'' and c != ':';
}

// === テスト ===

test "空文字列" {
    var t = Tokenizer.init("");
    const tok = t.next();
    try std.testing.expectEqual(TokenKind.eof, tok.kind);
}

test "ホワイトスペースのみ" {
    var t = Tokenizer.init("  \t\n  ");
    const tok = t.next();
    try std.testing.expectEqual(TokenKind.eof, tok.kind);
}

test "コメント" {
    var t = Tokenizer.init("; this is a comment\n42");
    const tok = t.next();
    try std.testing.expectEqual(TokenKind.integer, tok.kind);
    try std.testing.expectEqualStrings("42", tok.text(t.source));
}

test "区切り文字" {
    var t = Tokenizer.init("()[]{}");
    try std.testing.expectEqual(TokenKind.lparen, t.next().kind);
    try std.testing.expectEqual(TokenKind.rparen, t.next().kind);
    try std.testing.expectEqual(TokenKind.lbracket, t.next().kind);
    try std.testing.expectEqual(TokenKind.rbracket, t.next().kind);
    try std.testing.expectEqual(TokenKind.lbrace, t.next().kind);
    try std.testing.expectEqual(TokenKind.rbrace, t.next().kind);
    try std.testing.expectEqual(TokenKind.eof, t.next().kind);
}

test "整数" {
    var t = Tokenizer.init("42 -17 +5 0 0x2A");
    try std.testing.expectEqual(TokenKind.integer, t.next().kind);
    try std.testing.expectEqual(TokenKind.integer, t.next().kind);
    try std.testing.expectEqual(TokenKind.integer, t.next().kind);
    try std.testing.expectEqual(TokenKind.integer, t.next().kind);
    try std.testing.expectEqual(TokenKind.integer, t.next().kind);
}

test "基数 (radix)" {
    var t = Tokenizer.init("2r101010 8r52 16r2A 36rZZ");

    const tok1 = t.next();
    try std.testing.expectEqual(TokenKind.integer, tok1.kind);
    try std.testing.expectEqualStrings("2r101010", tok1.text(t.source));

    const tok2 = t.next();
    try std.testing.expectEqual(TokenKind.integer, tok2.kind);
    try std.testing.expectEqualStrings("8r52", tok2.text(t.source));

    const tok3 = t.next();
    try std.testing.expectEqual(TokenKind.integer, tok3.kind);
    try std.testing.expectEqualStrings("16r2A", tok3.text(t.source));

    const tok4 = t.next();
    try std.testing.expectEqual(TokenKind.integer, tok4.kind);
    try std.testing.expectEqualStrings("36rZZ", tok4.text(t.source));
}

test "浮動小数点" {
    var t = Tokenizer.init("3.14 1e10 2.5e-3");
    try std.testing.expectEqual(TokenKind.float, t.next().kind);
    try std.testing.expectEqual(TokenKind.float, t.next().kind);
    try std.testing.expectEqual(TokenKind.float, t.next().kind);
}

test "有理数" {
    var t = Tokenizer.init("22/7 1/2");
    try std.testing.expectEqual(TokenKind.ratio, t.next().kind);
    try std.testing.expectEqual(TokenKind.ratio, t.next().kind);
}

test "文字列" {
    var t = Tokenizer.init("\"hello\" \"with\\\"escape\"");
    const tok1 = t.next();
    try std.testing.expectEqual(TokenKind.string, tok1.kind);
    try std.testing.expectEqualStrings("\"hello\"", tok1.text(t.source));

    const tok2 = t.next();
    try std.testing.expectEqual(TokenKind.string, tok2.kind);
}

test "シンボル" {
    var t = Tokenizer.init("foo bar+ my-symbol clojure.core/map");
    try std.testing.expectEqual(TokenKind.symbol, t.next().kind);
    try std.testing.expectEqual(TokenKind.symbol, t.next().kind);
    try std.testing.expectEqual(TokenKind.symbol, t.next().kind);
    try std.testing.expectEqual(TokenKind.symbol, t.next().kind);
}

test "特殊シンボル" {
    var t = Tokenizer.init("nil true false");
    try std.testing.expectEqual(TokenKind.nil, t.next().kind);
    try std.testing.expectEqual(TokenKind.true_lit, t.next().kind);
    try std.testing.expectEqual(TokenKind.false_lit, t.next().kind);
}

test "+/- シンボル" {
    var t = Tokenizer.init("+ - -> ->> +-");
    try std.testing.expectEqual(TokenKind.symbol, t.next().kind);
    try std.testing.expectEqual(TokenKind.symbol, t.next().kind);
    try std.testing.expectEqual(TokenKind.symbol, t.next().kind);
    try std.testing.expectEqual(TokenKind.symbol, t.next().kind);
    try std.testing.expectEqual(TokenKind.symbol, t.next().kind);
}

test "キーワード" {
    var t = Tokenizer.init(":foo :ns/name ::auto");

    const tok1 = t.next();
    try std.testing.expectEqual(TokenKind.keyword, tok1.kind);
    try std.testing.expectEqualStrings(":foo", tok1.text(t.source));

    const tok2 = t.next();
    try std.testing.expectEqual(TokenKind.keyword, tok2.kind);
    try std.testing.expectEqualStrings(":ns/name", tok2.text(t.source));

    const tok3 = t.next();
    try std.testing.expectEqual(TokenKind.keyword, tok3.kind);
    try std.testing.expectEqualStrings("::auto", tok3.text(t.source));
}

test "マクロ文字" {
    var t = Tokenizer.init("'x @x ^x `x ~x ~@x");
    try std.testing.expectEqual(TokenKind.quote, t.next().kind);
    try std.testing.expectEqual(TokenKind.symbol, t.next().kind);
    try std.testing.expectEqual(TokenKind.deref, t.next().kind);
    try std.testing.expectEqual(TokenKind.symbol, t.next().kind);
    try std.testing.expectEqual(TokenKind.meta, t.next().kind);
    try std.testing.expectEqual(TokenKind.symbol, t.next().kind);
    try std.testing.expectEqual(TokenKind.syntax_quote, t.next().kind);
    try std.testing.expectEqual(TokenKind.symbol, t.next().kind);
    try std.testing.expectEqual(TokenKind.unquote, t.next().kind);
    try std.testing.expectEqual(TokenKind.symbol, t.next().kind);
    try std.testing.expectEqual(TokenKind.unquote_splicing, t.next().kind);
    try std.testing.expectEqual(TokenKind.symbol, t.next().kind);
}

test "ディスパッチ" {
    var t = Tokenizer.init("#_ #' #( #{ ## #? #: #^ #<");
    try std.testing.expectEqual(TokenKind.discard, t.next().kind);
    try std.testing.expectEqual(TokenKind.var_quote, t.next().kind);
    try std.testing.expectEqual(TokenKind.fn_lit, t.next().kind);
    try std.testing.expectEqual(TokenKind.set_lit, t.next().kind);
    try std.testing.expectEqual(TokenKind.symbolic, t.next().kind);
    try std.testing.expectEqual(TokenKind.reader_cond, t.next().kind);
    try std.testing.expectEqual(TokenKind.ns_map, t.next().kind);
    try std.testing.expectEqual(TokenKind.meta_deprecated, t.next().kind);
    try std.testing.expectEqual(TokenKind.unreadable, t.next().kind);
}

test "文字リテラル" {
    var t = Tokenizer.init("\\a \\newline \\u0041");

    const tok1 = t.next();
    try std.testing.expectEqual(TokenKind.character, tok1.kind);
    try std.testing.expectEqualStrings("\\a", tok1.text(t.source));

    const tok2 = t.next();
    try std.testing.expectEqual(TokenKind.character, tok2.kind);
    try std.testing.expectEqualStrings("\\newline", tok2.text(t.source));

    const tok3 = t.next();
    try std.testing.expectEqual(TokenKind.character, tok3.kind);
    try std.testing.expectEqualStrings("\\u0041", tok3.text(t.source));
}

test "行番号トラッキング" {
    var t = Tokenizer.init("foo\nbar\nbaz");

    const tok1 = t.next();
    try std.testing.expectEqual(@as(u32, 1), tok1.line);

    const tok2 = t.next();
    try std.testing.expectEqual(@as(u32, 2), tok2.line);

    const tok3 = t.next();
    try std.testing.expectEqual(@as(u32, 3), tok3.line);
}
