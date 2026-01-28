---
name: continue
description: セッション再開、実行計画に従って自律的に無限実行
disable-model-invocation: true
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Write
  - Edit
---

# セッション継続 (自律無限実行モード)

**このスキルが呼ばれたら、自動的に進み続ける。**

## 1. 現状把握 (毎イテレーション実行)

```bash
git log --oneline -3
git status --short
```

Read ツールで読む:
- `CLAUDE.md` — プロジェクト指示・コーディング規約・ベンチマーク方法
- `plan/memo.md` — 現在地点・**実行計画テーブル**

必要に応じて参照:
- `plan/roadmap.md` — タスク詳細
- `plan/notes.md` — 技術ノート・注意点

## 2. タスク選択

`plan/memo.md` の「実行計画」テーブルで**未完了の最初のタスク**に着手する。

## 3. イテレーション実行

### 開発手順

1. **TreeWalk で正しい振る舞いを実装**
2. **VM を同期**（同じ結果を返すように）
3. **`--compare` で回帰検出**: `zig build run -- --compare -e '(test-expr)'`
4. **テスト追加・実行**: `zig build test` (1036 pass が baseline)

### タスク完了時

1. `plan/memo.md` の該当タスクを「完了」に更新、changelog.mdも追記
2. **パフォーマンス系 (P3, G2) は必ずベンチマーク記録**:
   ```bash
   bash bench/run_bench.sh --quick --record --version="P3 NaN boxing"
   ```
3. 意味のある単位で `git commit`
4. **次の未完了タスクへ自動的に進む**

### 継続

- タスク完了後は実行計画の次のタスク(もし差し込みが必要ならふさわしいように)へ進む
- 設計判断が必要な場合は `plan/notes.md` に選択肢を記録し、最も妥当な方を選んで進む
- ビルドエラー・テスト失敗は原因を調査して修正を試みる
- **重要** 止めずに次のタスクへ移る



## 5. ユーザー指示

$ARGUMENTS
