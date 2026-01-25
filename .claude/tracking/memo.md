# セッションメモ

> 前回完了・次回タスク・技術メモ
> 古い内容は削除して肥大化を防ぐ

---

## 前回完了

- Phase 8: Compiler + VM（基盤）✓
  - バイトコード定義（OpCode, Instruction, Chunk, FnProto）
  - Emit（Node → Bytecode）- Compiler 構造体
  - VM 実装 - スタックベース、フレーム管理
  - Value に fn_proto, var_val を追加
  - E2E テスト追加（VM 経由の評価）

---

## 次回タスク

### Phase 8 続き: VM 完全化

- eval インターフェースを抽象化（TreeWalk / VM 切り替え）
- ユーザー定義関数の VM 実行
- クロージャのキャプチャ処理
- recur/loop の VM 実装

---

## 申し送り (解消したら削除)

- 有理数は Form では float で近似（Ratio 型は将来実装）
- マップ/セットは Reader で nil を返す仮実装
- コレクションは配列ベースの簡易実装（永続データ構造は将来）
- 複数アリティ fn は未実装（単一アリティのみ）
- 可変長引数（& rest）は解析のみ、評価は未実装
- BuiltinFn は value.zig では anyopaque、core.zig で型定義、evaluator.zig でキャスト
- char_val は Form に対応していない（valueToForm でエラー）
- VM でのユーザー定義関数実行は未完成（組み込み関数のみ動作）
