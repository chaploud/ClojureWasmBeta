# アーキテクチャ設計

ClojureWasmBeta の全体アーキテクチャ。
ツリーウォーク評価器から始め、バイトコードVM、データ抽象層、GC、Wasm連携へ拡張。

## 処理フロー

```
Source Code
     ↓
┌──────────────────────────────────────────────────────────────┐
│ src/reader/                                                   │
│   Tokenizer → Reader → Form                                   │
│   ソースコードを構文木（Form）に変換                           │
└──────────────────────────────────────────────────────────────┘
     ↓ Form
┌──────────────────────────────────────────────────────────────┐
│ src/analyzer/                                                 │
│   Analyzer → Node                                             │
│   マクロ展開、シンボル解決、構文解析                           │
└──────────────────────────────────────────────────────────────┘
     ↓ Node
┌──────────────────────────────────────────────────────────────┐
│ src/compiler/ + src/runtime/                                  │
│   TreeWalkEval または Compiler → VM                           │
│   Node を評価/実行して Value を生成                           │
└──────────────────────────────────────────────────────────────┘
     ↓ Value
┌──────────────────────────────────────────────────────────────┐
│ src/wasm/ (将来)                                              │
│   Component Model 連携                                        │
│   .wasm ロード、関数呼び出し、型変換                          │
└──────────────────────────────────────────────────────────────┘
```

## 設計方針

### デュアルバックエンド戦略

TreeWalk評価器とバイトコードVMを並行して維持し、`--compare`で回帰検出。

```
Form → Analyzer → Node → [Backend切り替え] → Value
                              ↑
                    ┌─────────┴─────────┐
                    │                   │
              TreeWalkEval            Compiler
              (正確性重視)               ↓
                                    Bytecode
                                       ↓
                                      VM
                                  (性能重視)
```

- **TreeWalk**: 新機能の正しい振る舞いを確立
- **VM**: TreeWalkと同じ結果を返すことを検証しながら実装
- **`--compare`オプション**: 両バックエンドで実行し結果を比較

### コア vs ライブラリの区別

**重要**: Clojureでは多くの「標準関数」が実際にはコア実装を要求する。

| 区分 | 例 | 追加方法 |
|------|-----|---------|
| **純粋なlib追加** | println, str, subs | core.zig に関数追加のみ |
| **コア改修必要** | map, filter, reduce | LazySeq型 + 新Node + VM対応 |
| **新しい抽象** | defprotocol, defrecord | Value型拡張 + Analyzer + VM |

「lib追加で済む」と思っても実際はコア改修が必要なケースが多い。

---

## ディレクトリ構成

```
src/
├── base/               # 共通基盤
│   └── error.zig       # エラー型
│
├── reader/             # Source → Form
│   ├── tokenizer.zig   # トークン化
│   ├── reader.zig      # S式構築
│   └── form.zig        # Form型定義
│
├── analyzer/           # Form → Node
│   ├── node.zig        # Node型定義
│   └── analyze.zig     # 解析・マクロ展開
│
├── compiler/           # Node → Bytecode
│   ├── bytecode.zig    # バイトコード定義
│   └── emit.zig        # コード生成
│
├── vm/                 # Bytecode実行
│   └── vm.zig          # VMメインループ
│
├── runtime/            # 実行時サポート
│   ├── value.zig       # Value型
│   ├── var.zig         # Var
│   ├── namespace.zig   # Namespace
│   ├── env.zig         # グローバル環境
│   ├── context.zig     # 評価コンテキスト
│   ├── evaluator.zig   # TreeWalk評価器
│   ├── engine.zig      # Backend切り替え
│   └── allocators.zig  # 寿命別アロケータ
│
├── lib/                # Clojure標準ライブラリ
│   └── core.zig        # clojure.core 組み込み関数
│
└── main.zig            # CLI
```

---

## ロードマップ

### 完了フェーズ

#### Phase 1-4: 基盤構築 ✓
- Reader (Tokenizer, Form)
- Runtime基盤 (Value, Var, Namespace, Env)
- Analyzer (Node, special forms, シンボル解決)
- TreeWalk評価器

#### Phase 5: ユーザー定義関数 ✓
- fn クロージャ
- def された関数呼び出し

#### Phase 6: マクロシステム ✓
- defmacro
- Analyzer内での自動展開

#### Phase 7: CLI ✓
- `-e` オプション
- 複数式の連続評価
- 状態保持

#### Phase 8.0: VM基盤 ✓
- バイトコード定義 (OpCode約50個)
- Compiler (Node → Bytecode)
- スタックベースVM
- engine.zig (Backend切り替え、--compare)

#### Phase 8.1: クロージャ・関数完成 ✓
- VMでのクロージャ実行
- 複数アリティfn
- 可変長引数 (& rest)

#### Phase 8.2: 高階関数 ✓
- apply
- partial
- comp
- reduce

---

### 進行中・今後のフェーズ

#### Phase 8.3: 分配束縛 (Destructuring) ← 次の最優先

Clojureの実用性に直結。これがないと多くのコードが書けない。

```clojure
;; ベクター分配
(let [[a b c] [1 2 3]] ...)
(fn [[x y] z] ...)

;; マップ分配
(let [{:keys [name age]} person] ...)
(fn [{:keys [x y] :as point}] ...)

;; ネスト分配
(let [[a [b c]] [[1 2] [3 4]]] ...)
```

**必要な変更**:
- Analyzer: let, fn 引数の分配パターン解析
- 新Node: DestructureBindingNode
- Evaluator/VM: 分配バインディング処理

#### Phase 8.4: 遅延シーケンス (Lazy Sequences)

map, filter, take など基本的なシーケンス操作の前提。

```clojure
(take 5 (range))           ; 無限シーケンスから5つ
(map inc [1 2 3])          ; 遅延変換
(filter even? (range 100)) ; 遅延フィルタ
```

**必要な変更**:
- Value: LazySeq型追加
- lazy-seq マクロ / cons 関数
- realize / force 処理
- ISeq プロトコル相当の実装

#### Phase 8.5: プロトコル (Protocols)

型ベースの多態性。多くのコア関数の拡張性がこれに依存。

```clojure
(defprotocol ILookup
  (get [this key]))

(extend-type PersistentVector
  ILookup
  (get [this key] (nth this key)))
```

**必要な変更**:
- Value: Protocol型追加
- defprotocol, extend-type 特殊形式
- 型→プロトコル実装のディスパッチテーブル

#### Phase 9: GC

遅延シーケンス導入後に必須となる。

- Mark-Sweep GC
- Arena から移行
- ルート追跡（スタック、Var、クロージャ）

#### Phase 10: Wasm連携

言語機能が充実してから意味を持つ。

- Component Model対応
- .wasmロード・呼び出し
- 型マッピング (Clojure ↔ Wasm)

---

## 現在の実装状況

### 組み込み関数 (core.zig)

```
算術:      +, -, *, /
比較:      =, <, >, <=, >=
述語:      nil?, number?, integer?, float?, string?, keyword?,
           symbol?, fn?, coll?, list?, vector?, map?, set?, empty?
コレクション: first, rest, cons, conj, count, nth, list, vector
出力:      println, pr-str
```

### 特殊形式 (Analyzer)

```
制御:      if, do, let, loop, recur
関数:      fn, def, defmacro
引用:      quote
高階:      apply, partial, comp, reduce
```

### 未実装の重要機能

| 機能 | 影響度 | 依存関係 |
|------|--------|----------|
| 分配束縛 | 高 | なし（すぐ着手可能） |
| 遅延シーケンス | 高 | map/filter/take に必須 |
| プロトコル | 高 | 型の拡張性に必須 |
| try/catch/finally | 中 | 例外処理 |
| Atom/Ref | 中 | 状態管理 |
| メタデータ | 低 | ^{:doc ...} 等 |
| マルチメソッド | 低 | 値ベースディスパッチ |

---

## VM設計

### 基本方針

- **スタックベース**: GCルート追跡が容易、Wasmと親和性あり
- **固定命令サイズ**: OpCode(u8) + operand(u16) = 3バイト
- **Clojure意味論のみ**: JVM詳細は実装しない

### OpCodeカテゴリ

| 範囲 | カテゴリ | 主なOpCode |
|-----|---------|-----------|
| 0x00-0x0F | 定数・リテラル | const_load, nil, true_val, false_val |
| 0x10-0x1F | スタック操作 | pop, dup, swap |
| 0x20-0x2F | ローカル変数 | local_load, local_store |
| 0x30-0x3F | クロージャ変数 | upvalue_load, upvalue_store |
| 0x40-0x4F | Var操作 | var_load, def, def_macro |
| 0x50-0x5F | 制御フロー | jump, jump_if_false, jump_if_true |
| 0x60-0x6F | 関数 | call, ret, closure, partial, comp, reduce |
| 0x70-0x7F | loop/recur | loop_start, recur |
| 0x80-0x8F | コレクション生成 | list_new, vec_new, map_new, set_new |
| 0x90-0x9F | コレクション操作 | nth, get, first, rest, conj, assoc, count |
| 0xA0-0xAF | 例外処理 | try_begin, catch_begin, finally_begin, throw_ex |
| 0xC0-0xCF | メタデータ | with_meta, meta |

---

## 参考資料

- 型設計: `docs/reference/type_design.md`
- Zigガイド: `docs/reference/zig_guide.md`
- 進捗メモ: `.claude/tracking/memo.md`
- sci: `~/Documents/OSS/sci`
- 本家Clojure: `~/Documents/OSS/clojure`
