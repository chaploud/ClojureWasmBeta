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
- `docs/roadmap.md` — ポスト実装フェーズのロードマップ (R/P/G/U/S/D)
- `docs/reference/architecture.md` — 全体設計・処理フロー
- `status/vars.yaml` — 実装状況（yq で照会、関数追加時のみ）

## 2. イテレーション実行

### 手順

1. **タスク確認**: memo.md の「推奨開始タスク」または指定タスクを確認
2. **ロードマップ確認**: roadmap.md で対象フェーズの詳細・依存関係を把握
3. **関連ノート確認**: notes.md で対象サブシステムの注意点を把握
4. **実装**: コードを書く
5. **テスト・検証**:
   - `zig build test` — 全テスト通過を確認 (760 pass が baseline)
   - `zig build run -- --compare -e '(+ 1 2)'` — デュアルバックエンド回帰検出 (必要に応じて)
   - リファクタリング時: テスト数が減らないことを確認
   - 高速化時: ベンチマークで前後比較 (`test/bench/` 参照)
6. **記録更新**:
   - **memo.md**: 「現在地点」と「推奨開始タスク」を更新
   - **notes.md**: 新しい技術的注意点・回避策があれば該当セクションに追記
   - **roadmap.md**: サブフェーズの状態を更新 (未着手→進行中→完了)
   - **architecture.md**: 設計変更があった場合のみ更新
   - **vars.yaml**: 新規関数追加時のみ yq で更新
     ```bash
     yq -i '.vars.clojure_core."関数名".status = "done" |
            .vars.clojure_core."関数名".impl_type = "builtin" |
            .vars.clojure_core."関数名".layer = "host"' status/vars.yaml
     ```
7. **コミット**: 意味のある単位で `git commit`
8. **次へ**: 次のタスクに進む

### 継続条件

- memo.md の推奨タスクまたはユーザー指示のタスクに取り組む
- 各タスク完了後、次のタスクに進む
- ユーザーからの指示や質問があるまで無限継続

### 停止条件（ユーザーに確認）

1. **設計判断が必要** — アーキテクチャ変更が必要、複数の選択肢、トレードオフがある。でも基本は自動でプランを比較検討して選択して継続
2. **ブロッカー発生** — 技術的に解決できない問題（どうしても無理なとき）
3. **回帰発生** — テスト数が減少した、`--compare` で不一致が出た場合はロールバックして報告

## 3. ユーザー指示

$ARGUMENTS
