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
- 式境界でのみ GC 実行 (pause time 予測可能)
- Clojure Value のみ追跡。インフラ (Env/Namespace/Var) は GPA 直接管理
- セミスペース導入で sweep 40x 高速化 (1,146ms → 29ms)

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

## ベンチマーク: fib(38)

素朴な二重再帰フィボナッチで関数呼び出しオーバーヘッドを比較。

**環境**: Apple M4 Pro, 48 GB RAM, macOS

| 言語                      | 時間(s) | メモリ(MB) |
|---------------------------|---------|------------|
| C (clang -O3)             | 0.06    | 1.8        |
| C++ (clang -O3)           | 0.06    | 1.8        |
| Zig (ReleaseFast)         | 0.06    | 1.8        |
| Java (OpenJDK 21, JIT)    | 0.08    | 40.7       |
| Ruby 3.3.6 (YJIT)        | 0.42    | 17.3       |
| Python 3.14               | 2.89    | 14.3       |
| **ClojureWasmBeta (VM)**  | 152.94  | 31,389     |

### 分析

- ネイティブコンパイラ (C/C++/Zig) は圧倒的。JIT (Java) もほぼ同等。
- ClojureWasmBeta は **動的言語のインタプリタ VM** であり:
  - 全 Value が tagged union (GC 追跡対象)
  - 関数呼び出しごとにフレーム生成
  - 式境界ごとに GC 実行 (fib(38) は ~6億回の再帰呼び出し)
- メモリ使用量が大きいのは GC セミスペースの特性 (2x + 整数の都度アロケーション)
- **最適化の余地**: NaN boxing, インラインキャッシュ, 定数畳み込み, tail call 最適化

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

- **NaN boxing**: Value サイズ縮小で大幅高速化 (最優先)
- **世代別 GC**: Young generation の bump allocator で短命オブジェクトを高速回収
- **Wasm ターゲット**: 処理系自体を Wasm にコンパイル (ブラウザで Clojure)
- **clojure.pprint**: 実用上重要な欠けている名前空間

---

## リンク

- リポジトリ: (TBD)
- Zig: https://ziglang.org/
- zware: https://github.com/nicoretti/zware
