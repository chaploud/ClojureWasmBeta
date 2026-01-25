# ClojureWasmBeta

ZigでClojure処理系をフルスクラッチ実装。動作互換（ブラックボックス）を目指す。

## イテレーションワークフロー

**開始時**: `ITERATION.md` を確認し、次のアクションから着手
**終了時**: `ITERATION.md` を更新し、意味のある単位で `git commit`

## ドキュメント構成

| パス | 内容 |
|-----|------|
| `ITERATION.md` | 次のアクション・後回し・将来TODO |
| `docs/reference/` | 永続的な参照資料 |
| `plan/archive/` | 議論履歴（読み取り専用） |
| `status/tokens.yaml` | トークン対応状況 |
| `status/vars.yaml` | Var対応状況（Phase 1-4） |

## コーディング規約

- **日本語コメント**: ソースコード内は日本語
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
