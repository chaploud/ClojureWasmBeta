# セッションメモ

> 現在地点・次回タスク。技術ノートは `notes.md` を参照。

---

## 現在地点

**Phase 9.2 完了 — 遅延ジェネレータ・lazy mapcat**

| Phase | 内容 |
|-------|------|
| 1-4 | Reader, Runtime基盤, Analyzer, TreeWalk評価器 |
| 5 | ユーザー定義関数 (fn, クロージャ) |
| 6 | マクロシステム (defmacro) |
| 7 | CLI (-e, 複数式, 状態保持) |
| 8.0 | VM基盤 (Bytecode, Compiler, VM, --compare) |
| 8.1 | クロージャ完成, 複数アリティfn, 可変長引数 |
| 8.2 | 高階関数 (apply, partial, comp, reduce) |
| 8.3 | 分配束縛（シーケンシャル・マップ） |
| 8.4 | シーケンス操作 (map, filter, take, drop, range 等) |
| 8.5 | 制御フローマクロ・スレッディングマクロ |
| 8.6 | try/catch/finally 例外処理 |
| 8.7 | Atom 状態管理 (atom, deref, reset!, swap!) |
| 8.8 | 文字列操作拡充 |
| 8.9 | defn・dotimes・doseq・if-not・comment |
| 8.10 | condp・case・some->・some->>・as->・mapv・filterv |
| 8.11 | キーワードを関数として使用 |
| 8.12 | every?/some/not-every?/not-any? |
| 8.13 | バグ修正・安定化 |
| 8.14 | マルチメソッド (defmulti, defmethod) |
| 8.15 | プロトコル (defprotocol, extend-type, extend-protocol) |
| 8.16 | ユーティリティ関数・HOF・マクロ拡充 |
| 8.17 | VM let-closure バグ修正 |
| 8.18 | letfn（相互再帰ローカル関数） |
| 8.19 | 実用関数・マクロ大量追加（~83関数/マクロ） |
| 8.20 | 動的コレクションリテラル（変数を含む [x y], {:a x} 等） |
| 9 | LazySeq — 真の遅延シーケンス（無限シーケンス対応） |
| 9.1 | Lazy map/filter/concat — 遅延変換・連結 |
| 9.2 | iterate/repeat/cycle/range()/mapcat — 遅延ジェネレータ・lazy mapcat |

実装状況: 228 done / 174 skip / 300 todo
照会: `yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' status/vars.yaml`

---

## ロードマップ

### 論点整理

残り 300 todo の Var は以下の 4 層に分かれる:

| 層 | 数 | 性質 |
|---|---|---|
| **PURE** | ~120 | 既存基盤の組み合わせ。設計不要。述語・シーケンス操作・ユーティリティ |
| **DESIGN** | ~86 | 新しいデータ構造・パターンが要るが、サブシステムは不要 |
| **SUBSYSTEM** | ~80 | 新サブシステムが必要（正規表現、名前空間、I/O） |
| **JVM_ADAPT** | ~10 | JVM 概念を簡略化移植（型変換・型チェック） |

**設計判断が必要な論点:**

1. **GC のタイミング**: LazySeq 導入でヒープ割り当てが急増。Arena 一括解放モデルでは
   長時間 REPL セッションでメモリが際限なく増える。しかしシンプルな GC で十分。
2. **PURE の一括実装**: 120 件は設計不要だが量が多い。バッチで進める。
3. **DESIGN 層の優先順位**: delay/force（簡単）→ volatile（簡単）→ transient（性能）
   → defrecord（実用性）→ 階層システム（multimethod 完成）→ Var 拡張（binding 等）
4. **SUBSYSTEM の取捨**: 正規表現（最重要）→ 名前空間（マルチファイル必須）
   → I/O（実用プログラム必須）→ reader/eval（セルフホスティング基盤）。
   正規表現は Zig 標準ライブラリにないため外部実装 or 自前が要る。
5. **JVM 概念の代替**: `byte`/`short`/`long` 等の型変換は Zig のキャスト相当に簡略化。
   `instance?`/`class` は内部タグ検査。深追いせず最小限で。
6. **skip にしない方針**: 明確に JVM 固有（proxy, agent, STM, Java array, unchecked-*,
   BigDecimal）のみ skip。迷うものは実装する。

---

### フェーズ計画

```
Phase 10: GC（シンプル版）
  └ mark-and-sweep or arena + 世代管理
  └ LazySeq のサンク→実体化で不要になった参照を回収

Phase 11: PURE 述語バッチ（~30 件）
  └ any?, boolean?, int?, double?, char?, ident?, indexed?,
    map-entry?, NaN?, infinite?, nat-int?, neg-int?, pos-int?,
    simple-ident?, simple-keyword?, simple-symbol?,
    qualified-ident?, qualified-keyword?, qualified-symbol?,
    special-symbol?, ifn?, identical?, record?, inst?,
    delay?, reduced?, tagged-literal?, uri?, uuid?, var?

Phase 12: PURE シーケンス・コレクション操作バッチ（~40 件）
  └ remove, list*, split-with, nthnext, nthrest, reductions,
    repeatedly, lazy-cat, tree-seq, partition-by, dedupe,
    bounded-count, rseq, empty, sequence,
    reduce-kv, merge-with, update-in, update-keys, update-vals,
    hash-set, array-map, key, val,
    bit-and-not, bit-clear, bit-flip, bit-set, bit-test,
    unsigned-bit-shift-right, compare, comparator,
    interleave, interpose, take-while/drop-while lazy 化

Phase 13: PURE ユーティリティ・HOF バッチ（~40 件）
  └ juxt, memoize, trampoline, max-key, min-key,
    rand-nth, random-sample, gensym, parse-long, parse-double,
    parse-boolean, identical?, find-keyword,
    reduced, unreduced, ensure-reduced, completing,
    transduce, cat, eduction,
    println-str, printf, newline, clojure-version,
    -', +', *', dec', inc',
    hash-combine, hash-ordered-coll, hash-unordered-coll,
    multimethod 拡張 (remove-method, get-method 等)

Phase 14: DESIGN — delay/force, volatile, transient
  └ delay/delay?/force: サンクラッパー（LazySeq より単純）
  └ volatile!/volatile?/vreset!/vswap!: ミュータブルボックス
  └ transient/persistent!/conj!/assoc!/dissoc!/disj!/pop!: 一時的ミュータブルコレクション

Phase 15: DESIGN — Atom 拡張・Var 操作・メタデータ
  └ add-watch, remove-watch, get-validator, set-validator!
  └ compare-and-set!, reset-vals!, swap-vals!
  └ var-get, var-set, alter-var-root, find-var, intern, bound?
  └ alter-meta!, reset-meta!, vary-meta

Phase 16: DESIGN — defrecord・deftype
  └ プロトコルと組み合わせた名前付きレコード型
  └ record?, instance?

Phase 17: DESIGN — 階層システム
  └ make-hierarchy, derive, underive, ancestors, descendants, parents, isa?
  └ マルチメソッドの完全なディスパッチ階層

Phase 18: SUBSYSTEM — 正規表現
  └ re-pattern, re-find, re-matches, re-seq, re-matcher, re-groups
  └ Zig で正規表現エンジン実装 or PCRE バインディング

Phase 19: DESIGN — 動的束縛・sorted コレクション
  └ binding, with-bindings, set! 等（束縛フレームスタック）
  └ sorted-map, sorted-map-by, sorted-set, sorted-set-by（赤黒木）

Phase 20: SUBSYSTEM — 名前空間システム
  └ ns, in-ns, require, use, refer, load, load-file
  └ マルチファイルプログラム対応

Phase 21: SUBSYSTEM — I/O
  └ *in*, *out*, *err*, slurp, spit, read-line, flush
  └ with-open, with-out-str, with-in-str, line-seq

Phase 22: SUBSYSTEM — Reader/Eval
  └ read, read-string, eval, macroexpand, macroexpand-1
  └ セルフホスティング基盤

Phase LAST: Wasm 連携
  └ 言語機能充実後
```

---

## 将来のフェーズ

上記ロードマップ参照。Wasm 連携が最後。

詳細: `docs/reference/architecture.md`
