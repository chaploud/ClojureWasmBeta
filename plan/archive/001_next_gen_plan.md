# ClojureWasm 次世代設計プラン

> このドキュメントは設計議論用。何往復かで詰めていく。
> 最終更新: 2026-01-25

---

## 背景: 3プロジェクトの反省

| プロジェクト | 方針 | 現状 | 反省点 |
|-------------|------|------|--------|
| SandboxClojureWasm | Zig中心、prelude.clj(1038行)でマクロ | 314テスト、GC実装済み | 本家互換性の担保が曖昧 |
| ClojureWasmPre | 本家core.cljをそのままロード | 学習プロジェクト | 「カスタムcore.cljは全て技術的負債」という強い方針 |
| ClojureWasmAlpha | 本家core.cljをそのままロード | 986行/8229行、100テスト | JavaInterOpを大量再実装することに |

**共通の矛盾**: ClojureWasmPre/Alphaは「JavaInterOp排除」と言いながら、本家core.cljをロードするためにJavaInterOpをZigで再実装している

---

## 設計上の論点（未解決）

### 1. 本家互換性の定義

**Q: 「正しいClojureの動き」とは何か？**

- [ ] 動作互換（ブラックボックス）: 同じ入力→同じ出力
- [ ] 実装互換（ホワイトボックス）: 本家.cljがそのまま動く

**本家のテストスイートは使えるか？**
```
clojure/test/clojure/test_clojure/
├── agents.clj        # JVM固有（並行処理）
├── atoms.clj         # 使える
├── control.clj       # 使える
├── data_structures.clj  # 使える
├── fn.clj            # 使える
├── for.clj           # 使える
├── ...
総計: 14,328行
```

**調査が必要:**
- [ ] どのテストがJVM非依存か分類
- [ ] 互換テストとして流用可能か
- [ ] テストフレームワーク(clojure.test)の実装コスト

**cljdocや他のソースからテストケースを生成できるか？**
- cljdocのコード例
- 4clojure問題
- Exercism Clojureトラック

---

### 2. JavaInterOp排除の範囲

**Q: 何を残し、何を捨てるか？**

本家core.cljの依存関係:
```clojure
;; 必須（言語機能）
(. clojure.lang.RT (seq coll))      ; シーケンス抽象
(. clojure.lang.Numbers (add x y))  ; 算術

;; JVM固有（代替必要）
(. clojure.lang.Reflector invokeInstanceMethod ...)  ; リフレクション
(java.util.concurrent.* ...)        ; 並行処理

;; 不要（Wasm向け）
(java.io.* ...)                     ; JavaのI/O
```

---

### 3. セルフホスティングの境界

**Q: どこまでZig、どこから.clj？**

```
理想的な階層:
┌─────────────────────────────────────┐
│  clojure.core（.cljでセルフホスト）  │  ← マクロ、高レベル関数
├─────────────────────────────────────┤
│  プリミティブ層（Zig）               │  ← if, let, fn, def, +, -, cons, first...
├─────────────────────────────────────┤
│  VM / ランタイム（Zig）              │  ← 評価器、GC、永続データ構造
└─────────────────────────────────────┘
```

**本家core.cljをどう扱うか選択肢:**

A. そのままロード（現状）→ JavaInterOp地獄
B. 改変してロード → 変更追従が複雑
C. 参照のみ、独自実装 → 互換性担保が手動
D. 本家テストで動作検証、実装は独自 → テスト駆動

---

### 4. 変更追従戦略

**Q: 本家Clojureの更新にどう追従するか？**

本家の変更パターン:
- core.cljへの関数追加 → 比較的追従しやすい
- 既存関数の修正 → 挙動変更の検出が難しい
- Java側の変更 → 対応不要（JavaInterOp排除）

**案:**
- 本家のテストスイートを定期実行
- diffで変更検出、影響範囲を特定
- セマンティックバージョニングで互換性レベルを明示

---

### 5. 高速性のための設計

**Q: バイトコードVM、GC、最適化を前提とした設計か？**

現状のClojureWasmAlpha:
- [ ] バイトコードVM → 未実装（ASTインタプリタ）
- [ ] GC → 未実装（Arenaのみ）
- [ ] 最適化 → 未実装

SandboxClojureWasm:
- [x] GC（Mark-Sweep Phase 2）
- [ ] バイトコードVM → 未実装

**処理系の高速化オプション:**
1. バイトコードコンパイル（Python, Lua方式）
2. トレーシングJIT
3. 型特殊化
4. インライン化
5. 永続データ構造の最適化（トランジェント）

---

### 6. Zig 0.15.2らしい設計

**Q: 処理系開発的なZigのベストプラクティスは？**

- アロケータ戦略（Arena vs General Purpose）
- エラーハンドリング（error union）
- Tagged Union（Value型）
- コンパイル時計算（comptime）
- SIMD最適化（将来）

---

### 7. REPL・エラーメッセージ

**Q: 本家より充実させるとは？**

- Babashka風のエラー表示（ソース位置、コンテキスト）
- スタックトレースの可読性
- 補完、ヘルプ
- 履歴、編集

---

### 8. ファイル配置・ディレクトリ構成

**Q: 理想的なプロジェクト構造は？**

```
clojure-wasm/
├── src/
│   ├── vm/           # バイトコードVM
│   ├── gc/           # ガベージコレクタ
│   ├── lang/         # Value, 永続データ構造
│   ├── reader/       # パーサー
│   ├── compiler/     # バイトコードコンパイラ
│   └── runtime/      # 組み込み関数
├── clj/
│   ├── core.clj      # セルフホスト部分（改変版 or 独自）
│   └── string.clj
├── test/
│   ├── zig/          # Zigユニットテスト
│   ├── clj/          # Clojure互換テスト
│   └── compat/       # 本家互換性テスト
└── docs/
    └── design/       # 設計ドキュメント
```

---

## 次のステップ

1. [ ] 各論点について議論・決定
2. [ ] 本家テストスイートの調査
3. [ ] アーキテクチャ設計
4. [ ] プロトタイプ or 既存コードの改修方針

---

## 議論ログ

### Round 1 (2026-01-25)

**ユーザーの問題意識:**

1. 「JavaInterOpは排除」と言いながら、実際はZigで再実装している矛盾
2. 本家core.cljの変更追従が困難
3. むしろcore.cljを改変してZigに都合の良いようにした方がいいのでは？
4. sciのようにブラックボックス的に動作互換を担保する方がよいのでは？
5. 将来のWasm Component Modelを見据えると、今JavaInterOp再実装する意味は薄い

**参照プロジェクトの調査結果:**

- **sci**: Clojure/ClojureScriptで書かれたインタプリタ。`copy-var`でホスト関数をコピー、マクロは手書き。本家core.cljは使わない。
- **babashka**: sciベース + GraalVM native-image。
- **SandboxClojureWasm**: Zig実装。1038行のprelude.cljでマクロ定義、関数はZig。314テスト、GC実装済み。

**未決定事項:**

- 動作互換 vs 実装互換、どちらを目指すか
- 本家テストスイートをどう活用するか
- フルスクラッチか既存改修か

---

### Round 2 (2026-01-25)

**Claudeの分析と提案:**

#### 1. 動作互換 vs 実装互換 → **動作互換を推奨**

理由:
- **JavaInterOp再実装は底なし**: core.cljは8229行、その背後に膨大なJavaクラスがある
- **sci/babashkaの成功例**: 動作互換路線で実用的なツールになっている
- **Wasm Component Model**: 将来的にはWasm標準インターフェースで外部連携するため、JavaInterOp再実装は無駄になる
- **保守性**: 本家core.cljの変更に追従する必要がなくなる

```
動作互換の定義:
(+ 1 2)         → 3           ✓ 同じ結果
(map inc [1 2]) → (2 3)       ✓ 同じ結果
(defmacro ...)  → マクロ定義  ✓ 同じ構文

実装の中身は問わない（RT.javaを再実装する必要なし）
```

#### 2. アーキテクチャ提案 → **Option D（テスト駆動）+ 改良**

```
┌─────────────────────────────────────────────────────┐
│  clojure.core (独自 core.clj)                        │
│  - マクロ: defn, when, cond, let, loop, etc.        │
│  - 高レベル関数: map, filter, reduce, etc.          │
│  ※ 本家core.cljを「参照」して同じ動作を実装         │
├─────────────────────────────────────────────────────┤
│  プリミティブ関数 (Zig)                              │
│  - cons, first, rest, nth, count                    │
│  - +, -, *, /, <, >, =                              │
│  - assoc, dissoc, get, contains?                    │
│  ※ clojure.lang.*を「模倣しない」直接実装           │
├─────────────────────────────────────────────────────┤
│  特殊形式 (Zig評価器)                                │
│  - if, do, let*, fn*, def, quote, var, .            │
│  - loop*, recur, try, throw                         │
├─────────────────────────────────────────────────────┤
│  VM / ランタイム (Zig)                               │
│  - 永続データ構造 (Vector, Map, Set)                 │
│  - GC (Mark-Sweep or Immix)                         │
│  - Reader / Printer                                  │
└─────────────────────────────────────────────────────┘
```

**重要な変更点:**
- `(. clojure.lang.RT ...)` 形式を使わない
- Zig側で `first`, `rest` 等を直接 `clojure.core` に登録
- core.cljはマクロと高レベル関数のみ定義

**メリット:**
- JavaInterOp再実装が不要
- core.cljが小さく保守しやすい（SandboxClojureWasmの1038行程度）
- 本家の変更に左右されない

**デメリット:**
- 本家core.cljとの差分管理が必要
- 動作互換のテストが重要になる

#### 3. テスト戦略

**Phase 1: 最小clojure.test実装**
```clojure
;; 必要な最小セット
(defmacro deftest [name & body] ...)
(defmacro is [form] ...)
(defmacro testing [msg & body] ...)
(defn run-tests [] ...)
```

**Phase 2: 本家テストスイートの分類**
```
JVM非依存（すぐ使える）:
- data_structures.clj (ベクタ、マップ、セット)
- fn.clj (関数定義)
- control.clj (制御構文)
- for.clj (forマクロ)
- sequences.clj (シーケンス操作)

JVM依存（対応必要）:
- agents.clj → 代替実装 or スキップ
- refs.clj → STMは後回し
- java_interop.clj → スキップ

I/O依存（Wasm対応必要）:
- reader.clj → 一部対応
- printer.clj → 一部対応
```

**Phase 3: 互換性テスト自動生成**
```bash
# 本家で実行した結果をキャプチャ
clj -M -e "(map inc [1 2 3])"  # => (2 3 4)

# ClojureWasmで実行して比較
zig build run -- -e "(map inc [1 2 3])"  # => (2 3 4) ✓
```

#### 4. 既存コードの活用

| コンポーネント | 採用元 | 理由 |
|---------------|--------|------|
| GC | SandboxClojureWasm | 既にMark-Sweep Phase 2実装済み |
| 永続データ構造 | ClojureWasmAlpha | 検証済み |
| Reader | ClojureWasmAlpha | 行・列トラッキング済み |
| エラー表示 | ClojureWasmAlpha | Babashka風実装済み |
| マクロ | SandboxClojureWasm prelude.clj | 1038行で動作確認済み |
| interop知見 | ClojureWasmAlpha | どのJavaクラスが必要か判明 |

**統合案:**
1. SandboxClojureWasmをベースにする
2. ClojureWasmAlphaのReader/エラー表示を移植
3. prelude.cljを本家互換テストで検証・拡張

#### 5. 未解決の質問（ユーザーへ）

1. **GCの優先度**: 今すぐ必要？それとも機能完成後？
2. **バイトコードVM**: ASTインタプリタのままでよいか？
3. **STM (ref, dosync)**: 必要か？Wasmでは使わない？
4. **並行処理 (agent, future)**: 必要か？Web Workerで代替？
5. **clojure.spec**: 必要か？後回し？

---

### Round 3 (次回)

**議論予定:**
- [ ] ユーザーからのフィードバック
- [ ] 優先順位の決定
- [ ] 具体的な移行計画

