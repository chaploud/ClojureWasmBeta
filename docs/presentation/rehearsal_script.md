# 通し練習台本 (15分 / 声に出して読む用)

**使い方**: これを頭から声に出して読む。デモ操作の箇所は
手元で操作をイメージしながら「操作:」の指示を読み上げる。
3回繰り返す。1回目は止まりながら、2回目は流れ重視、3回目は時間計測。

---

## [0:00] 自己紹介 + What & Why (2:00)

> こんにちは、chaploud です。
> Clojure が好きで、Zig も好きで、Shibuya.lisp #113 では
> 自作言語処理系 Sci-Lisp の発表をしました。
>
> 今日は「Clojure を Zig で作ったらどうなるか」というお話です。
>
> 実際に作りました。ClojureWasmBeta です。
>
> JVM の起動に 300ms 以上、メモリ 100MB 以上かかる。
> これを Zig で解決したい。
> そして JavaInterop を捨てて、代わりに WasmInterop を入れました。
> Go や Rust で書いたコードも Wasm 経由で呼び出せます。

**[スライド: ポジショニング表を見せる]**

> この表を見てください。
> ClojureWasm は起動 2-70ms、メモリ 2-22MB。
> Babashka とは立場が違っていて、Babashka は GraalVM ネイティブの SCI、
> こちらは Zig フルスクラッチで、Wasm 連携が独自の差別化点です。

---

## [2:00] ライブデモ (5:00)

### Demo 1: REPL 基本 (1:00)

> では実際に動かします。Emacs + CIDER で接続しています。

**操作: 01_basics.clj を表示**

> まず基本的な式評価。

**操作: `(+ 1 2 3)` を `, e f` で評価 → 6**

> 6 が返りました。次に関数定義。

**操作: `(greet "Shibuya.lisp")` を評価**

> 文字列結合も普通に動きます。
> 次に遅延シーケンス。

**操作: `(take 10 (filter odd? (range)))` を評価**

> 無限列から奇数だけ取り出して10個。
> Clojure らしい書き方がそのまま動きます。

**操作: threading macro の式を評価**

> threading macro も。

---

### Demo 2: プロトコル (0:45)

**操作: 02_protocols.clj を表示**

> プロトコルとマルチメソッドです。

**操作: defprotocol → extend-type → greet を評価**

> String 型にプロトコルを後付けしています。

**操作: defmulti area → defmethod → area 呼び出し**

> マルチメソッドでキーワードディスパッチ。

---

### Demo 3: マクロ + アトム (0:45)

**操作: 03_macros_atoms.clj を表示**

> マクロも動きます。

**操作: defmacro unless → unless 評価 → macroexpand-1**

> macroexpand で展開結果も見えます。

**操作: atom → dotimes → @counter**

> アトムで状態管理。5回 inc して 5。

---

### Demo 4: Wasm 基本 (1:15)

> ここからが WasmInterop です。

**操作: 04_wasm.clj を表示**

**操作: wasm/load-module → wasm/invoke "add" 3 4**

> Wasm ファイルをロードして、関数を呼びます。
> add(3, 4) = 7。

**操作: fib(10) を評価**

> フィボナッチ。Wasm で計算して 55。

**操作: memory-write → memory-read**

> Wasm のリニアメモリに文字列を書いて読み戻す。
> "Hello, Wasm!" が round-trip できます。

---

### Demo 5: ホスト関数注入 (1:15)

> 今度は逆方向です。Clojure の関数を Wasm にエクスポートします。

**操作: 05_wasm_host.clj を表示**

**操作: atom → defn my-print-i32 → wasm/load-module with imports**

> Clojure の関数をインポートマップで渡しています。

**操作: wasm/invoke "compute_and_print" 3 7 → @captured**

> Wasm が内部で 3+7=10 を計算して、Clojure の関数を呼びました。
> captured に [10] が入っています。
> Clojure と Wasm が双方向にやり取りできるんです。

---

### Demo 6: Go → Wasm (1:00)

> さらに。Go のコードも Wasm 経由で呼べます。

**操作: 06_go_wasm.clj を表示**

**操作: wasm/load-wasi で Go Wasm をロード**

> TinyGo でコンパイルした Go の Wasm です。
> load-wasi は WASI インポートを自動で提供します。

**操作: add, multiply, fibonacci を順に評価**

> add(3,4)=7、multiply(6,7)=42、fibonacci(10)=55。
> Go で書いた関数がそのまま動いています。

**操作: map + fibonacci を評価**

> そして Clojure の map で Go の fibonacci を呼んでいます。
> Clojure の高階関数と Go の関数の組み合わせ。
> Wasm がユニバーサルなバイナリフォーマットとして機能しています。

---

## [7:00] アーキテクチャ概要 (2:00)

**[スライド: 3フェーズ図を見せる]**

> アーキテクチャです。3フェーズ型設計を取っています。
>
> まず Source Code が Tokenizer → Reader を通って Form になる。
> これは構文レベル、S式のデータ表現です。
>
> 次に Analyzer が Form を Node に変換する。
> マクロ展開やシンボル解決が済んだ意味レベルの表現です。
>
> そして Node がデュアルバックエンドに入る。
> TreeWalk は AST を直接再帰評価する方式。正確性重視。
> BytecodeVM はバイトコードにコンパイルしてスタックマシンで実行。速い。
>
> `--compare` フラグで両方実行して結果を比較できます。
> 新機能追加時の回帰検出に使っています。
>
> Wasm 連携は zware という Pure Zig の Wasm ランタイムで、
> Value と Wasm の間が自然に統合されています。

---

## [9:00] エンジニアリングハイライト (2:30)

### comptime テーブル結合 (1:00)

**[スライド: registry.zig のコード]**

> Zig の comptime を使って、コンパイル時にテーブルを結合しています。
> 545個の組み込み関数をランタイムコストゼロで登録。
> 名前が重複したらコンパイルエラーで教えてくれる。
> テーブルを足すのは .zig ファイルを足して ++ するだけです。

### Fused Reduce (0:30)

> 一番楽しかった最適化が Fused Reduce です。
> 遅延シーケンスのチェーン take → map → filter → range を
> 単一ループに融合しています。
> 結果: メモリ割り当て 27GB → 2MB。12,857倍の削減。

### セミスペース GC (0:30)

> GC も自前実装です。セミスペース方式。
> sweep フェーズが 1,146ms → 29ms、40倍高速化しました。

### その他 (0:30)

> ほかにも、正規表現エンジンを Zig フルスクラッチで実装、
> さっきのデモで使っていた nREPL サーバー、
> デュアルバックエンドでの回帰検出、
> といった要素があります。

---

## [11:30] ベンチマーク (1:30)

**[スライド: Cold start 表]**

> ベンチマークです。Apple M4 Pro で hyperfine 計測。
>
> JVM Clojure の cold start は 300-400ms。JVM 起動のオーバーヘッドです。
> ClojureWasm は 2-70ms。C や Zig の次に速い。
> メモリは全条件で 2-22MB。JVM は 100MB 超です。
>
> 特に map_filter は JVM の warm (JIT 後) よりも 4倍速い。
> これが Fused Reduce の効果です。

**[スライド: 最適化前後表]**

> 最適化前後を見ると、fib30 で 27倍、
> map_filter で 12,857倍のメモリ削減。
> 起動が速くてメモリが少ない。CLI、スクリプト、Wasm 用途に最適です。

---

## [13:00] 今後 / まとめ (2:00)

> 今後の展望です。
>
> NaN Boxing で Value を 24 バイトから 8 バイトに。大規模変更なので設計中。
> Wasm ターゲットで処理系自体を Wasm にコンパイル。ブラウザで Clojure が動く世界。
> さっきデモした Go → Wasm 連携は動作確認済み。Rust や C でも同じことができます。
> Fermyon や WasmEdge、WASI 0.3 と合わせて Wasm クラウドも視野に。

**[スライド: 第4のClojure]**

> 「第4のClojure」として、
> JVM は サーバー、ClojureScript はフロントエンド、
> Babashka は CLI、そして ClojureWasm は Wasm/組込み/エッジ。

> まとめです。
> Zig フルスクラッチで Clojure を再実装しました。40,000行。
> 起動 2-70ms、メモリ 2-22MB で JVM の 1/50。
> WasmInterop で Go や Rust の Wasm を直接呼び出せます。
> CIDER から使える nREPL サーバーも入っています。
>
> Clojure の設計は美しい。実装してわかりました。
>
> ありがとうございました。

---

## 練習チェック

### 1回目: 止まりながら読む
- [ ] 全セクションの流れを把握した
- [ ] デモ操作の順番を覚えた
- [ ] 数字 (545, 27GB→2MB, 40x, 12857x) を言えた

### 2回目: 流れ重視
- [ ] 詰まらずに最後まで言えた
- [ ] デモ操作の順番に迷わなかった
- [ ] 「ここからが WasmInterop」等の切り替えフレーズが自然だった

### 3回目: 時間計測
- [ ] 15分以内に収まった
- [ ] 時間配分は妥当だった (デモに5分使えたか)
- [ ] 省略すべき箇所が見つかったか → メモ:
