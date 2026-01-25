# ClojureWasmBeta

ZigでClojure処理系をフルスクラッチ実装するプロジェクト。

## プロジェクト概要

**目標**: 動作互換（ブラックボックス）のClojure処理系をZigで実装し、将来的にWasmで動作させる。

**方針**:
- 本家core.cljを「そのままロード」する方針は取らない
- JavaInterOp再実装はしない
- 同じ入力 → 同じ出力を保証する動作互換
- 初期はZigで全て実装（セルフホスト.cljは後）
- 網羅的・精査的アプローチ

## 設計ドキュメント

| ファイル | 内容 |
|---------|------|
| `plan/001_next_gen_plan.md` | 設計議論ログ（3プロジェクトの反省、設計論点） |
| `plan/002_consolidated_plan.md` | 統合設計プラン（確定方針、開発フェーズ） |
| `plan/003_token_patterns.md` | Clojureトークン完全リスト（本家LispReader調査結果） |
| `plan/004_status_design.md` | ステータス管理の設計（tokens.yaml, vars.yaml） |
| `plan/005_java_namespaces.md` | clojure.java.* の機能リストとZig対応方針 |
| `plan/006_zig_optimize.md` | Zig処理系開発の高速化テクニック |
| `plan/007_error_design.md` | エラー設計（sci/babashka参考） |

## ステータス管理

実装対応状況を追跡するYAMLファイル:

| ファイル | 内容 |
|---------|------|
| `status/tokens.yaml` | トークンパターン（tools.readerベース） |
| `status/vars.yaml` | Var定義（Phase 1-4の15名前空間） |

ステータス値: `todo` → `wip` → `partial` → `done`（または `skip`）

### 対象名前空間（Phase 1-4）

- **Phase 1（必須）**: clojure.core, clojure.repl, clojure.string, clojure.set
- **Phase 2（テスト・デバッグ）**: clojure.test, clojure.pprint, clojure.stacktrace, clojure.walk
- **Phase 3（データ）**: clojure.edn, clojure.data, clojure.zip
- **Phase 4（その他）**: clojure.template, clojure.instant, clojure.uuid, clojure.math

### スキップ対象

- `clojure.java.*` - Java固有（ただしI/OはZigで独自実装）
- `clojure.reflect` - Javaリフレクション固有

## 過去プロジェクトからの教訓

### SandboxClojureWasm
- **良かった点**: GC実装済み、314テスト、prelude.cljでマクロ動作
- **苦しみ**: 本家互換性の担保が曖昧、テストがあっても本家との差異が発見しづらい

### ClojureWasmPre
- **良かった点**: 「カスタムcore.cljは技術的負債」という強い方針
- **苦しみ**: 学習プロジェクトで終わった

### ClojureWasmAlpha
- **良かった点**: 本家core.cljを986行までロード、Reader/エラー表示充実
- **苦しみ**:
  - JavaInterOp再実装が無限に続く（`(. clojure.lang.RT ...)` 形式）
  - 本家core.cljの変更追従が困難
  - 「JavaInterOp排除」と言いながら実際はZigで再実装している矛盾

### 共通の教訓
1. **互換性検証の仕組みが最重要** - 本家と同じ結果を返すかの自動テスト
2. **網羅的なトークン/構文テスト** - Readerの問題は後で発覚すると大変
3. **対応状況の可視化** - 何ができて何ができないかを常に把握

## コーディング規約

- **日本語コメント優先**: ソースコード内のコメントは日本語で記述
- **ドキュメント**: 日本語で記述
- **識別子**: 英語（関数名、変数名、型名）

## Zig 0.15.2 コーディングガイド

詳細: `plan/006_zig_optimize.md`

### 処理系設計の原則

- **comptime**: キーワードテーブル、トークン種別等は comptime で構築
- **ArenaAllocator**: フェーズ単位で arena を使い、まとめて解放
- **配列 > リンクリスト**: AST/IR はインデックス参照（NodeId = u32）
- **構造体は小さく**: Token は 8-16 バイト以内を目標

### Zig 0.15.2 正しいAPI（標準ライブラリで確認済み）

```zig
// ✅ ArrayList（Unmanaged形式、.empty で初期化）
var list: std.ArrayList(u8) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);

// ✅ HashMap（Unmanaged形式）
var map: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
defer map.deinit(allocator);
try map.put(allocator, key, value);

// ✅ stdout/stderr（Fileを直接取得）
const stdout = std.fs.File.stdout();
stdout.writeAll("output\n") catch {};

// ✅ フォーマット出力（バッファ経由）
var buf: [4096]u8 = undefined;
var fbs = std.io.fixedBufferStream(&buf);
try fbs.writer().print("value: {d}\n", .{42});
stdout.writeAll(fbs.getWritten()) catch {};

// ✅ デバッグ出力
std.debug.print("debug: {}\n", .{value});

// ✅ StaticStringMap（comptime文字列マップ、旧ComptimeStringMap）
const Keyword = enum { if_kw, else_kw, fn_kw };
const keywords = std.StaticStringMap(Keyword).initComptime(.{
    .{ "if", .if_kw },
    .{ "else", .else_kw },
    .{ "fn", .fn_kw },
});
// 使用: keywords.get("if") => ?Keyword
```

### 避けるべきパターン

```zig
// ❌ 古いAPI（0.15.2では存在しない）
// std.io.getStdOut()
// std.ComptimeStringMap

// ❌ Managed形式をフィールドに持つ（allocator二重保持）
// const Self = struct { map: std.AutoHashMap(...) };

// ❌ ポインタチェーン（キャッシュミス）
// node.next.?.child.?.sibling
```

## ビルド・テスト

```bash
zig build              # ビルド
zig build test         # テスト
zig build run          # REPL起動
```

## 参照リポジトリ

- 本家Clojure: `~/Documents/OSS/clojure`
- tools.reader: `~/Documents/OSS/tools.reader`
- sci: `~/Documents/OSS/sci`
- babashka: `~/Documents/OSS/babashka`
- Zig標準ライブラリ: `/opt/homebrew/Cellar/zig/0.15.2/lib/zig/std/`
- 旧プロジェクト: `~/Documents/MyProducts/ClojureWasmAlpha`

---

## 現在の進捗

### 完了

- [x] 設計方針の確定（動作互換、フルスクラッチ、Zig実装）
- [x] 過去プロジェクトの反省まとめ
- [x] tokens.yaml 作成（tools.readerベースで網羅）
- [x] vars.yaml 作成（Phase 1-4、15名前空間、約700 Var）
- [x] clojure.java.* の機能調査・ドキュメント化
- [x] スキップ対象の明確化（reflect, java.*の一部）

### 未着手

- [ ] Zigコード実装
- [ ] 本家との互換性テスト基盤

---

## 次のアクション

### 優先順位

1. **Value + Error 設計** - tagged union で値表現、エラー型も早期に定義
2. **Tokenizer/Reader** - tokens.yaml ベースで実装
3. **互換性テスト** - 本家との入出力比較（後回し可）

### A. 値表現（Value）とエラー設計

```
src/
  value.zig         # tagged union（nil, bool, int, float, string, symbol, keyword, list, vector, map, set）
  error.zig         # エラー型（sci/babashkaパターン参考）
  gc.zig            # ArenaAllocator ベース
```

エラー設計は `plan/007_error_design.md` 参照。

### B. Tokenizer/Reader 実装

```
src/
  reader/
    tokenizer.zig   # トークン分割
    reader.zig      # S式構築
    numbers.zig     # 数値パース（int/float/ratio/bigint）
```

### C. 互換性テスト基盤（後回し可）

本家Clojureとの入出力比較。本家テストは主にブラックボックス形式。

```
test/
  compat/
    cases/          # テストケース（.edn）
    runner.clj      # 本家で実行
    runner.zig      # Zig実装で実行
```

**本家テストの特徴**（調査済み）:
- 約100ファイル、16,000行超
- `deftest` + `is` によるアサーション
- `are` マクロによる表形式テスト
- 生成的テスト（clojure.test.check）
- ラウンドトリップテスト（print → read → compare）
