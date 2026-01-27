# アーキテクチャ設計

ClojureWasmBeta の全体アーキテクチャ。
ツリーウォーク評価器から始め、バイトコードVM、データ抽象層、GC、Wasm連携へ拡張。

## 処理フロー

```
Source Code
     ↓
┌──────────────────────────────────────────────────────────────┐
│ src/reader/                                                  │
│   Tokenizer → Reader → Form                                  │
│   ソースコードを構文木(Form)に変換                           │
└──────────────────────────────────────────────────────────────┘
     ↓ Form
┌──────────────────────────────────────────────────────────────┐
│ src/analyzer/                                                │
│   Analyzer → Node                                            │
│   マクロ展開、シンボル解決、構文解析                         │
└──────────────────────────────────────────────────────────────┘
     ↓ Node
┌──────────────────────────────────────────────────────────────┐
│ src/compiler/ + src/runtime/                                 │
│   TreeWalkEval または Compiler → VM                          │
│   Node を評価/実行して Value を生成                          │
└──────────────────────────────────────────────────────────────┘
     ↓ Value
┌──────────────────────────────────────────────────────────────┐
│ src/wasm/ (将来)                                             │
│   Component Model 連携                                       │
│   .wasm ロード、関数呼び出し、型変換                         │
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
              TreeWalkEval          Compiler
              (正確性重視)              ↓
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
| 区分              | 例                     | 追加方法                    |
|-------------------|------------------------|-----------------------------|
| **純粋なlib追加** | println, str, subs     | core.zig に関数追加のみ     |
| **コア改修必要**  | map, filter, reduce    | LazySeq型 + 新Node + VM対応 |
| **新しい抽象**    | defprotocol, defrecord | Value型拡張 + Analyzer + VM |

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

| Phase    | 内容                                                                                                                      |
|----------|---------------------------------------------------------------------------------------------------------------------------|
| 1-4      | Reader, Runtime基盤, Analyzer, TreeWalk評価器                                                                             |
| 5        | ユーザー定義関数 (fn, クロージャ)                                                                                         |
| 6        | マクロシステム (defmacro)                                                                                                 |
| 7        | CLI (-e, 複数式, 状態保持)                                                                                                |
| 8.0      | VM基盤 (Bytecode, Compiler, VM, --compare)                                                                                |
| 8.1-8.20 | VM機能拡充（クロージャ、HOF、シーケンス、マクロ、例外、Atom、文字列、マルチメソッド、プロトコル、letfn、動的リテラル 等） |
| 9-9.2    | LazySeq — 遅延シーケンス基盤、遅延 map/filter/concat、遅延ジェネレータ                                                    |
| 11-18b   | PURE+DESIGN — 組み込み関数 (delay/volatile/reduced/transient/transduce/atom拡張/var操作/階層/promise等)                   |
| 19a-19c  | struct/eval/read-string/sorted/dynamic-vars/NS操作/Reader/定義マクロ                                                      |
| 20       | FINAL — binding/chunk/regex/IO/NS/defrecord/deftype/動的Var                                                               |
| 21       | GC — Mark-Sweep at Expression Boundary                                                                                    |
| 22       | 正規表現エンジン (フルスクラッチ Zig 実装)                                                                                |
| 23       | 動的バインディング (本格実装)                                                                                             |
| 24       | 名前空間 (本格実装)                                                                                                       |
| 25       | REPL (対話型シェル)                                                                                                       |
| 26       | Reader Conditionals + 外部ライブラリ統合テスト (medley v1.4.0)                                                            |
| T1-T4    | テストフレームワーク + sci テストスイート移植 (678 pass)                                                                   |

> 詳細な完了フェーズ履歴: `.claude/tracking/memo.md`

### 今後のフェーズ

#### Phase Q: Wasm 前品質修正 (進行中)

テスト移植 (Phase T4) で発見された問題を Wasm 連携前に全て解消する。

| Sub   | 内容                                         | 複雑度 |
|-------|----------------------------------------------|--------|
| Q3    | Var システム修正 (def返値, #'var, var-set等)  | 低     |
| Q4a   | VM reduced 対応                              | 低     |
| Q2b   | fn-level recur 修正                          | 中     |
| Q1a   | Special Form 正規化 — eager 7関数            | 高     |
| Q1b   | Special Form 正規化 — lazy 5関数             | 高     |
| Q2a   | Map/Set リテラルの関数内コンパイル修正       | 中     |
| Q4b   | letfn 相互再帰修正                           | 中     |
| Q1c   | 死コード削除 (12 Node/Opcode)                | 中     |
| Q5    | with-out-str + 文字列表示                    | 高     |
| Q6    | ドキュメント整備 + ベンチマーク基盤          | 低     |

#### Phase LAST: Wasm 連携

言語機能充実後。Component Model 対応、.wasm ロード・呼び出し、型マッピング。

---

## VM設計

### 基本方針

- **スタックベース**: GCルート追跡が容易、Wasmと親和性あり
- **固定命令サイズ**: OpCode(u8) + operand(u16) = 3バイト
- **Clojure意味論のみ**: JVM詳細は実装しない

### OpCodeカテゴリ

| 範囲      | カテゴリ         | 主なOpCode                                      |
|-----------|------------------|-------------------------------------------------|
| 0x00-0x0F | 定数・リテラル   | const_load, nil, true_val, false_val            |
| 0x10-0x1F | スタック操作     | pop, dup, swap                                  |
| 0x20-0x2F | ローカル変数     | local_load, local_store                         |
| 0x30-0x3F | クロージャ変数   | upvalue_load, upvalue_store                     |
| 0x40-0x4F | Var操作          | var_load, def, def_macro                        |
| 0x50-0x5F | 制御フロー       | jump, jump_if_false, jump_if_true               |
| 0x60-0x6F | 関数             | call, ret, closure, partial, comp, reduce       |
| 0x70-0x7F | loop/recur       | loop_start, recur                               |
| 0x80-0x8F | コレクション生成 | list_new, vec_new, map_new, set_new             |
| 0x90-0x9F | コレクション操作 | nth, get, first, rest, conj, assoc, count       |
| 0xA0-0xAF | 例外処理         | try_begin, catch_begin, finally_begin, throw_ex |
| 0xC0-0xCF | メタデータ       | with_meta, meta                                 |

---

## 参考資料

- 型設計: `docs/reference/type_design.md`
- Zigガイド: `docs/reference/zig_guide.md`
- 進捗メモ: `.claude/tracking/memo.md`
- 技術ノート: `.claude/tracking/notes.md`
- 実装状況: `status/vars.yaml`
- sci: `~/Documents/OSS/sci`
- 本家Clojure: `~/Documents/OSS/clojure`
