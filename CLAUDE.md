# ClojureWasmBeta

ZigでClojure処理系をフルスクラッチ実装。動作互換（ブラックボックス）を目指す。

## 現在の状態（Phase 8.2 完了）

**評価器の骨格は完成**。デュアルバックエンド（TreeWalk + VM）で基本的な評価が動作。
ただし「Clojureらしさ」を支えるデータ抽象層（分配束縛、遅延シーケンス、プロトコル）は未実装。

### 次の優先タスク

1. **Phase 8.3: 分配束縛** ← 最優先（実用性に直結）
2. Phase 8.4: 遅延シーケンス（map/filter/take の前提）
3. Phase 8.5: プロトコル（型の拡張性）

詳細: `docs/reference/architecture.md`

## 実装方針

- **全てをZigで実装**（Tokenizer, Reader, Analyzer, Evaluator, VM, 組み込み関数）
- **JavaInterop再実装は行わない**（無限地獄を避ける）
- 本家.cljを「そのまま」読む方針は取らない
- Java依存を排除した形でcore機能を再実装

### コア vs ライブラリの区別（重要）

多くの「標準関数」は実際にはコア改修を要求する：

| 区分 | 例 | 必要な作業 |
|------|-----|-----------|
| 純粋なlib追加 | println, str | core.zig に関数追加のみ |
| コア改修必要 | map, filter | LazySeq型 + 新Node + VM対応 |
| 新しい抽象 | defprotocol | Value型拡張 + Analyzer + VM |

## セッションの進め方

### 開始時
1. `.claude/tracking/memo.md` を確認（必須）
2. 現在のタスクと申し送りを把握

### 開発中
1. **TreeWalk で正しい振る舞いを実装**
2. **VM を同期**（同じ結果を返すように）
3. **`--compare` で回帰検出**
4. テスト追加 → コミット

### 終了時
1. memo.md を更新
2. 意味のある単位で `git commit`

## ドキュメント構成

| パス | 内容 | 参照タイミング |
|-----|------|--------------|
| `.claude/tracking/memo.md` | 現在地点・次回タスク・申し送り | 毎セッション（必須） |
| `docs/reference/architecture.md` | ロードマップ・全体設計・未実装機能一覧 | フェーズ移行時・設計確認時 |
| `docs/reference/type_design.md` | 3フェーズ型設計 (Form→Node→Value) | 必要時のみ |
| `docs/reference/zig_guide.md` | Zig 0.15.2 の落とし穴・パターン | 必要時のみ |

## 評価エンジン（デュアルバックエンド）

```
Node → [Backend切り替え] → Value
              ↑
    ┌─────────┴─────────┐
    │                   │
TreeWalkEval          Compiler → VM
(正確性重視)          (性能重視)
```

```bash
# デフォルト（tree_walk）
./zig-out/bin/ClojureWasmBeta -e "(+ 1 2)"

# VM バックエンド
./zig-out/bin/ClojureWasmBeta --backend=vm -e "(+ 1 2)"

# 両方で実行して比較（開発時に有用）
./zig-out/bin/ClojureWasmBeta --compare -e "(+ 1 2)"
```

## コーディング規約

- **日本語コメント**: ソースコード内は日本語
- **コミットメッセージ**: 日本語
- **識別子**: 英語

## Zig 0.15.2 ガイド

詳細: `docs/reference/zig_guide.md`

```zig
// ✅ ArrayList（.empty で初期化）
var list: std.ArrayList(u8) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);

// ✅ HashMap（Unmanaged形式）
var map: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
defer map.deinit(allocator);
try map.put(allocator, key, value);

// ✅ stdout（バッファ必須）
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
const stdout = &writer.interface;
try stdout.flush();  // 忘れずに

// ✅ tagged union の判定は switch
return switch (self) { .nil => true, else => false };
// ❌ self == .nil は不安定
```

## 設計原則

- **comptime**: テーブル類はコンパイル時構築
- **ArenaAllocator**: フェーズ単位で一括解放
- **配列 > ポインタ**: NodeId = u32 でインデックス参照
- **構造体は小さく**: Token は 8-16 バイト以内

## 参照

- 本家Clojure: `~/Documents/OSS/clojure`
- tools.reader: `~/Documents/OSS/tools.reader`
- sci / babashka: `~/Documents/OSS/sci`, `~/Documents/OSS/babashka`
- Zig標準ライブラリ: `/opt/homebrew/Cellar/zig/0.15.2/lib/zig/std/`
