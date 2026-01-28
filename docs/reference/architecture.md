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
│ src/wasm/ (zware ベース)                                      │
│   .wasm ロード、関数呼び出し、型変換                         │
│   メモリ操作、ホスト関数、WASI サポート                      │
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

### コア vs ライブラリの区別

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
│   ├── value.zig       # Value型 (facade + 3 サブモジュール)
│   ├── var.zig         # Var
│   ├── namespace.zig   # Namespace
│   ├── env.zig         # グローバル環境
│   ├── context.zig     # 評価コンテキスト
│   ├── evaluator.zig   # TreeWalk評価器
│   ├── engine.zig      # Backend切り替え
│   └── allocators.zig  # 寿命別アロケータ
│
├── lib/                # Clojure標準ライブラリ
│   ├── core.zig        # clojure.core facade (re-export)
│   └── core/           # ドメイン別サブモジュール (19ファイル)
│
├── wasm/               # Wasm 連携 (zware)
│   ├── types.zig       # Value ↔ Wasm 型変換
│   ├── loader.zig      # .wasm ロード + インスタンス化
│   ├── runtime.zig     # invoke / exports
│   ├── interop.zig     # 文字列/メモリ変換
│   ├── host_functions.zig # ホスト関数ブリッジ
│   └── wasi.zig        # WASI サポート
│
├── clj/                # Clojure ソースライブラリ
│   └── clojure/        # clojure.* 名前空間 (.clj)
│
├── repl/               # REPL サポート
│   └── line_editor.zig # readline/履歴 (自前実装)
│
├── nrepl/              # nREPL サーバー
│   ├── bencode.zig     # bencode エンコード/デコード
│   └── server.zig      # TCP サーバー + セッション + ops
│
├── gc/                 # GC (セミスペース Arena)
│   ├── gc.zig          # Mark フェーズ
│   ├── gc_allocator.zig # Arena セミスペース Sweep
│   └── tracing.zig     # Fixup (ポインタ更新)
│
├── regex/              # 正規表現 (フルスクラッチ)
│   ├── regex.zig       # パーサ+コンパイラ
│   └── matcher.zig     # バックトラッキング実行
│
└── main.zig            # CLI (REPL, -e, file.clj, --dump-bytecode, --nrepl-server)
```

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

- ロードマップ: `plan/roadmap.md`
- 完了履歴: `docs/changelog.md`
- 型設計: `docs/reference/type_design.md`
- Zigガイド: `docs/reference/zig_guide.md`
- メモリ戦略: `docs/reference/memory_strategy.md`
- エラー設計: `docs/reference/error_design.md`
- 進捗メモ: `plan/memo.md`
- 技術ノート: `plan/notes.md`
- 実装状況: `status/vars.yaml`
