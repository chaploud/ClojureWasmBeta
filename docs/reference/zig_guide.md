# Zig 0.15.2 によるプログラミング言語処理系の高速化メモ

目的:
- 対象: プログラミング言語処理系（lexer / parser / IR / VM / compiler など）
- Zig version: 0.15.2
- 数値ベンチマークは扱わない
- Zig特有の話題と、言語処理系共通の話題を分離して整理する

---

## A. Zig特有の高速化テクニック

### A-1. comptime による「処理系の前計算」

Zig最大の特徴。
「処理系の一部を、実行時ではなくコンパイル時に動かす」という発想。

典型的なユースケース:
- キーワード集合
- トークン種別テーブル
- 演算子優先順位
- DFA / テーブル駆動パーサの遷移表
- enum ↔ ID / string 変換表
- 命令セットや opcode 情報

例: キーワードテーブルを comptime で構築

```zig
const Keyword = enum {
    if_kw,
    else_kw,
    while_kw,
    return_kw,
};

// Zig 0.15.2: StaticStringMap + initComptime を使用
const keywords = std.StaticStringMap(Keyword).initComptime(.{
    .{ "if", .if_kw },
    .{ "else", .else_kw },
    .{ "while", .while_kw },
    .{ "return", .return_kw },
});

// 使用例
pub fn lookupKeyword(str: []const u8) ?Keyword {
    return keywords.get(str);
}
```

ポイント:
- 実行時コストゼロ
- ヒープ確保ゼロ
- 実質「静的ジャンプテーブル」
- parser generator / table generator 的に使える

処理系では comptime を「メタ言語」として扱うと強い。

---

### A-2. アロケータを戦略として設計する

Zigには malloc/free が存在しない。
すべて Allocator 経由でメモリ管理する。

処理系にありがちなアロケーション特性:
- AST ノードを大量生成
- 個別解放はほぼ不要
- フェーズ終了時にまとめて破棄

→ ArenaAllocator が最適解になりやすい。

例: ArenaAllocator

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const allocator = arena.allocator();

const node = try allocator.create(AstNode);

利点:
- free 不要
- ロックなし
- フラグメントほぼなし
- キャッシュ効率が良い

実践パターン:
- lexer / parser / IR フェーズごとに arena を分ける
- フェーズ終了時に arena.deinit() で一括解放
- 将来的に GC を Allocator として差し替え可能

---

### A-3. 分岐ヒント（@branchHint / @branch）

Zigは分岐確率を明示できる。

例:

if (@branch(.likely, token.kind == .identifier)) {
    // 通常パス
} else if (@branch(.unlikely, token.kind == .invalid)) {
    return error.InvalidToken;
}

使いどころ:
- 正常系: .likely
- エラー系: .unlikely / .cold

効果:
- 分岐予測ミス削減
- I-cache 汚染の抑制
- hot path の最適化

ループ内部・opcode dispatch・parser の分岐で効きやすい。

---

### A-4. if による option / error の高速分解

Zig の if は「分解束縛構文」でもある。

Optional:

if (maybe_node) |node| {
    use(node);
} else {
    // null
}

Error union:

if (parseExpr()) |expr| {
    return expr;
} else |err| {
    return err;
}

重要:
- 例外ではない
- ヒープ確保なし
- 単なる分岐 + move

パターンマッチ風だが、実行コストは if と同等。
nullable / error 多用の処理系でも性能劣化しにくい。

---

### A-5. switch(enum) は十分に速い

Zig の switch(enum) はコンパイラが最適化する。
（ジャンプテーブル / 二分探索 / if-chain など）

例:

switch (token.kind) {
    .identifier => parseIdent(),
    .number     => parseNumber(),
    .lparen     => parseGroup(),
    else        => return error.UnexpectedToken,
}

用途:
- トークン分岐
- opcode dispatch
- AST node kind dispatch

C の switch と同等に安心して使ってよい。

---

## B. 言語処理系全般に共通する高速化原則

### B-1. 「if が遅い」はほぼ誤解

本当に遅いのは:
- 分岐予測ミス
- キャッシュミス
- 無駄なメモリアクセス

悪い例（ポインタチェーン）:
node = node.next.?.next.?.next.?;

良い例（配列）:
const node = nodes[i];

教訓:
分岐の数より、データ配置が速度を支配する。

---

### B-2. 配列 > リンクリスト（ほぼ常に）

処理系でありがちな失敗:
- AST をポインタでつなぐ
- IR を linked list で管理

→ キャッシュミス地獄。

推奨設計:
- AST node を配列に詰める
- index（u32 など）で参照

例:

const NodeId = u32;

const Node = struct {
    kind: NodeKind,
    lhs: ?NodeId,
    rhs: ?NodeId,
};

利点:
- キャッシュヒット率向上
- メモリ管理が単純
- シリアライズしやすい
- デバッグが楽

---

### B-3. 構造体サイズを意識する

例:

const Token = struct {
    kind: TokenKind, // u8 / u16
    start: u32,
    len: u16,
};

意識する点:
- hot struct は小さく
- cache line (64B) を超えない
- bool / enum の実サイズを把握

トークン・IR 命令・VM スタック要素は特に重要。

---

### B-4. アルゴリズムが9割

Zig以前の話。

代表例:
- O(n^2) → O(n)
- 再帰 → 反復
- backtracking → table / memo

処理系あるある改善:
- naive parser → Pratt parser
- recursive descent → precedence climbing
- 文字列比較 → ID / intern 化

---

### B-5. 遅くなりがちな処理チェックリスト

- 小さい alloc/free の乱発
- ポインタチェーン
- 仮想関数的 dispatch
- 文字列比較
- 深い再帰

Zigはこれらを設計段階で回避できる。

---

## まとめ（Zig × 言語処理系）

- comptime = 処理系の一部をコンパイル時へ
- Allocator = パフォーマンス設計そのもの
- if / switch は恐れず使う
- 速さは分岐よりデータ配置
- 配列 + arena は正義

Zig は「処理系を書くための言語」として非常に相性が良い。

次の発展トピック候補:
- VM opcode dispatch 最適化
- tagged union / NaN-boxing in Zig
- IR を struct-of-arrays にする設計
- Zig での JIT / 動的コード生成の注意点
