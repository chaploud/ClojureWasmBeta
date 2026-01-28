# セッションメモ

> 現在地点・次回タスク。技術ノートは `notes.md` を参照。

---

## 現在地点

**Phase LAST 完了 — Wasm 連携 (zware)**

### Phase LAST サブフェーズ

| Sub   | 内容                              | 状態         |
|-------|-----------------------------------|--------------|
| La    | zware 導入 + load + invoke (数値) | ✅ 完了      |
| Lb    | メモリ操作 + 文字列 interop       | ✅ 完了      |
| Lc    | ホスト関数注入 (Clojure→Wasm)     | ✅ 完了      |
| Ld    | WASI 基本サポート                 | ✅ 完了      |
| Le    | エラー改善 + GC + ドキュメント    | ✅ 完了      |

### 完了フェーズ

| Phase | 内容                                                                                          |
|-------|-----------------------------------------------------------------------------------------------|
| 1-4   | Reader, Runtime基盤, Analyzer, TreeWalk評価器                                                 |
| 5     | ユーザー定義関数 (fn, クロージャ)                                                             |
| 6     | マクロシステム (defmacro)                                                                     |
| 7     | CLI (-e, 複数式, 状態保持)                                                                    |
| 8.0   | VM基盤 (Bytecode, Compiler, VM, --compare)                                                    |
| 8.1   | クロージャ完成, 複数アリティfn, 可変長引数                                                    |
| 8.2   | 高階関数 (apply, partial, comp, reduce)                                                       |
| 8.3   | 分配束縛 (シーケンシャル・マップ)                                                             |
| 8.4   | シーケンス操作 (map, filter, take, drop, range 等)                                            |
| 8.5   | 制御フローマクロ・スレッディングマクロ                                                        |
| 8.6   | try/catch/finally 例外処理                                                                    |
| 8.7   | Atom 状態管理 (atom, deref, reset!, swap!)                                                    |
| 8.8   | 文字列操作拡充                                                                                |
| 8.9   | defn・dotimes・doseq・if-not・comment                                                         |
| 8.10  | condp・case・some->・some->>・as->・mapv・filterv                                             |
| 8.11  | キーワードを関数として使用                                                                    |
| 8.12  | every?/some/not-every?/not-any?                                                               |
| 8.13  | バグ修正・安定化                                                                              |
| 8.14  | マルチメソッド (defmulti, defmethod)                                                          |
| 8.15  | プロトコル (defprotocol, extend-type, extend-protocol)                                        |
| 8.16  | ユーティリティ関数・HOF・マクロ拡充                                                           |
| 8.17  | VM let-closure バグ修正                                                                       |
| 8.18  | letfn（相互再帰ローカル関数）                                                                 |
| 8.19  | 実用関数・マクロ大量追加（~83関数/マクロ）                                                    |
| 8.20  | 動的コレクションリテラル（変数を含む [x y], {:a x} 等）                                       |
| 9     | LazySeq — 真の遅延シーケンス（無限シーケンス対応）                                            |
| 9.1   | Lazy map/filter/concat — 遅延変換・連結                                                       |
| 9.2   | iterate/repeat/cycle/range()/mapcat — 遅延ジェネレータ・lazy mapcat                           |
| 11    | PURE述語(23)+コレクション/ユーティリティ(17)+ビット演算等(17) = +57関数                       |
| 12    | PURE残り: 述語(15)+型キャスト(6)+算術(5)+出力(4)+ハッシュ(4)+MM拡張(6)+HOF(6)+他(7) = +53関数 |
| 13    | DESIGN: delay/force(3)+volatile(4)+reduced(4) = 新型3種+11関数、deref拡張                     |
| 14    | DESIGN: transient(7)+transduce基盤(6) = Transient型+13関数                                    |
| 15    | DESIGN: Atom拡張(7)+Var操作(6)+メタデータ(3) = +16関数                                        |
| 17    | DESIGN: 階層システム(7) = make-hierarchy/derive/underive/isa?等                               |
| 18    | DESIGN: promise/deliver + ユーティリティ(10) = Promise型+UUID+他                              |
| 18b   | DESIGN: partitionv/splitv-at/tap/parse-uuid 等(9) = 追加ユーティリティ                        |
| 19a   | DESIGN: class/struct/accessor/xml-seq等(9) = struct操作+ユーティリティ                        |
| 19b   | DESIGN: eval/read-string/sorted/dynamic-vars(18+14dynvar) = eval基盤+ソートcol+動的Var        |
| 19c   | DESIGN: NS操作/Reader/定義マクロ等(27+2dynvar) = 名前空間スタブ+load+definline                |
| 20    | FINAL: 残り59一括実装 — binding/chunk/regex/IO/NS/defrecord/deftype/動的Var                   |
| 21    | GC: Mark-Sweep at Expression Boundary (GcAllocator + tracing + 式境界GC)                      |
| 22    | 正規表現エンジン（フルスクラッチ Zig 実装）                                                   |
| 23    | 動的バインディング（本格実装）                                                                |
| 24    | 名前空間（本格実装）                                                                          |
| 25    | REPL (対話型シェル)                                                                           |
| 26    | Reader Conditionals + 外部ライブラリ統合テスト (medley v1.4.0)                                |
| T1    | Assert ベーステストランナー (基盤)                                                            |
| T2    | sci 関数カバレッジ監査 + コアテスト (372/390 pass = 95%)                                      |
| T3    | 最小 clojure.test 実装 (deftest/is/testing/run-tests)                                         |
| T4    | sci テストスイート移植                                                                        |
| Q3    | Var システム修正 (def返値, #'var呼出, var-set, alter-var-root, defonce)                       |
| Q4a   | VM reduced 対応                                                                               |
| Q2b   | fn-level recur 修正                                                                           |
| Q1a   | Special Form 正規化 eager 7関数 (apply/partial/comp/reduce/sort-by/group-by/swap!)            |
| Q1b   | Special Form 正規化 lazy 5関数 (map/filter/take-while/drop-while/map-indexed)                 |
| Q1c   | 死コード削除 (12 Node/Opcode, -1,400行)                                                      |
| Q2a   | Map/Set リテラル in マクロ展開修正 (valueToForm に map/set 追加)                              |
| Q4b   | letfn 相互再帰修正 (fn名省略でインデックスずれ解消)                                          |
| Q5a   | with-out-str 実装 (threadlocal output capture)                                               |

### 実装状況

549 done / 169 skip / 0 todo (概算)

照会: `yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' status/vars.yaml`

---

## Phase T4 実装詳細

### テスト全体結果

**760 pass, 1 fail(意図的), 0 error** (total: 761)

### sci テストスイート移植

| テストファイル                           | テスト | アサーション | 状態 |
|------------------------------------------|--------|--------------|------|
| `test/compat/sci/core_test.clj`          | 33     | 123          | PASS |
| `test/compat/sci/vars_test.clj`          | 7      | 15           | PASS |
| `test/compat/sci/hierarchies_test.clj`   | 5      | 5            | PASS |
| `test/compat/sci/multimethods_test.clj`  | 4      | 4            | PASS |
| `test/compat/sci/error_test.clj`         | 6      | 12           | PASS |
| **sci 合計**                             | **55** | **159**      |      |

### compat テスト

| テストファイル                           | アサーション | 状態 |
|------------------------------------------|--------------|------|
| `test/compat/atoms.clj`                  | 33           | PASS |
| `test/compat/collections.clj`            | 76           | PASS |
| `test/compat/control_flow.clj`           | 53           | PASS |
| `test/compat/core_basic.clj`             | 54           | PASS |
| `test/compat/dynamic_binding.clj`        | 15           | PASS |
| `test/compat/higher_order.clj`           | 33           | PASS |
| `test/compat/lazy_seq.clj`               | 39           | PASS |
| `test/compat/multimethods.clj`           | 17           | PASS |
| `test/compat/predicates.clj`             | 91           | PASS |
| `test/compat/regex.clj`                  | 17           | PASS |
| `test/compat/sequences.clj`              | 48           | PASS |
| `test/compat/strings.clj`                | 54           | PASS |
| `test/compat/test_framework_test.clj`    | 8+1 fail     | PASS(意図的1fail) |
| `test/compat/var_system.clj`             | 13           | PASS |
| `test/compat/wasm_basic.clj`             | 15           | PASS |
| `test/compat/wasm_memory.clj`            | 7            | PASS |
| `test/compat/wasm_host.clj`              | 5            | PASS |
| `test/compat/wasm_wasi.clj`              | 4            | PASS |
| **compat 合計**                          | **564**      |      |

### テスト基盤

| ファイル                    | 内容                                      |
|-----------------------------|-------------------------------------------|
| `src/clj/clojure/test.clj` | 最小 clojure.test (deftest/is/run-tests)  |
| `test/lib/test_runner.clj`  | Assert ベーステストランナー               |
| `test/run_tests.sh`         | シェルテストランナー (T2+sci 両対応)      |

### テスト移植時の制限回避ルール

deftest body 内 (= defn body 内) で使えない構文:
- ~~マップリテラル `{...}`~~ → Q2a で修正済み
- ~~セットリテラル `#{...}`~~ → Q2a で修正済み
- マップ分配束縛 `{:keys [...]}` → 外部ヘルパー関数
- `def ^:dynamic` / `defmacro` → 外部ヘルパー関数
- `(def name "docstring" value)` (3-arg def) → スキップ

### 新規発見バグ一覧

| バグ                                   | 影響         | 回避策                            | 修正Phase |
|----------------------------------------|--------------|-----------------------------------|-----------|
| map/set リテラル in macro body         | load-file 時 | hash-map/hash-set                 | Q2a ✅    |
| fn-level recur returns nil             | defn+recur   | loop+recur を使用                 | Q2b ✅    |
| vector-list equality broken            | = [1] '(1)   | 修正済み (eql で sequential 比較) | 済        |
| map-as-fn 2-arity                      | ({:a 1} k d) | get with default                  | —         |
| symbol-as-fn                           | ('a map)     | get                               | —         |
| defonce not preventing redef           | defonce      | スキップ                          | Q3e ✅    |
| letfn mutual recursion                 | letfn f→g    | スキップ                          | Q4b ✅    |
| #'var as callable                      | (#'foo)      | スキップ                          | Q3b ✅    |
| (str (def x 1)) returns ""             | def-returns  | スキップ                          | Q3a ✅    |
| ^:const not respected                  | const        | スキップ                          | —         |
| var-set no effect                      | var-set      | スキップ                          | Q3c ✅    |
| alter-var-root uses thread-local       | avr+binding  | スキップ                          | Q3d ✅    |
| with-local-vars not implemented        | wlv          | スキップ                          | —         |
| add-watch on var not implemented       | add-watch    | スキップ                          | —         |
| thread-bound? 1-arity only             | thread-bound | 1引数で使用                       | —         |
| defmacro inside defn → Undefined       | defmacro     | トップレベルで定義                | —         |
| with-out-str 未実装 (出力未キャプチャ) | io           | str(do body) に展開、空文字列     | Q5a ✅    |
| VM reduced 未対応                      | reduce early | TreeWalk のみ                     | Q4a ✅    |

### 本セッションで実装した機能

- **Q3**: Var システム修正 (def返値→Var, #'var呼出, var-set thread binding, alter-var-root root, defonce)
- **Q4a**: VM reduced 対応 (executeReduce に reduced_val チェック追加)
- **Q2b**: fn-level recur (callWithArgs にリカーループ追加)
- **Q1a**: Special Form 正規化 eager 7関数 → builtin 移行 (apply/partial/comp/reduce/sort-by/group-by/swap!)
  - analyzeList の 7 分岐削除、core.zig に 7 builtin 関数追加
- **Q1b**: Special Form 正規化 lazy 5関数 → builtin 移行 (map/filter/take-while/drop-while/map-indexed)
  - TransformKind 拡張 (take_while/drop_while/map_indexed)
  - forceTransformOneStep の nil要素バグ修正 (isSourceExhausted 導入)
  - reverse の lazy-seq 対応修正
  - 第一級関数テスト 19 assertions
  - 全テスト 710 pass 維持
- **Q1c**: 死コード削除 (-1,400行)
  - node.zig: 12 struct定義 + 12 union variant + switch cases 削除
  - emit.zig: 12 emitXxx 関数 + dispatch cases 削除
  - bytecode.zig: 12 opcode 削除 (apply/partial/comp/reduce/map_seq/filter_seq 等)
  - vm.zig: executeXxx 関数 + WithExceptionHandling ラッパー + vmValueCompare 削除
  - analyze.zig: 12 analyzeXxx 関数削除
- **Q2a**: Map/Set リテラル in マクロ展開修正
  - valueToForm() に .map/.set ケース追加 (formToValue と対称化)
  - deftest body 内で {:a 1}, #{x} が使用可能に
- **Q4b**: letfn 相互再帰修正
  - 根本原因: analyzeLetfn で fn に名前を渡すと analyzeFn が自己参照ローカルを追加し、
    ローカルインデックスがずれる (余分なスロット → パラメータが範囲外に)
  - 修正: letfn Phase 2 で fn 名を省略 (自己参照は letfn スコープで提供済み)
  - evaluator で Fn.name をセット (デバッグ表示用)
  - letfn テスト 10 assertions 追加 (基本/自己再帰/相互再帰/前方参照/3-way 等)
  - 全テスト 720 pass 維持
- **Q5a**: with-out-str 実装
  - threadlocal output_capture バッファによる stdout キャプチャ
  - 全 print 系関数 (println/print/pr/prn/newline/printf) を output_capture 対応に修正
  - __begin-capture / __end-capture builtin 関数追加
  - with-out-str マクロ展開を let + do + capture に変更
  - ネスト対応 (内側キャプチャが外側に漏れない)
  - with-out-str テスト 9 assertions 追加
  - 全テスト 729 pass 維持

前セッション:
- keyword 2-arity / lazy-seq 等価比較 / memoize 本実装 / identical? キーワード

### 既知の制限 (Phase 26 から引き継ぎ)

- sets-as-functions 未対応 (`#{:a :b}` を関数として使用不可)
- フル medley の `compare-and-set!`/`deref-swap!`/`deref-reset!` 未実装
- ~~文字列表示で `!` がエスケープされる~~ → シェル環境の問題 (コードバグではない)
- VM での `with-redefs` 後のユーザー関数呼び出しクラッシュ (Phase 23 由来)

---

## ロードマップ

### Phase Q: Wasm 前品質修正 — 完了

```
  Q3  ✅ Var システム修正
  Q4a ✅ VM reduced 対応
  Q2b ✅ fn-level recur 修正
  Q1a ✅ Special Form 正規化 (eager 7関数)
  Q1b ✅ Special Form 正規化 (lazy 5関数)
  Q2a ✅ Map/Set リテラル in マクロ展開修正
  Q4b ✅ letfn 相互再帰修正
  Q1c ✅ 死コード削除 (12 Node/Opcode, -1400行)
  Q5a ✅ with-out-str 実装 (threadlocal output capture)
  Q6  ✅ ドキュメント整備
```

### 現在のフェーズ

```
Phase LAST: Wasm 連携 (zware pure Zig runtime) — 完了
  La ✅ zware 導入 + load + invoke (数値のみ)
  Lb ✅ メモリ操作 + 文字列 interop
  Lc ✅ ホスト関数注入 (Clojure→Wasm)
  Ld ✅ WASI 基本サポート
  Le ✅ エラー改善 + wasm/close + ドキュメント
```

---

## 設計判断の控え

1. **正規表現**: Zig フルスクラッチ実装。バックトラッキング方式で Java regex 互換。
2. **skip 方針**: 明確に JVM 固有（proxy, agent, STM, Java array, unchecked-*, BigDecimal）のみ skip。
   迷うものは実装する。
3. **JVM 型変換**: byte/short/long/float 等は Zig キャスト相当に簡略化。
   instance?/class は内部タグ検査。深追いせず最小限で。
4. **GC**: 式境界 Mark-Sweep。GcAllocator で Clojure Value のみ追跡。
   インフラ (Env/Namespace/Var/HashMap) は GPA 直接管理で GC 対象外。
   閾値超過時にのみ実行。サイクル検出付き (自己参照 fn 等に対応)。
   loop/recur は recur_buffer で in-place 更新 (GC 負荷を大幅削減)。
5. **動的バインディング**: マクロ展開方式 (push+try/finally+pop)。
   新 Node/Opcode 不要。既存インフラを最大限活用。

詳細: `docs/reference/architecture.md`
