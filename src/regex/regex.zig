//! 正規表現パーサー
//!
//! 正規表現パターン文字列を RegexNode AST にパースする。
//! Java regex 互換の構文をサポート（ASCII ベース）。
//!
//! 文法:
//!   regex      := alternation
//!   alternation := sequence ('|' sequence)*
//!   sequence   := quantified*
//!   quantified := atom quantifier?
//!   atom       := literal | '.' | char_class | group | escape | anchor
//!   quantifier := ('*'|'+'|'?'|'{n}'|'{n,}'|'{n,m}') '?'?
//!   char_class := '[' '^'? (range | char)+ ']'
//!   group      := '(' ('?:' | '?=' | '?!' | '?i' | '?m' | '?s')? regex ')'
//!   escape     := '\' (d|D|w|W|s|S|b|B|digit|metachar)

const std = @import("std");

/// コンパイル済み正規表現
pub const CompiledRegex = struct {
    nodes: []const RegexNode,
    group_count: u16,
    flags: Flags,
    source: []const u8,
};

/// 正規表現フラグ
pub const Flags = struct {
    case_insensitive: bool = false, // (?i)
    multiline: bool = false, // (?m): ^ $ が行頭行末にマッチ
    dotall: bool = false, // (?s): . が \n にもマッチ

    pub const empty: Flags = .{};
};

/// 文字範囲
pub const CharRange = struct {
    start: u8,
    end: u8,
};

/// 文字クラス
pub const CharClass = struct {
    ranges: []const CharRange,
    singles: []const u8,
    negated: bool,
};

/// 定義済みクラス
pub const Predefined = enum {
    digit, // \d = [0-9]
    non_digit, // \D = [^0-9]
    word, // \w = [a-zA-Z0-9_]
    non_word, // \W = [^a-zA-Z0-9_]
    whitespace, // \s = [ \t\n\r\f]
    non_whitespace, // \S = [^ \t\n\r\f]
};

/// アンカー
pub const Anchor = enum {
    start, // ^
    end, // $
    word_boundary, // \b
    non_word_boundary, // \B
};

/// グループ種別
pub const GroupKind = enum {
    capturing, // (...)
    non_capturing, // (?:...)
    lookahead, // (?=...)
    negative_lookahead, // (?!...)
    flag_group, // (?i), (?m), (?s) — フラグ設定のみ
};

/// グループ
pub const Group = struct {
    kind: GroupKind,
    children: []const RegexNode,
    capture_index: u16, // capturing グループのインデックス（0 = 未使用）
    flags: ?Flags, // flag_group の場合に設定されるフラグ
};

/// 選択
pub const Alternation = struct {
    alternatives: []const []const RegexNode,
};

/// 量指定子
pub const Quantifier = struct {
    child: *const RegexNode,
    min: u32,
    max: ?u32, // null = 無限
    greedy: bool,
};

/// 正規表現 AST ノード
pub const RegexNode = union(enum) {
    literal: u8, // 'a'
    dot, // .
    char_class: CharClass, // [abc], [a-z], [^abc]
    predefined: Predefined, // \d, \D, \w, \W, \s, \S
    anchor: Anchor, // ^, $, \b, \B
    group: Group, // (...), (?:...)
    alternation: Alternation, // a|b
    quantifier: Quantifier, // *, +, ?, {n,m}
    backreference: u16, // \1, \2
    sequence: []const RegexNode, // 連結
};

/// パーサーエラー
pub const ParseError = error{
    InvalidEscape,
    UnterminatedCharClass,
    UnterminatedGroup,
    InvalidQuantifier,
    InvalidBackreference,
    EmptyPattern,
    OutOfMemory,
    NothingToRepeat,
    InvalidFlag,
    UnterminatedRepetition,
};

/// 正規表現パーサー
pub const Parser = struct {
    source: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
    group_count: u16,
    flags: Flags,

    /// 初期化
    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return .{
            .source = source,
            .pos = 0,
            .allocator = allocator,
            .group_count = 0,
            .flags = .{},
        };
    }

    /// パースしてコンパイル済み正規表現を返す
    pub fn parse(self: *Parser) ParseError!CompiledRegex {
        const nodes = try self.parseAlternation();
        return .{
            .nodes = nodes,
            .group_count = self.group_count,
            .flags = self.flags,
            .source = self.source,
        };
    }

    // === 再帰下降パーサー ===

    /// alternation := sequence ('|' sequence)*
    fn parseAlternation(self: *Parser) ParseError![]const RegexNode {
        const first = try self.parseSequence();

        if (!self.isEof() and self.peek() == '|') {
            // 選択肢を収集
            var alts: std.ArrayListUnmanaged([]const RegexNode) = .empty;
            alts.append(self.allocator, first) catch return error.OutOfMemory;

            while (!self.isEof() and self.peek() == '|') {
                self.advance(); // '|' をスキップ
                const alt = try self.parseSequence();
                alts.append(self.allocator, alt) catch return error.OutOfMemory;
            }

            const node = self.allocator.create(RegexNode) catch return error.OutOfMemory;
            node.* = .{ .alternation = .{
                .alternatives = alts.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            } };

            const result = self.allocator.alloc(RegexNode, 1) catch return error.OutOfMemory;
            result[0] = node.*;
            return result;
        }

        return first;
    }

    /// sequence := quantified*
    fn parseSequence(self: *Parser) ParseError![]const RegexNode {
        var nodes: std.ArrayListUnmanaged(RegexNode) = .empty;

        while (!self.isEof()) {
            const c = self.peek();
            // シーケンスの終端
            if (c == ')' or c == '|') break;

            const node = try self.parseQuantified();
            nodes.append(self.allocator, node) catch return error.OutOfMemory;
        }

        return nodes.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    /// quantified := atom quantifier?
    fn parseQuantified(self: *Parser) ParseError!RegexNode {
        var atom = try self.parseAtom();

        // 量指定子をチェック
        if (!self.isEof()) {
            const c = self.peek();
            if (c == '*' or c == '+' or c == '?' or c == '{') {
                atom = try self.parseQuantifier(atom);
            }
        }

        return atom;
    }

    /// 量指定子のパース
    fn parseQuantifier(self: *Parser, child_node: RegexNode) ParseError!RegexNode {
        const c = self.peek();
        self.advance();

        var min: u32 = 0;
        var max: ?u32 = null;

        switch (c) {
            '*' => {
                min = 0;
                max = null;
            },
            '+' => {
                min = 1;
                max = null;
            },
            '?' => {
                min = 0;
                max = 1;
            },
            '{' => {
                // {n}, {n,}, {n,m}
                const result = try self.parseRepetition();
                min = result.min;
                max = result.max;
            },
            else => unreachable,
        }

        // 非貪欲 '?'
        var greedy = true;
        if (!self.isEof() and self.peek() == '?') {
            greedy = false;
            self.advance();
        }

        const child = self.allocator.create(RegexNode) catch return error.OutOfMemory;
        child.* = child_node;

        return .{ .quantifier = .{
            .child = child,
            .min = min,
            .max = max,
            .greedy = greedy,
        } };
    }

    /// {n}, {n,}, {n,m} のパース
    fn parseRepetition(self: *Parser) ParseError!struct { min: u32, max: ?u32 } {
        var min: u32 = 0;
        var max: ?u32 = null;

        // 最小値
        min = try self.parseRepNumber();

        if (self.isEof()) return error.UnterminatedRepetition;

        if (self.peek() == '}') {
            // {n}
            self.advance();
            max = min;
            return .{ .min = min, .max = max };
        }

        if (self.peek() != ',') return error.InvalidQuantifier;
        self.advance(); // ','

        if (self.isEof()) return error.UnterminatedRepetition;

        if (self.peek() == '}') {
            // {n,}
            self.advance();
            max = null;
            return .{ .min = min, .max = max };
        }

        // {n,m}
        max = try self.parseRepNumber();
        if (self.isEof() or self.peek() != '}') return error.UnterminatedRepetition;
        self.advance(); // '}'

        return .{ .min = min, .max = max };
    }

    /// 繰り返し回数の数値パース
    fn parseRepNumber(self: *Parser) ParseError!u32 {
        var n: u32 = 0;
        var found = false;
        while (!self.isEof() and self.peek() >= '0' and self.peek() <= '9') {
            n = n * 10 + @as(u32, self.peek() - '0');
            self.advance();
            found = true;
        }
        if (!found) return error.InvalidQuantifier;
        return n;
    }

    /// atom のパース
    fn parseAtom(self: *Parser) ParseError!RegexNode {
        if (self.isEof()) return error.EmptyPattern;

        const c = self.peek();
        switch (c) {
            '.' => {
                self.advance();
                return .dot;
            },
            '^' => {
                self.advance();
                return .{ .anchor = .start };
            },
            '$' => {
                self.advance();
                return .{ .anchor = .end };
            },
            '[' => return self.parseCharClass(),
            '(' => return self.parseGroup(),
            '\\' => return self.parseEscape(),
            '*', '+', '?' => return error.NothingToRepeat,
            else => {
                self.advance();
                return .{ .literal = c };
            },
        }
    }

    /// 文字クラス [...]
    fn parseCharClass(self: *Parser) ParseError!RegexNode {
        self.advance(); // '[' をスキップ

        var negated = false;
        if (!self.isEof() and self.peek() == '^') {
            negated = true;
            self.advance();
        }

        var ranges: std.ArrayListUnmanaged(CharRange) = .empty;
        var singles: std.ArrayListUnmanaged(u8) = .empty;

        // 最初の ']' はリテラルとして扱う
        var first = true;

        while (!self.isEof()) {
            const c = self.peek();

            if (c == ']' and !first) {
                self.advance();
                return .{ .char_class = .{
                    .ranges = ranges.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                    .singles = singles.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                    .negated = negated,
                } };
            }

            first = false;

            if (c == '\\') {
                // エスケープ
                self.advance();
                if (self.isEof()) return error.UnterminatedCharClass;
                const esc = try self.parseCharClassEscape();
                switch (esc) {
                    .single => |s| singles.append(self.allocator, s) catch return error.OutOfMemory,
                    .predefined => |p| {
                        // 定義済みクラスを範囲に展開
                        expandPredefined(p, &ranges, &singles, self.allocator) catch return error.OutOfMemory;
                    },
                }
            } else {
                self.advance();
                // 範囲チェック: a-z
                if (!self.isEof() and self.peek() == '-') {
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] != ']') {
                        self.advance(); // '-'
                        if (self.isEof()) return error.UnterminatedCharClass;
                        const end = self.peek();
                        self.advance();
                        ranges.append(self.allocator, .{ .start = c, .end = end }) catch return error.OutOfMemory;
                        continue;
                    }
                }
                singles.append(self.allocator, c) catch return error.OutOfMemory;
            }
        }

        return error.UnterminatedCharClass;
    }

    /// 文字クラス内エスケープ
    const CharClassEscapeResult = union(enum) {
        single: u8,
        predefined: Predefined,
    };

    fn parseCharClassEscape(self: *Parser) ParseError!CharClassEscapeResult {
        const c = self.peek();
        self.advance();
        return switch (c) {
            'd' => .{ .predefined = .digit },
            'D' => .{ .predefined = .non_digit },
            'w' => .{ .predefined = .word },
            'W' => .{ .predefined = .non_word },
            's' => .{ .predefined = .whitespace },
            'S' => .{ .predefined = .non_whitespace },
            'n' => .{ .single = '\n' },
            't' => .{ .single = '\t' },
            'r' => .{ .single = '\r' },
            'f' => .{ .single = '\x0C' },
            else => .{ .single = c }, // メタ文字のエスケープ
        };
    }

    /// グループ (...)
    fn parseGroup(self: *Parser) ParseError!RegexNode {
        self.advance(); // '(' をスキップ

        var kind: GroupKind = .capturing;
        var group_flags: ?Flags = null;
        var capture_idx: u16 = 0;

        // グループ種別チェック
        if (!self.isEof() and self.peek() == '?') {
            self.advance();
            if (self.isEof()) return error.UnterminatedGroup;

            const c = self.peek();
            switch (c) {
                ':' => {
                    kind = .non_capturing;
                    self.advance();
                },
                '=' => {
                    kind = .lookahead;
                    self.advance();
                },
                '!' => {
                    kind = .negative_lookahead;
                    self.advance();
                },
                'i', 'm', 's' => {
                    // インラインフラグ (?i), (?m), (?s)
                    var f = self.flags;
                    while (!self.isEof() and self.peek() != ')' and self.peek() != ':') {
                        switch (self.peek()) {
                            'i' => f.case_insensitive = true,
                            'm' => f.multiline = true,
                            's' => f.dotall = true,
                            else => return error.InvalidFlag,
                        }
                        self.advance();
                    }

                    if (!self.isEof() and self.peek() == ')') {
                        // (?i) — フラグのみ、グループ内容なし
                        self.advance();
                        self.flags = f;
                        kind = .flag_group;
                        return .{ .group = .{
                            .kind = kind,
                            .children = &[_]RegexNode{},
                            .capture_index = 0,
                            .flags = f,
                        } };
                    }

                    // (?i:...) — フラグ付き非キャプチャグループ
                    if (!self.isEof() and self.peek() == ':') {
                        self.advance();
                    }
                    kind = .non_capturing;
                    group_flags = f;
                    // グローバルフラグも更新
                    self.flags = f;
                },
                else => return error.InvalidFlag,
            }
        }

        if (kind == .capturing) {
            self.group_count += 1;
            capture_idx = self.group_count;
        }

        // グループの中身をパース
        const children = try self.parseAlternation();

        if (self.isEof() or self.peek() != ')') {
            return error.UnterminatedGroup;
        }
        self.advance(); // ')' をスキップ

        return .{ .group = .{
            .kind = kind,
            .children = children,
            .capture_index = capture_idx,
            .flags = group_flags,
        } };
    }

    /// エスケープシーケンス
    fn parseEscape(self: *Parser) ParseError!RegexNode {
        self.advance(); // '\' をスキップ
        if (self.isEof()) return error.InvalidEscape;

        const c = self.peek();
        self.advance();

        return switch (c) {
            // 定義済みクラス
            'd' => .{ .predefined = .digit },
            'D' => .{ .predefined = .non_digit },
            'w' => .{ .predefined = .word },
            'W' => .{ .predefined = .non_word },
            's' => .{ .predefined = .whitespace },
            'S' => .{ .predefined = .non_whitespace },
            // アンカー
            'b' => .{ .anchor = .word_boundary },
            'B' => .{ .anchor = .non_word_boundary },
            // エスケープ文字
            'n' => .{ .literal = '\n' },
            't' => .{ .literal = '\t' },
            'r' => .{ .literal = '\r' },
            'f' => .{ .literal = '\x0C' },
            // 後方参照
            '1'...'9' => .{ .backreference = @as(u16, c - '0') },
            // メタ文字のエスケープ
            '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '^', '$', '\\' => .{ .literal = c },
            else => .{ .literal = c },
        };
    }

    // === ヘルパー ===

    fn isEof(self: *const Parser) bool {
        return self.pos >= self.source.len;
    }

    fn peek(self: *const Parser) u8 {
        return self.source[self.pos];
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.source.len) {
            self.pos += 1;
        }
    }
};

/// 定義済みクラスを CharRange/singles に展開
fn expandPredefined(
    p: Predefined,
    ranges: *std.ArrayListUnmanaged(CharRange),
    singles: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
) !void {
    switch (p) {
        .digit => try ranges.append(allocator, .{ .start = '0', .end = '9' }),
        .non_digit => {
            // [^0-9] をクラス内に展開するのは難しいので、0-9以外の範囲を追加
            try ranges.append(allocator, .{ .start = 0, .end = '0' - 1 });
            try ranges.append(allocator, .{ .start = '9' + 1, .end = 127 });
        },
        .word => {
            try ranges.append(allocator, .{ .start = 'a', .end = 'z' });
            try ranges.append(allocator, .{ .start = 'A', .end = 'Z' });
            try ranges.append(allocator, .{ .start = '0', .end = '9' });
            try singles.append(allocator, '_');
        },
        .non_word => {
            // 面倒なので skip — 実行時に predefined として処理
            try ranges.append(allocator, .{ .start = 0, .end = '0' - 1 });
            try ranges.append(allocator, .{ .start = '9' + 1, .end = 'A' - 1 });
            try ranges.append(allocator, .{ .start = 'Z' + 1, .end = '_' - 1 });
            try ranges.append(allocator, .{ .start = '_' + 1, .end = 'a' - 1 });
            try ranges.append(allocator, .{ .start = 'z' + 1, .end = 127 });
        },
        .whitespace => {
            try singles.append(allocator, ' ');
            try singles.append(allocator, '\t');
            try singles.append(allocator, '\n');
            try singles.append(allocator, '\r');
            try singles.append(allocator, '\x0C');
        },
        .non_whitespace => {
            try ranges.append(allocator, .{ .start = '!', .end = '~' });
            // その他の非空白文字
            try ranges.append(allocator, .{ .start = 0, .end = 8 }); // \t=9 の前
            try ranges.append(allocator, .{ .start = 14, .end = 31 }); // \r=13 の後
        },
    }
}

// === テスト ===

test "リテラルパース" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "abc");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 3), result.nodes.len);
    try std.testing.expectEqual(@as(u8, 'a'), result.nodes[0].literal);
    try std.testing.expectEqual(@as(u8, 'b'), result.nodes[1].literal);
    try std.testing.expectEqual(@as(u8, 'c'), result.nodes[2].literal);
}

test "ドットパース" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "a.b");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 3), result.nodes.len);
    try std.testing.expectEqual(@as(u8, 'a'), result.nodes[0].literal);
    try std.testing.expect(result.nodes[1] == .dot);
    try std.testing.expectEqual(@as(u8, 'b'), result.nodes[2].literal);
}

test "量指定子パース" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "a*b+c?");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 3), result.nodes.len);
    // a*
    try std.testing.expect(result.nodes[0] == .quantifier);
    try std.testing.expectEqual(@as(u32, 0), result.nodes[0].quantifier.min);
    try std.testing.expect(result.nodes[0].quantifier.max == null);
    try std.testing.expect(result.nodes[0].quantifier.greedy);
    // b+
    try std.testing.expect(result.nodes[1] == .quantifier);
    try std.testing.expectEqual(@as(u32, 1), result.nodes[1].quantifier.min);
    try std.testing.expect(result.nodes[1].quantifier.max == null);
    // c?
    try std.testing.expect(result.nodes[2] == .quantifier);
    try std.testing.expectEqual(@as(u32, 0), result.nodes[2].quantifier.min);
    try std.testing.expectEqual(@as(u32, 1), result.nodes[2].quantifier.max.?);
}

test "非貪欲量指定子" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "a*?b+?");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 2), result.nodes.len);
    try std.testing.expect(!result.nodes[0].quantifier.greedy);
    try std.testing.expect(!result.nodes[1].quantifier.greedy);
}

test "文字クラス" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "[abc]");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.len);
    try std.testing.expect(result.nodes[0] == .char_class);
    try std.testing.expect(!result.nodes[0].char_class.negated);
    try std.testing.expectEqual(@as(usize, 3), result.nodes[0].char_class.singles.len);
}

test "否定文字クラス" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "[^abc]");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.len);
    try std.testing.expect(result.nodes[0].char_class.negated);
}

test "文字範囲" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "[a-z0-9]");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), result.nodes[0].char_class.ranges.len);
    try std.testing.expectEqual(@as(u8, 'a'), result.nodes[0].char_class.ranges[0].start);
    try std.testing.expectEqual(@as(u8, 'z'), result.nodes[0].char_class.ranges[0].end);
    try std.testing.expectEqual(@as(u8, '0'), result.nodes[0].char_class.ranges[1].start);
    try std.testing.expectEqual(@as(u8, '9'), result.nodes[0].char_class.ranges[1].end);
}

test "選択" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "a|b|c");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.len);
    try std.testing.expect(result.nodes[0] == .alternation);
    try std.testing.expectEqual(@as(usize, 3), result.nodes[0].alternation.alternatives.len);
}

test "キャプチャグループ" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "(abc)");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.len);
    try std.testing.expect(result.nodes[0] == .group);
    try std.testing.expect(result.nodes[0].group.kind == .capturing);
    try std.testing.expectEqual(@as(u16, 1), result.nodes[0].group.capture_index);
    try std.testing.expectEqual(@as(u16, 1), result.group_count);
}

test "非キャプチャグループ" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "(?:abc)");
    const result = try p.parse();

    try std.testing.expect(result.nodes[0].group.kind == .non_capturing);
    try std.testing.expectEqual(@as(u16, 0), result.group_count);
}

test "定義済みクラス" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "\\d\\w\\s");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 3), result.nodes.len);
    try std.testing.expect(result.nodes[0] == .predefined);
    try std.testing.expect(result.nodes[0].predefined == .digit);
    try std.testing.expect(result.nodes[1].predefined == .word);
    try std.testing.expect(result.nodes[2].predefined == .whitespace);
}

test "アンカー" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "^abc$");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 5), result.nodes.len);
    try std.testing.expect(result.nodes[0] == .anchor);
    try std.testing.expect(result.nodes[0].anchor == .start);
    try std.testing.expect(result.nodes[4] == .anchor);
    try std.testing.expect(result.nodes[4].anchor == .end);
}

test "後方参照" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "(a)\\1");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 2), result.nodes.len);
    try std.testing.expect(result.nodes[1] == .backreference);
    try std.testing.expectEqual(@as(u16, 1), result.nodes[1].backreference);
}

test "繰り返し {n,m}" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "a{2,4}");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.len);
    try std.testing.expect(result.nodes[0] == .quantifier);
    try std.testing.expectEqual(@as(u32, 2), result.nodes[0].quantifier.min);
    try std.testing.expectEqual(@as(u32, 4), result.nodes[0].quantifier.max.?);
}

test "エスケープメタ文字" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "\\.");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 1), result.nodes.len);
    try std.testing.expect(result.nodes[0] == .literal);
    try std.testing.expectEqual(@as(u8, '.'), result.nodes[0].literal);
}

test "複合パターン \\d+-\\d+" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "\\d+-\\d+");
    const result = try p.parse();

    // \d+ - \d+ = quantifier, literal('-'), quantifier
    try std.testing.expectEqual(@as(usize, 3), result.nodes.len);
    try std.testing.expect(result.nodes[0] == .quantifier);
    try std.testing.expectEqual(@as(u8, '-'), result.nodes[1].literal);
    try std.testing.expect(result.nodes[2] == .quantifier);
}

test "空パターン" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "");
    const result = try p.parse();
    try std.testing.expectEqual(@as(usize, 0), result.nodes.len);
}

test "インラインフラグ (?i)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "(?i)abc");
    const result = try p.parse();

    try std.testing.expect(result.flags.case_insensitive);
}

test "先読み (?=...)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(allocator, "a(?=b)");
    const result = try p.parse();

    try std.testing.expectEqual(@as(usize, 2), result.nodes.len);
    try std.testing.expect(result.nodes[1] == .group);
    try std.testing.expect(result.nodes[1].group.kind == .lookahead);
}
