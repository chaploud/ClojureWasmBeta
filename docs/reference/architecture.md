# アーキテクチャ設計

ClojureWasmBeta の全体アーキテクチャ。
ツリーウォーク評価器から始め、将来的にバイトコードVM、GC、Wasm連携へ拡張。

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
│ src/runtime/                                                  │
│   TreeWalkEval (Phase 4) または VMEval (Phase 8)              │
│   Node を評価して Value を生成                                │
└──────────────────────────────────────────────────────────────┘
     ↓ Value
┌──────────────────────────────────────────────────────────────┐
│ src/wasm/ (将来)                                              │
│   Component Model 連携                                        │
│   .wasm ロード、関数呼び出し、型変換                          │
└──────────────────────────────────────────────────────────────┘
```

## 設計方針: ツリーウォーク → バイトコードVM

最初はツリーウォーク型インタプリタで実装し、後にバイトコードVMへ移行する。

**ツリーウォークを先にする理由:**
- 実装がシンプルでデバッグしやすい
- Clojure の正しい振る舞いを確認しやすい
- sci（Small Clojure Interpreter）も同様のアプローチ

**二度手間を避ける設計:**
```
Form → Analyzer → Node → [eval インターフェース] → Value
                              ↑
                    ┌─────────┴─────────┐
                    │                   │
              TreeWalkEval          VMEval
              (Phase 4)            (Phase 8)
```

- Analyzer (Form → Node) は共通
- eval を抽象化し、後から差し替え可能に

## ディレクトリ構成

```
src/
├── base/               # 共通基盤
│   ├── error.zig       # エラー型
│   ├── allocator.zig   # アロケータ抽象化 (将来)
│   └── intern.zig      # 文字列インターニング (将来)
│
├── reader/             # Phase 1: Source → Form
│   ├── tokenizer.zig   # トークン化
│   ├── reader.zig      # S式構築
│   └── form.zig        # Form型定義
│
├── analyzer/           # Phase 2: Form → Node
│   ├── node.zig        # Node型定義
│   ├── analyze.zig     # 解析メイン (将来)
│   └── macroexpand.zig # マクロ展開 (将来)
│
├── compiler/           # Phase 3a: Node → Bytecode (将来)
│   ├── bytecode.zig    # バイトコード定義
│   ├── emit.zig        # コード生成
│   └── optimize.zig    # 最適化パス
│
├── vm/                 # Phase 3b: Bytecode 実行 (将来)
│   ├── vm.zig          # VMメインループ
│   ├── stack.zig       # 値スタック
│   └── ops.zig         # オペコード実装
│
├── runtime/            # 実行時サポート
│   ├── value.zig       # Value型
│   ├── var.zig         # Var
│   ├── namespace.zig   # Namespace
│   ├── env.zig         # グローバル環境
│   └── context.zig     # 評価コンテキスト
│
├── gc/                 # ガベージコレクション (将来)
│   ├── gc.zig          # GCインターフェース
│   ├── arena.zig       # Arenaアロケータ
│   └── tracing.zig     # Mark-Sweep GC
│
├── wasm/               # Wasm Component Model (将来)
│   ├── loader.zig      # .wasmロード
│   ├── component.zig   # Component API
│   ├── types.zig       # 型マッピング
│   └── call.zig        # 関数呼び出しブリッジ
│
└── lib/                # Clojure 標準ライブラリ
    ├── core.zig        # clojure.core
    ├── string.zig      # clojure.string (将来)
    └── set.zig         # clojure.set (将来)
```

## コンポーネント詳細

### Reader (src/reader/)

ソースコードを Form（構文木）に変換。

- **Tokenizer**: 文字列 → トークン列
- **Reader**: トークン列 → Form
- **Form**: 構文表現（Symbol, List, Vector, etc.）

### Analyzer (src/analyzer/)

Form を実行可能な Node に変換。

- **マクロ展開**: マクロを展開
- **シンボル解決**: Var/ローカル変数を解決
- **構文解析**: special form (if, let, fn, etc.) を Node に

### Compiler (src/compiler/) [将来]

Node からバイトコードを生成。

- **Emit**: Node → Bytecode
- **Optimize**: 定数畳み込み、TCO、デッドコード除去

### VM (src/vm/) [将来]

バイトコードを実行するスタックベースVM。

- **値スタック**: 演算のためのスタック
- **コールフレーム**: 関数呼び出し管理
- **オペコード**: 各命令の実装

### GC (src/gc/) [将来]

メモリ管理。

| 戦略 | 特徴 | 用途 |
|------|------|------|
| Arena | 一括解放、シンプル | 初期実装、短命オブジェクト |
| Mark-Sweep | 到達可能性ベース | 長時間実行 |
| Generational | 世代別 | 高性能（将来） |

### Wasm Component Model (src/wasm/) [将来]

.wasm ファイルをロードして Clojure から呼び出し。

```clojure
;; Clojure での使用例
(def math (wasm/load "math.wasm"))
(wasm/call math "add" 1 2)  ; => 3
(wasm/exports math)         ; => ["add" "sub" "mul" "div"]

;; 型マッピング
;; Clojure int    → Wasm i64
;; Clojure float  → Wasm f64
;; Clojure string → Wasm string
;; Clojure vector → Wasm list<T>
```

**双方向呼び出し:**
- Clojure → Wasm: `wasm/call`
- Wasm → Clojure: インポート関数として Clojure 関数を公開

## 依存関係

```
base ←─────────────────────────────────────────────────┐
  ↑                                                    │
reader ←── analyzer ←── compiler ←── vm               │
              ↑                       ↑                │
              └───── runtime ─────────┴── gc ──────────┤
                        ↑                              │
                      wasm ────────────────────────────┘
                        ↑
                       lib
```

## ロードマップ

### Phase 1: Reader ✓
- [x] Tokenizer
- [x] Form 設計
- [x] Reader（S式構築）

### Phase 2: Runtime 基盤 ✓
- [x] Value 型
- [x] Var, Namespace
- [x] Env（グローバル環境）

### Phase 3: Analyzer ✓
- [x] Node 型
- [x] special forms（if, let, fn, def, do, quote, loop, recur）
- [x] シンボル解決

### Phase 4: ツリーウォーク評価器 ✓
- [x] Context（ローカルバインディング管理）
- [x] Evaluator 実装
- [x] 組み込み関数（算術、比較、述語、コレクション、出力）

### Phase 5: ユーザー定義関数 ✓
- [x] 統合テスト（Reader → Analyzer → Evaluator）
- [x] ユーザー定義関数（fn クロージャ実装）
- [x] def された関数の呼び出し

### Phase 6: マクロシステム ✓
- [x] defmacro
- [x] macroexpand（Analyzer内で自動展開）
- [x] Analyzer 拡張（マクロ展開）

### Phase 7: CLI ✓
- [x] `-e` オプション（式評価）
- [x] 複数式の連続評価
- [x] 状態保持（def の値を次の -e で使用可能）

### Phase 8: Compiler + VM (進行中)
- [x] バイトコード定義（OpCode, Instruction, Chunk, FnProto）
- [x] Emit（Node → Bytecode）- Compiler 構造体
- [x] VM 実装（基盤）- スタックベース、フレーム管理
- [x] OpCode 完全設計（約50個、カテゴリ別予約）

#### Phase 8.0.5: 評価エンジン抽象化（次）
- [ ] engine.zig 新設（Backend切り替え）
- [ ] CLI --backend オプション
- [ ] テスト統合（両バックエンドで実行・比較）
- [ ] ベンチマーク対応（リリースビルド直接実行）

#### Phase 8.1: クロージャ完成
- [ ] upvalue_load, upvalue_store
- [ ] ユーザー定義関数の VM 実行

#### Phase 8.2: コレクションリテラル
- [ ] vec_new, map_new, set_new, list_new

#### Phase 8.3: 末尾呼び出し最適化
- [ ] tail_call, apply

### Phase 9: GC
- [ ] Mark-Sweep GC
- [ ] Arena から移行

### Phase 10: Wasm 連携
- [ ] Component Model 対応
- [ ] .wasm ロード・呼び出し
- [ ] 型マッピング（Clojure ↔ Wasm）

### 後回し
- **互換性テスト基盤** - 本家 Clojure との入出力比較
- **REPL** - Phase 7 以降、必要に応じて

---

## マクロシステムについて

マクロ展開には循環依存がある:
- `macroexpand` にはマクロ関数の **eval** が必要
- `analyze` には `macroexpand` が必要

**解決策:** Phase 3 では special forms のみ対応し、Phase 6 でマクロを追加。
基本的な eval が動いてからマクロシステムを導入する。

---

## CLI について

本家 `clj` コマンドの挙動を参考にする:

```bash
clj -M -e "(def x 10)" -e "(+ x 5)"
# => #'user/x
# => 15

clj -M -e "(do (println \"hello\") 42)"
# => hello
# => 42
```

- 各 `-e` の評価値を出力
- 副作用（println 等）は発生時に出力
- 複数 `-e` 間で状態保持

---

## VM 設計

### 設計方針

**スタックベース VM** を採用（レジスタマシンではない）。

| 選択 | 理由 |
|-----|------|
| スタックベース | GC ルート追跡が容易、Wasm と親和性あり |
| 固定命令サイズ | OpCode(u8) + operand(u16) = 3バイト |
| JVM 非互換 | Clojure 意味論のみ実装、JVM 詳細は不要 |

**参考にしたもの:**
- Lua 5.x（スタックベース、シンプル）
- "Crafting Interpreters"（Chunk 構造、ジャンプパッチング）
- Python bytecode（定数テーブル）

**参考にしないもの:**
- JVM bytecode（複雑、クラスベース OOP 前提）
- LuaJIT（レジスタマシン、JIT 前提）
- V8（JIT 前提、hidden class など不要）

### OpCode カテゴリ

| 範囲 | カテゴリ | 用途 |
|-----|---------|------|
| 0x00-0x0F | 定数・リテラル | nil, true, false, 定数ロード |
| 0x10-0x1F | スタック操作 | pop, dup, swap |
| 0x20-0x2F | ローカル変数 | let バインディング |
| 0x30-0x3F | クロージャ変数 | upvalue（外側スコープ参照） |
| 0x40-0x4F | Var 操作 | def, Var 参照、動的バインディング |
| 0x50-0x5F | 制御フロー | jump, 条件分岐 |
| 0x60-0x6F | 関数 | call, ret, closure, tail_call |
| 0x70-0x7F | loop/recur | Clojure 特有のループ |
| 0x80-0x8F | コレクション生成 | [], {}, #{} リテラル |
| 0x90-0x9F | コレクション操作 | nth, get, conj 等（将来最適化） |
| 0xA0-0xAF | 例外処理 | try/catch/finally |
| 0xC0-0xCF | メタデータ | with-meta, meta |
| 0xF0-0xFF | 予約・デバッグ | nop, debug |

### 実装ロードマップ

```
Phase 8.0 (完了): 基本 OpCode（20個）
  - 定数、スタック、ローカル、Var、制御フロー、関数基本

Phase 8.1: クロージャ完成
  - upvalue_load, upvalue_store
  - クロージャキャプチャ処理

Phase 8.2: コレクションリテラル
  - vec_new, map_new, set_new, list_new

Phase 8.3: 末尾呼び出し最適化
  - tail_call, apply

Phase 9 (GC 後): 例外処理
  - try_begin, catch_begin, finally_begin, throw_ex

Phase 10: メタデータ
  - with_meta, meta
```

### Wasm 連携との親和性

Wasm もスタックベース VM のため、設計上の親和性が高い。

```
Clojure Value ←→ Wasm 型変換レイヤー ←→ Wasm Component
```

- OpCode 追加なし: Wasm 関数は組み込み関数として登録
- `call` OpCode で統一的に呼び出し可能

### 組み込み関数 vs OpCode

頻出操作は OpCode 化を検討するが、基本は組み込み関数で実装。

| 操作 | 方針 | 理由 |
|-----|------|------|
| +, -, *, / | 組み込み関数 | 多態性（数値型ごと）が必要 |
| nth, get | 将来 OpCode 化 | 頻出だが、まず組み込みで |
| first, rest | 将来 OpCode 化 | シーケンス操作の中核 |
| conj, assoc | 組み込み関数 | コレクション型で振る舞いが異なる |

---

## 参考資料

- 型設計: `docs/reference/type_design.md`
- エラー設計: `docs/reference/error_design.md`
- Zig ガイド: `docs/reference/zig_guide.md`
- sci: `~/Documents/OSS/sci`
- 本家 Clojure: `~/Documents/OSS/clojure`
