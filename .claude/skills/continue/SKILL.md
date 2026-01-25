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

以下を実行:

```bash
git log --oneline -5
git status
```

Read ツールで読む:
- `.claude/tracking/memo.md` - 前回完了・次回タスク・注意点
- `docs/reference/architecture.md` - アーキテクチャ・ロードマップ

## 2. イテレーション実行

### 手順

1. **タスク確認**: memo.md の「次回タスク」を確認
2. **実装**: コードを書く
3. **テスト**: `zig build test`
4. **記録更新**:
   - `status/*.yaml` を更新（todo → done）
   - memo.md の「前回完了」「次回タスク」を更新
   - もししばらく保持する申し送りがあれば追記
   - architecture.mdのチェックボックスを更新。もし設計変更があったならこのファイル自体を更新。
5. **コミット**: 意味のある単位で `git commit`
6. **次へ**: 次のタスクに進む

### 継続条件

- memo.md の次回タスクに取り組む
- 各タスク完了後、次のタスクに進む
- ユーザーからの指示や質問があるまで無限継続

### 停止条件（ユーザーに確認）

1. **設計判断が必要** - アーキテクチャ変更が必要、複数の選択肢、トレードオフがある。でも基本は自動でプランを比較検討して選択して継続
2. **ブロッカー発生** - 技術的に解決できない問題(どうしても無理なとき)

## 3. ユーザー指示

$ARGUMENTS
