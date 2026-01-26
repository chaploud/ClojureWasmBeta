# セッションメモ

> 現在地点・次回タスク。技術ノートは `notes.md` を参照。

---

## 現在地点

**Phase 8.16 完了**

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

実装状況の詳細: `yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' status/vars.yaml`

---

## 次回タスク候補

- VM の let-closure バグ修正（`(let [x 0] (fn [] x))` で x がキャプチャされない）
- LazySeq（真の遅延シーケンス）
- 正規表現
- letfn（相互再帰ローカル関数）
- defrecord（プロトコルと組み合わせ）

---

## 将来のフェーズ

| Phase | 内容 | 依存 |
|-------|------|------|
| 9 | LazySeq（真の遅延シーケンス）| 無限シーケンスに必要 |
| 10 | GC | LazySeq導入後に必須 |
| 11 | Wasm連携 | 言語機能充実後 |

詳細: `docs/reference/architecture.md`
