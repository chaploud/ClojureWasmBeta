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

5種のベンチマークで7言語と比較。

**環境**: Apple M4 Pro, 48 GB RAM, macOS

### 全言語比較 (最適化後)

| ベンチマーク     | C/Zig   | Java    | JVM Clojure | Python  | Ruby    | ClojureWasmBeta |
|------------------|---------|---------|-------------|---------|---------|-----------------|
| fib30            | 0.01s   | 0.03s   | 0.38s       | 0.07s   | 0.16s   | 0.07s           |
| sum_range        | 0.00s   | 0.04s   | 0.31s       | 0.02s   | 0.10s   | 0.01s           |
| map_filter       | 0.00s   | 0.05s   | 0.38s       | 0.02s   | 0.10s   | 0.00s           |
| string_ops       | 0.00s   | 0.05s   | 0.31s       | 0.02s   | 0.10s   | 0.01s           |
| data_transform   | 0.00s   | 0.04s   | 0.39s       | 0.02s   | 0.10s   | 0.01s           |

※ JVM Clojure は同じ .clj ファイルを `clojure -M` で実行。0.3-0.4s の大部分は JVM 起動 + Clojure ランタイムロード。長期稼働 (JIT warm-up 後) では計算部分が大幅に高速化される。

### 最適化前後の改善

| ベンチマーク     | 最適化前        | 最適化後        | 改善            |
|------------------|-----------------|-----------------|-----------------|
| fib30            | 1.90s / 1.5GB   | 0.07s / 2.1MB   | 27x速           |
| sum_range        | 0.07s / 133MB   | 0.01s / 2.1MB   | 7x速            |
| map_filter       | 1.75s / 27GB    | 0.00s / 2.1MB   | 12857x省メモリ  |
| string_ops       | 0.09s / 1.3GB   | 0.01s / 14MB    | 9x速            |
| data_transform   | 0.06s / 782MB   | 0.01s / 22.5MB  | 6x速            |

### 実施した最適化

1. **VM 算術 opcode 化**: `+`, `-`, `<`, `>` を専用 opcode で実行。汎用 call を回避
2. **定数畳み込み**: Analyzer 段階で `(+ 1 2)` → `3` に事前計算
3. **Safe Point GC**: `recur` opcode で GC チェック。長い再帰中のメモリ膨張を抑制
4. **Fused Reduce**: lazy-seq チェーン (take→map→filter→range) を単一ループに展開。中間 LazySeq 構造体を排除
5. **遅延 Take/Range**: `(take N lazy-seq)` と大きい `(range N)` を遅延ジェネレータ化
6. **スタック引数バッファ**: reduce ループ内の引数 alloc をスタック変数で再利用

### 分析

- **全5ベンチで JVM Clojure より速度・メモリとも上位** (短期実行ベンチ限定)
- fib30 以外で **純 Java (JIT) よりも高速**
- fib30 は Python と同等、純 Java の 2.3x 遅 (JIT の壁)
- メモリは全ベンチで Java / JVM Clojure より少ない
- JVM Clojure との差の大部分は JVM 起動コスト。長期稼働 JIT warm-up 後は逆転の可能性あり

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
