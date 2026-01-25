---
name: continue
description: セッション再開、イテレーションを自律的に進める
disable-model-invocation: true
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Write
  - Edit
---

# セッション継続

## 1. 現状把握

以下を実行して現状を把握する:

```bash
# Git状態
git log --oneline -5
git status
```

以下のファイルを Read ツールで読む:

1. `.claude/tracking/checklist.md` - 現在のタスク
2. `.claude/tracking/memo.md` - 申し送り事項

> **参照ドキュメント**（必要時のみ Read）:
> - `ITERATION.md` - バックログ全体
> - `docs/reference/architecture.md` - アーキテクチャ詳細
> - `docs/reference/type_design.md` - 型設計詳細

## 2. イテレーション実行

### 各イテレーションで実行すること

1. **タスク選択**: checklist.md の次の未完了項目
2. **実装**: 必要なコードを書く
3. **テスト**: `zig build test` を実行
4. **検証**: 必要に応じて追加確認
5. **記録**:
   - checklist.md を更新（完了マーク）
   - memo.md に気づきを記録（古いものは削除）
   - status/*.yaml を更新（todo → done）
6. **コミット**: 意味のある単位で git commit
7. **次へ**: 次のタスクへ進む

### 継続条件

- checklist.md の次の未完了項目に取り組む
- 各タスク完了後、次のタスクに進む
- ユーザーからの指示や質問があるまで継続

### 停止条件（以下の場合のみ停止してユーザーに確認）

1. **設計判断が必要** - 複数の選択肢があり、トレードオフがある場合
2. **ブロッカー発生** - 技術的に解決できない問題
3. **方針変更** - アーキテクチャを変更する必要がある場合
4. **外部依存** - ユーザーの環境設定や外部ツールが必要
5. **checklist.md が空** - 次のフェーズへ移行が必要

## 3. 品質チェック

各タスク完了時に確認:

- [ ] `zig build test` がパスするか？
- [ ] 新しい警告やエラーは出ていないか？
- [ ] `yamllint status/*.yaml` でエラーなしか？

問題があれば修正してから次のタスクへ。

## 4. フェーズ移行

checklist.md のタスクが全て完了したら:

1. ITERATION.md のバックログから次のフェーズを確認
2. checklist.md に次フェーズのタスクを追加
3. ユーザーに報告して確認を取る

## 5. ユーザー指示

$ARGUMENTS
