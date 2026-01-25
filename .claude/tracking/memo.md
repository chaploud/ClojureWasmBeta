# セッションメモ

> 前回完了・次回タスク・技術メモ
> 古い内容は削除して肥大化を防ぐ

---

## 前回完了

- Value 型 (`src/runtime/value.zig`)
  - 基本型: nil, bool, int, float, char
  - 文字列・識別子: String, Symbol, Keyword
  - コレクション: PersistentList, PersistentVector, PersistentMap, PersistentSet
  - 関数: Fn (組み込み関数対応)
  - 等価性判定、format 出力
- Var 型 (`src/runtime/var.zig`)
  - root バインディング
  - dynamic, macro, private フラグ
- Namespace 型 (`src/runtime/namespace.zig`)
  - intern, resolve, alias, refer
- Env 型 (`src/runtime/env.zig`)
  - 名前空間管理
  - シンボル解決

---

## 次回タスク

### Phase 3: Analyzer

1. **Node 型** (`src/analyzer/node.zig`)
   - ConstantNode: リテラル値
   - VarRefNode: Var参照
   - IfNode, DoNode, LetNode
   - FnNode, CallNode
   - DefNode

2. **Analyzer** (`src/analyzer/analyze.zig`)
   - Form → Node 変換
   - special forms の解析
   - シンボル解決

### Phase 4: ツリーウォーク評価器

- Node.run() で Value を返す
- Context: ローカルバインディング管理

---

## 申し送り (解消したら削除)

- 有理数は Form では float で近似（Ratio 型は将来実装）
- マップ/セットは Reader で nil を返す仮実装
- コレクションは配列ベースの簡易実装（永続データ構造は将来）
