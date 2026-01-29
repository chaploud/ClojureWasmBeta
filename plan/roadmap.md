# ロードマップ

> 将来の改善計画。完了済みフェーズの履歴は `docs/changelog.md` を参照。

---

## プロジェクト指標

| 指標                  | 値                                     |
|-----------------------|----------------------------------------|
| テスト                | 1036 pass / 1 fail (意図的)            |
| clojure.core 実装状況 | 545 done / 169 skip                    |
| Zig ソースコード      | ~38,000 行 (src/ 以下)                 |
| GC                    | セミスペース Arena Mark-Sweep (式境界) |

---

## 完了済みフェーズ (サマリ)

| フェーズ | 状態           | 概要                                                                                     |
|----------|----------------|------------------------------------------------------------------------------------------|
| Phase R  | ○ R1-R7 完了   | リファクタリング (core.zig/value.zig 分割, branchHint, 死コード除去, Zig イディオム改善) |
| Phase P  | ○ P1-P2c 完了  | 高速化 (ベンチマーク基盤, VM最適化, Map ハッシュ)                                        |
| Phase G  | ○ G1a-G1c 完了 | GC (計測基盤, セミスペース Arena 40x 高速化)                                             |
| Phase U  | ○ U1-U6 完了   | UX (REPL readline, エラー表示, doc/dir, バグ修正, CLI, nREPL)                            |
| Phase S  | S1a-S1j 完了   | セルフホスト (10 標準名前空間)                                                           |
| Phase D  | ○ D1-D3 完了   | ドキュメント (presentation, getting_started, developer_guide)                            |

---

## 実行計画

**実行順序は `plan/memo.md` を参照。** セッション開始時は memo.md の「実行計画」テーブルを確認し、未完了の最初のタスクから着手すること。

---

## タスク詳細

### U4: 既知バグ

| バグ                   | 難易度 |
|------------------------|--------|
| ^:const 未対応         | 中     |
| with-local-vars 未実装 | 中     |
| defmacro inside defn   | 高     |

### S1: clojure.pprint

本家互換の pretty-print 実装。`pprint`, `cl-format`, `print-table` 等。

### P3: NaN boxing

Value を 64bit に収める。int/float/nil/bool をインライン化し、ポインタは下位ビットでタグ付け。

### G2: 世代別 GC

| ステップ | 内容                                   |
|----------|----------------------------------------|
| G2a      | GC 計測基盤 (alloc 数、GC 頻度、pause) |
| G2b      | Young generation bump allocator        |
| G2c      | minor GC + promotion                   |
| G2d      | write barrier (card marking)           |
| G2e      | チューニング (閾値、promote 回数)      |

### P3: inline caching

関数呼び出しサイトに前回の解決結果をキャッシュ。monomorphic/polymorphic 対応。

### P3: 定数畳み込み

Compiler 側で `(+ 1 2)` → `3` 等の定数式を事前評価。

### P3: tail call dispatch

computed goto 相当の最適化。末尾呼び出しをジャンプに変換。

---

## スコープ外 (将来検討)

- **S2**: セルフホスト化 (pure 関数の .clj 移行)
- **S1**: clojure.core.protocols, clojure.java.io サブセット

---

## 参照

- 現在地点: `plan/memo.md`
- 技術ノート: `plan/notes.md`
- 完了履歴: `docs/changelog.md`
- 全体設計: `docs/reference/architecture.md`
- 実装状況: `status/vars.yaml`
