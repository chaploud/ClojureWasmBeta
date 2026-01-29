# ZigによるClojure処理系の再実装ーWasmInterOpを添えて

Shibuya.lisp lispmeetup #117
2026/01/29 @株式会社スタディスト

---

## 時間配分

| # | セクション                 | 時間 |
|---|----------------------------|------|
| 1 | 導入: What & Why           | 2:00 |
| 2 | ライブデモ (Emacs+CIDER)   | 5:00 |
| 3 | アーキテクチャ概要         | 2:00 |
| 4 | エンジニアリングハイライト | 2:30 |
| 5 | ベンチマーク               | 1:30 |
| 6 | 未来/まとめ                | 2:00 |

---

## 自己紹介

- [@\_\_chaploud\_\_](https://x.com/__chaploud__)
- Clojure が好き。Zig も好き。
- Shibuya.lisp #113 で自作言語処理系 Sci-Lisp の紹介発表

---

## 1. ClojureWasmBeta とは (2:00)

Zig で Clojure 処理系をフルスクラッチ実装。JVM 不要、Wasm ネイティブ。

| 項目              | 内容                             |
|-------------------|----------------------------------|
| 言語              | Zig 0.15.2 (フルスクラッチ)      |
| テスト            | 1036 pass / 1 fail (意図的)      |
| clojure.core 実装 | 545 done / 169 skip              |
| ソースコード      | ~40,000 行 (src/ 以下)           |
| バックエンド      | TreeWalk + BytecodeVM (デュアル) |
| nREPL             | CIDER/Calva/Conjure 互換         |

### なぜ作ったか

- **JVM 脱却**: 起動 300ms+、メモリ 100MB+ から解放
- **JavaInterop → WasmInterop**: Java API 再実装地獄を避ける (Go 等の他言語 Wasm も呼べる)
- **全レイヤーを自分で**: Tokenizer → Reader → Analyzer → VM → GC → Wasm

### ポジショニング

| 特性        | Clojure (JVM) | Babashka       | ClojureWasm        |
|-------------|---------------|----------------|--------------------|
| ランタイム  | JVM           | GraalVM Native | Zig Native         |
| 起動時間    | 300-400ms     | 10-150ms       | 2-70ms             |
| メモリ      | 100-120MB     | 30-70MB        | 2-22MB             |
| WasmInterop | ×             | ×              | ○                  |
| 実装        | Java          | SCI (Clojure)  | Zig フルスクラッチ |

---

## 2. ライブデモ (5:00)

### Demo 1: REPL 基本 + 遅延シーケンス

```clojure
(+ 1 2 3)                    ;; => 6
(defn greet [name] (str "Hello, " name "!"))
(greet "Shibuya.lisp")       ;; => "Hello, Shibuya.lisp!"

(take 10 (filter odd? (range)))
;; => (1 3 5 7 9 11 13 15 17 19)

(->> (range 1 100) (filter #(zero? (mod % 3))) (map #(* % %)) (reduce +))
;; => 105876
```

### Demo 2: プロトコル + マルチメソッド

```clojure
(defprotocol Greetable (greet [this]))
(extend-type String Greetable
  (greet [this] (str "Hello, " this)))
(greet "Shibuya.lisp")       ;; => "Hello, Shibuya.lisp"

(defmulti area :shape)
(defmethod area :circle [{:keys [radius]}] (* 3.14159265 radius radius))
(area {:shape :circle :radius 5}) ;; => 78.5398...
```

### Demo 3: マクロ + アトム

```clojure
(defmacro unless [pred then else]
  (list 'if pred else then))
(unless false "yes" "no")    ;; => "yes"

(def counter (atom 0))
(dotimes [_ 5] (swap! counter inc))
@counter                      ;; => 5
```

### Demo 4: Wasm 連携

```clojure
(def math (wasm/load-module "test/wasm/fixtures/01_add.wasm"))
(wasm/invoke math "add" 3 4) ;; => 7

(wasm/invoke fib-mod "fib" 10) ;; => 55
```

### Demo 5: ホスト関数注入 (Clojure → Wasm コールバック)

```clojure
(def captured (atom []))
(defn my-print-i32 [n] (swap! captured conj n))

(def imports-mod
  (wasm/load-module "test/wasm/fixtures/04_imports.wasm"
    {:imports {"env" {"print_i32" my-print-i32 ...}}}))

(wasm/invoke imports-mod "compute_and_print" 3 7)
@captured ;; => [10]
```

### Demo 6: Go → Wasm (多言語連携)

```clojure
;; TinyGo でコンパイルした Go の Wasm をロード
(def go-math (wasm/load-wasi "test/wasm/fixtures/08_go_math.wasm"))
(wasm/invoke go-math "add" 3 4)       ;; => 7
(wasm/invoke go-math "fibonacci" 10)  ;; => 55

;; Clojure の高階関数で Go 関数を活用
(map #(wasm/invoke go-math "fibonacci" %) (range 1 11))
;; => (1 1 2 3 5 8 13 21 34 55)
```

---

## 3. アーキテクチャ概要 (2:00)

### 3フェーズ型設計

```
Source Code
     ↓
 Tokenizer → Reader → Form        (構文)
     ↓
 Analyzer → Node                   (意味)
     ↓
 ┌─────────────┬───────────────┐
 │ TreeWalk    │ Compiler → VM │
 │ (正確性)    │ (性能)        │
 └─────────────┴───────────────┘
     ↓
 Value ↔ Wasm                      (実行)
```

- **Form → Node → Value**: 各フェーズで関心を分離
- **デュアルバックエンド**: `--compare` で回帰検出
- **zware**: Pure Zig Wasm ランタイムで Value ↔ Wasm を自然に統合

---

## 4. エンジニアリングハイライト (2:30)

### comptime テーブル結合

```zig
// src/lib/core/registry.zig
pub const all_builtins = arithmetic.builtins ++
    predicates.builtins ++ collections.builtins ++
    sequences.builtins ++ strings.builtins ++ ...;

comptime {
    validateNoDuplicates(all_builtins, "clojure.core");
}
```

- 545 関数を **ランタイムコストゼロ** で登録
- 名前重複は **コンパイルエラー** で検出

### Fused Reduce

`(take → map → filter → range)` を単一ループに展開
→ 中間 LazySeq 排除: **27GB → 2MB** (12,857x メモリ削減)

### セミスペース GC

sweep フェーズ: **1,146ms → 29ms** (40x 高速化)

### その他

- 正規表現エンジン (Zig フルスクラッチ)
- nREPL サーバー (CIDER 互換)
- デュアルバックエンド (`--compare`)

---

## 5. ベンチマーク (1:30)

### Cold start (hyperfine, Apple M4 Pro)

| ベンチマーク   | JVM Clj (cold) | Babashka | ClojureWasm | C     |
|----------------|----------------|----------|-------------|-------|
| fib30          | 384ms          | 152ms    | **69ms**    | 6.4ms |
| sum_range      | 307ms          | 22ms     | **13ms**    | 4.1ms |
| map_filter     | 383ms          | 13ms     | **2.3ms**   | 3.2ms |
| string_ops     | 320ms          | 13ms     | **6.4ms**   | 5.1ms |
| data_transform | 385ms          | 13ms     | **11ms**    | 3.8ms |

- **JVM cold の 5-170x 高速**、メモリ **2-22MB** (JVM: 108-121MB)
- map_filter は JVM warm より **4x 速い** (Fused Reduce)

### 最適化前後

| ベンチマーク | Before        | After         | 改善            |
|--------------|---------------|---------------|-----------------|
| fib30        | 1.90s / 1.5GB | 69ms / 2.1MB  | 27x速           |
| map_filter   | 1.75s / 27GB  | 1.8ms / 2.1MB | 12,857x省メモリ |

---

## 6. 今後の展望 / まとめ (2:00)

### 今後

- **NaN Boxing**: Value 24B → 8B (大規模変更のため設計文書作成中)
- **Wasm ターゲット**: 処理系自体を Wasm にコンパイル → ブラウザで Clojure
- **多言語 Wasm 連携**: Go (TinyGo) → Wasm → Clojure は動作確認済み。Rust, C 等も同様に可能
- **Wasm クラウド**: Fermyon / WasmEdge / WASI 0.3 (2026)

### 「第4のClojure」

```
Clojure (JVM)   — サーバー/エンタープライズ
ClojureScript   — フロントエンド
Babashka        — CLI/スクリプト
ClojureWasm     — Wasm/組込み/エッジ ← New
```

### まとめ

- Zig フルスクラッチで Clojure を再実装 (40,000行)
- 起動 2-70ms / メモリ 2-22MB で JVM の 1/50
- WasmInterop で JavaInterop の代替を提案 (Go/Rust/C の Wasm を直接呼び出し)
- CIDER から使える nREPL サーバー
- Clojure の設計は美しい。実装してわかる。

---

**ありがとうございました**

リポジトリ: (非公開 / 後日公開予定)
