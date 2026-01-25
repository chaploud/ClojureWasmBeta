# イテレーション管理

**開始時**: このファイルを確認し、次のアクションから着手
**終了時**: このファイルを更新し、コミット

---

## 次のアクション

1. **Value設計** - tagged union で Clojure値を表現
   - `src/value.zig` 作成
   - nil, bool, int, float, string, symbol, keyword, list, vector, map, set

2. **Error設計** - エラー型定義
   - `src/error.zig` 作成
   - `docs/reference/error_design.md` 参照

3. **Tokenizer** - tokens.yaml ベースで実装
   - `src/reader/tokenizer.zig`

---

## 後回し

- **互換性テスト基盤** - 本家Clojureとの入出力比較
- **GC実装** - 初期は ArenaAllocator で代用

---

## 将来TODO（バックログ）

- [ ] Reader（S式構築）
- [ ] Eval（評価器）
- [ ] clojure.core 関数群
- [ ] clojure.string, clojure.set 等
- [ ] マクロシステム
- [ ] REPL
- [ ] Wasm対応

---

## イテレーション終了チェックリスト

- [ ] このファイルを更新した
- [ ] 実装したら `status/*.yaml` を更新した（todo → wip → done）
- [ ] CLAUDE.md の変更があれば更新した
- [ ] `git add` → `git commit` した（意味のある単位で）
- [ ] `yamllint status/*.yaml` でエラーなし確認
