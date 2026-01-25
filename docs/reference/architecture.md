# アーキテクチャ設計

ClojureWasmBeta の全体アーキテクチャ。
3フェーズ処理、バイトコードVM、GC、Wasm連携を含む。

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
│ src/compiler/ (将来)                                          │
│   Emit → Optimize → Bytecode                                  │
│   バイトコード生成と最適化                                    │
└──────────────────────────────────────────────────────────────┘
     ↓ Bytecode
┌──────────────────────────────────────────────────────────────┐
│ src/vm/ (将来)                                                │
│   VM → Value                                                  │
│   バイトコード実行                                            │
└──────────────────────────────────────────────────────────────┘
     ↓ Value
┌──────────────────────────────────────────────────────────────┐
│ src/wasm/ (将来)                                              │
│   Component Model 連携                                        │
│   .wasm ロード、関数呼び出し、型変換                          │
└──────────────────────────────────────────────────────────────┘
```

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
│   ├── reader.zig      # S式構築 (将来)
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

## 実装優先順位

1. **Phase 1**: Reader (tokenizer, reader, form) ← 現在
2. **Phase 2**: Runtime (value, var, namespace) + 簡易評価器
3. **Phase 3**: Analyzer (node, analyze, macroexpand)
4. **Phase 4**: lib/core.zig (基本関数)
5. **Phase 5**: VM (bytecode, vm)
6. **Phase 6**: GC (mark-sweep)
7. **Phase 7**: Wasm Component Model

## 参考資料

- 型設計: `docs/reference/type_design.md`
- エラー設計: `docs/reference/error_design.md`
- Zig ガイド: `docs/reference/zig_guide.md`
- sci: `~/Documents/OSS/sci`
- 本家 Clojure: `~/Documents/OSS/clojure`
