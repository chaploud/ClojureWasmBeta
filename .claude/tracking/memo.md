# セッションメモ

> 前回完了・次回タスク・技術メモ
> 古い内容は削除して肥大化を防ぐ

---

## 前回完了

- Phase 8.2.1: 可変長引数 (& rest) ✓
- Phase 8.2.2: apply ✓
- Phase 8.2.3: 複数アリティ fn ✓
  - Analyzer: 複数の ([params] body...) 形式を解析
  - Compiler: closure_multi オペコードで複数 FnProto を結合
  - VM: createMultiClosure で複数アリティの Fn を作成
  - 両バックエンドで動作確認

---

## 次回タスク

### Phase 8.2: 機能拡張（継続）

**開発サイクル**: TreeWalk 一機能追加 → VM 同期 → 繰り返し

**候補機能**:
- コレクションリテラル (vec_new, map_new 等)
- tail_call 最適化
- partial
- comp

---

## 申し送り (解消したら削除)

- 有理数は Form では float で近似（Ratio 型は将来実装）
- マップ/セットは Reader で nil を返す仮実装
- コレクションは配列ベースの簡易実装（永続データ構造は将来）
- BuiltinFn は value.zig では anyopaque、core.zig で型定義、evaluator.zig でキャスト
- char_val は Form に対応していない（valueToForm でエラー）
- **メモリリーク（Phase 9 GC で対応予定）**:
  - evaluator.zig の args 配列（バインディングスタック改善で対応）
  - Value 所有権（Var 破棄時に内部 Fn が解放されない）
