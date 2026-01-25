# セッションメモ

> 前回完了・次回タスク・技術メモ
> 古い内容は削除して肥大化を防ぐ

---

## 前回完了

- Node 型 (`src/analyzer/node.zig`)
  - ConstantNode: リテラル値
  - VarRefNode, LocalRefNode: 変数参照
  - IfNode, DoNode, LetNode: 制御構造
  - LoopNode, RecurNode: ループ
  - FnNode, CallNode: 関数
  - DefNode, QuoteNode, ThrowNode

---

## 次回タスク

### Phase 3 続き: Analyzer

1. **Analyzer** (`src/analyzer/analyze.zig`)
   - Form → Node 変換
   - special forms の解析 (if, do, let, fn, def, quote)
   - シンボル解決（ローカル変数 vs Var）

### Phase 4: ツリーウォーク評価器

1. **Context** (`src/runtime/context.zig`)
   - ローカルバインディング管理
   - recur ターゲット

2. **Evaluator**
   - Node を実行して Value を返す
   - 組み込み関数の実装

---

## 申し送り (解消したら削除)

- 有理数は Form では float で近似（Ratio 型は将来実装）
- マップ/セットは Reader で nil を返す仮実装
- コレクションは配列ベースの簡易実装（永続データ構造は将来）
