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

Clojureでは多くの「標準関数」が実際にはコア実装を要求する。

| 区分 | 例 | 追加方法 |
|------|-----|---------|
| **純粋なlib追加** | println, str, subs | core.zig に関数追加のみ |
| **コア改修必要** | map, filter, reduce | LazySeq型 + 新Node + VM対応 |
| **新しい抽象** | defprotocol, defrecord | Value型拡張 + Analyzer + VM |

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

### 完了フェーズ (Phase 1 - 8.16)

| Phase | 内容 |
|-------|------|
| 1-4 | Reader, Runtime基盤, Analyzer, TreeWalk評価器 |
| 5 | ユーザー定義関数 (fn, クロージャ) |
| 6 | マクロシステム (defmacro) |
| 7 | CLI (-e, 複数式, 状態保持) |
| 8.0 | VM基盤 (Bytecode, Compiler, VM, --compare) |
| 8.1 | クロージャ完成, 複数アリティfn, 可変長引数 |
| 8.2 | 高階関数 (apply, partial, comp, reduce) |
| 8.3 | 分配束縛（シーケンシャル・マップ） |
| 8.4 | シーケンス操作 (map, filter, take, drop, range 等) |
| 8.5 | 制御フローマクロ・スレッディングマクロ |
| 8.6 | try/catch/finally 例外処理 |
| 8.7 | Atom 状態管理 |
| 8.8 | 文字列操作拡充 |
| 8.9 | defn・dotimes・doseq・if-not・comment |
| 8.10 | condp・case・some->・some->>・as->・mapv・filterv |
| 8.11 | キーワードを関数として使用 |
| 8.12 | every?/some/not-every?/not-any? |
| 8.13 | バグ修正・安定化 |
| 8.14 | マルチメソッド (defmulti, defmethod) |
| 8.15 | プロトコル (defprotocol, extend-type, extend-protocol) |
| 8.16 | ユーティリティ関数・HOF・マクロ拡充 |

### 今後のフェーズ

#### Phase 9: LazySeq（真の遅延シーケンス）

現在の map/filter は Eager 実装。無限シーケンスに対応するには遅延評価が必要。

- Value: LazySeq型追加
- lazy-seq マクロ / cons 関数
- realize / force 処理
- ISeq プロトコル相当の実装

#### Phase 10: GC

遅延シーケンス導入後に必須となる。

- Mark-Sweep GC
- Arena から移行
- ルート追跡（スタック、Var、クロージャ）

#### Phase 11: Wasm連携

言語機能が充実してから意味を持つ。

- Component Model対応
- .wasmロード・呼び出し
- 型マッピング (Clojure ↔ Wasm)

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
- 技術ノート: `.claude/tracking/notes.md`
- 実装状況: `status/vars.yaml`
- sci: `~/Documents/OSS/sci`
- 本家Clojure: `~/Documents/OSS/clojure`
