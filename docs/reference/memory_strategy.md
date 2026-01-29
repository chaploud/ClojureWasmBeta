# メモリ管理戦略

ClojureWasmBeta のメモリ管理方針。

## 基本原則

Zig はランタイム GC を持たないため、オブジェクトの寿命に応じてアロケータを使い分ける。

## 寿命の分類

| 分類           | 寿命             | アロケータ | 例                           |
|----------------|------------------|------------|------------------------------|
| **persistent** | プロセス終了まで | GPA（親）  | Var, Namespace, 組み込み関数 |
| **scratch**    | 式の評価完了まで | Arena      | Form, Node, 評価中間構造     |

## Allocators 構造体

`src/runtime/allocators.zig` で定義。

```zig
pub const Allocators = struct {
    /// 永続オブジェクト用（親アロケータ）
    persistent_allocator: std.mem.Allocator,

    /// 一時オブジェクト用 Arena
    scratch_arena: std.heap.ArenaAllocator,

    /// 永続アロケータを取得
    pub fn persistent(self: *Allocators) std.mem.Allocator;

    /// 一時アロケータを取得
    pub fn scratch(self: *Allocators) std.mem.Allocator;

    /// scratch Arena をリセット（評価完了後に呼ぶ）
    pub fn resetScratch(self: *Allocators) void;
};
```

## 使用パターン

### CLI (main.zig)

```zig
// GPA で persistent アロケータを作成
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var allocs = Allocators.init(gpa.allocator());
defer allocs.deinit();

// Env は persistent（Var, Namespace が長寿命）
var env = Env.init(allocs.persistent());
defer env.deinit();

// 各式の評価
for (expressions) |expr| {
    // 評価開始前に scratch をリセット
    allocs.resetScratch();

    // Reader/Analyzer は scratch（Form/Node は一時的）
    var reader = Reader.init(allocs.scratch(), source);
    var analyzer = Analyzer.init(allocs.scratch(), env);

    // EvalEngine は persistent（結果が長寿命かもしれない）
    var eng = EvalEngine.init(allocs.persistent(), env, backend);
}
```

### テスト

```zig
// テスト用 GPA（リーク検出）
const allocator = std.testing.allocator;
var allocs = Allocators.init(allocator);
defer allocs.deinit();
```

## オブジェクト別アロケータ選択

| オブジェクト          | アロケータ     | 理由                             |
|-----------------------|----------------|----------------------------------|
| Form (Reader出力)     | scratch        | 評価後は不要                     |
| Node (Analyzer出力)   | scratch        | 評価後は不要                     |
| Env                   | persistent     | プロセス全体で使用               |
| Namespace             | persistent     | def された値を保持               |
| Var                   | persistent     | 状態を保持                       |
| 組み込み関数 (Fn)     | persistent     | 常に参照される                   |
| ユーザー定義関数 (Fn) | persistent     | スコープを超えて参照される可能性 |
| 評価中の引数配列      | scratch (将来) | 関数呼び出し後は不要             |

## GC による解決 (実装済み)

以下の問題は Phase 21 + G1c で GC 導入により解決済み。

- **Evaluator 引数配列**: GcAllocator 経由で確保、GC sweep で回収
- **Value 所有権**: セミスペース Arena Mark-Sweep GC で管理
- **クロージャ環境**: deepClone で scratch→persistent にコピー、GC が回収
- **Reader/Analyzer の中間構造**: scratch Arena で式評価後にリセット

詳細は `docs/reference/gc_design.md` を参照。

## Zig アロケータ比較

| アロケータ              | 用途     | 特徴                     |
|-------------------------|----------|--------------------------|
| GeneralPurposeAllocator | デバッグ | リーク検出、二重解放検出 |
| ArenaAllocator          | 一括解放 | 高速確保、まとめて解放   |
| FixedBufferAllocator    | 制限環境 | ヒープ不使用、サイズ固定 |
| page_allocator          | 大規模   | OS 直接、ページ単位      |

## 参考

- [Zig Memory Management Guide](https://ziglang.org/documentation/master/#Memory)
- `src/runtime/allocators.zig` - 実装
- `docs/reference/architecture.md` - 全体設計
