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

### 完了フェーズ

| Phase | 内容 |
|-------|------|
| 1-4 | Reader, Runtime基盤, Analyzer, TreeWalk評価器 |
| 5 | ユーザー定義関数 (fn, クロージャ) |
| 6 | マクロシステム (defmacro) |
| 7 | CLI (-e, 複数式, 状態保持) |
| 8.0 | VM基盤 (Bytecode, Compiler, VM, --compare) |
| 8.1-8.20 | VM機能拡充（クロージャ、HOF、シーケンス、マクロ、例外、Atom、文字列、マルチメソッド、プロトコル、letfn、動的リテラル 等） |
| 9-9.2 | LazySeq — 遅延シーケンス基盤、遅延 map/filter/concat、遅延ジェネレータ |
| 11 | PURE バッチ — 述語(23)+コレクション/ユーティリティ(17)+ビット演算/HOF(17) = +57関数 |

> 詳細な完了フェーズ履歴: `.claude/tracking/memo.md`

### 今後のフェーズ

残り 243 todo を 4 層（PURE / DESIGN / SUBSYSTEM / JVM_ADAPT）に分類し、
設計不要の PURE → 新型が要る DESIGN → 新サブシステムの SUBSYSTEM の順で進める。
GC は旧計画で Phase 10 だったが、ArenaAllocator でバッチ実行に問題がないため
言語機能充実後（Phase 23）に延期。

#### Phase 12: PURE 残り（~55 件）

既存基盤の組み合わせで実装可能。設計不要。

- 述語: bytes?, class?, decimal?, ratio?, rational?, record? 等
- HOF: juxt, memoize, trampoline
- シーケンス: lazy-cat, tree-seq, partition-by, replicate
- 算術: *', +', -', dec', inc'（オーバーフロー安全）
- ユーティリティ: gensym, clojure-version, newline, printf, println-str
- ハッシュ: hash-combine, hash-ordered-coll, hash-unordered-coll, mix-collection-hash
- マルチメソッド拡張: get-method, methods, remove-method, remove-all-methods, prefer-method, prefers
- 型変換: char, byte, short, long, float, num, find-keyword, parse-uuid, random-uuid, comparator

#### Phase 13-18: DESIGN（~75 件）

新しいデータ構造・パターンが要るが、サブシステムは不要。

| Phase | 内容 |
|-------|------|
| 13 | delay/force, volatile, transient |
| 14 | reduced/transduce 基盤（Reduced ラッパー型、completing, cat, eduction） |
| 15 | Atom 拡張・Var 操作・メタデータ（watch, validator, var-get/set, alter-meta!） |
| 16 | defrecord・deftype・defstruct |
| 17 | 階層システム（derive, ancestors, descendants, isa?） |
| 18 | 動的束縛（binding, with-bindings）, sorted コレクション（赤黒木）, promise |

#### Phase 19-22: SUBSYSTEM（~100 件）

新しいサブシステムの構築が必要。

| Phase | 内容 |
|-------|------|
| 19 | 正規表現（re-find, re-matches, re-seq 等）— Zig に標準なし、要検討 |
| 20 | 名前空間システム（ns, require, use, refer, load 等）— マルチファイル対応 |
| 21 | I/O（slurp, spit, read-line, *in*/*out*/*err*, with-open 等） |
| 22 | Reader/Eval（read, read-string, eval, macroexpand 等）— セルフホスティング基盤 |

#### Phase 23: GC

ArenaAllocator でバッチ実行は問題なし。長時間 REPL 対応時に実装。

#### Phase LAST: Wasm 連携

言語機能充実後。Component Model 対応、.wasm ロード・呼び出し、型マッピング。

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
