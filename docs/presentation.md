# ClojureWasmBeta — Zig で Clojure 処理系をフルスクラッチ

> shibuya.lisp 発表資料 (15分 + デモ)

---

## 自己紹介 & モチベーション

- Clojure が好き。Zig も好き。
- 「Clojure を Zig で実装したらどうなるか？」→ やってみた
- 目標: **動作互換** (ブラックボックステスト)、**Wasm 対応**

---

## プロジェクト概要

| 項目                  | 内容                                     |
|-----------------------|------------------------------------------|
| 言語                  | Zig 0.15.2 (フルスクラッチ)              |
| テスト                | 1036 pass / 1 fail (意図的)              |
| clojure.core 実装     | 545 done / 169 skip                      |
| ソースコード          | ~38,000 行 (src/ 以下)                   |
| バックエンド          | TreeWalk + BytecodeVM (デュアル)         |
| GC                    | セミスペース Arena Mark-Sweep            |
| Wasm 連携             | zware (pure Zig Wasm ランタイム)         |
| 正規表現              | Zig フルスクラッチ実装                   |
| nREPL                 | CIDER/Calva/Conjure 互換                 |

---

## アーキテクチャ

```
Source Code
     ↓
 Tokenizer → Reader → Form        (src/reader/)
     ↓
 Analyzer → Node                   (src/analyzer/)
     ↓
 ┌─────────────┬───────────────┐
 │ TreeWalk    │ Compiler → VM │   (src/runtime/ + src/compiler/ + src/vm/)
 │ (正確性)    │ (性能)        │
 └─────────────┴───────────────┘
     ↓
 Value ↔ Wasm                      (src/wasm/, zware)
```

- **3フェーズ型設計**: Form (構文) → Node (意味) → Value (実行)
- **デュアルバックエンド**: `--compare` で回帰検出

---

## 設計判断: 何を捨てたか

### 捨てたもの
- **JavaInterop**: 無限に JVM を再実装する地獄を回避
- **本家 .clj 読み込み**: Java 依存を排除するため自前 core を実装
- **JVM 固有機能**: proxy, agent, STM, BigDecimal, unchecked-*

### 得たもの
- **ゼロ依存**: Zig + zware のみ。JVM 不要
- **Wasm ネイティブ**: zware が pure Zig なので Wasm ↔ ホスト間のブリッジが自然
- **全レイヤーを理解**: Tokenizer から GC まで全てフルスクラッチ

---

## 実装の深掘り

### 1. バイトコード VM

- スタックベース、固定3バイト命令 (OpCode u8 + operand u16)
- フレーム管理: クロージャキャプチャ → 引数 → ローカル → 一時値
- 約 60 OpCode (制御フロー、コレクション操作、例外処理、メタデータ)

### 2. GC

- セミスペース Arena Mark-Sweep
- 式境界 + Safe Point (recur opcode) で GC 実行
- Clojure Value のみ追跡。インフラ (Env/Namespace/Var) は GPA 直接管理
- セミスペース導入で sweep 40x 高速化 (1,146ms → 29ms)
- 世代別 GC 基盤 (Nursery bump allocator) は実装済み、統合は保留

### 3. 正規表現エンジン

- Zig フルスクラッチ (Java regex 互換目標)
- バックトラッキング方式
- `re-find`, `re-matches`, `re-seq`, `re-pattern` 対応

### 4. Wasm 連携

- zware (pure Zig Wasm ランタイム) を組み込み
- .wasm ファイルのロード、関数呼び出し、メモリ I/O
- Clojure 関数をホスト関数としてエクスポート
- WASI 基本サポート

---

## ベンチマーク: 5種比較

5種のベンチマークで 8 言語/実行環境と比較。

**環境**: Apple M4 Pro, 48 GB RAM, macOS

### Cold start 比較 (コマンドライン実行, hyperfine)

| ベンチマーク     | C       | Zig     | Java    | JVM Clj (cold) | babashka | Python  | Ruby    | CWB     |
|------------------|---------|---------|---------|----------------|----------|---------|---------|---------|
| fib30            | 4.7ms   | 3.6ms   | 33ms    | 384ms          | 152ms    | 76ms    | 140ms   | 69ms    |
| sum_range        | —       | 6.0ms   | 34ms    | 314ms          | 21ms     | 21ms    | 97ms    | 13ms    |
| map_filter       | —       | 3.4ms   | 45ms    | 391ms          | 13ms     | 15ms    | 98ms    | 1.8ms   |
| string_ops       | —       | 2.1ms   | 49ms    | 321ms          | 14ms     | 18ms    | 99ms    | 6.6ms   |
| data_transform   | —       | 5.2ms   | 38ms    | 386ms          | 16ms     | 17ms    | 105ms   | 10ms    |

- JVM Clj (cold): `clojure -M file.clj`。300-400ms の大部分は JVM 起動 + Clojure ランタイムロード
- babashka: GraalVM ネイティブコンパイル済み Clojure (sci ベース)
- CWB: ClojureWasmBeta (VM backend, ReleaseFast)

### JVM Clojure warm (JIT warm-up 後)

1 JVM プロセスで全ベンチを warm-up 3回 + 計測 5回の中央値。純粋な計算時間。

| ベンチマーク     | JVM Clj (warm) | CWB (warm) | 比率      |
|------------------|----------------|------------|-----------|
| fib30            | 9.7ms          | 63.8ms     | JVM 7x速  |
| sum_range        | 5.8ms          | 10.4ms     | JVM 2x速  |
| map_filter       | 1.6ms          | 0.4ms      | CWB 4x速  |
| string_ops       | 1.8ms          | 59.4ms*    | JVM 33x速 |
| data_transform   | 1.5ms          | 6.7ms      | JVM 4x速  |

*string_ops: nREPL 内 System/nanoTime ラッパーでクラッシュするため壁時計計測 (精度低)

### 最適化前後の改善

| ベンチマーク     | 最適化前          | 最適化後 (hyperfine) | 改善           |
|------------------|-------------------|----------------------|----------------|
| fib30            | 1.90s / 1.5GB     | 69ms / 2.1MB         | 27x速          |
| sum_range        | 0.07s / 133MB     | 13ms / 2.1MB         | 5x速           |
| map_filter       | 1.75s / 27GB      | 1.8ms / 2.1MB        | 12857x省メモリ |
| string_ops       | 0.09s / 1.3GB     | 6.6ms / 14MB         | 14x速          |
| data_transform   | 0.06s / 782MB     | 10ms / 22.5MB        | 6x速           |

### 実施した最適化

1. **VM 算術 opcode 化**: `+`, `-`, `<`, `>` を専用 opcode で実行。汎用 call を回避
2. **定数畳み込み**: Analyzer 段階で `(+ 1 2)` → `3` に事前計算
3. **Safe Point GC**: `recur` opcode で GC チェック。長い再帰中のメモリ膨張を抑制
4. **Fused Reduce**: lazy-seq チェーン (take→map→filter→range) を単一ループに展開。中間 LazySeq 構造体を排除
5. **遅延 Take/Range**: `(take N lazy-seq)` と大きい `(range N)` を遅延ジェネレータ化
6. **スタック引数バッファ**: reduce ループ内の引数 alloc をスタック変数で再利用

### 分析

- **Cold start**: 全5ベンチで JVM Clojure (cold) / babashka より速度・メモリとも上位
- **Warm JVM**: JIT warm-up 後は JVM Clojure が fib30 で 7x、string_ops で 33x 速い
- **CWB warm 優位**: map_filter で CWB が 4x 速い (fused reduce の効果)
- メモリは全条件で ClojureWasmBeta が最少 (2-22MB vs JVM 108-121MB)
- **ポジショニング**: 起動が速くメモリが少ない CLI/スクリプト用途に強い。長期稼働サーバーでは JVM JIT が有利

---

## デモ (5分)

### 1. REPL 基本操作

```bash
$ clj-wasm
user=> (+ 1 2 3)
6
user=> (defn greet [name] (str "Hello, " name "!"))
#'user/greet
user=> (greet "shibuya.lisp")
"Hello, shibuya.lisp!"
```

### 2. 遅延シーケンス

```bash
user=> (take 10 (filter odd? (range)))
(1 3 5 7 9 11 13 15 17 19)
user=> (->> (range 1 100) (filter #(zero? (mod % 3))) (map #(* % %)) (reduce +))
105876
```

### 3. プロトコル・マルチメソッド

```bash
user=> (defprotocol Greetable (greet [this]))
Greetable
user=> (defrecord Person [name] Greetable (greet [this] (str "Hi, I'm " (:name this))))
Person
user=> (greet (->Person "Alice"))
"Hi, I'm Alice"
```

### 4. アトム・状態管理

```bash
user=> (def counter (atom 0))
#'user/counter
user=> (dotimes [_ 5] (swap! counter inc))
nil
user=> @counter
5
```

### 5. Wasm 連携

```bash
user=> (def m (wasm/load-module "add.wasm"))
#'user/m
user=> (wasm/invoke m "add" 3 4)
7
```

### 6. --compare モード

```bash
$ clj-wasm --compare -e "(map inc [1 2 3])"
--- TreeWalk ---
(2 3 4)
--- VM ---
(2 3 4)
✅ 一致
```

### 7. nREPL

```bash
$ clj-wasm --nrepl-server --port=7888
# Emacs: M-x cider-connect → localhost:7888
```

---

## 学んだこと

1. **comptime が強力**: ビルトイン関数テーブル、エラーメッセージ、重複検出を全てコンパイル時に
2. **Arena は正義**: フェーズ単位の一括解放でメモリ管理が劇的に楽に
3. **デュアルバックエンドの安心感**: TreeWalk で正しさを保証、VM で速度を追求
4. **GC は甘くない**: セミスペース導入前は sweep だけで 1秒以上
5. **Clojure の設計は美しい**: 実装してわかる一貫性と拡張性

---

## 今後の展望

- **NaN boxing**: Value 24B→8B でキャッシュ効率向上 (大規模変更のため保留中)
- **世代別 GC 統合**: 基盤 (G2a-c) は実装済み。式境界 GC からの統合が残課題
- **Wasm ターゲット**: 処理系自体を Wasm にコンパイル (ブラウザで Clojure)

---

## リンク

- リポジトリ: (TBD)
- Zig: https://ziglang.org/
- zware: https://github.com/nicoretti/zware
