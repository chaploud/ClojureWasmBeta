# ZigによるClojure処理系の再実装ーWasmInterOpを添えて

Shibuya.lisp lispmeetup #117
2026/01/29 @株式会社スタディスト

---

## 自己紹介

- [@\_\_chaploud\_\_](https://x.com/__chaploud__)
- Clojure が好き。Zig も好き。
- Shibuya.lisp #113 で自作言語処理系 Sci-Lisp の紹介発表

---

## ClojureWasmBeta とは

Zig で Clojure 処理系をフルスクラッチ実装するプロジェクト。
JVM を使わず、Clojure の動作互換 (ブラックボックステスト) を目指す。

| 項目                  | 内容                                     |
|-----------------------|------------------------------------------|
| 言語                  | Zig 0.15.2 (フルスクラッチ)              |
| テスト                | 1036 pass / 1 fail (意図的)              |
| clojure.core 実装     | 545 done / 169 skip                      |
| ソースコード          | ~40,000 行 (src/ 以下)                   |
| バックエンド          | TreeWalk + BytecodeVM (デュアル)         |
| GC                    | セミスペース Arena Mark-Sweep            |
| Wasm 連携             | zware (pure Zig Wasm ランタイム)         |
| 正規表現              | Zig フルスクラッチ実装                   |
| nREPL                 | CIDER/Calva/Conjure 互換                 |

---

## なぜ作ったか

### モチベーション

1. **JVM 脱却**: 起動 300ms+、メモリ 100MB+ の JVM 制約から解放されたい
2. **JavaInterop 排除**: Java API の無限再実装地獄を避ける → **WasmInterop** で代替 (Go 等の他言語の Wasm も呼べる)
3. **全レイヤーを理解**: Tokenizer から GC まで自分で書きたい
4. **Wasm ネイティブ**: Pure Zig の zware で Wasm ↔ ホスト間が自然に統合

### 設計判断: 何を捨てたか

| 捨てたもの                  | 得たもの                               |
|-----------------------------|----------------------------------------|
| JavaInterop                 | ゼロ依存 (Zig + zware のみ)            |
| 本家 .clj 読み込み          | Java 依存なしの自前 core               |
| JVM 固有 (proxy, agent 等)  | Wasm ネイティブ連携                    |
| STM, BigDecimal             | シンプルな concurrency (atom のみ)     |

---

## ポジショニング

| 特性             | Clojure (JVM)   | ClojureScript | Babashka       | ClojureWasm      |
|------------------|-----------------|---------------|----------------|------------------|
| ランタイム       | JVM             | JS Engine     | GraalVM Native | Zig Native       |
| 起動時間         | 300-400ms       | 即時 (ブラウザ) | 10-150ms     | 2-70ms           |
| メモリ           | 100-120MB       | ブラウザ依存  | 30-70MB        | 2-22MB           |
| JavaInterop      | ✅ 完全         | ❌            | ✅ 制限付き    | ❌               |
| WasmInterop      | ❌              | ❌            | ❌             | ✅               |
| clojure.core     | 完全            | ほぼ完全      | 大部分         | 545/714 (76%)    |
| 用途             | サーバー全般    | フロントエンド | CLI/スクリプト | CLI/Wasm/組込み  |
| 実装             | Java            | Clojure→JS    | SCI (Clojure)  | Zig フルスクラッチ |

### Babashka との関係

Babashka は GraalVM ネイティブコンパイルした SCI (Small Clojure Interpreter)。
スクリプティング用途で Clojure と協調する立場。

ClojureWasm は Zig フルスクラッチで全レイヤー再実装、Wasm 連携が独自。
起動時間・メモリで Babashka を上回り、Wasm エコシステムとの統合が差別化点。

---

## ライブデモ

### デモ環境

- Emacs + CIDER (nREPL 接続)
- `clj-wasm --nrepl-server --port=7888`
- form 単位で `C-c C-e` 評価

### Demo 1: REPL 基本 + 遅延シーケンス (`demo/01_basics.clj`)

```clojure
(+ 1 2 3)            ;; => 6
(defn greet [name] (str "Hello, " name "!"))
(greet "Shibuya.lisp") ;; => "Hello, Shibuya.lisp!"

;; 遅延シーケンス — 無限列から必要な分だけ取る
(take 10 (filter odd? (range)))
;; => (1 3 5 7 9 11 13 15 17 19)

;; threading macro
(->> (range 1 100) (filter #(zero? (mod % 3))) (map #(* % %)) (reduce +))
;; => 105876
```

### Demo 2: プロトコル + マルチメソッド (`demo/02_protocols.clj`)

```clojure
(defprotocol Greetable (greet [this]))
(extend-type String Greetable
  (greet [this] (str "Hello, " this)))
(greet "Shibuya.lisp") ;; => "Hello, Shibuya.lisp"

(defmulti area :shape)
(defmethod area :circle [{:keys [radius]}] (* 3.14159265 radius radius))
(defmethod area :rect [{:keys [w h]}] (* w h))
(area {:shape :circle :radius 5}) ;; => 78.5398...
```

### Demo 3: マクロ + アトム (`demo/03_macros_atoms.clj`)

```clojure
(defmacro unless [pred then else]
  (list 'if pred else then))
(unless false "yes" "no") ;; => "yes"
(macroexpand-1 '(unless false "yes" "no"))
;; => (if false "no" "yes")

(def counter (atom 0))
(dotimes [_ 5] (swap! counter inc))
@counter ;; => 5
```

### Demo 4: Wasm 基本連携 (`demo/04_wasm.clj`)

```clojure
(def math (wasm/load-module "test/wasm/fixtures/01_add.wasm"))
(wasm/invoke math "add" 3 4) ;; => 7

(def fib-mod (wasm/load-module "test/wasm/fixtures/02_fibonacci.wasm"))
(wasm/invoke fib-mod "fib" 10) ;; => 55

;; メモリ操作
(def mem-mod (wasm/load-module "test/wasm/fixtures/03_memory.wasm"))
(wasm/memory-write mem-mod 256 "Hello, Wasm!")
(wasm/memory-read mem-mod 256 12) ;; => "Hello, Wasm!"
```

### Demo 5: ホスト関数注入 (`demo/05_wasm_host.clj`)

```clojure
;; Clojure 関数を Wasm にエクスポート
(def captured (atom []))
(defn my-print-i32 [n] (swap! captured conj n))

(def imports-mod
  (wasm/load-module "test/wasm/fixtures/04_imports.wasm"
    {:imports {"env" {"print_i32" my-print-i32
                      "print_str" (fn [p l] nil)}}}))

(wasm/invoke imports-mod "compute_and_print" 3 7)
@captured ;; => [10]  — Wasm が Clojure 関数を呼んだ
```

### Demo 6: Go → Wasm 連携 (`demo/06_go_wasm.clj`)

```clojure
;; TinyGo でコンパイルした Go の Wasm をロード
(def go-math (wasm/load-wasi "test/wasm/fixtures/08_go_math.wasm"))

;; Go 関数を Clojure から呼び出し
(wasm/invoke go-math "add" 3 4)       ;; => 7
(wasm/invoke go-math "multiply" 6 7)  ;; => 42
(wasm/invoke go-math "fibonacci" 10)  ;; => 55

;; Clojure の高階関数で Go 関数を活用
(map #(wasm/invoke go-math "fibonacci" %) (range 1 11))
;; => (1 1 2 3 5 8 13 21 34 55)
```

### Demo 7: --compare モード (ターミナル)

```bash
$ clj-wasm --compare -e "(map inc [1 2 3])"
tree_walk: (2 3 4)
vm:        (2 3 4)
=> MATCH
```

---

## アーキテクチャ

### 3フェーズ型設計

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

- **Form** (構文): S式のデータ表現
- **Node** (意味): マクロ展開済み、シンボル解決済みの意味木
- **Value** (実行): 実行時のClojure値

### デュアルバックエンド

- **TreeWalk**: 正確性重視。新機能はまずこちらで実装
- **BytecodeVM**: 性能重視。スタックベース、固定3バイト命令 (OpCode u8 + operand u16)
- `--compare`: 両方で評価して結果を比較 → 回帰検出

### ディレクトリ構成

```
src/
├── reader/       Source → Form (Tokenizer, Reader)
├── analyzer/     Form → Node (マクロ展開、シンボル解決)
├── compiler/     Node → Bytecode
├── vm/           Bytecode 実行
├── runtime/      Value 型、Var、Namespace、TreeWalk 評価器
├── lib/          clojure.core (19 ドメインファイル)
├── wasm/         Wasm 連携 (zware)
├── nrepl/        nREPL サーバー (CIDER 互換)
├── gc/           セミスペース Arena Mark-Sweep
├── regex/        正規表現エンジン (フルスクラッチ)
├── repl/         REPL + line editor
└── main.zig      CLI エントリポイント
```

---

## エンジニアリングハイライト

### 1. comptime テーブル結合 + 重複検出

Zig の `comptime` で15ドメインの組み込み関数テーブルを結合。
名前の重複はコンパイル時に検出・エラー。

```zig
// src/lib/core/registry.zig
pub const all_builtins = arithmetic.builtins ++
    predicates.builtins ++
    collections.builtins ++
    sequences.builtins ++
    strings.builtins ++
    io.builtins ++
    meta.builtins ++
    concurrency.builtins ++
    interop.builtins ++
    transducers.builtins ++
    namespaces.builtins ++
    eval_mod.builtins ++
    misc.builtins ++
    math_fns.builtins;

// comptime 検証: 名前の重複チェック
comptime {
    validateNoDuplicates(all_builtins, "clojure.core");
    validateNoDuplicates(string_ns_builtins, "clojure.string");
    validateNoDuplicates(wasm_builtins, "wasm");
}

fn validateNoDuplicates(comptime table: anytype, comptime ns_name: []const u8) void {
    @setEvalBranchQuota(table.len * table.len * 10);
    for (table, 0..) |a, i| {
        for (table[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) {
                @compileError(std.fmt.comptimePrint(
                    "{s}: builtin '{s}' が重複登録されています",
                    .{ ns_name, a.name },
                ));
            }
        }
    }
}
```

- 545 個の組み込み関数を **ランタイムコストゼロ** で登録
- テーブルの追加は `.zig` ファイルを足して `++` するだけ

### 2. Fused Reduce (27GB → 2MB)

遅延シーケンスチェーン `(take → map → filter → range)` を単一ループに展開。
中間 LazySeq 構造体を完全に排除。

- **Before**: `(reduce + (take 10000 (map #(* % %) (filter odd? (range)))))` → 27GB 割り当て
- **After**: 同じ式 → 2MB、12,857x メモリ削減

### 3. セミスペース GC (sweep 40x 高速化)

- 式境界 + Safe Point (recur opcode) で GC 実行
- セミスペース導入: sweep フェーズ 1,146ms → 29ms
- Clojure Value のみ追跡。インフラ (Env/Namespace/Var) は GPA 直接管理
- 世代別 GC 基盤 (Nursery bump allocator) は実装済み、統合は保留

### 4. 正規表現エンジン (フルスクラッチ)

- Zig で実装 (Java regex 互換目標)
- バックトラッキング方式
- `re-find`, `re-matches`, `re-seq`, `re-pattern` 対応

### 5. nREPL サーバー (CIDER 互換)

- bencode エンコード/デコード
- TCP サーバー + セッション管理
- CIDER / Calva / Conjure から接続可能
- `clj-wasm --nrepl-server --port=7888`

### 6. デュアルバックエンド (--compare)

- TreeWalk で正しさを保証、VM で速度を追求
- `--compare` フラグで両方を実行、結果を自動比較
- 新機能追加時の回帰検出に不可欠

---

## 楽しかったこと

1. **最適化の達成感**: fib30 で 1.9s → 69ms、map_filter で 27GB → 2MB
2. **nREPL で CIDER 接続した瞬間**: 自作処理系が Emacs から動く
3. **Clojure 設計の美しさの再発見**: 実装してわかる一貫性と拡張性
4. **comptime が強力**: ビルトイン関数テーブル、エラーメッセージ、重複検出を全てコンパイル時に
5. **Arena は正義**: フェーズ単位の一括解放でメモリ管理が劇的に楽に
6. **多言語 Wasm**: Go (TinyGo) のコードを Wasm 経由で Clojure から呼べた瞬間

---

## ベンチマーク

### 環境

Apple M4 Pro, 48 GB RAM, macOS (Darwin 25.2.0)

### Cold start 比較 (hyperfine)

| ベンチマーク    | C     | Zig   | Java | Python | Ruby  | JVM Clj (cold) | Babashka | ClojureWasm |
|-----------------|-------|-------|------|--------|-------|----------------|----------|-------------|
| fib30           | 6.4ms | 4.5ms | 33ms | 77ms   | 135ms | 384ms          | 152ms    | 69ms        |
| sum_range       | 4.1ms | 3.8ms | 35ms | 20ms   | 103ms | 307ms          | 22ms     | 13ms        |
| map_filter      | 3.2ms | 4.0ms | 44ms | 15ms   | 97ms  | 383ms          | 13ms     | 2.3ms       |
| string_ops      | 5.1ms | 3.9ms | 49ms | 18ms   | 98ms  | 320ms          | 13ms     | 6.4ms       |
| data_transform  | 3.8ms | 3.3ms | 32ms | 17ms   | 100ms | 385ms          | 13ms     | 11ms        |

- **全5ベンチで JVM Clojure (cold) より 5-170x 高速**
- メモリは全条件で最少 (2-22MB vs JVM 108-121MB)

### JVM warm 比較 (JIT warm-up 後)

| ベンチマーク      | JVM Clj (warm) | ClojureWasm (warm) | 比率       |
|-------------------|----------------|------------|------------|
| fib30             | 10.1ms         | 63.8ms     | JVM 6x速   |
| sum_range         | 5.9ms          | 10.4ms     | JVM 2x速   |
| map_filter        | 1.4ms          | 0.4ms      | ClojureWasm 4x速   |
| string_ops        | 1.9ms          | 59.4ms     | JVM 31x速  |
| data_transform    | 1.5ms          | 6.7ms      | JVM 4x速   |

- JIT warm-up 後は JVM が数値演算・文字列で優位
- **map_filter は ClojureWasm が 4x 速い** (Fused Reduce の効果)

### 最適化前後

| ベンチマーク      | 最適化前          | 最適化後          | 改善            |
|-------------------|-------------------|-------------------|-----------------|
| fib30             | 1.90s / 1.5GB     | 69ms / 2.1MB      | 27x速           |
| sum_range         | 0.07s / 133MB     | 13ms / 2.1MB      | 5x速            |
| map_filter        | 1.75s / 27GB      | 1.8ms / 2.1MB     | 12,857x省メモリ |
| string_ops        | 0.09s / 1.3GB     | 6.6ms / 14MB      | 14x速           |
| data_transform    | 0.06s / 782MB     | 10ms / 22.5MB     | 6x速            |

### 実施した最適化

1. **VM 算術 opcode 化**: `+`, `-`, `<`, `>` を専用 opcode で実行
2. **定数畳み込み**: Analyzer 段階で `(+ 1 2)` → `3` に事前計算
3. **Safe Point GC**: `recur` opcode で GC チェック
4. **Fused Reduce**: lazy-seq チェーンを単一ループに展開
5. **遅延 Take/Range**: 遅延ジェネレータ化
6. **スタック引数バッファ**: reduce ループ内の引数 alloc をスタック再利用

### 分析

- **Cold start**: CLI/スクリプト用途では JVM Clojure / Babashka より圧倒的に速い
- **Warm JVM**: 長期稼働サーバーでは JVM JIT が有利
- **ポジショニング**: 起動が速くメモリが少ない CLI/スクリプト/Wasm 用途に最適

---

## 今後の展望

### NaN Boxing (保留中)

- Value 24B → 8B でキャッシュ効率向上
- 全 Value 表現の大規模変更 → 事前に設計文書が必要
- 実装されれば全ベンチで大幅改善が見込まれる

### 多言語 Wasm 連携 (実証済み)

- Go (TinyGo) → Wasm → ClojureWasm の連携は**動作確認済み**
- TinyGo `-target=wasi` でコンパイル → `wasm/load-wasi` で即座にロード・実行
- Rust, C 等の Wasm 出力も同様に呼び出し可能
- Wasm がユニバーサルなバイナリフォーマットとして機能する実例

### Wasm ターゲット (ブラウザ Clojure)

- 処理系自体を Wasm にコンパイル
- ブラウザで Clojure が直接動く世界
- Zig は Wasm ターゲットをネイティブサポート (`zig build -Dtarget=wasm32-wasi`)

### Wasm クラウド

- **Fermyon** (Spin + Fermyon Cloud): Wasm ネイティブのサーバーレス
- **WasmEdge** (CNCF): コンテナ代替としての Wasm ランタイム
- **AWS Lambda Wasm**: Lambda での Wasm 実行
- WASI 0.3 (2026) で非同期対応 → コンテナ代替がさらに現実的に

### 「第4のClojure」

```
Clojure (JVM) — サーバー/エンタープライズ
ClojureScript — フロントエンド
Babashka — CLI/スクリプト
ClojureWasm — Wasm/組込み/エッジ ← New
```

---

## 用語集

| 用語              | 説明                                                         |
|-------------------|--------------------------------------------------------------|
| TreeWalk          | AST を直接再帰的に評価する方式。正確性重視                   |
| BytecodeVM        | バイトコードにコンパイルしてスタックマシンで実行。性能重視   |
| comptime          | Zig のコンパイル時実行。テーブル構築やバリデーションに活用   |
| Arena             | メモリをまとめて確保・一括解放するアロケータ                 |
| セミスペースGC    | 2つのメモリ空間を交互に使う GC。コピー方式で断片化なし       |
| Fused Reduce      | 遅延シーケンスチェーンを単一ループに融合する最適化           |
| nREPL             | Network REPL。Clojure エディタ統合の標準プロトコル           |
| WAT               | WebAssembly Text Format。Wasm のテキスト表現                 |
| ホスト関数        | Wasm モジュールに外部から注入する関数                         |
| NaN Boxing        | IEEE 754 NaN の未使用ビットに型情報と値を埋め込む手法       |
| TinyGo            | Go のサブセットコンパイラ。Wasm/WASI ターゲット対応           |
| zware             | Pure Zig の Wasm ランタイム                                   |

---

## リンク

- リポジトリ: (非公開)
- Zig: https://ziglang.org/
- zware: Pure Zig Wasm ランタイム
