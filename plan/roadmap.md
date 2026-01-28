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

| フェーズ | 状態         | 概要                                                          |
|----------|--------------|---------------------------------------------------------------|
| Phase R  | ✅ R1-R6 完了 | リファクタリング (core.zig/value.zig 分割, branchHint, 死コード除去) |
| Phase P  | ✅ P1-P2c 完了 | 高速化 (ベンチマーク基盤, VM最適化, Map ハッシュ)              |
| Phase G  | ✅ G1a-G1c 完了 | GC (計測基盤, セミスペース Arena 40x 高速化)                  |
| Phase U  | ✅ U1-U6 完了 | UX (REPL readline, エラー表示, doc/dir, バグ修正, CLI, nREPL) |
| Phase S  | S1a-S1j 完了 | セルフホスト (10 標準名前空間)                                |

---

## 未着手・将来の計画

### Phase R3 残項目: Zig イディオム再点検

- switch exhaustiveness の統合 (新型追加時の更新箇所を減らす)
- エラー伝播の改善 (`catch { return error.X }` → `try` 活用)
- `anyopaque` キャスト削減 (wasm 周りで zware 型を直接使える箇所)

### Phase U4 残項目: 既知バグ

| バグ                   | 優先度 | 難易度 |
|------------------------|--------|--------|
| ^:const 未対応         | 低     | 中     |
| with-local-vars 未実装 | 低     | 中     |
| defmacro inside defn   | 低     | 高     |

### Phase G2: 世代別 GC

Young (bump allocator) + Old (Mark-Sweep) 方式。Write barrier (card marking) が必要。

| ステップ | 内容                                     |
|----------|------------------------------------------|
| G2a      | GC 計測基盤 (alloc 数、GC 頻度、pause)   |
| G2b      | Young generation bump allocator          |
| G2c      | minor GC + promotion                    |
| G2d      | write barrier (card marking)             |
| G2e      | チューニング (閾値、promote 回数)        |

### Phase P3: VM 最適化 (高インパクト候補)

| 最適化           | 期待効果 | 難易度 | 備考                 |
|------------------|----------|--------|----------------------|
| NaN boxing       | 高       | 高     | Value サイズ縮小     |
| 定数畳み込み     | 中       | 中     | Compiler 側          |
| inline caching   | 高       | 高     | 関数呼び出し高速化   |
| tail call dispatch | 中     | 中     | computed goto 相当   |

### Phase S2: セルフホスト化 (pure 関数の .clj 移行)

候補: juxt, comp, partial, keep, keep-indexed, mapcat, for, tree-seq, partition-by。
性能トレードオフあり (Zig builtin → Clojure 関数呼び出し)。ベンチマーク後に判断。

### Phase S1 追加候補: 新規標準名前空間

- clojure.pprint
- clojure.core.protocols
- clojure.java.io (ファイル I/O のサブセット)

### Phase D: ドキュメント

| 系統     | 内容                                                 |
|----------|------------------------------------------------------|
| 利用者向け | Getting Started, 本家との差分一覧, Wasm チュートリアル |
| 開発者向け | コード読み順ガイド, Value ライフサイクル図            |
| 発表用   | 全体構成, 設計判断, 工夫の深掘り                     |

---

## 参照

- 現在地点: `plan/memo.md`
- 技術ノート: `plan/notes.md`
- 完了履歴: `docs/changelog.md`
- 全体設計: `docs/reference/architecture.md`
- 実装状況: `status/vars.yaml`
