# Q&A 緊急リファレンス

発表中に手元で開いておく用。質問されたらここを見る。

---

## ソースコード参照パス (説明時に開く用)

Q&A や深堀り質問で「コード見せて」と言われたらここを開く。
パスは全てプロジェクトルート (`ClojureWasmBeta/`) からの相対パス。

### comptime テーブル結合

| ファイル                         | 行    | 内容                            |
|----------------------------------|-------|---------------------------------|
| `src/lib/core/registry.zig`      | 35    | `all_builtins` テーブル結合開始 |
| `src/lib/core/registry.zig`      | 57-62 | `comptime` 重複検証ブロック     |
| `src/lib/core/registry.zig`      | 63    | `validateNoDuplicates` 関数本体 |
| `src/lib/core/registry.zig`      | 85    | `registerCore` (起動時の登録)   |

### Value 型 (全体設計)

| ファイル                         | 行    | 内容                              |
|----------------------------------|-------|-----------------------------------|
| `src/runtime/value.zig`          | 61-112 | Value tagged union 全フィールド  |
| `src/runtime/value/types.zig`    | 354-360 | WasmModule 構造体定義           |

### Fused Reduce

| ファイル                         | 行    | 内容                             |
|----------------------------------|-------|----------------------------------|
| `src/lib/core/sequences.zig`     | 950   | Fused reduce 概要コメント        |
| `src/lib/core/sequences.zig`     | 1029  | `reduceFused` 関数本体           |
| `src/lib/core/sequences.zig`     | 902   | lazy_seq チェーン分岐            |

### GC (セミスペース)

| ファイル                         | 行    | 内容                             |
|----------------------------------|-------|----------------------------------|
| `src/gc/gc.zig`                  | 32    | GC.init                         |
| `src/gc/gc.zig`                  | 37    | `collectGarbage` (GC 本体)      |
| `src/gc/gc_allocator.zig`        | 109   | `mark` (マーキング)             |
| `src/gc/gc_allocator.zig`        | 140   | `sweep` (スイープ)              |
| `src/gc/gc_allocator.zig`        | 229   | `shouldCollect` (GC 判定)       |

### Wasm 連携

| ファイル                         | 行    | 内容                               |
|----------------------------------|-------|------------------------------------|
| `src/wasm/wasi.zig`              | 18-38 | WASI 19関数テーブル                |
| `src/wasm/wasi.zig`              | 49    | `registerWasiFunctions`            |
| `src/wasm/wasi.zig`              | 83    | `loadWasiModule` (load-wasi 本体) |
| `src/wasm/loader.zig`            | 76    | `loadModule` (load-module 本体)   |
| `src/wasm/runtime.zig`           | 13    | `invoke` (wasm/invoke 本体)       |
| `src/wasm/host_functions.zig`    | 46    | `hostTrampoline` (Clj→Wasm ブリッジ) |
| `src/wasm/host_functions.zig`    | 82    | `registerImports` (インポート登録)   |
| `src/wasm/interop.zig`           | 23    | `readString` (メモリ読み出し)     |
| `src/wasm/interop.zig`           | 40    | `writeBytes` (メモリ書き込み)     |

### nREPL サーバー

| ファイル                         | 行    | 内容                               |
|----------------------------------|-------|------------------------------------|
| `src/nrepl/server.zig`           | 45    | `startServer` (TCP サーバー起動)  |
| `src/nrepl/server.zig`           | 185   | `dispatchOp` (op ディスパッチ)    |
| `src/nrepl/server.zig`           | 323   | `opEval` (式評価ハンドラ)        |
| `src/nrepl/server.zig`           | 546   | `opCompletions` (補完)           |
| `src/nrepl/bencode.zig`          | -     | bencode エンコード/デコード       |

### 正規表現エンジン

| ファイル                         | 行    | 内容                             |
|----------------------------------|-------|----------------------------------|
| `src/regex/regex.zig`            | -     | パーサー + コンパイラ            |
| `src/regex/matcher.zig`          | -     | バックトラッキングマッチャー     |

### メインエントリポイント

| ファイル                         | 行    | 内容                             |
|----------------------------------|-------|----------------------------------|
| `src/main.zig`                   | 40    | `main` (CLI エントリ)           |
| `src/main.zig`                   | 303   | `runWithBackend` (評価実行)     |
| `src/main.zig`                   | 372   | `runCompare` (--compare 実装)   |
| `src/main.zig`                   | 595   | `runRepl` (REPL ループ)         |

### デモファイル (発表時に開くもの)

| ファイル                                 | 内容                   |
|------------------------------------------|------------------------|
| `docs/presentation/demo/01_basics.clj`   | REPL 基本 + 遅延       |
| `docs/presentation/demo/02_protocols.clj`| プロトコル             |
| `docs/presentation/demo/03_macros_atoms.clj` | マクロ + アトム    |
| `docs/presentation/demo/04_wasm.clj`     | Wasm 基本              |
| `docs/presentation/demo/05_wasm_host.clj`| ホスト関数注入         |
| `docs/presentation/demo/06_go_wasm.clj`  | Go → Wasm              |

### Go Wasm ソース

| ファイル                                 | 内容                   |
|------------------------------------------|------------------------|
| `test/wasm/src/go_math.go`               | Go ソース (24行)       |
| `test/wasm/fixtures/08_go_math.wasm`     | コンパイル済み (20KB)  |

---

## 言語選択

### なぜ Zig?
- **comptime**: テーブル結合、重複検出、エラーメッセージ全てコンパイル時
- **手動メモリ管理**: GC を自分で設計できる自由度 (Rust だと所有権と衝突)
- **Wasm ターゲット**: `zig build -Dtarget=wasm32-wasi` でネイティブ対応
- **C ABI 互換**: 既存の C ライブラリをそのまま呼べる
- **シンプル**: Rust ほど複雑でなく、C より安全

### なぜ Rust じゃないの?
- 自作 GC を作りたかった → Rust の所有権モデルと GC は相性が悪い
- comptime 相当の機能が Rust にはない (proc_macro はあるが別物)
- Zig の方がメンタルモデルがシンプルで言語処理系向き

### Zig のバージョンは?
- 0.15.2 (2025年リリース)。まだ 1.0 前だがかなり安定

---

## 本家 Clojure との関係

### 互換性は?
- 1036 テスト pass / 1 fail (意図的)
- clojure.core の **76%** 実装 (545 done / 169 skip)
- skip は Java 固有 (proxy, agent, STM, BigDecimal, unchecked-* 等)
- **動作互換 (ブラックボックス)** を目指す。完全互換は非目標

### 本家 .clj は読めるの?
- 本家 .clj は Java 依存がある → そのまま読む方針は取っていない
- clojure.core は Zig で再実装 (545 関数)
- ユーザーの .clj (Java 依存なし) はそのまま読める

### 標準名前空間は?
clojure.string, clojure.set, clojure.walk, clojure.edn, clojure.math,
clojure.repl, clojure.data, clojure.stacktrace, clojure.template,
clojure.zip, clojure.test, clojure.pprint (全12名前空間)

---

## Babashka との比較

### 何が違う?
| 項目           | Babashka                   | ClojureWasm             |
|----------------|----------------------------|-------------------------|
| 実装           | SCI (Clojure製インタプリタ) | Zig フルスクラッチ      |
| ランタイム     | GraalVM Native Image       | Zig ネイティブ          |
| 起動           | 10-150ms                   | 2-70ms                  |
| メモリ         | 30-70MB                    | 2-22MB                  |
| WasmInterop    | なし                       | あり                    |
| JavaInterop    | あり (制限付き)            | なし                    |
| 用途           | CLI/スクリプト             | CLI/Wasm/組込み/エッジ  |

### Babashka でいいのでは?
- Babashka は素晴らしいツールで、用途が重なる部分はある
- 差別化: **WasmInterop** と **極限の軽量さ** (メモリ 2MB)
- 競合ではなく棲み分け: Babashka は Java ライブラリ資産を使いたい場面に強い

---

## Wasm 関連

### WasmInterop って何?
- JavaInterop の代わりに Wasm モジュールを呼ぶ仕組み
- `wasm/load-module`: 手書き WAT や各言語の Wasm をロード
- `wasm/load-wasi`: WASI インポート付きロード (TinyGo 等)
- `wasm/invoke`: エクスポート関数の呼び出し
- `wasm/memory-read/write`: リニアメモリ操作
- ホスト関数: Clojure の関数を Wasm にインジェクト可能 (双方向)

### Go の Wasm も動く?
- **動作確認済み**: TinyGo `-target=wasi` → `wasm/load-wasi` でそのまま動く
- TinyGo が要求する WASI: fd_write, proc_exit, random_get → 全て実装済み
- サイズ: 単純な数学関数で約 20KB (Wasm)
- Rust/C の Wasm も同様に呼べるはず (未検証だが原理的に同じ)

### zware って何?
- Pure Zig で書かれた WebAssembly ランタイム
- Zig のプロジェクトなので依存ゼロで組み込める
- Store → Module → Instance の3段階で管理
- ホスト関数の登録も Zig の関数ポインタで自然にできる

### WASI って何? (非エンジニアに聞かれたら)
- WebAssembly System Interface
- Wasm からファイル操作やネットワークをする標準 API
- 「Wasm 用の OS みたいなもの」と思えばいい
- 現在 19 関数をサポート

### Wasm ターゲットの進捗は?
- まだ未着手 (今は Zig ネイティブバイナリ)
- Zig は `wasm32-wasi` ターゲットをネイティブサポート
- 理論上は `zig build -Dtarget=wasm32-wasi` でビルドできるはず
- 実現すれば **ブラウザで Clojure が動く**

---

## アーキテクチャ

### 3フェーズって?
1. **Form** (構文): S式のデータ表現。Tokenizer → Reader が生成
2. **Node** (意味): マクロ展開・シンボル解決済みの意味木。Analyzer が生成
3. **Value** (実行): 実行時の Clojure 値。TreeWalk or VM が生成

### TreeWalk と VM の違い
| 項目         | TreeWalk         | BytecodeVM              |
|--------------|------------------|-------------------------|
| 方式         | AST 直接再帰評価 | スタックマシン          |
| 速度         | 遅い             | 速い                    |
| 用途         | 正確性保証       | 高速実行                |
| 実装の容易さ | 簡単             | 複雑                    |
| --compare    | 基準値           | 比較対象                |

### なぜデュアルバックエンド?
- 新機能はまず TreeWalk で正しく動かす
- VM を同期して同じ結果を返すようにする
- `--compare` で両方実行して回帰検出 → バグが即座にわかる

---

## エンジニアリング詳細

### comptime テーブル結合
- `registry.zig` で 15 ドメインのテーブルを `++` で結合
- ドメイン: arithmetic, predicates, collections, sequences, strings,
  io, meta, concurrency, interop, transducers, namespaces, eval, misc, math
- 545 関数がコンパイル時に1つの配列になる
- 重複があると `@compileError` で名前付きエラーメッセージ

### Fused Reduce の仕組み
- `(reduce + (take N (map f (filter pred (range)))))` のようなチェーンを検出
- 中間の LazySeq 構造体 (GC 対象) を一切作らず、単一の for ループに展開
- **Before**: filter が LazySeq → map がさらに LazySeq → take がさらに ... → 27GB
- **After**: 1ループで filter チェック → map 適用 → take カウント → 2MB

### セミスペース GC
- 2つのメモリ空間 (from/to) を交互に使うコピー GC
- sweep は生存オブジェクトを to にコピーするだけ → from を丸ごと破棄
- 式境界 + Safe Point (recur opcode) で GC 実行
- Clojure Value のみ追跡。インフラ (Env/Namespace/Var) は GPA 直接管理

### 正規表現エンジン
- Zig フルスクラッチ、バックトラッキング方式
- Java regex 互換を目標
- re-find, re-matches, re-seq, re-pattern 対応

### nREPL
- bencode エンコード/デコード (Zig 実装)
- TCP サーバー + セッション管理
- CIDER / Calva / Conjure から接続可能
- `clj-wasm --nrepl-server --port=7888`

---

## ベンチマーク数字 (暗記用)

| 数字              | 意味                             |
|-------------------|----------------------------------|
| 545               | 実装済み clojure.core 関数数     |
| 1036              | テスト数 (pass)                  |
| 40,000            | Zig ソースコード行数             |
| 2-70ms            | 起動時間                         |
| 2-22MB            | メモリ使用量                     |
| 300-400ms         | JVM Clojure cold start           |
| 100-120MB         | JVM メモリ                       |
| 27GB → 2MB        | Fused Reduce のメモリ改善        |
| 12,857x           | map_filter メモリ削減倍率        |
| 1,146ms → 29ms    | GC sweep 改善                    |
| 40x               | GC sweep 高速化倍率              |
| 27x               | fib30 速度改善倍率               |
| 5-170x            | JVM cold 比での高速化範囲        |
| 4x                | map_filter が JVM warm より速い  |
| 24B → 8B          | NaN Boxing の Value サイズ改善   |
| 19                | WASI サポート関数数              |

---

## 想定外の質問

### 開発期間は?
→ (自分の記憶で回答)

### テストはどう書いてる?
- Zig の built-in テストフレームワーク
- Clojure コードで書いたテスト (clojure.test)
- `--compare` でデュアルバックエンドの一致を確認

### エラーメッセージは?
- Clojure 互換のエラー形式
- スタックトレースあり (clojure.stacktrace)
- Wasm トラップもエラーマップで返す

### パフォーマンスの弱点は?
- JIT warm-up 後の JVM には数値演算で負ける (fib30 で JVM 6x 速い)
- 文字列処理は大差 (JVM warm 31x 速い) ← 改善余地大
- **ただし cold start と メモリでは圧倒**

### デバッグ手段は?
- `--dump-bytecode` でバイトコードダンプ
- `--compare` で TreeWalk vs VM 比較
- `--gc-stats` で GC 統計
- nREPL 経由で CIDER のインスペクタ等

### 実用例は?
- CLI ツール (起動が速いので向いている)
- スクリプティング (Babashka の代替)
- Wasm ホスト (Go/Rust の Wasm を Clojure でオーケストレーション)
- 教育用 (Clojure の仕組みを全部見られる)

### マルチスレッドは?
- 現在はシングルスレッド
- atom は mutex ベース (シングルスレッドなので実質ロックフリー)
- STM は実装しない (意味がない)
- 将来的に検討

### NaN Boxing って何?
- IEEE 754 の NaN (Not a Number) には未使用ビットが大量にある
- そこに型タグと値を埋め込むテクニック
- Value 構造体が 24B → 8B になる
- キャッシュ効率が劇的に向上 → 全ベンチ改善見込み
- 大規模変更なので設計文書作成中

### Wasm クラウドって何? (具体的に)
- **Fermyon Spin**: Wasm をサーバーレス関数として実行するプラットフォーム
- **WasmEdge**: CNCF のプロジェクト。コンテナの代替として Wasm ランタイム
- **WASI 0.3** (2026年): 非同期 I/O 対応 → サーバーワークロードが現実的に
- ClojureWasm が Wasm ターゲットに対応すれば、これらの上で直接動く

### SCI との違いは? (技術的に詳しい人向け)
- SCI: Clojure で書かれた Clojure インタプリタ。GraalVM でネイティブ化
- ClojureWasm: Zig で全レイヤーをフルスクラッチ (GC も自前)
- SCI は Clojure の eval を使わずに独自評価器。ClojureWasm も同じアプローチ
- SCI は Clojure のデータ構造をそのまま使う。ClojureWasm は全部自前実装
