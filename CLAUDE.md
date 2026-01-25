# ClojureWasmBeta

ZigでClojure処理系をフルスクラッチ実装。動作互換（ブラックボックス）を目指す。

## 実装方針

- **現段階**: 全てをZigで実装（Tokenizer, Reader, Eval, 組み込み関数）
- **将来**: JavaInterOp/JVM前提を排除した.cljをロード可能に（手書きマクロ等で書き換え）
- 本家.cljを「そのまま」読む方針は取らない（JavaInterOp再実装は無限地獄）
- 第一目標はcore.clj、他の名前空間も同様にJava依存を排除

## イテレーションワークフロー

**開始時**: `ITERATION.md` を確認し、次のアクションから着手
**終了時**: `ITERATION.md` を更新し、意味のある単位で `git commit`

## ドキュメント構成

| パス | 内容 | 参照タイミング |
|-----|------|--------------|
| `ITERATION.md` | 次のアクション・後回し・将来TODO | 毎イテレーション開始/終了時 |
| `docs/reference/zig_guide.md` | Zig処理系の高速化テクニック | Zigコード設計時 |
| `docs/reference/error_design.md` | エラー型設計（sci/babashka参考） | エラー処理実装時 |
| `docs/reference/java_namespaces.md` | clojure.java.*のZig対応方針 | I/O実装時 |
| `status/tokens.yaml` | トークン対応状況 | Tokenizer実装時 |
| `status/vars.yaml` | Var対応状況（Phase 1-4） | 関数実装時 |
| `plan/archive/` | 議論履歴（読み取り専用） | 設計意図確認時 |

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
