# Getting Started

ClojureWasmBeta の導入と基本的な使い方。

---

## 前提条件

- **Zig 0.15.2** (https://ziglang.org/download/)
- macOS / Linux (arm64 / x86_64)

## ビルド

```bash
git clone https://github.com/chaploud/ClojureWasmBeta
cd ClojureWasmBeta
zig build # リリースビルドにしたいなら、--release=fastを付ける
```

ビルド成功後、`zig-out/bin/ClojureWasmBeta` にバイナリが生成される。

パスに追加 (任意):

```bash
# ~/.bashrc or ~/.zshrc
alias clj-wasm="$(pwd)/zig-out/bin/ClojureWasmBeta"
```

最適化ビルド:

```bash
zig build --release=fast
```

## 使い方

### REPL

```bash
clj-wasm
```

引数なしで起動すると対話的 REPL が開始。readline (Emacs ショートカット) と履歴に対応。

```
user=> (+ 1 2 3)
6
user=> (defn square [x] (* x x))
#'user/square
user=> (map square (range 1 6))
(1 4 9 16 25)
user=> (doc map)
```

REPL を終了するには Ctrl-D。

### 式を評価

```bash
clj-wasm -e "(+ 1 2)"
# => 3

clj-wasm -e "(println \"Hello, World\")"
# Hello, World
```

### スクリプトファイルを実行

```bash
clj-wasm script.clj
```

### nREPL サーバー

CIDER (Emacs), Calva (VS Code), Conjure (Neovim) から接続可能。

```bash
clj-wasm --nrepl-server --port=7888
```

接続例 (Emacs CIDER):

```
M-x cider-connect → localhost → 7888
```

---

## 主な機能

### データ型

```clojure
;; 数値
42        ; 整数 (i64)
3.14      ; 浮動小数点 (f64)
22/7      ; 有理数 (ratio)

;; 文字列・文字
"hello"   ; 文字列
\a        ; 文字

;; キーワード・シンボル
:name     ; キーワード
'sym      ; シンボル

;; コレクション
'(1 2 3)        ; リスト
[1 2 3]         ; ベクター
{:a 1 :b 2}     ; マップ
#{1 2 3}        ; セット

;; 正規表現
#"[a-z]+"        ; 正規表現リテラル
```

### 関数定義

```clojure
;; 基本
(defn add [x y] (+ x y))

;; マルチアリティ
(defn greet
  ([] (greet "World"))
  ([name] (str "Hello, " name "!")))

;; 可変長引数
(defn sum [& nums] (reduce + 0 nums))

;; 無名関数
(map (fn [x] (* x x)) [1 2 3])
(map #(* % %) [1 2 3])
```

### 遅延シーケンス

```clojure
(take 5 (range))           ; => (0 1 2 3 4)
(take 5 (iterate inc 10))  ; => (10 11 12 13 14)
(take 5 (cycle [1 2 3]))   ; => (1 2 3 1 2)
(->> (range)
     (filter odd?)
     (map #(* % %))
     (take 5))             ; => (1 9 25 49 81)
```

### マクロ

```clojure
(defmacro unless [test & body]
  `(if (not ~test) (do ~@body)))

(unless false (println "executed!"))
```

### プロトコル

```clojure
(defprotocol Describable
  (describe [this]))

(defrecord Dog [name breed]
  Describable
  (describe [this]
    (str (:name this) " is a " (:breed this))))

(describe (->Dog "Rex" "Shepherd"))
; => "Rex is a Shepherd"
```

### アトム (状態管理)

```clojure
(def state (atom {:count 0}))
(swap! state update :count inc)
@state  ; => {:count 1}
```

### 名前空間

```clojure
(ns my-app.core
  (:require [clojure.string :as str]
            [clojure.set :as set]))

(str/upper-case "hello")  ; => "HELLO"
```

### 例外処理

```clojure
(try
  (/ 1 0)
  (catch Exception e
    (println "Error:" (ex-message e)))
  (finally
    (println "cleanup")))
```

---

## デバッグ機能

### バイトコードダンプ

```bash
clj-wasm --dump-bytecode -e "(defn f [x] (+ x 1))"
```

### 両バックエンド比較

```bash
clj-wasm --compare -e "(map inc [1 2 3])"
```

TreeWalk と BytecodeVM の結果を比較し、一致を確認。

### GC 統計

```bash
clj-wasm --gc-stats -e '(dotimes [_ 1000] (vec (range 100)))'
```

---

## 本家 Clojure との主な差異

| 項目                     | 本家 Clojure      | ClojureWasmBeta         |
|--------------------------|--------------------|-------------------------|
| ランタイム               | JVM                | Zig ネイティブ          |
| Java Interop             | あり               | なし                    |
| 整数型                   | long (64bit)       | i64                     |
| BigDecimal/BigInteger    | あり               | なし                    |
| Agent/STM                | あり               | なし                    |
| Proxy                    | あり               | なし                    |
| Wasm 連携                | なし               | あり (zware)            |
| nREPL                    | nREPL (JVM)        | 互換実装 (Zig)          |
| 正規表現                 | java.util.regex    | Zig フルスクラッチ      |

---

## 利用可能な標準名前空間

| 名前空間              | 主な関数                                       |
|-----------------------|------------------------------------------------|
| clojure.core          | 545 関数 (map, filter, reduce, defprotocol 等) |
| clojure.string        | join, split, upper-case, replace 等            |
| clojure.set           | union, intersection, difference 等             |
| clojure.walk          | walk, postwalk, prewalk, keywordize-keys       |
| clojure.edn           | read-string                                    |
| clojure.math          | sin, cos, pow, log, sqrt 等 (33 関数)          |
| clojure.repl          | doc, find-doc, apropos, source                 |
| clojure.data          | diff                                           |
| clojure.stacktrace    | print-stack-trace                              |
| clojure.template      | apply-template, do-template                    |
| clojure.zip           | zipper, vector-zip, seq-zip, xml-zip           |
| clojure.test          | deftest, is, testing, run-tests                |
| clojure.pprint        | pprint, print-table, cl-format                 |

---

## トラブルシューティング

### ビルドが失敗する

Zig 0.15.2 が必要。`zig version` でバージョンを確認。

### `!` を含む式が bash でエラーになる

`-e` フラグで `!` (swap!, reset! 等) を含む式を渡すと bash の history expansion が発動する。ファイル経由で実行するか、`set +H` で無効化。

```bash
# ファイル経由
echo '(swap! (atom 0) inc)' > /tmp/test.clj
clj-wasm /tmp/test.clj

# history expansion 無効化
set +H
clj-wasm -e '(swap! (atom 0) inc)'
```
