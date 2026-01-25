# 対応状況管理の設計

> status/ ディレクトリの構造とスキーマを定義
> 最終更新: 2026-01-25

---

## 背景

本家Clojureとの動作互換を目指すにあたり、何ができて何ができないかを常に把握する必要がある。過去プロジェクトでは互換性の担保が曖昧だったため、構造化データで明示的に管理する。

---

## Clojureの処理段階

```
ソースコード
    ↓ Lexer/Tokenizer
トークン列 (tokens)      ← tokens.yaml で管理
    ↓ Reader
フォーム (forms)         ← Readerテストで担保
    ↓ Macro Expansion
展開済みフォーム
    ↓ Evaluator
値 (values)              ← vars.yaml で管理
```

| 用語 | 説明 | 例 |
|------|------|-----|
| **Token** | 最小の字句単位 | `123`, `"hello"`, `foo`, `:key`, `(`, `)` |
| **Form** | 読み込み可能な構文単位（S式） | `(+ 1 2)`, `[1 2 3]`, `{:a 1}` |
| **Var** | 名前空間に登録された変数 | `clojure.core/map`, `clojure.core/defn` |

---

## ディレクトリ構造

```
status/
├── README.md        # ステータス定義、スキーマ説明
├── tokens.yaml      # 字句解析レベルの対応状況
└── vars.yaml        # Var対応状況（名前空間は階層で）
```

### 設計判断

- **ファイル分割は最小限**: マクロ/関数/特殊形式の区別はYAML内の属性で制御
- **名前空間はYAML階層で表現**: ディレクトリを切らない
- **forms.yaml は保留**: シンタックス（フォーム）の進捗はReaderテストで担保、必要になったら追加

---

## ステータス定義

| ステータス | 意味 | 説明 |
|-----------|------|------|
| `todo` | 未着手 | まだ手をつけていない |
| `wip` | 実装中 | 存在するが動作が未熟 |
| `partial` | 部分実装 | 一部機能のみ、暫定実装で先送り項目あり |
| `done` | 完成 | テストあり、本家と同じ動作 |
| `skip` | 対応しない | JVM固有、Wasm不要等の理由で非対応 |

---

## tokens.yaml スキーマ

003_token_patterns.md を構造化したもの。

```yaml
# status/tokens.yaml
# 字句解析の対応状況

tokens:
  # カテゴリ
  integers:
    # サブカテゴリ
    decimal:
      status: todo          # 必須
      pattern: "[0-9]+"     # 任意: 正規表現パターン
      examples:             # 任意: テスト用の例
        - "42"
        - "-17"
        - "+42"
      note: ""              # 任意: 備考

    hexadecimal:
      status: todo
      pattern: "0x[0-9A-Fa-f]+"
      examples:
        - "0x2A"
        - "0xFF"

    # ...

  floats:
    basic:
      status: todo
      examples:
        - "3.14"
        - "1.0"

    scientific:
      status: todo
      examples:
        - "1e10"
        - "1.5e-3"

    bigdecimal:
      status: todo
      examples:
        - "3.14M"

  ratio:
    status: todo
    pattern: "[0-9]+/[0-9]+"
    examples:
      - "22/7"
      - "-3/4"

  special_numbers:
    infinity:
      status: todo
      examples:
        - "##Inf"
        - "##-Inf"
    nan:
      status: todo
      examples:
        - "##NaN"

  strings:
    basic:
      status: todo
    escape_sequences:
      status: todo
      note: "\\t, \\n, \\r, \\\\, \\\", \\uXXXX, \\oXXX"
    multiline:
      status: todo

  characters:
    basic:
      status: todo
      examples:
        - "\\a"
        - "\\A"
    named:
      status: todo
      examples:
        - "\\newline"
        - "\\space"
        - "\\tab"
    unicode:
      status: todo
      examples:
        - "\\u0041"
    octal:
      status: todo
      examples:
        - "\\o101"

  symbols:
    basic:
      status: todo
    namespaced:
      status: todo
      examples:
        - "ns/name"
        - "clojure.core/map"
    special:
      status: todo
      note: "nil, true, false"

  keywords:
    basic:
      status: todo
    namespaced:
      status: todo
    auto_resolved:
      status: todo
      examples:
        - "::foo"
        - "::alias/name"

  collections:
    list:
      status: todo
    vector:
      status: todo
    map:
      status: todo
    set:
      status: todo
    ns_map:
      status: todo
      examples:
        - "#:ns{:a 1}"
        - "#::{:a 1}"

  reader_macros:
    quote:
      status: todo
      expansion: "(quote x)"
    syntax_quote:
      status: todo
      note: "複雑、gensym対応必要"
    unquote:
      status: todo
    unquote_splicing:
      status: todo
    deref:
      status: todo
      expansion: "(deref x)"
    meta:
      status: todo
    comment:
      status: todo

  dispatch_macros:
    var:
      status: todo
      expansion: "(var x)"
    regex:
      status: todo
    fn:
      status: todo
      note: "%, %1, %&"
    set:
      status: todo
    discard:
      status: todo
    symbolic:
      status: todo
      note: "##Inf, ##-Inf, ##NaN"
    conditional:
      status: todo
      note: "#?, #?@"
    tagged:
      status: todo
      note: "#inst, #uuid, カスタム"

  whitespace:
    status: done
    note: "space, tab, newline, comma"
```

---

## vars.yaml スキーマ

clojure.core およびその他名前空間のVar対応状況。

```yaml
# status/vars.yaml
# Var対応状況

vars:
  clojure.core:
    # 特殊形式
    def:
      type: special-form
      status: todo
      note: "基盤"

    if:
      type: special-form
      status: todo

    "fn*":
      type: special-form
      status: todo
      note: "fnマクロの展開先"

    "let*":
      type: special-form
      status: todo

    loop:
      type: special-form
      status: todo

    recur:
      type: special-form
      status: todo

    do:
      type: special-form
      status: todo

    quote:
      type: special-form
      status: todo

    var:
      type: special-form
      status: todo

    try:
      type: special-form
      status: todo

    throw:
      type: special-form
      status: todo

    # 関数
    first:
      type: function
      arity: [1]
      status: todo

    rest:
      type: function
      arity: [1]
      status: todo

    cons:
      type: function
      arity: [2]
      status: todo

    map:
      type: function
      arity: [1, 2, 3, 4, variadic]
      status: todo
      note: "transducer版(arity 1)は後回し"

    filter:
      type: function
      arity: [1, 2]
      status: todo

    reduce:
      type: function
      arity: [2, 3]
      status: todo

    "+":
      type: function
      arity: [0, 1, 2, variadic]
      status: todo

    "-":
      type: function
      arity: [1, 2, variadic]
      status: todo

    "*":
      type: function
      arity: [0, 1, 2, variadic]
      status: todo

    "/":
      type: function
      arity: [1, 2, variadic]
      status: todo

    "=":
      type: function
      arity: [1, 2, variadic]
      status: todo

    # マクロ
    defn:
      type: macro
      status: todo
      depends: ["fn*", def]

    defmacro:
      type: macro
      status: todo

    when:
      type: macro
      status: todo
      depends: [if, do]

    cond:
      type: macro
      status: todo

    let:
      type: macro
      status: todo
      depends: ["let*"]

    fn:
      type: macro
      status: todo
      depends: ["fn*"]

    "->":
      type: macro
      status: todo

    "->>":
      type: macro
      status: todo

    # 動的Var
    "*ns*":
      type: dynamic-var
      status: todo

    "*out*":
      type: dynamic-var
      status: todo

  clojure.string:
    join:
      type: function
      status: todo

    split:
      type: function
      status: todo

    # ... 必要に応じて追加

  clojure.set:
    union:
      type: function
      status: todo

    intersection:
      type: function
      status: todo

    # ... 必要に応じて追加
```

---

## type 定義

| type | 説明 |
|------|------|
| `special-form` | 評価器で直接処理される特殊形式 |
| `function` | 関数（Zigで実装） |
| `macro` | マクロ（将来は.cljで実装可能） |
| `dynamic-var` | 動的束縛可能なVar（`*earmuffs*`） |

---

## 追加フィールド（任意）

| フィールド | 説明 | 例 |
|-----------|------|-----|
| `arity` | 対応するアリティ | `[1, 2, variadic]` |
| `depends` | 依存する他のVar | `["fn*", def]` |
| `note` | 備考 | `"transducer版は後回し"` |
| `tests` | テスト数 | `5` |
| `priority` | 実装優先度 | `1` (高) 〜 `5` (低) |

---

## 次のアクション

1. [x] 004_status_design.md 作成（本ドキュメント）
2. [ ] status/README.md 作成
3. [ ] status/tokens.yaml 作成（003から生成）
4. [ ] 本家 clojure.core の Var 一覧取得
5. [ ] status/vars.yaml 作成

---

## 議論ログ

### 2026-01-25

**決定事項:**

1. ファイル分割は最小限（tokens.yaml + vars.yaml）
2. マクロ/関数/特殊形式の区別はYAML属性で
3. 名前空間はYAML階層で表現
4. ステータスは5段階: todo, wip, partial, done, skip
5. forms.yaml（シンタックス管理）は保留、Readerテストで担保
