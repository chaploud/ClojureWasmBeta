# ClojureWasmBeta

ZigでClojure処理系をフルスクラッチ実装。動作互換（ブラックボックス）を目指す。

## 実装方針

- **現段階**: 全てをZigで実装（Tokenizer, Reader, Eval, 組み込み関数）
- **将来**: JavaInterOp/JVM前提を排除した.cljをロード可能に（手書きマクロ等で書き換え）
- 本家.cljを「そのまま」読む方針は取らない（JavaInterOp再実装は無限地獄）
- 第一目標はcore.clj、他の名前空間も同様にJava依存を排除

## イテレーションワークフロー

**スキル実行**: `/continue` で自律的にイテレーションを進行

**手動実行時**:
- **開始時**: `.claude/tracking/checklist.md` を確認
- **終了時**: checklist.md, memo.md を更新し、意味のある単位で `git commit`

## ドキュメント構成

| パス | 内容 | 参照タイミング |
|-----|------|--------------|
| `.claude/tracking/checklist.md` | 現在のタスク・進捗 | 毎イテレーション |
| `.claude/tracking/memo.md` | セッション間申し送り | セッション開始/終了時 |
| `ITERATION.md` | バックログ・将来TODO | フェーズ移行時 |
| `docs/reference/architecture.md` | 全体アーキテクチャ | 設計確認時 |
| `docs/reference/type_design.md` | 3フェーズ型設計 | 型設計時 |
| `docs/reference/zig_guide.md` | Zig高速化テクニック | Zigコード設計時 |
| `docs/reference/error_design.md` | エラー型設計 | エラー処理実装時 |
| `status/tokens.yaml` | トークン対応状況 | Reader実装時 |
| `status/vars.yaml` | Var対応状況 | 関数実装時 |

## コーディング規約

- **日本語コメント**: ソースコード内は日本語
- **コミットメッセージ**: 日本語
- **識別子**: 英語
- **YAML**: `yamllint` でエラーなし（`.yamllint` 設定あり）
  - ステータス値: `todo` → `wip` → `partial` → `done`（または `skip`）

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

// ✅ stdout
const stdout = std.fs.File.stdout();
stdout.writeAll("output\n") catch {};

// ✅ StaticStringMap（comptime）
const keywords = std.StaticStringMap(Keyword).initComptime(.{
    .{ "if", .if_kw },
    .{ "else", .else_kw },
});
```

```zig
// ❌ 存在しないAPI
// std.io.getStdOut()
// std.ComptimeStringMap
```

### 落とし穴

```zig
// ❌ stdout 取得（バッファ必須）
const stdout = std.io.getStdOut().writer();

// ✅ バッファ付き writer
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
const stdout = &writer.interface;
try stdout.flush();  // 忘れずに

// ❌ format メソッドを持つ型の {} 出力
try writer.print("loc: {}", .{self.location});  // ambiguous format string

// ✅ 明示的に format 呼び出し
try writer.writeAll("loc: ");
try self.location.format("", .{}, writer);

// ❌ メソッド名と同名のローカル変数
pub fn next(self: *T) {
    const next = self.peek();  // シャドウイングエラー
}

// ✅ 別名を使う
pub fn next(self: *T) {
    const next_char = self.peek();
}

// ❌ tagged union で == 比較（不安定）
return self == .nil;

// ✅ switch で判定
return switch (self) { .nil => true, else => false };
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
- 旧実装: `~/Documents/MyProducts/ClojureWasmAlpha`
