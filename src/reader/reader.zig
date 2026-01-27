//! Clojure Reader
//!
//! Tokenizer のトークン列を Form（構文木）に変換する。
//! tools.reader の処理フローを Zig で実装。
//!
//! 処理の流れ:
//! 1. Tokenizer からトークンを取得
//! 2. リテラル（数値、文字列、シンボル等）を Form に変換
//! 3. コレクション（リスト、ベクター、マップ）を再帰的に構築
//! 4. マクロ文字（quote, deref 等）を展開

const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("tokenizer.zig").Token;
const TokenKind = @import("tokenizer.zig").TokenKind;
const Form = @import("form.zig").Form;
const Symbol = @import("form.zig").Symbol;
const err = @import("../base/error.zig");

/// Reader
/// Tokenizer から Form を構築する
pub const Reader = struct {
    tokenizer: Tokenizer,
    source: []const u8,
    allocator: std.mem.Allocator,

    /// 先読みトークン（peek用）
    peeked: ?Token = null,

    /// 初期化
    pub fn init(allocator: std.mem.Allocator, source: []const u8) Reader {
        return .{
            .tokenizer = Tokenizer.init(source),
            .source = source,
            .allocator = allocator,
        };
    }

    /// 次の Form を読み取る
    /// EOF の場合は null を返す
    pub fn read(self: *Reader) err.Error!?Form {
        const token = self.nextToken();

        if (token.kind == .eof) {
            return null;
        }

        const form = try self.readForm(token);
        return form;
    }

    /// 全てのフォームを読み取る
    pub fn readAll(self: *Reader) err.Error![]Form {
        var forms: std.ArrayListUnmanaged(Form) = .empty;
        errdefer forms.deinit(self.allocator);

        while (true) {
            const form = try self.read();
            if (form) |f| {
                forms.append(self.allocator, f) catch return error.OutOfMemory;
            } else {
                break;
            }
        }

        return forms.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    // === 内部実装 ===

    /// トークンを Form に変換
    fn readForm(self: *Reader, token: Token) err.Error!Form {
        return switch (token.kind) {
            // リテラル
            .nil => .nil,
            .true_lit => .bool_true,
            .false_lit => .bool_false,
            .integer => self.readInteger(token),
            .float => self.readFloat(token),
            .ratio => self.readRatio(token),
            .string => self.readString(token),
            .regex => self.readRegex(token),
            .symbol => self.readSymbol(token),
            .keyword => self.readKeyword(token),

            // コレクション
            .lparen => self.readList(),
            .lbracket => self.readVector(),
            .lbrace => self.readMap(),

            // マクロ文字
            .quote => self.readWrapped("quote"),
            .deref => self.readWrapped("deref"),
            .syntax_quote => self.readWrapped("syntax-quote"),
            .unquote => self.readWrapped("unquote"),
            .unquote_splicing => self.readWrapped("unquote-splicing"),

            // ディスパッチ
            .discard => self.readDiscard(),
            .set_lit => self.readSet(),
            .fn_lit => self.readFnLit(),
            .var_quote => self.readWrapped("var"),
            .symbolic => self.readSymbolic(),

            // 閉じ括弧は直接呼ばれるとエラー
            .rparen, .rbracket, .rbrace => self.unmatchedDelimiterError(token),

            // 未対応・無効
            .eof => unreachable, // 呼び出し前にチェック済み
            .invalid => self.invalidTokenError(token),
            .comment => unreachable, // Tokenizer がスキップ
            else => self.unsupportedTokenError(token),
        };
    }

    /// 整数リテラル
    fn readInteger(self: *Reader, token: Token) err.Error!Form {
        const text = token.text(self.source);
        const value = self.parseInteger(text) catch |e| {
            return self.numberParseError(token, e);
        };
        return Form{ .int = value };
    }

    /// 整数パース（基数、16進数対応）
    fn parseInteger(self: *Reader, text: []const u8) !i64 {
        _ = self;

        var s = text;
        var negative = false;

        // 符号
        if (s.len > 0 and s[0] == '-') {
            negative = true;
            s = s[1..];
        } else if (s.len > 0 and s[0] == '+') {
            s = s[1..];
        }

        // N サフィックス除去（BigInt用、現時点ではi64に収める）
        if (s.len > 0 and s[s.len - 1] == 'N') {
            s = s[0 .. s.len - 1];
        }

        // 16進数 0x
        if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
            const val = std.fmt.parseInt(i64, s[2..], 16) catch return error.InvalidNumber;
            return if (negative) -val else val;
        }

        // 基数 NNrXXX (2r101, 16rFF, 36rZZ)
        if (std.mem.indexOfScalar(u8, s, 'r')) |idx| {
            const radix_str = s[0..idx];
            const digits = s[idx + 1 ..];
            const radix = std.fmt.parseInt(u8, radix_str, 10) catch return error.InvalidNumber;
            if (radix < 2 or radix > 36) return error.InvalidNumber;
            const val = std.fmt.parseInt(i64, digits, radix) catch return error.InvalidNumber;
            return if (negative) -val else val;
        }
        if (std.mem.indexOfScalar(u8, s, 'R')) |idx| {
            const radix_str = s[0..idx];
            const digits = s[idx + 1 ..];
            const radix = std.fmt.parseInt(u8, radix_str, 10) catch return error.InvalidNumber;
            if (radix < 2 or radix > 36) return error.InvalidNumber;
            const val = std.fmt.parseInt(i64, digits, radix) catch return error.InvalidNumber;
            return if (negative) -val else val;
        }

        // 8進数 0NNN（先頭0、ただし0単体は10進数）
        if (s.len > 1 and s[0] == '0' and s[1] >= '0' and s[1] <= '7') {
            const val = std.fmt.parseInt(i64, s, 8) catch return error.InvalidNumber;
            return if (negative) -val else val;
        }

        // 10進数
        const val = std.fmt.parseInt(i64, s, 10) catch return error.InvalidNumber;
        return if (negative) -val else val;
    }

    /// 浮動小数点リテラル
    fn readFloat(self: *Reader, token: Token) err.Error!Form {
        const text = token.text(self.source);
        var s = text;

        // M サフィックス除去（BigDecimal用）
        if (s.len > 0 and s[s.len - 1] == 'M') {
            s = s[0 .. s.len - 1];
        }

        const value = std.fmt.parseFloat(f64, s) catch {
            return self.numberParseError(token, error.InvalidNumber);
        };
        return Form{ .float = value };
    }

    /// 有理数リテラル（現時点では浮動小数点で近似）
    fn readRatio(self: *Reader, token: Token) err.Error!Form {
        const text = token.text(self.source);

        // TODO: 有理数型を実装したらそちらを使う
        // 現時点では分子/分母をパースして浮動小数点で近似
        const slash_idx = std.mem.indexOfScalar(u8, text, '/') orelse {
            return self.numberParseError(token, error.InvalidNumber);
        };

        const num_str = text[0..slash_idx];
        const den_str = text[slash_idx + 1 ..];

        const numerator = std.fmt.parseInt(i64, num_str, 10) catch {
            return self.numberParseError(token, error.InvalidNumber);
        };
        const denominator = std.fmt.parseInt(i64, den_str, 10) catch {
            return self.numberParseError(token, error.InvalidNumber);
        };

        if (denominator == 0) {
            return err.parseError(.division_by_zero, "Division by zero in ratio", self.tokenLocation(token));
        }

        const value: f64 = @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator));
        return Form{ .float = value };
    }

    /// 文字列リテラル
    fn readString(self: *Reader, token: Token) err.Error!Form {
        const text = token.text(self.source);

        // 引用符を除去
        if (text.len < 2) {
            return err.parseError(.invalid_string, "Invalid string literal", self.tokenLocation(token));
        }

        const content = text[1 .. text.len - 1];

        // エスケープ処理
        const unescaped = self.unescapeString(content) catch {
            return err.parseError(.invalid_string, "Invalid escape sequence", self.tokenLocation(token));
        };

        return Form{ .string = unescaped };
    }

    /// 文字列のエスケープ解除
    fn unescapeString(self: *Reader, s: []const u8) ![]const u8 {
        // エスケープがなければそのまま返す
        if (std.mem.indexOfScalar(u8, s, '\\') == null) {
            return s;
        }

        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '\\' and i + 1 < s.len) {
                const c = s[i + 1];
                switch (c) {
                    'n' => result.append(self.allocator, '\n') catch return error.OutOfMemory,
                    't' => result.append(self.allocator, '\t') catch return error.OutOfMemory,
                    'r' => result.append(self.allocator, '\r') catch return error.OutOfMemory,
                    '\\' => result.append(self.allocator, '\\') catch return error.OutOfMemory,
                    '"' => result.append(self.allocator, '"') catch return error.OutOfMemory,
                    'u' => {
                        // Unicode エスケープ \uXXXX
                        if (i + 5 < s.len) {
                            const hex = s[i + 2 .. i + 6];
                            const codepoint = std.fmt.parseInt(u21, hex, 16) catch return error.InvalidString;
                            var buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidString;
                            result.appendSlice(self.allocator, buf[0..len]) catch return error.OutOfMemory;
                            i += 6;
                            continue;
                        }
                        return error.InvalidString;
                    },
                    else => {
                        // 不明なエスケープはそのまま
                        result.append(self.allocator, '\\') catch return error.OutOfMemory;
                        result.append(self.allocator, c) catch return error.OutOfMemory;
                    },
                }
                i += 2;
            } else {
                result.append(self.allocator, s[i]) catch return error.OutOfMemory;
                i += 1;
            }
        }

        return result.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    /// 正規表現リテラル #"pattern"
    fn readRegex(self: *Reader, token: Token) err.Error!Form {
        const text = token.text(self.source);
        // #"..." — 先頭 #" と末尾 " を除去
        if (text.len < 3) {
            return err.parseError(.invalid_token, "Invalid regex literal", self.tokenLocation(token));
        }
        const pattern = text[2 .. text.len - 1];
        return Form{ .regex = pattern };
    }

    /// シンボル
    fn readSymbol(self: *Reader, token: Token) Form {
        const text = token.text(self.source);
        return Form{ .symbol = self.parseSymbol(text) };
    }

    /// キーワード
    fn readKeyword(self: *Reader, token: Token) Form {
        var text = token.text(self.source);

        // 先頭の : を除去
        if (text.len > 0 and text[0] == ':') {
            text = text[1..];
        }
        // :: の場合（自動解決、現時点では : として扱う）
        if (text.len > 0 and text[0] == ':') {
            text = text[1..];
        }

        return Form{ .keyword = self.parseSymbol(text) };
    }

    /// シンボル文字列をパース（名前空間/名前 分割）
    fn parseSymbol(self: *Reader, text: []const u8) Symbol {
        _ = self;
        if (std.mem.indexOfScalar(u8, text, '/')) |idx| {
            // 特殊ケース: "/" 単体はシンボル
            if (idx == 0 and text.len == 1) {
                return Symbol.init(text);
            }
            const ns = text[0..idx];
            const name = text[idx + 1 ..];
            return Symbol.initNs(ns, name);
        }
        return Symbol.init(text);
    }

    /// リスト ()
    fn readList(self: *Reader) err.Error!Form {
        const items = try self.readDelimited(.rparen);
        return Form{ .list = items };
    }

    /// ベクター []
    fn readVector(self: *Reader) err.Error!Form {
        const items = try self.readDelimited(.rbracket);
        return Form{ .vector = items };
    }

    /// マップ {}
    fn readMap(self: *Reader) err.Error!Form {
        const items = try self.readDelimited(.rbrace);
        // マップは偶数個の要素が必要 [k1, v1, k2, v2, ...]
        if (items.len % 2 != 0) {
            return err.parseError(.invalid_token, "map literal must have even number of forms", .{});
        }
        return Form{ .map = items };
    }

    /// セット #{}
    fn readSet(self: *Reader) err.Error!Form {
        const items = try self.readDelimited(.rbrace);
        return Form{ .set = items };
    }

    /// 閉じ括弧までの要素を読み取る
    fn readDelimited(self: *Reader, closing: TokenKind) err.Error![]Form {
        var items: std.ArrayListUnmanaged(Form) = .empty;
        errdefer items.deinit(self.allocator);

        while (true) {
            const token = self.nextToken();

            if (token.kind == .eof) {
                return err.parseError(.unexpected_eof, "EOF while reading collection", self.tokenLocation(token));
            }

            if (token.kind == closing) {
                break;
            }

            const form = try self.readForm(token);
            items.append(self.allocator, form) catch return error.OutOfMemory;
        }

        return items.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    /// ラップ構文 (quote x), (deref x) 等
    fn readWrapped(self: *Reader, wrapper_name: []const u8) err.Error!Form {
        const next = self.nextToken();
        if (next.kind == .eof) {
            return err.parseError(.unexpected_eof, "EOF after reader macro", .{});
        }

        const inner = try self.readForm(next);

        // (wrapper inner) 形式のリストを作成
        const items = try self.allocator.alloc(Form, 2);
        items[0] = Form{ .symbol = Symbol.init(wrapper_name) };
        items[1] = inner;

        return Form{ .list = items };
    }

    /// #_ (discard)
    fn readDiscard(self: *Reader) err.Error!Form {
        // 次のフォームを読んで捨てる
        const next = self.nextToken();
        if (next.kind == .eof) {
            return err.parseError(.unexpected_eof, "EOF after #_", .{});
        }
        _ = try self.readForm(next);

        // 次のフォームを読み取る
        const maybeForm = try self.read();
        return maybeForm orelse .nil;
    }

    /// #() 無名関数リテラル
    fn readFnLit(self: *Reader) err.Error!Form {
        // #(body) → (fn* [args...] body) への変換は Analyzer で行う
        // Reader では #(...) を特別な形式で保存
        const body = try self.readDelimited(.rparen);

        // (fn* [] body) 形式で返す（引数解析は後で）
        const items = try self.allocator.alloc(Form, 3);
        items[0] = Form{ .symbol = Symbol.init("fn*") };
        items[1] = Form{ .vector = &[_]Form{} }; // 仮の空引数（TODO: %1, %2 解析）
        items[2] = if (body.len == 1) body[0] else Form{ .list = body };

        return Form{ .list = items };
    }

    /// ## (symbolic values: ##Inf, ##-Inf, ##NaN)
    fn readSymbolic(self: *Reader) err.Error!Form {
        const next = self.nextToken();
        if (next.kind != .symbol) {
            return err.parseError(.invalid_token, "Expected symbolic value after ##", self.tokenLocation(next));
        }

        const text = next.text(self.source);
        if (std.mem.eql(u8, text, "Inf")) {
            return Form{ .float = std.math.inf(f64) };
        } else if (std.mem.eql(u8, text, "-Inf")) {
            return Form{ .float = -std.math.inf(f64) };
        } else if (std.mem.eql(u8, text, "NaN")) {
            return Form{ .float = std.math.nan(f64) };
        }

        return err.parseError(.invalid_token, "Unknown symbolic value", self.tokenLocation(next));
    }

    // === トークン操作 ===

    fn nextToken(self: *Reader) Token {
        if (self.peeked) |token| {
            self.peeked = null;
            return token;
        }
        return self.tokenizer.next();
    }

    fn peekToken(self: *Reader) Token {
        if (self.peeked == null) {
            self.peeked = self.tokenizer.next();
        }
        return self.peeked.?;
    }

    // === エラーヘルパー ===

    fn tokenLocation(self: *Reader, token: Token) err.SourceLocation {
        _ = self;
        return .{
            .line = token.line,
            .column = token.column,
        };
    }

    fn numberParseError(self: *Reader, token: Token, _: anyerror) err.Error {
        return err.parseError(.invalid_number, "Invalid number literal", self.tokenLocation(token));
    }

    fn invalidTokenError(self: *Reader, token: Token) err.Error {
        return err.parseError(.invalid_token, "Invalid token", self.tokenLocation(token));
    }

    fn unmatchedDelimiterError(self: *Reader, token: Token) err.Error {
        return err.parseError(.unmatched_delimiter, "Unmatched delimiter", self.tokenLocation(token));
    }

    fn unsupportedTokenError(self: *Reader, token: Token) err.Error {
        return err.parseError(.invalid_token, "Unsupported token type", self.tokenLocation(token));
    }
};

// === テスト ===

test "nil, true, false" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = Reader.init(allocator, "nil true false");
    const f1 = (try r.read()).?;
    const f2 = (try r.read()).?;
    const f3 = (try r.read()).?;

    try std.testing.expect(f1.isNil());
    try std.testing.expectEqual(Form.bool_true, f2);
    try std.testing.expectEqual(Form.bool_false, f3);
}

test "整数" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = Reader.init(allocator, "42 -17 0x2A 2r101010 0755");
    try std.testing.expectEqual(@as(i64, 42), (try r.read()).?.int);
    try std.testing.expectEqual(@as(i64, -17), (try r.read()).?.int);
    try std.testing.expectEqual(@as(i64, 42), (try r.read()).?.int); // 0x2A
    try std.testing.expectEqual(@as(i64, 42), (try r.read()).?.int); // 2r101010
    try std.testing.expectEqual(@as(i64, 493), (try r.read()).?.int); // 0755 (8進数)
}

test "浮動小数点" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = Reader.init(allocator, "3.14 1e10 2.5e-3");
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), (try r.read()).?.float, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1e10), (try r.read()).?.float, 1e5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0025), (try r.read()).?.float, 0.0001);
}

test "有理数" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = Reader.init(allocator, "22/7 1/2");
    try std.testing.expectApproxEqAbs(@as(f64, 3.142857), (try r.read()).?.float, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), (try r.read()).?.float, 0.001);
}

test "文字列" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = Reader.init(allocator, "\"hello\" \"with\\nline\"");
    try std.testing.expectEqualStrings("hello", (try r.read()).?.string);
    try std.testing.expectEqualStrings("with\nline", (try r.read()).?.string);
}

test "シンボル" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = Reader.init(allocator, "foo clojure.core/map");

    const s1 = (try r.read()).?.symbol;
    try std.testing.expectEqualStrings("foo", s1.name);
    try std.testing.expect(s1.namespace == null);

    const s2 = (try r.read()).?.symbol;
    try std.testing.expectEqualStrings("map", s2.name);
    try std.testing.expectEqualStrings("clojure.core", s2.namespace.?);
}

test "キーワード" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = Reader.init(allocator, ":foo :ns/bar");

    const k1 = (try r.read()).?.keyword;
    try std.testing.expectEqualStrings("foo", k1.name);

    const k2 = (try r.read()).?.keyword;
    try std.testing.expectEqualStrings("bar", k2.name);
    try std.testing.expectEqualStrings("ns", k2.namespace.?);
}

test "リスト" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = Reader.init(allocator, "(+ 1 2)");

    const form = (try r.read()).?;
    try std.testing.expectEqualStrings("list", form.typeName());

    const items = form.list;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("+", items[0].symbol.name);
    try std.testing.expectEqual(@as(i64, 1), items[1].int);
    try std.testing.expectEqual(@as(i64, 2), items[2].int);
}

test "ベクター" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = Reader.init(allocator, "[1 2 3]");

    const form = (try r.read()).?;
    try std.testing.expectEqualStrings("vector", form.typeName());

    const items = form.vector;
    try std.testing.expectEqual(@as(usize, 3), items.len);
}

test "ネストしたコレクション" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = Reader.init(allocator, "(defn add [a b] (+ a b))");

    const form = (try r.read()).?;
    const items = form.list;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings("defn", items[0].symbol.name);
    try std.testing.expectEqualStrings("add", items[1].symbol.name);
    try std.testing.expectEqualStrings("vector", items[2].typeName());
    try std.testing.expectEqualStrings("list", items[3].typeName());
}

test "quote" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = Reader.init(allocator, "'foo");

    const form = (try r.read()).?;
    const items = form.list;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("quote", items[0].symbol.name);
    try std.testing.expectEqualStrings("foo", items[1].symbol.name);
}

test "#_ discard" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = Reader.init(allocator, "#_ignored 42");

    const form = (try r.read()).?;
    try std.testing.expectEqual(@as(i64, 42), form.int);
}

test "readAll" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = Reader.init(allocator, "1 2 3");
    const forms = try r.readAll();

    try std.testing.expectEqual(@as(usize, 3), forms.len);
    try std.testing.expectEqual(@as(i64, 1), forms[0].int);
    try std.testing.expectEqual(@as(i64, 2), forms[1].int);
    try std.testing.expectEqual(@as(i64, 3), forms[2].int);
}

test "] [ パターン: (let [x 1] [x])" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = Reader.init(allocator, "(let [x 1] [x])");
    const form = (try r.read()).?;
    // リスト: (let [x 1] [x])
    try std.testing.expect(form == .list);
    try std.testing.expectEqual(@as(usize, 3), form.list.len);
    // form.list[0] = let
    try std.testing.expect(form.list[0] == .symbol);
    // form.list[1] = [x 1]
    try std.testing.expect(form.list[1] == .vector);
    try std.testing.expectEqual(@as(usize, 2), form.list[1].vector.len);
    // form.list[2] = [x]
    try std.testing.expect(form.list[2] == .vector);
    try std.testing.expectEqual(@as(usize, 1), form.list[2].vector.len);
}

test "symbolic ##Inf, ##NaN" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var r = Reader.init(allocator, "##Inf ##NaN");

    const f1 = (try r.read()).?.float;
    try std.testing.expect(std.math.isInf(f1));

    const f2 = (try r.read()).?.float;
    try std.testing.expect(std.math.isNan(f2));
}
