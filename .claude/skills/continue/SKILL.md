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
- `.claude/tracking/memo.md` — 現在地点・次回タスク
- `.claude/tracking/notes.md` — 技術ノート（関連サブシステムの注意点）

必要に応じて参照:
- `docs/reference/architecture.md` — ロードマップ・全体設計
- `status/vars.yaml` — 実装状況（yq で照会）

## 2. イテレーション実行

### 手順

1. **タスク確認**: memo.md の「次回タスク候補」を確認
2. **関連ノート確認**: notes.md で対象サブシステムの注意点を把握
3. **実装**: コードを書く
4. **テスト**: `zig build test`
5. **記録更新**:
   - **vars.yaml**: 新しく実装した関数/マクロ/特殊形式を yq で更新
     ```bash
     # 例: 新 builtin を done 化
     yq -i '.vars.clojure_core."関数名".status = "done" |
            .vars.clojure_core."関数名".impl_type = "builtin" |
            .vars.clojure_core."関数名".layer = "host"' status/vars.yaml
     # impl_type: builtin | special_form | macro
     # layer: host | bridge | pure
     ```
   - **memo.md**: 「現在地点」テーブルと「次回タスク候補」を更新
   - **notes.md**: 新しい技術的注意点・回避策があれば該当セクションに追記
   - **architecture.md**: 設計変更があった場合のみ更新
6. **コミット**: 意味のある単位で `git commit`
7. **次へ**: 次のタスクに進む

### 継続条件

- memo.md の次回タスクに取り組む
- 各タスク完了後、次のタスクに進む
- ユーザーからの指示や質問があるまで無限継続

### 停止条件（ユーザーに確認）

1. **設計判断が必要** — アーキテクチャ変更が必要、複数の選択肢、トレードオフがある。でも基本は自動でプランを比較検討して選択して継続
2. **ブロッカー発生** — 技術的に解決できない問題（どうしても無理なとき）

## 3. ユーザー指示

$ARGUMENTS
