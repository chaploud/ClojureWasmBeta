# セッションメモ

> 前回完了・次回タスク・技術メモ
> 古い内容は削除して肥大化を防ぐ

---

## 前回完了

- Phase 8.0.5: 評価エンジン抽象化 ✓
  - engine.zig 新設（Backend enum, EvalEngine struct）
  - CLI --backend=tree_walk|vm オプション
  - CLI --compare オプション（両バックエンドで実行して比較）
  - test_e2e.zig 統合（evalWithBackend, evalBothAndCompare）

- Phase 8.1: VM を TreeWalk に同期 ✓
  - ユーザー定義関数の VM 実行
    - `createClosure` で正しいアリティ情報を設定
    - `callValue` で `FnProto` を取得してバイトコード実行
  - クロージャ対応
    - `createClosure` でフレームのローカル変数をキャプチャ
    - `callValue` でクロージャ環境をスタックに展開
  - loop/recur 対応
    - `recur` オペコードでループ変数を更新
    - `jump` で後方ジャンプ
  - 再帰 execute 問題の修正
    - `entry_frame_count` を記録し、`ret` で適切に return

---

## 次回タスク

### Phase 8.2: 機能拡張（短サイクル開発）

**開発サイクル**: TreeWalk 一機能追加 → VM 同期 → 繰り返し

**候補機能**:
- 複数アリティ fn
- 可変長引数 (& rest)
- コレクションリテラル (vec_new, map_new 等)
- tail_call 最適化
- apply

---

## 申し送り (解消したら削除)

- 有理数は Form では float で近似（Ratio 型は将来実装）
- マップ/セットは Reader で nil を返す仮実装
- コレクションは配列ベースの簡易実装（永続データ構造は将来）
- 複数アリティ fn は未実装（単一アリティのみ）
- 可変長引数（& rest）は解析のみ、評価は未実装
- BuiltinFn は value.zig では anyopaque、core.zig で型定義、evaluator.zig でキャスト
- char_val は Form に対応していない（valueToForm でエラー）
- メモリリーク警告が出る（GC フェーズで対応予定）
