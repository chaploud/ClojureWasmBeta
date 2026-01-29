# ClojureWasmBeta

**Zig で Clojure 処理系をフルスクラッチ実装。**

JVM を一切使わず、Tokenizer から GC まで全てを Zig で書き上げた Clojure 処理系です。
545 個の clojure.core 関数、遅延シーケンス、マクロ、プロトコル、nREPL サーバー、
そして Wasm 連携まで、Clojure の世界を Zig ネイティブで再現しています。

## ここが面白い

- **起動 2ms**: JVM の起動待ちなし。コマンドラインツールとして即座に使える
- **メモリ 2MB**: JVM Clojure が 100MB 以上消費する処理を 2MB で完了
- **デュアルバックエンド**: TreeWalk (正確性検証) と BytecodeVM (高速実行) の2系統を搭載。`--compare` で常に回帰検出
- **フルスクラッチ GC**: セミスペース Arena Mark-Sweep を自前実装。sweep 40x 高速化を達成
- **正規表現エンジン**: java.util.regex 互換を目指した Zig 製バックトラッキングエンジン
- **Wasm 連携**: zware (pure Zig Wasm ランタイム) で .wasm ファイルを直接ロード・実行。Go (TinyGo) 等の他言語で書いた Wasm も呼び出せる
- **nREPL 互換**: CIDER (Emacs) / Calva (VS Code) / Conjure (Neovim) からそのまま接続可能

## ベンチマーク

Apple M4 Pro, 48 GB RAM, macOS。hyperfine で計測。

### Cold start (コマンドライン実行)

| ベンチマーク   | C     | Zig   | Java | Python | Ruby  | JVM Clojure | Babashka | **ClojureWasm** |
|----------------|-------|-------|------|--------|-------|-------------|----------|---------|
| fib30          | 6.4ms | 4.5ms | 33ms | 77ms   | 135ms | 384ms       | 152ms    | **69ms**  |
| sum_range      | 4.1ms | 3.8ms | 35ms | 20ms   | 103ms | 307ms       | 22ms     | **13ms**  |
| map_filter     | 3.2ms | 4.0ms | 44ms | 15ms   | 97ms  | 383ms       | 13ms     | **2.3ms** |
| string_ops     | 5.1ms | 3.9ms | 49ms | 18ms   | 98ms  | 320ms       | 13ms     | **6.4ms** |
| data_transform | 3.8ms | 3.3ms | 32ms | 17ms   | 100ms | 385ms       | 13ms     | **11ms**  |

Cold start では JVM Clojure に対して 5-200x 速く、babashka と同等以上。
map_filter (遅延シーケンスチェーン) では Fused Reduce の効果で全言語中最速を記録。

### Warm (JIT / nREPL warm-up 後)

| ベンチマーク   | JVM Clojure (warm) | ClojureWasm (warm) | 比率     |
|----------------|---------------------|------------|----------|
| fib30          | 10ms                | 64ms       | JVM 7x速  |
| sum_range      | 5.9ms               | 10ms       | JVM 2x速  |
| map_filter     | 1.4ms               | 0.4ms      | ClojureWasm 4x速  |
| string_ops     | 1.9ms               | 59ms*      | JVM 33x速 |
| data_transform | 1.5ms               | 6.7ms      | JVM 4x速  |

*string_ops: nREPL 内タイミングラッパーでクラッシュするため壁時計計測 (精度低)

JIT warm-up 後の JVM Clojure は fib30 等の純粋な計算で強いが、
Fused Reduce が効く map_filter では ClojureWasm が 4x 上回る。

## プロジェクト指標

| 項目                  | 状態                                           |
|-----------------------|------------------------------------------------|
| テスト                | 1036 pass / 1 fail (意図的)                    |
| clojure.core 実装     | 545 done / 169 skip (JVM 固有)                 |
| Zig ソースコード      | ~38,000 行                                     |
| バックエンド          | TreeWalk + BytecodeVM (デュアル)               |
| GC                    | セミスペース Arena Mark-Sweep + 世代別 GC 基盤 |
| Wasm 連携             | zware (pure Zig, WASI 対応, Go/TinyGo 動作確認済み) |
| 正規表現              | Zig フルスクラッチ (Java regex 互換目標)       |
| nREPL                 | CIDER / Calva / Conjure 互換                   |

### 標準名前空間

clojure.string, clojure.set, clojure.walk, clojure.edn, clojure.math,
clojure.repl, clojure.data, clojure.stacktrace, clojure.template,
clojure.zip, clojure.test, clojure.pprint

## クイックスタート

### 前提条件

- **Zig 0.15.2** (https://ziglang.org/download/)
- macOS / Linux (arm64 / x86_64)

### ビルド

```bash
git clone <repository-url>
cd ClojureWasmBeta
zig build                 # デバッグビルド
zig build --release=fast  # 最適化ビルド (ベンチマーク用)
```

### 使い方

```bash
# REPL を起動
./zig-out/bin/ClojureWasmBeta

# 式を評価
./zig-out/bin/ClojureWasmBeta -e "(+ 1 2)"

# スクリプトを実行
./zig-out/bin/ClojureWasmBeta script.clj

# 両バックエンドで結果を比較
./zig-out/bin/ClojureWasmBeta --compare -e "(map inc [1 2 3])"

# バイトコードをダンプ
./zig-out/bin/ClojureWasmBeta --dump-bytecode -e "(defn f [x] (+ x 1))"

# GC 統計を表示
./zig-out/bin/ClojureWasmBeta --gc-stats -e '(dotimes [_ 1000] (vec (range 100)))'

# nREPL サーバーを起動 (CIDER / Calva / Conjure から接続可能)
./zig-out/bin/ClojureWasmBeta --nrepl-server --port=7888
```

## 動くコード例

```clojure
;; 遅延シーケンス
(->> (range)
     (filter odd?)
     (map #(* % %))
     (take 5))
;; => (1 9 25 49 81)

;; プロトコル
(defprotocol Greetable (greet [this]))
(defrecord Person [name]
  Greetable
  (greet [this] (str "Hi, I'm " (:name this))))
(greet (->Person "Alice"))
;; => "Hi, I'm Alice"

;; アトム
(def counter (atom 0))
(dotimes [_ 100] (swap! counter inc))
@counter  ;; => 100

;; マクロ
(defmacro unless [test & body]
  `(if (not ~test) (do ~@body)))
(unless false (println "executed!"))

;; Wasm 連携 (手書き WAT)
(def m (wasm/load-module "add.wasm"))
(wasm/invoke m "add" 3 4)  ;; => 7

;; Go → Wasm 連携 (TinyGo でコンパイルした Go コード)
(def go (wasm/load-wasi "go_math.wasm"))
(wasm/invoke go "fibonacci" 10)  ;; => 55

;; System 互換
(System/nanoTime)            ;; => 1769643920644642000
(System/currentTimeMillis)   ;; => 1769643920642
```

## アーキテクチャ

```
Source Code (.clj / -e / REPL / nREPL)
     |
 Tokenizer --> Reader --> Form          (src/reader/)
     |
 Analyzer --> Node                      (src/analyzer/)
     |
 +---------------+------------------+
 | TreeWalk      | Compiler --> VM  |   (src/runtime/ + src/compiler/ + src/vm/)
 | (正確性検証)  | (高速実行)       |
 +---------------+------------------+
     |
 Value <--> Wasm                        (src/wasm/, zware)
     |
 GC (Semi-space Arena Mark-Sweep)       (src/gc/)
```

3フェーズ型設計: Form (構文) --> Node (意味) --> Value (実行)

## 設計判断

### 捨てたもの

- **Java Interop**: 無限に JVM を再実装する地獄を回避
- **本家 .clj 読み込み**: Java 依存を排除するため自前 core を実装
- **JVM 固有機能**: proxy, agent, STM, BigDecimal, unchecked-*

### 得たもの

- **ゼロ依存**: Zig + zware のみ。JVM 不要
- **Wasm ネイティブ**: zware が pure Zig なので Wasm <-> ホスト間のブリッジが自然
- **全レイヤーを理解**: Tokenizer から GC まで全てフルスクラッチ
- **起動速度とメモリ効率**: CLI/スクリプト用途では JVM Clojure を圧倒

## 本家 Clojure との主な差異

| 項目                  | 本家 Clojure       | ClojureWasmBeta          |
|-----------------------|--------------------|--------------------------|
| ランタイム            | JVM                | Zig ネイティブ           |
| Java Interop          | あり               | なし (System/* は互換)   |
| 整数型                | long (64bit)       | i64                      |
| BigDecimal/BigInteger | あり               | なし                     |
| Agent/STM             | あり               | なし                     |
| Wasm 連携             | なし               | あり (zware)             |
| 正規表現              | java.util.regex    | Zig フルスクラッチ       |
| 起動時間              | 300-400ms          | 2-10ms                   |
| メモリ (典型的)       | 100-120MB          | 2-22MB                   |

## ドキュメント

| パス                             | 内容                             |
|----------------------------------|----------------------------------|
| `docs/getting_started.md`        | 導入ガイド・使い方               |
| `docs/developer_guide.md`        | 開発者向け技術ガイド             |
| `docs/presentation.md`           | 発表資料 (ベンチマーク含む)      |
| `docs/reference/architecture.md` | 全体設計・ディレクトリ構成       |
| `docs/reference/vm_design.md`    | VM 設計・スタック・クロージャ    |
| `docs/reference/gc_design.md`    | GC 設計・セミスペース            |
| `status/vars.yaml`               | clojure.core 実装状況            |
| `status/bench.yaml`              | ベンチマーク履歴                 |

## ベンチマーク実行

```bash
# ClojureWasmBeta のみ (回帰チェック)
bash bench/run_bench.sh --quick

# 全言語比較 + hyperfine 高精度
bash bench/run_bench.sh --hyperfine

# 結果を記録
bash bench/run_bench.sh --quick --record --version="最適化名"
```

## 今後の展望

- **NaN boxing**: Value 24B --> 8B でキャッシュ効率向上
- **世代別 GC 統合**: 基盤 (Nursery bump allocator) は実装済み
- **Wasm ターゲット**: 処理系自体を Wasm にコンパイル (ブラウザで Clojure)

## License

TBD
