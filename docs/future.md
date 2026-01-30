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

ClojureWasm 自体を `zig build -target wasm32-wasi` で .wasm にコンパイルする路線。
ネイティブバイナリではなく、Wasm ランタイム上で動く処理系そのものを配布する。

- ビルド: Zig の Wasm ターゲットで処理系全体を .wasm 化
- GC: WasmGC アノテーションを活用し、ランタイムの GC に協調
- 最適化: ランタイムの JIT / TCO を活用。Wasm tail-call proposal 等に対応
- 配布: .wasm ファイル、WasmEdge / Wasmtime 等で実行
- 用途: ポータブルなサービス、Wasm-first なプラットフォーム

**native との違い**: ビルドされたバイナリ自体が Wasm なので、
処理系が実行中に .clj を処理する際も Wasm ランタイムの機能 (JIT, GC, TCO) が効く。
Wasm のデータ型・構造に寄せた内部表現を採用することで、
ランタイムが最適化しやすいコードを生成できる可能性がある。

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

| 層           | 共有可能性 | 理由                                                   |
|--------------|------------|--------------------------------------------------------|
| Reader       | 高         | 純粋なパーサ、バックエンド非依存                       |
| Analyzer     | 中〜高     | マクロ展開は共通だが、最適化パスが分岐する可能性       |
| OpCode 定義  | 中         | 意味論は共通、native 固有の高速 opcode が入る可能性    |
| VM           | 低         | 実行エンジンの中核。native と wasm_rt で根本的に異なる |
| GC           | 低         | 責務が完全に異なる                                     |
| Value 型定義 | 中         | variant は共通だが内部表現 (NaN boxing 等) は路線依存  |
| builtin 関数 | 中〜高     | 意味論は共通、GC/アロケータ依存コードは路線別          |

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

### 9.5 コレクション実装の見直し

Beta では配列ベースの簡易コレクション実装を採用した (Vector = ArrayList)。
正式版ではインターフェースの互換性を維持しつつ、実装は Zig の強みを活かす。

**方針**: 本家の HAMT / RRB-Tree をそのまま模倣するのではなく、
メモリ効率・速度で上回れる Zig ネイティブな実装を探求する。
Zig の comptime、Arena allocator、値型セマンティクスを活かした
高速実装が可能であれば、それを採用すべき。

**段階的アプローチ**:
1. 初期は Beta と同じ配列ベースで開始 (動作の正確性を優先)
2. プロファイル結果を見てボトルネックのコレクションから最適化
3. Vector が最も使用頻度が高いため、最初の最適化候補

**インターフェース要件** (本家互換):
- persistent (既存コレクションは変更されない)
- structural sharing (大きなコレクションのコピーコストを抑える)
- O(log32 N) の lookup/update (Map, Vector)

**GC との相互作用に注意**: 構造共有を導入すると、複数の Value が同じ内部ノードを
参照するため、fixup が木構造を辿る必要がある。Beta の「fixup 漏れ = 即死」教訓が
さらに厳しくなる。comptime での検証がより重要になる。

---

## 10. 互換性検証戦略

### 課題: Clojure には仕様書がない

Clojure は「本家実装が仕様」であり、形式仕様が先にある言語ではない。
そのため「動作互換」を検証するには本家の振る舞いを機械的に参照するしかない。

Beta では場当たり的にテストを書いた (35 ファイル, ~3,265 行)。
vars.yaml で関数の実装状況 (done/skip) を追跡しているが、
「存在する」と「正しく動く」の間に大きなギャップがある。

### 互換性のレベル定義

| レベル | 検証内容                                 | 重要度 | 検証方法            |
|--------|------------------------------------------|--------|---------------------|
| L0     | 関数/マクロが存在する                    | 必須   | vars.yaml で追跡    |
| L1     | 基本的な入出力が一致する                 | 必須   | テストオラクル      |
| L2     | 辺境値・エラーケースが一致する           | 高     | upstream テスト移植 |
| L3     | 遅延評価・副作用の観測可能な振る舞い     | 中     | 意味論テスト        |
| L4     | エラーメッセージ・スタックトレースの形式 | 低     | 互換性は追求しない  |

**原則**: 入出力の等価性を保証する。内部実装の詳細 (realize タイミング等) は、
観測可能な結果が同じであれば許容する。fused reduce 等の最適化は
「外から見た振る舞いを変えない」ことが条件。
既存の Pure Clojure コードベースを実行した際に、
ユーザーのビジネスロジックの結果が変わることは許容しない。

**注意: 副作用を含む lazy-seq と chunked sequence**

本家 Clojure は内部的に chunked sequence (32 要素単位の先読み) を使う。
そのため `(take 3 (map #(do (println %) %) (range 100)))` は
本家では 0〜31 が println される可能性がある (chunk 単位の先読み)。

ClojureWasm の fused reduce は厳密に必要な 3 要素だけ処理する。
これは**観測可能な副作用の差異**であり、互換性テストで `diff` になりうる。

ただし本家の chunked seq の挙動自体が「仕様ではなく実装詳細」とされており、
Pure Clojure のコード (副作用のない map/filter) では問題にならない。
副作用を持つ lazy 変換に依存するコードはそもそも non-idiomatic であり、
この差異は許容する判断とする。compat_status.yaml では `diff` として記録し、
理由を明記する。

### テストカタログの真実のソース

3つの upstream から機械的にテストを取り込み、継続的に同期する:

```
upstream テスト (Clojure / ClojureScript / SCI)
        ↓
   Tier 1: 決定論的ルール変換 (構文変換、NS 置換)
   Tier 2: 決定論的 Java エイリアス置換 (tryJavaInterop 拡張)
   Tier 3: AI 補助変換 → 人間レビュー → コミット (コミット後は決定論的)
        ↓
imported/ テストファイル群
        ↓ ClojureWasm で実行
        ↓
結果 → compat_status.yaml に記録
        ↓
未対応 → issue or skip (理由付き)
```

#### ソース別の特性

| ソース        | 規模       | Java 汚染    | 変換コスト | テスト行数の期待値   |
|---------------|------------|--------------|------------|----------------------|
| SCI           | ~4,650 行  | 低 (.cljc)   | 低         | ~4,000 行 (大半取込) |
| ClojureScript | ~21,400 行 | なし (.cljs) | 中         | ~15,000 行 (JS 除去) |
| Clojure 本家  | ~14,300 行 | 高 (.clj)    | 高         | ~5,000 行 (Tier 2/3) |

合計: **~24,000 行** のテストカタログを構築可能 (現在の ~3,265 行の 7 倍以上)

#### 3 段階の変換パイプライン

**Tier 1: 決定論的ルール変換** (SCI + CLJS)

変換が機械的で、結果が一意に定まるもの。最優先で取り組む。

SCI (.cljc):
- `eval*` → 直接実行
- `tu/native?` 分岐 → `true` 側を採用
- マップリテラル `{}` → `(hash-map ...)` (deftest body 内)
- Beta で 5 ファイル移植済み → 残り ~15 ファイルを同ルールで処理

ClojureScript (.cljs):
- `cljs.test` → `clojure.test` (ClojureWasm の互換層)
- `js/Error` → ClojureWasm のエラー型
- `js/Object`, `js/Array` → skip
- `satisfies?` → ClojureWasm の protocol チェック
- `catch :default` → `catch` (ClojureWasm の catch-all)

**Tier 2: Java エイリアス置換** (Clojure 本家)

Java Interop 呼び出しを ClojureWasm のネイティブ代替に変換する。
テスト関数単位で処理し、変換できたもののみ取り込む。

決定論的に変換可能なパターン:
- `System/nanoTime` → `(__nano-time)`
- `System/currentTimeMillis` → `(__current-time-millis)`
- `Thread/sleep` → `(__sleep ms)`
- `(instance? String x)` → `(string? x)`
- `(instance? Long x)` → `(integer? x)`
- `(.length s)` → `(count s)`
- `(.toUpperCase s)` → `(clojure.string/upper-case s)`
- `(import ...)` → 除去 (エイリアスでカバーされていれば)

変換不能なパターン → Tier 3 または skip:
- `proxy`, `reify`, `gen-class`
- `java.util.concurrent.*`
- reflection (`(.getMethod ...)`)
- `java.io.*` の深い利用

**Tier 3: AI 補助 + 人間レビュー** (残り)

Tier 2 で変換できなかったテストのうち、テストの意図が Java 非依存なもの:
- AI にテストの意図を解析させ、等価な Java-free テストを生成
- 人間がレビューし、正しければコミット
- コミット後は決定論的なテストとして扱う
- 変換元の upstream ref とレビュー者を記録

原則: AI 生成テストは必ず人間レビューを経る。
レビューなしの自動生成テストは信頼しない。

#### cljs.test 互換層

ClojureScript テスト (~21,400 行) をそのまま実行するため、
`cljs.test` の主要マクロを ClojureWasm で実装する:

```clojure
;; ClojureWasm が提供する cljs.test 互換 NS
(ns cljs.test)

;; 必要なマクロ/関数:
;; deftest, is, are, testing, run-tests, use-fixtures
;; assert-expr (multimethod), do-report
```

ClojureScript テストの JS 固有部分の扱い:

| CLJS パターン             | ClojureWasm での扱い              |
|---------------------------|-----------------------------------|
| `js/Error`                | ClojureWasm の例外型にマッピング  |
| `js/Object`               | skip (JS 固有)                    |
| `js/Array`                | skip (JS 固有)                    |
| `js/parseInt`             | `Integer/parseInt` エイリアス     |
| `(catch :default e ...)`  | `(catch e ...)` (catch-all)       |
| `satisfies?`              | protocol チェック (Beta 実装済み) |
| `(exists? js/Symbol)`     | `false` (JS ランタイム不在)       |
| `#js [...]` / `#js {...}` | skip (JS リテラル)                |

#### upstream 同期の自動化

- upstream リポジトリの特定コミット/タグをサブモジュールまたは snapshot で追跡
- CI でテスト生成 → 実行 → 結果を YAML に記録
- 新テストが追加されたら自動で取り込み、初回は `pending` ステータス
- upstream の変更差分から影響テストを特定し、再変換・再実行

### ステータス管理

vars.yaml (関数存在) に加え、テスト単位のステータスを管理する:

```yaml
# compat_status.yaml (構想)
tests:
  sci/core_test:
    test-eval:
      status: pass          # pass | fail | skip | pending
      source: sci
      upstream_ref: "abc123"
    test-map-indexed:
      status: skip
      source: sci
      reason: "java.util.ArrayList 依存"
      issue: null

  clojure/data_structures:
    test-associative:
      status: pass
      source: clojure
      upstream_ref: "def456"
    test-sorted-maps:
      status: fail
      source: clojure
      reason: "Sorted map 未実装"
      issue: "#42"
```

#### ステータスの意味

| ステータス | 意味                                                   |
|------------|--------------------------------------------------------|
| pass       | テストが通る                                           |
| fail       | テストが落ちる (実装が必要、またはバグ)                |
| skip       | 意図的に見送り (Java 依存、未実装型等)。理由を必ず記録 |
| pending    | 未評価 (upstream から新規取り込み、まだ実行していない) |
| diff       | 動作するが本家と微妙に異なる。差異の内容を記録         |

### Java Interop 排除と互換エイリアス

Java Interop は排除するが、プログラミング上必須な機能はエイリアスで提供する:

| 本家 (Java)                     | ClojureWasm              | 方針               |
|---------------------------------|--------------------------|--------------------|
| `System/nanoTime`               | `__nano-time` (Zig 実装) | Beta で対応済み    |
| `System/currentTimeMillis`      | `__current-time-millis`  | Beta で対応済み    |
| `slurp` / `spit`                | Zig ファイル I/O で実装  | 正式版で対応       |
| `clojure.java.io/reader`        | ネイティブ I/O で代替    | エイリアス提供     |
| `clojure.string/*`              | Zig builtin で直接実装   | Beta で対応済み    |
| `Thread/sleep`                  | Zig の `std.time.sleep`  | エイリアス提供     |
| `java.util.regex.Pattern`       | Zig フルスクラッチ regex | Beta で対応済み    |
| `BigDecimal` / `BigInteger`     | skip                     | 正式版で要検討     |
| `proxy` / `reify` / `gen-class` | skip                     | JVM 固有、代替なし |

**方針**: `tryJavaInterop` パターン (Beta の analyze.zig) を拡張し、
本家テストに含まれる `System/foo` や `java.lang.*` 呼び出しを
自動的にネイティブ代替にルーティングする。
これにより、本家テストをできるだけ「そのまま」実行できるようにする。

### Beta での教訓

- `--compare` (TW vs VM) は「内部一貫性」の検証。外部互換性の検証は別途必要
- 場当たり的なテスト追加では抜け漏れが避けられない
- SCI 移植ルールの文書化は有効だった → 自動化すればさらに効果的
- vars.yaml の `done/skip` 二値では「動くが微妙に違う」を表現できなかった

---

## 11. 進め方

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
   - §10 の互換性検証パイプラインを初期から構築

---

## 12. OSS 化とネーミング

### ライセンス

Clojure 本家は EPL-1.0。ClojureWasm が本家コードを直接利用していなくても、
テストカタログの移植やインターフェース互換を謳う以上、EPL-1.0 が自然な選択。
初期は破壊的変更ありの割り切りで進める (SemVer 0.x)。

### ネーミング

「Clojure」を名前に含めるかは慎重に検討が必要。

| プロジェクト   | 名前に「Clojure」 | 背景                                   |
|---------------|-------------------|----------------------------------------|
| ClojureScript | あり               | Rich Hickey 自身が設計・主導           |
| ClojureCLR    | あり               | clojure org 配下 (公式)                |
| ClojureDart   | あり               | コミュニティ重鎮、Conj 発表、公式紹介  |
| Babashka      | なし               | SCI ベース、独自名                     |
| SCI           | なし               | "Small Clojure Interpreter"            |
| Jank          | なし               | "A Clojure dialect on LLVM"            |

ClojureDart は Clojure 公式 Deref で紹介され Clojure/Conj で発表されているが、
Rich Hickey から明示的な商標許諾があったかは公開情報では確認できない。
Babashka / SCI / Jank は意図的に「Clojure」を名前から外している。

**結論**: 正式版の名前は OSS 公開時に決定する。
候補は仮置きしておくが、早い段階で Clojure コミュニティとの関係を整理する。
名前に「Clojure」を含めるなら、コミュニティへの貢献実績と認知が先。

---

## 13. まとめ

ClojureWasm は
「超高速単一バイナリとして成立する Clojure」をまず極め、
その上で Wasm ランタイムの力を **選択的に借りられる構造**を目指す。

世界線は comptime で切替え、単一リポジトリで管理する。
Beta で学んだ「静かに壊れるバグ」「GC の網羅性」「暗黙の契約」を
正式版では設計レベルで防止する。
