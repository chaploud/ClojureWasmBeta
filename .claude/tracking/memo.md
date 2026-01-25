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

- OpCode 完全設計 ✓
  - 本家 Clojure Compiler.java 調査（JVM bytecode 生成方式）
  - Clojure 意味論ベースの OpCode セット設計（約50個）
  - カテゴリ別に範囲予約（0x00-0xFF）
  - architecture.md に VM 設計セクション追加
  - bytecode.zig に完全版 OpCode 定義
  - vm.zig に全 OpCode のスタブ実装

- Phase 8.0.5: 評価エンジン抽象化 ✓
  - engine.zig 新設（Backend enum, EvalEngine struct）
  - CLI --backend=tree_walk|vm オプション
  - CLI --compare オプション（両バックエンドで実行して比較）
  - test_e2e.zig 統合（evalWithBackend, evalBothAndCompare）
  - 両バックエンド比較テスト追加

---

## 次回タスク

### Phase 8.1: クロージャ完成

- upvalue_load, upvalue_store の実装
- クロージャキャプチャ処理
- ユーザー定義関数の VM 実行

### Phase 8.2: コレクションリテラル

- vec_new, map_new, set_new, list_new
- Reader → Compiler → VM の連携

### Phase 8.3: 末尾呼び出し最適化

- tail_call 実装
- apply 実装

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
