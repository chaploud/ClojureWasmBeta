# セッションメモ

> 前回完了・次回タスク・技術メモ
> 古い内容は削除して肥大化を防ぐ

---

## 前回完了

- Analyzer (`src/analyzer/analyze.zig`)
  - Form → Node 変換
  - special forms: if, do, let, fn, def, quote, loop, recur
  - シンボル解決（ローカル変数 vs Var）
  - 関数呼び出し解析

---

## 次回タスク

### Phase 4: ツリーウォーク評価器

1. **Context** (`src/runtime/context.zig`)
   - ローカルバインディング管理
   - recur ターゲット

2. **Evaluator** (`src/runtime/evaluator.zig`)
   - Node を実行して Value を返す
   - 各ノード型の評価ロジック

3. **組み込み関数** (`src/lib/core.zig`)
   - 算術: +, -, *, /
   - 比較: =, <, >, <=, >=
   - 述語: nil?, number?, etc.
   - コレクション: first, rest, cons, conj

---

## 申し送り (解消したら削除)

- 有理数は Form では float で近似（Ratio 型は将来実装）
- マップ/セットは Reader で nil を返す仮実装
- コレクションは配列ベースの簡易実装（永続データ構造は将来）
- 複数アリティ fn は未実装
