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

---

## 次回タスク

### Phase 8.0.5: 評価エンジン抽象化レイヤー（優先）

**目的**: TreeWalk と VM の並行開発を可能にする

**背景**:
- 現状は evaluator.zig (TreeWalk) と vm.zig (VM) が独立
- main.zig は TreeWalk にハードコード
- テストも別関数で分離
- 片方だけ修正してバグが不一致になるリスク

**実装内容**:

1. **engine.zig 新設** (~50行)
   - Backend enum: tree_walk, vm
   - EvalEngine struct: バックエンド切り替え

2. **main.zig 修正** (~20行)
   - `--backend=tree_walk|vm` オプション追加
   - デフォルトは tree_walk（安定版）

3. **test_e2e.zig 統合** (~100行)
   - 同じテストを両バックエンドで実行
   - 結果の一致を検証

4. **ベンチマーク対応**
   - build.zig に benchmark ステップ追加
   - リリースビルド済みバイナリを直接実行
   - 注: zig build run はコンパイル時間が加算されるため使わない

**CLI オプション設計**:
```bash
# 通常実行（デフォルト: tree_walk）
clj-wasm -e "(+ 1 2)"

# バックエンド指定
clj-wasm --backend=vm -e "(+ 1 2)"
clj-wasm --backend=tree_walk -e "(+ 1 2)"

# 両方で実行して比較（開発用）
clj-wasm --compare -e "(+ 1 2)"
```

**ベンチマーク考慮**:
- `zig build run` はコンパイル時間が含まれる → 使わない
- リリースビルド済みバイナリを直接実行
- `zig build -Doptimize=ReleaseFast` でビルド
- `./zig-out/bin/clj-wasm` を hyperfine 等で計測

**完了条件**:
- [ ] engine.zig が両バックエンドを切り替え可能
- [ ] main.zig が --backend オプションを受け付ける
- [ ] test_e2e.zig が両バックエンドでテスト実行
- [ ] 既存テストがすべて通る

---

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
