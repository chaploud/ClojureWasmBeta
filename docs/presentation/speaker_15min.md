# スピーカーノート (15分版)

## 事前準備チェックリスト

- [ ] `zig build --release=fast` でリリースビルド済み
- [ ] Emacs 起動、フォントサイズ拡大 `SPC t p`
- [ ] `clj-wasm --nrepl-server --port=7888` を別ターミナルで起動
- [ ] Emacs: `SPC m c j` → localhost:7888 で接続確認
- [ ] `docs/presentation/demo/` の6ファイルを Emacs で開いておく
- [ ] ターミナルも1つ用意 (`--compare` デモ用)
- [ ] CWD = ClojureWasmBeta/ (Wasm パスの相対パス前提)

### トラブルシューティング

- **nREPL 接続できない**: ポート確認 (`lsof -i :7888`)、プロセス再起動
- **Wasm パスエラー**: CWD がプロジェクトルートか確認 (`pwd`)
- **CIDER 評価でエラー**: `C-c C-q` で切断 → 再接続

---

## セクション別ノート

### 1. 導入: What & Why (2:00)

**話すこと**:
- 自己紹介: Clojure 好き、Zig 好き、#113 で Sci-Lisp 発表した
- 「Clojure を Zig で作ったら？」→ 作った
- JVM の起動時間・メモリが気になる → Zig で解決
- JavaInterop を捨てて WasmInterop を入れた (Go 等の Wasm も呼べる)
- ポジショニング表をさっと見せる (Clojure / Babashka / ClojureWasm)

**ポイント**:
- Babashka は GraalVM ネイティブ SCI。スクリプティング用途で Clojure と協調
- ClojureWasm は Zig フルスクラッチ。全レイヤー再実装 + Wasm 連携が独自

---

### 2. ライブデモ (5:00)

**操作手順**:

1. **01_basics.clj** を Emacs で表示 (1:00)
   - CIDER Connectする様子 + REPL表示 + 補完が出る様子(println)
   - `(+ 1 2 3)` → `, e f` → 6 が出る
   - `(greet "Shibuya.lisp")` → 文字列結合
   - `(take 10 (filter odd? (range)))` → 遅延シーケンスのデモ
   - threading macro → 「Clojure らしい書き方がそのまま動く」

2. **02_protocols.clj** (0:45)
   - defprotocol + extend-type → 型にプロトコルを後付け
   - defmulti/defmethod → ディスパッチ

3. **03_macros_atoms.clj** (0:45)
   - defmacro unless → macroexpand-1 で展開を見せる
   - atom/swap! → 状態管理

4. **04_wasm.clj** (1:15)
   - 「ここからが WasmInterop」
   - wasm/load-module → add.wasm ロード
   - wasm/invoke → 関数呼び出し
   - fib(10) = 55 → Wasm でフィボナッチ
   - memory-write/read → 文字列の round-trip

5. **05_wasm_host.clj** (1:15)
   - 「逆方向: Clojure 関数を Wasm にエクスポート」
   - atom でキャプチャ → Wasm が Clojure 関数を呼ぶ
   - with-out-str でキャプチャ → 標準出力も取れる
   - 「Clojure と Wasm が双方向にやり取りできる」

6. **06_go_wasm.clj** (1:00)
   - 「Go のコードも Wasm 経由で呼べる」
   - TinyGo でコンパイルした Go の Wasm をロード (`wasm/load-wasi`)
   - add, multiply, fibonacci を呼び出し
   - `map` で fibonacci を Go 関数で計算 → 「Clojure の高階関数 + Go の関数」
   - 「Wasm がユニバーサルなバイナリフォーマット。言語を問わず連携できる」

**もし時間が余ったら**: ターミナルで `--compare` デモ

```bash
clj-wasm --compare -e "(map inc [1 2 3])"
```

---

### 3. アーキテクチャ概要 (2:00)

**話すこと**:
- 3フェーズ型設計の図を見せる
- Form (構文) → Node (意味) → Value (実行)
- デュアルバックエンド: TreeWalk は新機能の正確性保証、VM は性能
- `--compare` で両方実行して回帰検出
- zware (Pure Zig Wasm ランタイム) で Value ↔ Wasm が自然に統合

**口頭で補足する用語**:
- TreeWalk: AST を直接再帰評価。遅いが実装が簡単で正確性を保証しやすい
- BytecodeVM: 命令列にコンパイルしてスタックマシンで実行。速い

---

### 4. エンジニアリングハイライト (2:30)

**話すこと**:

1. **comptime テーブル結合** (1:00)
   - Zig の comptime でコンパイル時にテーブル結合
   - 545 関数をランタイムコストゼロで登録
   - 名前重複するとコンパイルエラー → バグ防止
   - コードスニペットをさっと見せる

2. **Fused Reduce** (0:30)
   - 遅延シーケンスのチェーンを1ループに融合
   - 27GB → 2MB、12,857倍のメモリ削減
   - 「これが一番楽しかった最適化」

3. **セミスペース GC** (0:30)
   - sweep 1,146ms → 29ms (40倍高速化)
   - 式境界 + Safe Point で GC 実行

4. **その他** (0:30)
   - 正規表現エンジン: Zig フルスクラッチ (Java regex 互換目標)
   - nREPL サーバー: さっきのデモで使ってた
   - デュアルバックエンド: 新機能の回帰検出

---

### 5. ベンチマーク (1:30)

**話すこと**:
- Cold start 表を見せる
  - JVM Clojure (cold) の 300-400ms は JVM 起動のオーバーヘッド
  - ClojureWasm は 2-70ms。C/Zig に次ぐ速さ
  - メモリ 2-22MB (JVM は 100MB 超)
- map_filter は JVM warm より 4x 速い → Fused Reduce の効果
- 最適化前後の表: fib30 で 27倍、map_filter で 12,857倍改善
- 「起動が速くてメモリが少ない。CLI/スクリプト/Wasm 用途に最適」

---

### 6. 未来/まとめ (2:00)

**話すこと**:
- NaN Boxing: Value を 24B → 8B に (保留中、大規模変更)
- Wasm ターゲット: 処理系自体を Wasm にコンパイル → ブラウザで Clojure
- 多言語 Wasm 連携: Go (TinyGo) は動作確認済み。Rust/C も同様に可能
- Wasm クラウド: Fermyon, WasmEdge, WASI 0.3 (2026)
- 「第4のClojure」のポジション
- まとめ:
  - 40,000行 Zig で Clojure を再実装
  - 起動 JVM の 1/50、WasmInterop
  - CIDER から使える
  - 「Clojure の設計は美しい。実装してわかる」

---

## Q&A 用メモ

- **なぜ Zig?**: comptime が強力、手動メモリ管理 (GC 設計の自由度)、Wasm ターゲット対応、C ABI 互換
- **なぜ Rust じゃないの?**: 自作 GC を作りたかった (Rust の所有権と GC は相性悪い)、comptime の魅力
- **本家 Clojure との互換性は?**: 1036 テスト pass。clojure.core の 76% 実装。動作互換 (ブラックボックス) を目指すが完全互換は非目標
- **実用的に使える?**: CLI/スクリプト用途なら使える。サーバー用途は JVM Clojure が良い
- **Babashka と何が違う?**: Babashka は SCI (Clojure で書かれた Clojure インタプリタ) の GraalVM ネイティブ。CWB は Zig フルスクラッチで Wasm 連携がある
- **Go の Wasm も動く?**: TinyGo でコンパイルした Go の Wasm は動作確認済み。WASI 関数 (fd_write, proc_exit, random_get) をサポートしているので、TinyGo の wasi ターゲットがそのまま動く。Rust/C の Wasm も同様に呼べるはず
- **STM は?**: 実装しない。atom のみ。シングルスレッドなので STM の意味がない
- **マルチスレッドは?**: 現在はシングルスレッド。将来的に検討
