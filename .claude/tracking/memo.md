# セッションメモ

> 前回完了・次回タスク・技術メモ
> 古い内容は削除して肥大化を防ぐ

---

## 前回完了

- Phase 7: CLI ✓
  - `-e` オプション（式評価）
  - 複数式の連続評価
  - 状態保持（def の値を次の -e で使用可能）
  - BuiltinFn の循環依存を anyopaque で解決

---

## 次回タスク

### Phase 6: マクロシステム（後回し可）

- defmacro
- macroexpand
- Analyzer 拡張（マクロ展開）

### Phase 8: Compiler + VM

- バイトコード定義
- Emit（Node → Bytecode）
- VM 実装
- eval インターフェースを VMEval に差し替え

---

## 申し送り (解消したら削除)

- 有理数は Form では float で近似（Ratio 型は将来実装）
- マップ/セットは Reader で nil を返す仮実装
- コレクションは配列ベースの簡易実装（永続データ構造は将来）
- 複数アリティ fn は未実装（単一アリティのみ）
- 可変長引数（& rest）は解析のみ、評価は未実装
- BuiltinFn は value.zig では anyopaque、core.zig で型定義、evaluator.zig でキャスト
