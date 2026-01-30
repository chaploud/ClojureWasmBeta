# ClojureWasm 正式版 設計方針

> Beta (本リポジトリ) で得た知見を踏まえた正式版の設計構想。
> Beta の教訓がなぜ各判断の根拠になるかを併記する。

---

## 0. 前提・現在地

- Zig による **Java Interop を完全に排除した Clojure 再実装**
- 単一バイナリ配布前提
- Beta では TreeWalk + BytecodeVM を並行実装し、`--compare` で意味論を検証
- テスト 1036 pass、clojure.core 545 関数実装、~38,000 行
- **Babashka より起動が速く、メモリ使用量も少ない**
- 正式版は **英語コメント・英語ドキュメント・OSS 体裁** でスクラッチ再設計

---

## 1. Wasm の位置付け

### 検討した選択肢

#### A. Wasm を Clojure ライブラリとして利用
- JVM / FFI 経由で Wasm を呼ぶ

**採用しなかった理由**
- JVM/FFI のオーバーヘッドで Wasm の高速性が失われる
- GC 境界が重く、性能面で意味が薄い

#### B. Clojure を全面的に Wasm に寄せる
- 値表現・GC を WasmGC に統合

**採用しなかった理由**
- Clojure の値モデル (NaN boxing / 永続 DS) と WasmGC が根本的に合わない
- 勝手に解放される危険
- 研究レベルで現実的でない

### 最終判断

- **Wasm は「AOT 最適化された高速プリミティブ実行層」**
- 動的性・意味論は Clojure 側で保持
- 固定高速コア + 動的制御層という構図を採用

### Beta での実感

Beta の Wasm 層は 10 API の薄いラッパー (623 行) にとどまった。
型変換は i32/i64/f64 のみ、戻り値は単一値、ホスト関数は 256 スロット固定テーブル。
「Wasm は高速プリミティブ層」という構想自体は正しいが、
正式版では以下の段階を踏む必要がある:

1. **Phase 1**: 型安全な境界 — Wasm 関数シグネチャに基づく自動変換、multi-value return
2. **Phase 2**: 構造データ受け渡し — メモリ上の構造体マーシャリングヘルパー
3. **Phase 3**: エコシステム連携 — Wasm で配布されたライブラリを Clojure から自然に使う

---

## 2. 動的性と Wasm の関係

- Wasm 自体を動的に書き換えるのはセキュリティ的に不適切
- 代わりに:
  - Wasm をラップする Clojure 関数は動的
  - 合成・差し替え・検証は REPL 側で実施

**結論**: 動的性は Wasm の外側で担保する

### Beta からの知見

Beta で `threadlocal` callback パターン (`call_fn`, `force_fn` 等) を多用した。
Clojure 関数を Wasm ホスト関数として登録する際にも同じパターンが使える。
ただし Beta の 256 スロット静的テーブルは制約が強すぎた。
正式版ではクロージャベースの登録方式に移行し、スロット数制限を撤廃する。

---

## 3. 型・引数検証とマクロ

- Clojure の柔軟性と Wasm の厳密な型のギャップが課題

**方針**
- 言語仕様は変えない
- マクロで境界コードを生成
  - 型検証
  - 変換
  - unsafe / fast パス併存

### Beta からの知見

Beta では Value 型が 28+ variant の tagged union に膨張した。
型判定は switch exhaustiveness で網羅性を保証しているが、
新しい型を追加するたびに traceValue / fixupValue / deepClone / format / eql の
5箇所を同時更新する必要があり、漏れが GC クラッシュに直結した。

正式版では:
- Value variant 数を抑制する設計 (NaN boxing による inline 化)
- 型追加時の更新箇所を comptime で検証する仕組み

---

## 4. WIT / Component Model

### 認識
- WIT は単なる仕様書ではなく、実運用されている IDL
- Clojure 界隈では未開拓
- Wasm ライブラリのエコシステムとしてはまだ発展途上

### 方針
- WIT を **Clojure データとして表現**
- hiccup / honeysql / malli 系譜の DSL
- ベクタ + キーワードで順序を保持
- WIT <-> Clojure DSL の相互変換

### 現実的な段階

WIT/Component Model は正式版でも最初から取り組むべき領域ではない。
Wasm ライブラリのエコシステムが成熟してから着手しても遅くない。

1. **初期**: Wasm モジュールの手動ロード・呼び出し (Beta 相当の機能強化版)
2. **中期**: WIT 定義からの Clojure ラッパー自動生成
3. **長期**: Component Model 対応 (複数モジュールの型安全な合成)

---

## 5. GC・バイトコード・最適化

### WasmGC の整理
- WasmGC は Wasm 世界内部の GC
- Clojure の GC を置き換えるものではない

### 採用した考え方
- GC を差し替え可能にしようとしない
- 責務を分離する

**構成**
- Clojure 値・永続 DS -> 自前 GC
- Wasm オブジェクト -> WasmGC
- 境界はハンドル / コピー / pin

### Beta で得た GC の教訓

Beta の GC 実装 (セミスペース Arena Mark-Sweep) から得た重要な知見:

**1. fixup の網羅性が生命線**

Arena 一括解放は高速 (GPA 比 40x) だが、ポインタ fixup を1箇所漏らすだけで
use-after-free が発生する。しかも「即座にクラッシュしない」のが最も危険。
正式版では:
- `else => {}` を禁止し、新タグ追加時にコンパイルエラーで検出
- comptime でタグと fixup 関数の対応を検証

**2. Safe Point GC の制約**

Zig builtin 関数のローカル変数は GC ルートとして追跡されない。
セミスペースコピーでオブジェクトが移動すると、Zig スタック上のポインタが
旧アドレスを指したまま SIGSEGV になる。
Beta では recur opcode でのみ GC チェックを行う妥協をした。
正式版では:
- builtin 関数の中間値を VM スタックか専用ルート配列に退避する設計を最初から組む
- または NaN boxing で GC 移動対象を減らす

**3. Deep Clone の蔓延**

scratch -> persistent の安全化のため、def / swap! / atom / constant 等あらゆる箇所で
deepClone が必要になった。正式版ではアロケータ戦略を見直し、
コピー頻度を構造的に減らす。

**4. 世代別 GC は式境界 GC では効果限定**

G2a-c で Nursery + promotion を実装したが、式境界での GC では
Young -> Old の参照パターンが稀で、write barrier の投資対効果が低かった。
正式版で世代別を採用するなら、式境界ではなく関数境界 or allocation 閾値ベースに。

### 将来の設計余地
- ルート列挙形式 (stack map)
- write barrier フック
- メモリ境界の明確化

---

## 6. Wasm 実行エンジン選択

### 検討
- zware (Beta で利用)
- Wasmtime
- 完全自作

### 判断
- zware を当面利用 (Zig 完結・軽量)
- Wasmtime は将来の backend として視野に入れる
- WasmBackend interface を Zig 側に用意し差し替え可能に

### Beta での実感

zware は Zig 完結で組み込みやすく、学習目的には最適だった。
ただし以下の制約がある:
- multi-value return 未対応の可能性
- WASI は手動登録が必要 (自動解決なし)
- `@ptrCast` によるシグネチャ適合がフラジャイル

正式版では WasmBackend trait を最初から定義し、
zware / Wasmtime / 自作エンジンを差し替え可能にする。

---

## 7. 超高速バイナリ路線 vs Wasm フリーライド路線

二路線は完全には両立しない。GC / バイトコード実装は分岐する。

### native 路線 (超高速単一バイナリ)
- GC: 自前 (セミスペース or 世代別)
- 最適化: 自前 (NaN boxing, inline caching, fused reduce 等)
- 配布: 単一バイナリ、起動即実行
- 用途: CLI ツール、Server Function、Edge Computing

### wasm_rt 路線 (Wasm ランタイムフリーライド)
- GC: WasmGC に委ねられる部分は委ねる
- 最適化: ランタイムの JIT / TCO を活用
- 配布: .wasm ファイル、WasmEdge 等のランタイム上で実行
- 用途: ポータブルなサービス、Wasm-first なプラットフォーム

**重要な決断**
- 一本化しない
- 実行時分岐は入れない

---

## 8. アーキテクチャ方針

### 単一リポジトリ・comptime 切替

Beta ではリポジトリ分離の構想があったが、
現実には Reader/Analyzer にもバックエンド依存が入り込む
(エラー追跡、REPL 統合、ネイティブ最適化パス等)。

**正式版の方針**: 単一リポジトリ、Zig の `comptime` でビルド時に世界線を切替。

```
src/
├── common/           # 両路線で共有
│   ├── reader/       # Tokenizer, Reader, Form
│   ├── analyzer/     # Analyzer, Node, macro expansion
│   ├── bytecode/     # OpCode 定義、定数テーブル形式
│   └── value/        # Value 型定義 (表現は路線別)
│
├── native/           # 超高速・単一バイナリ路線
│   ├── vm/           # VM 実行エンジン (NaN boxing 等)
│   ├── gc/           # 自前 GC (セミスペース/世代別)
│   ├── optimizer/    # 定数畳み込み、fused reduce 等
│   └── main.zig
│
├── wasm_rt/          # Wasm ランタイムフリーライド路線
│   ├── vm/           # Wasm target VM
│   ├── gc_bridge/    # WasmGC 連携
│   ├── wasm_backend/ # WasmBackend trait 実装
│   └── main.zig
│
└── build.zig         # comptime で native / wasm_rt を選択
```

### 共有層の境界

Beta の経験から、共有しやすい / しにくい領域:

| 層             | 共有可能性 | 理由                                                     |
|----------------|------------|----------------------------------------------------------|
| Reader         | 高         | 純粋なパーサ、バックエンド非依存                         |
| Analyzer       | 中〜高     | マクロ展開は共通だが、最適化パスが分岐する可能性         |
| OpCode 定義    | 中         | 意味論は共通、native 固有の高速 opcode が入る可能性      |
| VM             | 低         | 実行エンジンの中核。native と wasm_rt で根本的に異なる   |
| GC             | 低         | 責務が完全に異なる                                       |
| Value 型定義   | 中         | variant は共通だが内部表現 (NaN boxing 等) は路線依存    |
| builtin 関数   | 中〜高     | 意味論は共通、GC/アロケータ依存コードは路線別            |

### Zig の活用
- comptime で世界線をビルド時に切替
- 実行時分岐ゼロ
- 不要コードはリンクされない

---

## 9. Beta から正式版へ持ち越す設計知見

Beta の開発で確立した知見のうち、正式版で最初から組み込むべきもの:

### 9.1 コンパイラ-VM 間の契約を明文化する

Beta で最も多かったバグは「コンパイラが emit する値と VM が解釈する値の意味の不一致」。
capture_count, slot 番号, scope_exit の引数など、暗黙の契約が壊れると
**クラッシュではなく間違った値を返す** (静かに壊れる)。

**正式版**: 契約を型で表現し、comptime で整合性を検証。

### 9.2 デュアルバックエンドの `--compare` は初期から用意する

Beta の `--compare` モード (TreeWalk と VM の突き合わせ) は
バグ発見の最も有効な手段だった。
正式版でも**意味論の参照実装** (遅くてよい) を維持し、
高速実装との差分検出に使う。

ただし Beta では TW と VM 両方の維持コストが大きかった。
正式版では参照実装をより軽量にする (例: インタプリタではなくテストオラクル生成)。

### 9.3 Fused Reduce パターン

lazy-seq チェーン (take -> map/filter -> source) を単一ループに展開する最適化は
メモリ効率に劇的な効果があった (map_filter: 27GB -> 2MB)。
正式版では最初からこのパターンを VM レベルで組み込む。

### 9.4 アロケータ分離原則

Env/Namespace/Var/HashMap は GPA 直接管理 (GC 対象外)、
Clojure Value のみ GcAllocator 経由という分離は正しかった。
正式版でも「インフラ vs ユーザー値」の寿命分離を初期設計に含める。

### 9.5 永続データ構造への移行

Beta では配列ベースの簡易コレクション実装を採用した (Vector = ArrayList)。
正式版では HAMT / RRB-Tree 等の永続データ構造を最初から導入し、
構造共有による GC 負荷軽減と Clojure 意味論の正確な再現を目指す。

---

## 10. 進め方

1. **native 路線を完成させる**
   - NaN boxing / 永続 DS / GC 改良で到達点を把握
   - Server Function / Edge での強みを確立

2. **Wasm フリーライド路線は実験的に並行**
   - GC 二層モデル理解
   - WIT / Component Model の接続感確認
   - プロダクション品質は求めない

3. **正式版はスクラッチで再設計**
   - 両路線の知見を統合
   - 英語・OSS 体裁・ライセンス整備
   - §9 の知見を設計の前提として組み込む

---

## 11. まとめ

ClojureWasm は
「超高速単一バイナリとして成立する Clojure」をまず極め、
その上で Wasm ランタイムの力を **選択的に借りられる構造**を目指す。

世界線は comptime で切替え、単一リポジトリで管理する。
Beta で学んだ「静かに壊れるバグ」「GC の網羅性」「暗黙の契約」を
正式版では設計レベルで防止する。
