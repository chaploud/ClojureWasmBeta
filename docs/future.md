# ClojureWasm 正式版 設計方針

> Beta (本リポジトリ) で得た知見を踏まえた正式版の設計構想。
> Beta の教訓がなぜ各判断の根拠になるかを併記する。

---

## 0. 前提・現在地

- Zig による **Java Interop を完全に排除した Clojure 再実装**
- 単一バイナリ配布前提
- Beta では TreeWalk + BytecodeVM を並行実装し、`--compare` で意味論を検証
- テスト 1036 pass、clojure.core 545 関数実装、~38,000 行
- **Babashka より起動が速く、メモリ使用量も少ない**
- 正式版は **英語コメント・英語ドキュメント・OSS 体裁** でスクラッチ再設計

---

## 1. Wasm の位置付け

### 検討した選択肢

#### A. Wasm を Clojure ライブラリとして利用
- JVM / FFI 経由で Wasm を呼ぶ

**採用しなかった理由**
- JVM/FFI のオーバーヘッドで Wasm の高速性が失われる
- GC 境界が重く、性能面で意味が薄い

#### B. Clojure を全面的に Wasm に寄せる
- 値表現・GC を WasmGC に統合

**採用しなかった理由**
- Clojure の値モデル (NaN boxing / 永続 DS) と WasmGC が根本的に合わない
- 勝手に解放される危険
- 研究レベルで現実的でない

### 最終判断

- **Wasm は「AOT 最適化された高速プリミティブ実行層」**
- 動的性・意味論は Clojure 側で保持
- 固定高速コア + 動的制御層という構図を採用

### Beta での実感

Beta の Wasm 層は 10 API の薄いラッパー (623 行) にとどまった。
型変換は i32/i64/f64 のみ、戻り値は単一値、ホスト関数は 256 スロット固定テーブル。
「Wasm は高速プリミティブ層」という構想自体は正しいが、
正式版では以下の段階を踏む必要がある:

1. **Phase 1**: 型安全な境界 — Wasm 関数シグネチャに基づく自動変換、multi-value return
2. **Phase 2**: 構造データ受け渡し — メモリ上の構造体マーシャリングヘルパー
3. **Phase 3**: エコシステム連携 — Wasm で配布されたライブラリを Clojure から自然に使う

---

## 2. 動的性と Wasm の関係

- Wasm 自体を動的に書き換えるのはセキュリティ的に不適切
- 代わりに:
  - Wasm をラップする Clojure 関数は動的
  - 合成・差し替え・検証は REPL 側で実施

**結論**: 動的性は Wasm の外側で担保する

### Beta からの知見

Beta で `threadlocal` callback パターン (`call_fn`, `force_fn` 等) を多用した。
Clojure 関数を Wasm ホスト関数として登録する際にも同じパターンが使える。
ただし Beta の 256 スロット静的テーブルは制約が強すぎた。
正式版ではクロージャベースの登録方式に移行し、スロット数制限を撤廃する。

---

## 3. 型・引数検証とマクロ

- Clojure の柔軟性と Wasm の厳密な型のギャップが課題

**方針**
- 言語仕様は変えない
- マクロで境界コードを生成
  - 型検証
  - 変換
  - unsafe / fast パス併存

### Beta からの知見

Beta では Value 型が 28+ variant の tagged union に膨張した。
型判定は switch exhaustiveness で網羅性を保証しているが、
新しい型を追加するたびに traceValue / fixupValue / deepClone / format / eql の
5箇所を同時更新する必要があり、漏れが GC クラッシュに直結した。

正式版では:
- Value variant 数を抑制する設計 (NaN boxing による inline 化)
- 型追加時の更新箇所を comptime で検証する仕組み

---

## 4. WIT / Component Model

### 認識
- WIT は単なる仕様書ではなく、実運用されている IDL
- Clojure 界隈では未開拓
- Wasm ライブラリのエコシステムとしてはまだ発展途上

### 方針
- WIT を **Clojure データとして表現**
- hiccup / honeysql / malli 系譜の DSL
- ベクタ + キーワードで順序を保持
- WIT <-> Clojure DSL の相互変換

### 現実的な段階

WIT/Component Model は正式版でも最初から取り組むべき領域ではない。
Wasm ライブラリのエコシステムが成熟してから着手しても遅くない。

1. **初期**: Wasm モジュールの手動ロード・呼び出し (Beta 相当の機能強化版)
2. **中期**: WIT 定義からの Clojure ラッパー自動生成
3. **長期**: Component Model 対応 (複数モジュールの型安全な合成)

---

## 5. GC・バイトコード・最適化

### WasmGC の整理
- WasmGC は Wasm 世界内部の GC
- Clojure の GC を置き換えるものではない

### 採用した考え方
- GC を差し替え可能にしようとしない
- 責務を分離する

**構成**
- Clojure 値・永続 DS -> 自前 GC
- Wasm オブジェクト -> WasmGC
- 境界はハンドル / コピー / pin

### Beta で得た GC の教訓

Beta の GC 実装 (セミスペース Arena Mark-Sweep) から得た重要な知見:

**1. fixup の網羅性が生命線**

Arena 一括解放は高速 (GPA 比 40x) だが、ポインタ fixup を1箇所漏らすだけで
use-after-free が発生する。しかも「即座にクラッシュしない」のが最も危険。
正式版では:
- `else => {}` を禁止し、新タグ追加時にコンパイルエラーで検出
- comptime でタグと fixup 関数の対応を検証

**2. Safe Point GC の制約**

Zig builtin 関数のローカル変数は GC ルートとして追跡されない。
セミスペースコピーでオブジェクトが移動すると、Zig スタック上のポインタが
旧アドレスを指したまま SIGSEGV になる。
Beta では recur opcode でのみ GC チェックを行う妥協をした。
正式版では:
- builtin 関数の中間値を VM スタックか専用ルート配列に退避する設計を最初から組む
- または NaN boxing で GC 移動対象を減らす

**3. Deep Clone の蔓延**

scratch -> persistent の安全化のため、def / swap! / atom / constant 等あらゆる箇所で
deepClone が必要になった。正式版ではアロケータ戦略を見直し、
コピー頻度を構造的に減らす。

**4. 世代別 GC は式境界 GC では効果限定**

G2a-c で Nursery + promotion を実装したが、式境界での GC では
Young -> Old の参照パターンが稀で、write barrier の投資対効果が低かった。
正式版で世代別を採用するなら、式境界ではなく関数境界 or allocation 閾値ベースに。

### 将来の設計余地
- ルート列挙形式 (stack map)
- write barrier フック
- メモリ境界の明確化

### GC・最適化のモジュラー設計

Beta の反省: GC と最適化 (fused reduce 等) が場当たり的に追加され、
builtin 関数のあちこちに `safePointCollectNoStack()` や `forceCollect()` が
散在する結果になった。正式版では **最初からモジュラーな抽象層** を設計する。

#### Beta の問題の具体例

```zig
// Beta: builtin 関数内に GC 呼び出しが直接埋まっている
pub fn reduceFn(allocator: Allocator, args: []const Value) !Value {
    // ... reduce ロジック ...
    // GC を呼ぶかどうかの判断が関数ごとにバラバラ
}
```

```zig
// Beta: VM の safe point も vm.zig に直接記述
// recur opcode でのみ GC チェック → 長い builtin ループでは GC が走らない
if (defs.current_allocators) |allocs| {
    allocs.safePointCollect(self.env, core.getGcGlobals(), self.stack[0..self.sp]);
}
```

#### 正式版の設計: 3層分離

```
┌─────────────────────────────────────────────────────┐
│ Layer 3: 最適化層 (OptimizationPass)                │
│   fused reduce, 定数畳み込み, inline caching        │
│   → GC層・実行層に依存しない純粋な変換              │
├─────────────────────────────────────────────────────┤
│ Layer 2: 実行層 (ExecutionEngine)                   │
│   native VM / wasm_rt VM                            │
│   → safe point を GC 層に委譲                       │
├─────────────────────────────────────────────────────┤
│ Layer 1: メモリ層 (MemoryManager)                   │
│   GcAllocator / WasmGC bridge                       │
│   → アロケータインターフェースで抽象化              │
└─────────────────────────────────────────────────────┘
```

#### Layer 1: メモリ層の抽象化

```zig
// 正式版: GC 戦略を trait で抽象化
const GcStrategy = struct {
    // vtable パターン (Zig の interface idiom)
    allocFn: *const fn (self: *anyopaque, size: usize) ?[*]u8,
    collectFn: *const fn (self: *anyopaque, roots: RootSet) void,
    shouldCollectFn: *const fn (self: *anyopaque) bool,

    pub fn alloc(self: GcStrategy, size: usize) ?[*]u8 {
        return self.allocFn(self.ptr, size);
    }
    pub fn shouldCollect(self: GcStrategy) bool {
        return self.shouldCollectFn(self.ptr);
    }
};

// native 路線: セミスペース GC
const NativeGc = struct {
    arena: ArenaAllocator,
    registry: AllocMap,
    threshold: usize,
    // ...
    pub fn strategy(self: *NativeGc) GcStrategy { ... }
};

// wasm_rt 路線: WasmAllocator ベース (GC は Wasm ランタイムに委譲)
const WasmRtGc = struct {
    // std.heap.WasmAllocator を使用
    // memory.grow ベースの割り当て
    // sweep は不要 (ランタイムが管理)
    pub fn strategy(self: *WasmRtGc) GcStrategy { ... }
};
```

**comptime 切替**: `build.zig` で `-Dbackend=native` or `-Dbackend=wasm_rt` を指定すると、
対応する GcStrategy 実装だけがリンクされる。

#### Layer 2: 実行層の safe point 設計

Beta では recur opcode でのみ GC チェックを行う妥協をした。
正式版では safe point を **yield point** として明示的に設計する。

```zig
// 正式版: VM の yield point を明示化
const YieldPoint = enum {
    recur,          // ループ末尾
    call_return,    // 関数呼び出し後
    alloc_check,    // N 回の alloc 後
};

// VM ループ内
fn executeOp(self: *VM, op: OpCode) !void {
    switch (op) {
        .recur => {
            // ... recur 処理 ...
            self.checkYieldPoint(.recur);
        },
        .call, .call_0, .call_1 => {
            const result = try self.callFunction(fn_val, args);
            self.checkYieldPoint(.call_return);
            // ...
        },
        // ...
    }
}

fn checkYieldPoint(self: *VM, point: YieldPoint) void {
    _ = point; // 将来: point 別の統計取得に活用
    if (self.gc.shouldCollect()) {
        self.gc.collect(.{ .vm_stack = self.stack[0..self.sp] });
    }
}
```

#### Layer 3: 最適化層の GC 非依存化

Beta の fused reduce は builtin 関数内に直接実装されており、
GC 呼び出しが混在していた。正式版では最適化パスを **pure な変換** として分離する。

```zig
// 正式版: fused reduce は OpCode レベルで表現
// コンパイラが (reduce + (take (map f (range N)))) を検出し、
// 専用の fused_reduce opcode を emit する

const OpCode = enum {
    // ... 既存 opcodes ...
    fused_reduce_range,     // (reduce f init (range N))
    fused_reduce_map,       // (reduce f init (map g coll))
    fused_reduce_filter,    // (reduce f init (filter pred coll))
    fused_reduce_chain,     // 汎用チェーン (transform stack 付き)
};
```

これにより:
- **コンパイラ** が最適化判断を行い (Analyzer or emit 段階)
- **VM** が専用 opcode を実行 (safe point は VM が管理)
- **builtin 関数** は非最適化パスのフォールバックのみ担当
- native/wasm_rt 両方で同じ opcode を使えるが、VM 実装は路線別

#### 路線別の違い

| 層           | native 路線                         | wasm_rt 路線                          |
|--------------|-------------------------------------|---------------------------------------|
| メモリ層     | セミスペース GC + Arena              | std.heap.WasmAllocator + ランタイム GC |
| safe point   | VM 内 yield point で自前 GC 呼び出し | alloc 閾値で memory.grow、GC はランタイム任せ |
| fused reduce | 専用 opcode → VM 直接実行            | 同じ opcode → wasm_rt VM で実行        |
| 定数畳み込み | コンパイラで完結 (GC 無関係)         | 同じ                                   |
| NaN boxing   | 自前実装 (f64 ビット操作)            | 不使用 (Wasm の i64/f64 を活用)        |

#### 段階的導入計画

1. **Phase 2** (§19): GcStrategy trait と NativeGc 実装。wasm_rt は stub
2. **Phase 4** (§19): fused_reduce opcode 追加。コンパイラの最適化パス
3. **Phase 10** (§19): WasmRtGc 実装。std.heap.WasmAllocator 統合

各 Phase で既存コードを壊さずに拡張できるのがこの3層分離のメリット。

---

## 6. Wasm 実行エンジン選択

### 検討
- zware (Beta で利用)
- Wasmtime
- 完全自作

### 判断
- zware を当面利用 (Zig 完結・軽量)
- Wasmtime は将来の backend として視野に入れる
- WasmBackend interface を Zig 側に用意し差し替え可能に

### Beta での実感

zware は Zig 完結で組み込みやすく、学習目的には最適だった。
ただし以下の制約がある:
- multi-value return 未対応の可能性
- WASI は手動登録が必要 (自動解決なし)
- `@ptrCast` によるシグネチャ適合がフラジャイル

正式版では WasmBackend trait を最初から定義し、
zware / Wasmtime / 自作エンジンを差し替え可能にする。

---

## 7. 超高速バイナリ路線 vs Wasm フリーライド路線

二路線は完全には両立しない。GC / バイトコード実装は分岐する。

### native 路線 (超高速単一バイナリ)
- GC: 自前 (セミスペース or 世代別)
- 最適化: 自前 (NaN boxing, inline caching, fused reduce 等)
- 配布: 単一バイナリ、起動即実行
- 用途: CLI ツール、Server Function、Edge Computing

### wasm_rt 路線 (Wasm ランタイムフリーライド)

ClojureWasm 自体を `zig build -target wasm32-wasi` で .wasm にコンパイルする路線。
ネイティブバイナリではなく、Wasm ランタイム上で動く処理系そのものを配布する。

- ビルド: Zig の Wasm ターゲットで処理系全体を .wasm 化
- GC: WasmGC アノテーションを活用し、ランタイムの GC に協調
- 最適化: ランタイムの JIT / TCO を活用。Wasm tail-call proposal 等に対応
- 配布: .wasm ファイル、WasmEdge / Wasmtime 等で実行
- 用途: ポータブルなサービス、Wasm-first なプラットフォーム

**native との違い**: ビルドされたバイナリ自体が Wasm なので、
処理系が実行中に .clj を処理する際も Wasm ランタイムの機能 (JIT, GC, TCO) が効く。
Wasm のデータ型・構造に寄せた内部表現を採用することで、
ランタイムが最適化しやすいコードを生成できる可能性がある。

**重要な決断**
- 一本化しない
- 実行時分岐は入れない

### Zig 0.15.2 の Wasm サポート調査結果

wasm_rt 路線で `zig build -Dtarget=wasm32-wasi` する際に活用できる
Zig 標準ライブラリの機能を調査した (Zig 0.15.2、本 PC 上で確認)。

#### std.heap.WasmAllocator

パス: `std/heap/WasmAllocator.zig`

Wasm ターゲット専用のアロケータ。`@wasmMemoryGrow` を直接使用する。

```zig
// Wasm ターゲットでは std.heap.page_allocator が自動的に WasmAllocator を使う
// 明示的に使う場合:
const wasm_alloc = std.heap.wasm_allocator;
```

**特徴**:
- **power-of-two サイズクラス**: 小さいアロケーションはサイズクラス別のフリーリスト管理
- **bigpage (64KB)**: 大きなアロケーションは 64KB 単位の倍数で確保
- **`@wasmMemoryGrow(0, n)`**: ページ単位 (64KB) でリニアメモリを伸長
- **制約**: `single_threaded` モードのみ対応 (comptime エラーで保護)
- **メモリ縮小不可**: Wasm の制約で memory.grow のみ、shrink なし

**vtable**: `alloc`, `resize`, `remap`, `free` の4メソッド。
`std.mem.Allocator` インターフェースに準拠しており、
Beta の GcAllocator と同じ `Allocator` 型として統一的に扱える。

#### wasm.zig (バイナリ形式定義)

パス: `std/wasm.zig`

- `page_size = 64 * 1024` (64 KiB)
- `Valtype`: `i32, i64, f32, f64, v128`
- `RefType`: `funcref (0x70), externref (0x6F)`
- `Opcode`: MVP 全命令 (memory_size, memory_grow 含む)
- `SimdOpcode`: v128 SIMD 命令 (~200+)
- `AtomicsOpcode`: スレッド関連 atomic 命令

#### Wasm ターゲット CPU features

パス: `std/Target/wasm.zig`

`zig build -Dtarget=wasm32-wasi` のデフォルト (generic モデル) で有効になるもの:

| feature               | 有効 (generic) | ClojureWasm での活用          |
|-----------------------|----------------|-------------------------------|
| bulk_memory           | Yes            | メモリコピー・充填の高速化    |
| multivalue            | Yes            | 関数の複数戻り値              |
| mutable_globals       | Yes            | グローバル変数の書き換え      |
| nontrapping_fptoint   | Yes            | float→int 変換の安全化        |
| reference_types       | Yes            | externref で外部オブジェクト  |
| sign_ext              | Yes            | 符号拡張命令                  |
| tail_call             | No (opt-in)    | **TCO に必要** → 有効化検討   |
| simd128               | No (opt-in)    | 文字列処理・コレクション高速化 |
| atomics               | No (opt-in)    | 将来のマルチスレッド          |

**tail_call feature**: `zig build -Dcpu=bleeding_edge` で有効化可能。
wasm_rt 路線で recur の TCO をランタイムに任せるなら必須。

#### WASI API

パス: `std/os/wasi.zig`

`wasi_snapshot_preview1` の extern 関数群:

- **ファイル I/O**: `fd_read`, `fd_write`, `fd_seek`, `path_open` 等
- **時刻**: `clock_time_get` (MONOTONIC, REALTIME 対応)
- **環境**: `environ_get`, `args_get`
- **乱数**: `random_get`

ClojureWasm の `slurp`, `spit`, `__nano-time` 等は WASI 経由で実装可能。

#### wasm_rt 路線での GcAllocator 設計への影響

1. **backing allocator の差し替え**:
   - Beta: `ArenaAllocator.init(std.heap.page_allocator)`
   - native: 同じ (page_allocator はOS の mmap)
   - wasm_rt: page_allocator が自動的に `WasmAllocator` になる
   - → **コード変更なしで動く** (Zig の抽象化が効いている)

2. **セミスペース GC の制約**:
   - sweep 時の新 Arena 確保は memory.grow で OK
   - ただし旧 Arena の解放が **実質不可能** (Wasm は shrink できない)
   - → wasm_rt ではセミスペースではなく **mark-compact** or
     **mark-sweep (free-list)** が適切
   - WasmAllocator の free-list がそのまま使える

3. **メモリ上限**:
   - wasm32 は 4GiB アドレス空間 (実質 2-3GiB 程度)
   - page_size = 64KiB → 最大 ~65,536 ページ
   - GC 閾値の設計を native とは変える必要あり

4. **NaN boxing の可否**:
   - wasm32 では pointer が 32-bit → NaN boxing の空間は十分
   - ただし Wasm ランタイムの JIT が NaN boxing を理解できない
   - wasm_rt では NaN boxing を使わず、tagged union + ランタイム最適化が有利

**結論**: Zig の Allocator 抽象のおかげで、
wasm_rt 路線でもコードの大部分は共有可能。
ただし GC 戦略 (セミスペース → mark-sweep) と Value 表現 (NaN boxing → tagged union) は
路線別に comptime 切替する必要がある。§5 の「GC・最適化のモジュラー設計」で述べた
GcStrategy trait が、この差異を吸収する鍵となる。

---

## 8. アーキテクチャ方針

### 単一リポジトリ・comptime 切替

Beta ではリポジトリ分離の構想があったが、
現実には Reader/Analyzer にもバックエンド依存が入り込む
(エラー追跡、REPL 統合、ネイティブ最適化パス等)。

**正式版の方針**: 単一リポジトリ、Zig の `comptime` でビルド時に世界線を切替。

```
src/
├── common/           # 両路線で共有
│   ├── reader/       # Tokenizer, Reader, Form
│   ├── analyzer/     # Analyzer, Node, macro expansion
│   ├── bytecode/     # OpCode 定義、定数テーブル形式
│   └── value/        # Value 型定義 (表現は路線別)
│
├── native/           # 超高速・単一バイナリ路線
│   ├── vm/           # VM 実行エンジン (NaN boxing 等)
│   ├── gc/           # 自前 GC (セミスペース/世代別)
│   ├── optimizer/    # 定数畳み込み、fused reduce 等
│   └── main.zig
│
├── wasm_rt/          # Wasm ランタイムフリーライド路線
│   ├── vm/           # Wasm target VM
│   ├── gc_bridge/    # WasmGC 連携
│   ├── wasm_backend/ # WasmBackend trait 実装
│   └── main.zig
│
└── build.zig         # comptime で native / wasm_rt を選択
```

### 共有層の境界

Beta の経験から、共有しやすい / しにくい領域:

| 層           | 共有可能性 | 理由                                                   |
|--------------|------------|--------------------------------------------------------|
| Reader       | 高         | 純粋なパーサ、バックエンド非依存                       |
| Analyzer     | 中〜高     | マクロ展開は共通だが、最適化パスが分岐する可能性       |
| OpCode 定義  | 中         | 意味論は共通、native 固有の高速 opcode が入る可能性    |
| VM           | 低         | 実行エンジンの中核。native と wasm_rt で根本的に異なる |
| GC           | 低         | 責務が完全に異なる                                     |
| Value 型定義 | 中         | variant は共通だが内部表現 (NaN boxing 等) は路線依存  |
| builtin 関数 | 中〜高     | 意味論は共通、GC/アロケータ依存コードは路線別          |

### Zig の活用
- comptime で世界線をビルド時に切替
- 実行時分岐ゼロ
- 不要コードはリンクされない

> **Note**: 正式版の具体的なディレクトリ構造は §17 で詳述。

---

## 9. Beta から正式版へ持ち越す設計知見

Beta の開発で確立した知見のうち、正式版で最初から組み込むべきもの:

### 9.1 コンパイラ-VM 間の契約を明文化する

Beta で最も多かったバグは「コンパイラが emit する値と VM が解釈する値の意味の不一致」。
capture_count, slot 番号, scope_exit の引数など、暗黙の契約が壊れると
**クラッシュではなく間違った値を返す** (静かに壊れる)。

**正式版**: 契約を型で表現し、comptime で整合性を検証。

### 9.2 デュアルバックエンドの `--compare` は初期から用意する

Beta の `--compare` モード (TreeWalk と VM の突き合わせ) は
バグ発見の最も有効な手段だった。
正式版でも**意味論の参照実装** (遅くてよい) を維持し、
高速実装との差分検出に使う。

ただし Beta では TW と VM 両方の維持コストが大きかった。
正式版では参照実装をより軽量にする (例: インタプリタではなくテストオラクル生成)。

### 9.3 Fused Reduce パターン

lazy-seq チェーン (take -> map/filter -> source) を単一ループに展開する最適化は
メモリ効率に劇的な効果があった (map_filter: 27GB -> 2MB)。
正式版では最初からこのパターンを VM レベルで組み込む。

### 9.4 アロケータ分離原則

Env/Namespace/Var/HashMap は GPA 直接管理 (GC 対象外)、
Clojure Value のみ GcAllocator 経由という分離は正しかった。
正式版でも「インフラ vs ユーザー値」の寿命分離を初期設計に含める。

### 9.5 コレクション実装の見直し

Beta では配列ベースの簡易コレクション実装を採用した (Vector = ArrayList)。
正式版ではインターフェースの互換性を維持しつつ、実装は Zig の強みを活かす。

**方針**: 本家の HAMT / RRB-Tree をそのまま模倣するのではなく、
メモリ効率・速度で上回れる Zig ネイティブな実装を探求する。
Zig の comptime、Arena allocator、値型セマンティクスを活かした
高速実装が可能であれば、それを採用すべき。

**段階的アプローチ**:
1. 初期は Beta と同じ配列ベースで開始 (動作の正確性を優先)
2. プロファイル結果を見てボトルネックのコレクションから最適化
3. Vector が最も使用頻度が高いため、最初の最適化候補

**インターフェース要件** (本家互換):
- persistent (既存コレクションは変更されない)
- structural sharing (大きなコレクションのコピーコストを抑える)
- O(log32 N) の lookup/update (Map, Vector)

**GC との相互作用に注意**: 構造共有を導入すると、複数の Value が同じ内部ノードを
参照するため、fixup が木構造を辿る必要がある。Beta の「fixup 漏れ = 即死」教訓が
さらに厳しくなる。comptime での検証がより重要になる。

### 9.6 コアライブラリのビルド時 AOT コンパイル

#### 課題: Beta は全てを Zig で実装した

Beta では clojure.core の 545 関数・マクロを全て Zig builtin として実装した。
これには理由があった (起動速度、ブートストラップ回避) が、以下の問題を生んだ:

- Analyzer に 54 個のマクロ展開が Zig でハードコードされた
- 本家 core.clj と実装が乖離し、互換性テストが困難
- マクロの追加・修正に Zig の再コンパイルが必要

#### 他の実装の戦略

| 実装           | core の定義方法                    | 起動時ロード | AOT         |
|----------------|------------------------------------|-------------|-------------|
| Clojure 本家   | core.clj (276KB) を毎回パース      | Yes         | No          |
| ClojureScript  | core.cljc → JS にコンパイル        | No          | Yes (→JS)   |
| SCI/Babashka   | copy-var でホスト関数をラップ      | macro展開時  | GraalVM のみ |
| jank           | core.jank (7.6K行) + C++ native    | Yes         | →C++ 変換   |
| ClojureWasm Beta | 全て Zig builtin                 | No          | —           |

#### 正式版の方針: ビルド時 AOT (ClojureScript 方式)

**core.clj をビルド時にバイトコードへプリコンパイルし、`@embedFile` でバイナリに埋め込む。**

```
ビルド時:
  core.clj → Reader → Analyzer → Compiler → bytecode blob
                                                 ↓
                                         @embedFile("core.bc")
                                                 ↓
起動時:                                    単一バイナリに含まれる
  VM が bytecode blob を即実行 (パース不要)
  → Var が Env に登録される
  → ユーザーコードが利用可能に
```

**利点**:

- **単一バイナリ**: .clj ファイルを同梱する必要なし
- **高速起動**: パース・解析をスキップ、バイトコード実行のみ
- **本家互換**: マクロ定義を本家 core.clj に近い形で記述可能
- **分離**: Zig コードと Clojure コードの責務が明確に分かれる

**ビルドパイプライン**:

```
build.zig:
  1. zig build → ClojureWasm コンパイラ自体をビルド (ホストツール)
  2. ホストツールで core.clj → core.bc にコンパイル
  3. @embedFile("core.bc") で core.bc をバイナリに埋め込み
  4. 最終バイナリをビルド
```

Zig の `build.zig` は任意のビルドステップを追加でき、
ステップ 2 で「自分自身のコンパイラを使って .clj をコンパイル」できる。

#### Zig に残すもの vs core.clj に移すもの

**判断基準**: 「VM opcode 最適化が必要か」「OS/ランタイム依存か」

| 移行先    | 対象                                                   | 理由                              |
|-----------|-------------------------------------------------------|-----------------------------------|
| core.clj  | マクロ 43+個 (defn, when, cond, ->, and, or 等)       | 純粋 Form→Form 変換              |
| core.clj  | 高レベル関数 (map, filter, take, drop, partition 等)   | 本家と同じ定義で互換性向上        |
| core.clj  | ユーティリティ (complement, constantly, juxt, memoize) | Zig 依存ゼロ                      |
| Zig 維持  | VM intrinsic (+, -, first, rest, conj, assoc, get)    | 専用 opcode で最適化              |
| Zig 維持  | reduce (fused reduce のエントリポイント)              | §5 最適化パスと密結合             |
| Zig 維持  | I/O・OS (slurp, spit, re-find, __nano-time)           | Zig/OS API 依存                   |
| Zig 維持  | 状態管理 (atom, swap!, deref, reset!)                  | ランタイム内部構造に依存          |

Beta の Analyzer に実装された 54 マクロのうち、**約 79% (43個)** は
純粋な Form→Form 変換であり、.clj にそのまま移行可能。

#### ブートストラップ順序

本家 core.clj は段階的な自己定義を行う:

```clojure
;; Phase 1: fn*, def のみ使える (destructuring なし)
(def list (fn* list [& items] items))
(def cons (fn* cons [x seq] ...))

;; Phase 2: defn を定義 (fn* + def で)
(def defn (fn* defn [name & decl] ...))
(.setMacro (var defn))  ;; ← Java Interop

;; Phase 3: defn が使えるようになる
(defn map [f coll] ...)
```

ClojureWasm では `.setMacro` の Java Interop を排除するため:

```clojure
;; ClojureWasm の core.clj
;; Phase 1: special form のみ
(def list (fn* list [& items] items))

;; Phase 2: defmacro (special form) で defn を定義
(defmacro defn [name & decl]
  `(def ~name (fn ~name ~@decl)))

;; Phase 3: 通常の定義
(defn map [f coll] ...)
```

`defmacro` は special form として Zig Analyzer に残るため、
ブートストラップの「鶏と卵」問題は発生しない。

#### リスクと緩和策

| リスク                                    | 緩和策                                     |
|-------------------------------------------|--------------------------------------------|
| core.clj のパースがビルド時間を増やす     | インクリメンタルビルド (core.bc をキャッシュ) |
| 起動時の bytecode 実行コスト              | ベンチマーク計測、必要なら遅延ロード       |
| core.clj のデバッグが困難                 | `--dump-core-bytecode` フラグで検査        |
| Zig builtin と core.clj の二重定義リスク  | comptime で重複検出 (registry.zig 方式)    |

---

## 10. 互換性検証戦略

### 課題: Clojure には仕様書がない

Clojure は「本家実装が仕様」であり、形式仕様が先にある言語ではない。
そのため「動作互換」を検証するには本家の振る舞いを機械的に参照するしかない。

Beta では場当たり的にテストを書いた (35 ファイル, ~3,265 行)。
vars.yaml で関数の実装状況 (done/skip) を追跡しているが、
「存在する」と「正しく動く」の間に大きなギャップがある。

### 互換性のレベル定義

| レベル | 検証内容                                 | 重要度 | 検証方法            |
|--------|------------------------------------------|--------|---------------------|
| L0     | 関数/マクロが存在する                    | 必須   | vars.yaml で追跡    |
| L1     | 基本的な入出力が一致する                 | 必須   | テストオラクル      |
| L2     | 辺境値・エラーケースが一致する           | 高     | upstream テスト移植 |
| L3     | 遅延評価・副作用の観測可能な振る舞い     | 中     | 意味論テスト        |
| L4     | エラーメッセージ・スタックトレースの形式 | 低     | 互換性は追求しない  |

**原則**: 入出力の等価性を保証する。内部実装の詳細 (realize タイミング等) は、
観測可能な結果が同じであれば許容する。fused reduce 等の最適化は
「外から見た振る舞いを変えない」ことが条件。
既存の Pure Clojure コードベースを実行した際に、
ユーザーのビジネスロジックの結果が変わることは許容しない。

**注意: 副作用を含む lazy-seq と chunked sequence**

本家 Clojure は内部的に chunked sequence (32 要素単位の先読み) を使う。
そのため `(take 3 (map #(do (println %) %) (range 100)))` は
本家では 0〜31 が println される可能性がある (chunk 単位の先読み)。

ClojureWasm の fused reduce は厳密に必要な 3 要素だけ処理する。
これは**観測可能な副作用の差異**であり、互換性テストで `diff` になりうる。

ただし本家の chunked seq の挙動自体が「仕様ではなく実装詳細」とされており、
Pure Clojure のコード (副作用のない map/filter) では問題にならない。
副作用を持つ lazy 変換に依存するコードはそもそも non-idiomatic であり、
この差異は許容する判断とする。compat_status.yaml では `diff` として記録し、
理由を明記する。

### テストカタログの真実のソース

3つの upstream から機械的にテストを取り込み、継続的に同期する:

```
upstream テスト (Clojure / ClojureScript / SCI)
        ↓
   Tier 1: 決定論的ルール変換 (構文変換、NS 置換)
   Tier 2: 決定論的 Java エイリアス置換 (tryJavaInterop 拡張)
   Tier 3: AI 補助変換 → 人間レビュー → コミット (コミット後は決定論的)
        ↓
imported/ テストファイル群
        ↓ ClojureWasm で実行
        ↓
結果 → compat_status.yaml に記録
        ↓
未対応 → issue or skip (理由付き)
```

#### ソース別の特性

| ソース        | 規模       | Java 汚染    | 変換コスト | テスト行数の期待値   |
|---------------|------------|--------------|------------|----------------------|
| SCI           | ~4,650 行  | 低 (.cljc)   | 低         | ~4,000 行 (大半取込) |
| ClojureScript | ~21,400 行 | なし (.cljs) | 中         | ~15,000 行 (JS 除去) |
| Clojure 本家  | ~14,300 行 | 高 (.clj)    | 高         | ~5,000 行 (Tier 2/3) |

合計: **~24,000 行** のテストカタログを構築可能 (現在の ~3,265 行の 7 倍以上)

#### 3 段階の変換パイプライン

**Tier 1: 決定論的ルール変換** (SCI + CLJS)

変換が機械的で、結果が一意に定まるもの。最優先で取り組む。

SCI (.cljc):
- `eval*` → 直接実行
- `tu/native?` 分岐 → `true` 側を採用
- マップリテラル `{}` → `(hash-map ...)` (deftest body 内)
- Beta で 5 ファイル移植済み → 残り ~15 ファイルを同ルールで処理

ClojureScript (.cljs):
- `cljs.test` → `clojure.test` (ClojureWasm の互換層)
- `js/Error` → ClojureWasm のエラー型
- `js/Object`, `js/Array` → skip
- `satisfies?` → ClojureWasm の protocol チェック
- `catch :default` → `catch` (ClojureWasm の catch-all)

**Tier 2: Java エイリアス置換** (Clojure 本家)

Java Interop 呼び出しを ClojureWasm のネイティブ代替に変換する。
テスト関数単位で処理し、変換できたもののみ取り込む。

決定論的に変換可能なパターン:
- `System/nanoTime` → `(__nano-time)`
- `System/currentTimeMillis` → `(__current-time-millis)`
- `Thread/sleep` → `(__sleep ms)`
- `(instance? String x)` → `(string? x)`
- `(instance? Long x)` → `(integer? x)`
- `(.length s)` → `(count s)`
- `(.toUpperCase s)` → `(clojure.string/upper-case s)`
- `(import ...)` → 除去 (エイリアスでカバーされていれば)

変換不能なパターン → Tier 3 または skip:
- `proxy`, `reify`, `gen-class`
- `java.util.concurrent.*`
- reflection (`(.getMethod ...)`)
- `java.io.*` の深い利用

**Tier 3: AI 補助 + 人間レビュー** (残り)

Tier 2 で変換できなかったテストのうち、テストの意図が Java 非依存なもの:
- AI にテストの意図を解析させ、等価な Java-free テストを生成
- 人間がレビューし、正しければコミット
- コミット後は決定論的なテストとして扱う
- 変換元の upstream ref とレビュー者を記録

原則: AI 生成テストは必ず人間レビューを経る。
レビューなしの自動生成テストは信頼しない。

#### cljs.test 互換層

ClojureScript テスト (~21,400 行) をそのまま実行するため、
`cljs.test` の主要マクロを ClojureWasm で実装する:

```clojure
;; ClojureWasm が提供する cljs.test 互換 NS
(ns cljs.test)

;; 必要なマクロ/関数:
;; deftest, is, are, testing, run-tests, use-fixtures
;; assert-expr (multimethod), do-report
```

ClojureScript テストの JS 固有部分の扱い:

| CLJS パターン             | ClojureWasm での扱い              |
|---------------------------|-----------------------------------|
| `js/Error`                | ClojureWasm の例外型にマッピング  |
| `js/Object`               | skip (JS 固有)                    |
| `js/Array`                | skip (JS 固有)                    |
| `js/parseInt`             | `Integer/parseInt` エイリアス     |
| `(catch :default e ...)`  | `(catch e ...)` (catch-all)       |
| `satisfies?`              | protocol チェック (Beta 実装済み) |
| `(exists? js/Symbol)`     | `false` (JS ランタイム不在)       |
| `#js [...]` / `#js {...}` | skip (JS リテラル)                |

#### upstream 同期の自動化

- upstream リポジトリの特定コミット/タグをサブモジュールまたは snapshot で追跡
- CI でテスト生成 → 実行 → 結果を YAML に記録
- 新テストが追加されたら自動で取り込み、初回は `pending` ステータス
- upstream の変更差分から影響テストを特定し、再変換・再実行

### ステータス管理

vars.yaml (関数存在) に加え、テスト単位のステータスを管理する:

```yaml
# compat_status.yaml (構想)
tests:
  sci/core_test:
    test-eval:
      status: pass          # pass | fail | skip | pending
      source: sci
      upstream_ref: "abc123"
    test-map-indexed:
      status: skip
      source: sci
      reason: "java.util.ArrayList 依存"
      issue: null

  clojure/data_structures:
    test-associative:
      status: pass
      source: clojure
      upstream_ref: "def456"
    test-sorted-maps:
      status: fail
      source: clojure
      reason: "Sorted map 未実装"
      issue: "#42"
```

#### ステータスの意味

| ステータス | 意味                                                   |
|------------|--------------------------------------------------------|
| pass       | テストが通る                                           |
| fail       | テストが落ちる (実装が必要、またはバグ)                |
| skip       | 意図的に見送り (Java 依存、未実装型等)。理由を必ず記録 |
| pending    | 未評価 (upstream から新規取り込み、まだ実行していない) |
| diff       | 動作するが本家と微妙に異なる。差異の内容を記録         |

### Java Interop 排除と互換エイリアス

Java Interop は排除するが、プログラミング上必須な機能はエイリアスで提供する:

| 本家 (Java)                     | ClojureWasm              | 方針               |
|---------------------------------|--------------------------|--------------------|
| `System/nanoTime`               | `__nano-time` (Zig 実装) | Beta で対応済み    |
| `System/currentTimeMillis`      | `__current-time-millis`  | Beta で対応済み    |
| `slurp` / `spit`                | Zig ファイル I/O で実装  | 正式版で対応       |
| `clojure.java.io/reader`        | ネイティブ I/O で代替    | エイリアス提供     |
| `clojure.string/*`              | Zig builtin で直接実装   | Beta で対応済み    |
| `Thread/sleep`                  | Zig の `std.time.sleep`  | エイリアス提供     |
| `java.util.regex.Pattern`       | Zig フルスクラッチ regex | Beta で対応済み    |
| `BigDecimal` / `BigInteger`     | skip                     | 正式版で要検討     |
| `proxy` / `reify` / `gen-class` | skip                     | JVM 固有、代替なし |

**方針**: `tryJavaInterop` パターン (Beta の analyze.zig) を拡張し、
本家テストに含まれる `System/foo` や `java.lang.*` 呼び出しを
自動的にネイティブ代替にルーティングする。
これにより、本家テストをできるだけ「そのまま」実行できるようにする。

### Beta での教訓

- `--compare` (TW vs VM) は「内部一貫性」の検証。外部互換性の検証は別途必要
- 場当たり的なテスト追加では抜け漏れが避けられない
- SCI 移植ルールの文書化は有効だった → 自動化すればさらに効果的
- vars.yaml の `done/skip` 二値では「動くが微妙に違う」を表現できなかった

### Var メタデータとシンボル分類の設計

#### 課題: Clojure のシンボル種別は外から見えにくい

Clojure では `map` が関数、`defn` がマクロ、`if` がスペシャルフォームだが、
ユーザーがコードを読むだけでは区別がつかない。
本家では `(doc map)`, `(meta #'map)` で確認できる。

正式版では **Var のメタデータを初期設計から充実させ**、
「どの層に依存しているか」を明示的に分類する。

#### Beta の現状と問題点

Beta の `Var` 構造体 (src/runtime/var.zig):

```zig
pub const Var = struct {
    sym: Symbol,
    ns_name: []const u8,
    root: Value,
    dynamic: bool,      // ^:dynamic
    macro: bool,        // ^:macro
    private: bool,      // ^:private
    is_const: bool,     // ^:const
    meta: ?*const Value,
    doc: ?[]const u8,
    arglists: ?[]const u8,
};
```

- スペシャルフォーム (if, do, let 等 17 個) は Analyzer のハードコード文字列比較で識別。Var に記録されない
- マクロ 54 個が Zig Analyzer にハードコード。うち 79% は純粋な Form→Form 変換で .clj に書ける
- `(doc if)` で「special form」と表示できない
- builtin 関数の結合度 (VM 最適化対象 vs 汎用) の区別がない

#### 正式版の設計: 依存層ベースの VarKind

§9.6 の AOT 戦略を前提に、**「何語で実装したか」ではなく「どの層に依存しているか」** で分類する。

```zig
pub const VarKind = enum(u8) {
    /// スペシャルフォーム — Compiler 層に依存
    /// Analyzer が専用 AST ノードを生成。VM opcode に直接対応
    /// 例: if, do, let, fn, def, quote, loop, recur, throw, try,
    ///     defmacro, defmulti, defmethod, defprotocol, extend-type, lazy-seq
    special_form,

    /// VM intrinsic — VM 層に依存
    /// 専用 opcode で高速実行。VM 変更時に影響あり
    /// Zig builtin として実装、core.clj には移行しない
    /// 例: +, -, *, /, =, <, first, rest, cons, conj, assoc, get, nth
    vm_intrinsic,

    /// ランタイム関数 — Runtime 層 (Zig/OS) に依存
    /// Zig で実装、VM opcode 最適化なし。OS/Zig API への依存がある
    /// 例: slurp, spit, re-find, re-matches, __nano-time, atom, swap!, deref
    runtime_fn,

    /// コア関数 — 依存なし (pure)
    /// core.clj に定義し、ビルド時 AOT でバイトコードに埋め込む
    /// 例: map, filter, take, drop, partition, str, subs, comp, partial
    core_fn,

    /// コアマクロ — 依存なし (pure)
    /// core.clj に定義。Form→Form 変換のみ
    /// 例: defn, when, cond, ->, ->>, if-let, and, or, complement, constantly
    core_macro,

    /// ユーザー定義関数
    user_fn,

    /// ユーザー定義マクロ
    user_macro,
};
```

#### 依存層による分類

| 依存層               | VarKind          | 定義場所    | 変更時の影響              | 例                              |
|----------------------|------------------|-------------|---------------------------|---------------------------------|
| **Compiler** (AST)   | `special_form`   | Zig Analyzer | Analyzer/Compiler 再実装  | if, do, let, fn, def, try       |
| **VM** (opcode)      | `vm_intrinsic`   | Zig builtin  | VM opcode 変更で影響      | +, -, first, rest, conj, assoc  |
| **Runtime** (Zig/OS) | `runtime_fn`     | Zig builtin  | OS API 変更で影響         | slurp, re-find, __nano-time     |
| **なし** (pure)      | `core_fn`        | core.clj AOT | Zig 変更の影響なし        | map, filter, take, drop, str    |
| **なし** (pure)      | `core_macro`     | core.clj AOT | Zig 変更の影響なし        | defn, when, cond, ->, and, or   |
| **なし**             | `user_fn/macro`  | ユーザー    | —                         | ユーザー定義                    |

**fn と macro の対称性**: `core_fn` / `core_macro`、`user_fn` / `user_macro` で対称。
Beta の「マクロ = 特別な実装形態」という暗黙の区別がなくなる。

**マクロは原則として密結合しない**: Beta の 54 マクロのうち 43 個は
純粋 Form→Form 変換で、Zig 固有ロジックは不要。正式版では `core_macro` として
core.clj に定義する。Zig Analyzer に残るのは `defmacro` (special form) のみ。

#### 本家 Clojure メタデータの採用方針

Clojure 本家の Var には豊富なメタデータが付与される。
正式版では **本家のメタデータ体系を最初から踏襲** し、
`(doc map)` や `(meta #'map)` が本家と同等の情報を返すようにする。

**本家の主要メタデータキーと採用判断**:

| キー              | 例                           | 本家での用途                 | 採用       | 備考                             |
|-------------------|------------------------------|------------------------------|------------|----------------------------------|
| `:doc`            | `"Returns a lazy seq..."`    | ドキュメント                 | 必須       | `(doc x)` の出力                 |
| `:arglists`       | `'([f coll] [f c1 c2])`     | 引数リスト                   | 必須       | `(doc x)` の引数表示             |
| `:added`          | `"1.0"`                      | 本家 Clojure での導入版      | 必須       | 本家参照点 (後述)                |
| `:ns`             | `#<Namespace clojure.core>`  | 所属名前空間                 | 自動設定   | Var.ns_name から自動生成         |
| `:name`           | `map`                        | シンボル名                   | 自動設定   | Var.sym から自動生成             |
| `:file`           | `"clojure/core.clj"`         | 定義ファイル                 | 採用       | Zig 定義は `"zig:arithmetic"` 等 |
| `:line`           | `2744`                       | 定義行番号                   | 採用       | core.clj 定義のみ有効           |
| `:private`        | `true`                       | 非公開 Var                   | 採用済み   | Var.private フラグ               |
| `:macro`          | `true`                       | マクロフラグ                 | 採用済み   | Var.macro フラグ                 |
| `:dynamic`        | `true`                       | 動的バインディング           | 採用済み   | Var.dynamic フラグ               |
| `:tag`            | `String`                     | 戻り値型ヒント               | 後回し     | 型推論導入時に検討               |
| `:deprecated`     | `"1.2"`                      | 非推奨マーク                 | 後で採用   | 警告表示                         |
| `:static`         | `true`                       | JVM 直呼び出し最適化         | 不採用     | JVM 固有                         |
| `:inline`         | `(fn [x y] ...)`             | インライン展開               | 不採用     | JVM 固有 (fused reduce で代替)   |
| `:inline-arities` | `#{2}`                       | インラインアリティ制限       | 不採用     | JVM 固有                         |

**ClojureWasm 独自のメタデータキー**:

| キー              | 例                | 用途                                                     |
|-------------------|--------------------|----------------------------------------------------------|
| `:since-cw`       | `"0.1.0"`          | ClojureWasm での追加バージョン                            |
| `:kind`           | `:vm-intrinsic`    | VarKind 分類 (前述)。`(meta #'+ )` で層が分かる          |
| `:defined-in`     | `"zig"` / `"clj"` | 定義元。Zig builtin か core.clj AOT かを区別             |

#### 本家参照バージョンの追跡

`:added` は「本家 Clojure でいつ導入されたか」を示す。
ClojureWasm は特定バージョンの Clojure に準拠するため、
**プロジェクトレベルで参照バージョンを管理** する:

- `clojure_ref_version`: プロジェクト全体が準拠を目指す本家バージョン (例: `"1.12.0"`)
- 個別 Var には `:added` で本家導入バージョンを記録
- 本家が新バージョンをリリースした際、`:added` が新しい Var を機械的に抽出し未対応を特定

```bash
# 例: 1.13 で追加された関数のうち未実装のものを抽出
yq '.vars.clojure_core | to_entries
    | map(select(.value.added == "1.13" and .value.status != "done"))
    | .[].key' status/vars.yaml
```

#### 名前空間対応の保証

**原則: Zig で実装しても、本家と同じ名前空間に配置する。**

Beta ではこの原則を守っている (clojure.core, clojure.string, wasm)。
正式版では以下の仕組みで対応を保証する:

1. **registry.zig の comptime 検証**: 登録先の名前空間名をリテラル文字列で保持。
   本家 core.clj の `(ns clojure.core)` と対応

2. **core.clj AOT**: core.clj 内の `(ns clojure.core)` 宣言により、
   定義された関数は自動的に `clojure.core` に配置される。
   Zig 側の BuiltinDef と重複した場合は comptime エラー

3. **vars.yaml の `ns` フィールド**: 各 Var がどの名前空間に属するかを明示的に記録。
   CI で `ns` と実際の登録先の一致を検証

4. **名前空間の網羅性検証**: 本家の名前空間 (clojure.core, clojure.string,
   clojure.set, clojure.walk 等) のうち、ClojureWasm が提供するものを
   status/namespaces.yaml (構想) で追跡

```yaml
# status/namespaces.yaml (構想)
clojure_ref_version: "1.12.0"

namespaces:
  clojure.core:
    status: partial     # done | partial | stub | skip
    var_count: 545      # 実装済み Var 数
    upstream_count: 657 # 本家の Var 数
    provider: [zig, core.clj]  # Zig builtin + core.clj AOT

  clojure.string:
    status: partial
    var_count: 18
    upstream_count: 23
    provider: [zig]

  clojure.set:
    status: todo
    upstream_count: 11
    provider: [core.clj]  # 全て pure → core.clj で定義

  clojure.walk:
    status: todo
    upstream_count: 7
    provider: [core.clj]  # 全て pure

  wasm:
    status: done
    var_count: 10
    note: ClojureWasm 独自拡張 (本家にはない)
```

#### BuiltinDef の拡張 (Zig 側)

Zig 側に残る関数 (`vm_intrinsic` + `runtime_fn`) のメタデータ:

```zig
pub const BuiltinDef = struct {
    name: []const u8,
    func: BuiltinFn,
    kind: VarKind,
    doc: ?[]const u8 = null,
    arglists: ?[]const []const u8 = null,
    added: ?[]const u8 = null,             // 本家 Clojure の :added (例: "1.0")
    since_cw: ?[]const u8 = null,          // ClojureWasm 追加バージョン
};
```

`registerCore()` で Var 生成時に、BuiltinDef のメタデータを Var に転記する:

```zig
for (all_builtins) |b| {
    const v = try core_ns.intern(b.name);
    const fn_obj = try value_allocator.create(Fn);
    fn_obj.* = Fn.initBuiltin(b.name, b.func);
    v.bindRoot(Value{ .fn_val = fn_obj });
    // メタデータ転記
    v.doc = b.doc;
    v.arglists = b.arglists;
    // :added, :kind 等は Var.meta (PersistentMap) に格納
}
```

**Beta との差分**: Beta の BuiltinDef は `name` + `func` の 2 フィールドのみ。
Var.doc, Var.arglists フィールドは存在するが未設定で `(doc map)` が空を返す。
正式版では登録時に必ず設定する。

core.clj 側の関数・マクロは通常の Clojure メタデータで管理:

```clojure
(defn map
  "Returns a lazy sequence consisting of the result of applying f to
  the set of first items of each coll, followed by applying f to the
  set of second items in each coll, until any one of the colls is
  exhausted."
  {:added "1.0" :since-cw "0.1.0"}
  ([f coll] ...)
  ([f c1 c2] ...)
  ([f c1 c2 c3] ...)
  ([f c1 c2 c3 & colls] ...))
```

core.clj のメタデータは AOT コンパイル時にバイトコードに埋め込まれ、
起動時に Var に自動設定される。Zig 側の BuiltinDef と統一的に
`(doc x)`, `(meta #'x)` でアクセスできる。

#### スペシャルフォームの comptime テーブル化

Beta では Analyzer にハードコードされていたスペシャルフォームを、
正式版では comptime テーブルとして明示化する:

```zig
const special_forms = [_]BuiltinDef{
    .{ .name = "if",     .kind = .special_form, .doc = "..." },
    .{ .name = "do",     .kind = .special_form, .doc = "..." },
    .{ .name = "let",    .kind = .special_form, .doc = "..." },
    .{ .name = "fn",     .kind = .special_form, .doc = "..." },
    .{ .name = "def",    .kind = .special_form, .doc = "..." },
    .{ .name = "quote",  .kind = .special_form, .doc = "..." },
    .{ .name = "loop",   .kind = .special_form, .doc = "..." },
    .{ .name = "recur",  .kind = .special_form, .doc = "..." },
    .{ .name = "throw",  .kind = .special_form, .doc = "..." },
    .{ .name = "try",    .kind = .special_form, .doc = "..." },
    .{ .name = "defmacro", .kind = .special_form, .doc = "..." },
    // ...
};
```

Analyzer は `special_forms` テーブルを comptime で参照し、
文字列比較の if-else チェーンを `comptime` ルックアップに置き換える。

#### vars.yaml / compat_status.yaml との統合

```yaml
# status/vars.yaml (拡張構想)
clojure_ref_version: "1.12.0"  # 準拠を目指す本家バージョン

vars:
  clojure_core:
    "+":
      status: done
      kind: vm_intrinsic
      defined_in: zig
      ns: clojure.core
      added: "1.0"              # 本家で導入されたバージョン
      doc: "Returns the sum of nums..."
      arglists: "([] [x] [x y] [x y & more])"
      vm_opcode: add
      compat: L1
    "map":
      status: done
      kind: core_fn
      defined_in: core.clj       # AOT でバイナリに埋め込み
      ns: clojure.core
      added: "1.0"
      vm_opcode: null
      compat: L2
    "if":
      status: done
      kind: special_form
      defined_in: zig
      ns: clojure.core
      added: "1.0"
      vm_opcode: jump_if_false
      compat: L1
    "defn":
      status: done
      kind: core_macro
      defined_in: core.clj
      ns: clojure.core
      added: "1.0"
      expands_to: [def, fn]
      compat: L1
    "slurp":
      status: done
      kind: runtime_fn
      defined_in: zig
      ns: clojure.core
      added: "1.0"
      vm_opcode: null
      compat: L1
    "splitv-at":
      status: todo
      kind: core_fn
      defined_in: core.clj
      ns: clojure.core
      added: "1.12"              # 1.12 で追加された新関数
      compat: null

  clojure_string:
    "upper-case":
      status: done
      kind: runtime_fn           # Zig の Unicode 処理に依存
      defined_in: zig
      ns: clojure.string         # 本家と同じ名前空間
      added: "1.2"
      compat: L1
```

これにより:
- `defined_in` で .clj 移行の進捗を追跡
- `kind` 別に互換性テストの優先度を決定
  (special_form > vm_intrinsic > runtime_fn > core_fn/core_macro)
- VM リファクタリング時の影響範囲を `vm_opcode != null` で機械的に特定
- 互換性ダッシュボード (§18.4) で依存層別の pass 率を可視化
- `ns` で名前空間対応を明示。CI で登録先との一致を検証
- `added` で本家追従を管理。新バージョン追加関数の未対応を機械的に検出
- `clojure_ref_version` でプロジェクト全体の準拠目標を宣言

---

## 11. (§19 に統合)

> 移行ロードマップの詳細は **§19** を参照。

---

## 12. OSS 化とネーミング

> リポジトリ・プロジェクト管理の詳細は **§16** を参照。

### ライセンス

Clojure 本家は EPL-1.0。ClojureWasm が本家コードを直接利用していなくても、
テストカタログの移植やインターフェース互換を謳う以上、EPL-1.0 が自然な選択。
初期は破壊的変更ありの割り切りで進める (SemVer 0.x)。

### ネーミング

「Clojure」を名前に含めるかは慎重に検討が必要。

| プロジェクト  | 名前に「Clojure」 | 背景                                  |
|---------------|-------------------|---------------------------------------|
| ClojureScript | あり              | Rich Hickey 自身が設計・主導          |
| ClojureCLR    | あり              | clojure org 配下 (公式)               |
| ClojureDart   | あり              | コミュニティ重鎮、Conj 発表、公式紹介 |
| Babashka      | なし              | SCI ベース、独自名                    |
| SCI           | なし              | "Small Clojure Interpreter"           |
| Jank          | なし              | "A Clojure dialect on LLVM"           |

ClojureDart は Clojure 公式 Deref で紹介され Clojure/Conj で発表されているが、
Rich Hickey から明示的な商標許諾があったかは公開情報では確認できない。
Babashka / SCI / Jank は意図的に「Clojure」を名前から外している。

**方針**: リポジトリ名 **ClojureWasm**、CLI コマンド **`cljw`** を第一候補とする。

- `cljs` (ClojureScript), `cljd` (ClojureDart) と同じ命名パターン
- 「Java 非依存の Clojure をエッジ環境向けに Zig で再実装」は
  Clojure コミュニティへの貢献であり、名前を使う正当性がある
- 万一コミュニティから異議があればリネームする (リダイレクト対応可能)
- `cljw` は左右交互の打鍵で ergonomics も良好

---

## 13. まとめ

ClojureWasm は
「超高速単一バイナリとして成立する Clojure」をまず極め、
その上で Wasm ランタイムの力を **選択的に借りられる構造**を目指す。

世界線は comptime で切替え、単一リポジトリで管理する。
Beta で学んだ「静かに壊れるバグ」「GC の網羅性」「暗黙の契約」を
正式版では設計レベルで防止する。

加えて、正式版では以下の領域も設計段階から組み込む:

- **Var メタデータ** (§10): 本家 Clojure メタデータ体系の採用、`:added` による
  本家参照バージョン追跡、名前空間対応の保証
- **セキュリティ設計** (§14): メモリ安全性、サンドボックスモデル、入力検証
- **C/Zig ABI と FFI** (§15): 3階層の拡張機構 (Wasm / Zig プラグイン / C ABI)
- **リポジトリ管理** (§16): GitHub Organization、CI/CD、リリース戦略
- **ディレクトリ構造** (§17): 参考プロジェクト分析に基づく構成
- **ドキュメント戦略** (§18): 4層構造、mdBook、ADR
- **移行ロードマップ** (§19): Phase 0〜11 の具体的なステップ

---

## 14. セキュリティ設計

ClojureWasm は Zig で書かれたネイティブバイナリであり、
Clojure (JVM) の SecurityManager やサンドボックスとは異なるアプローチが必要。

### 14.1 メモリ安全性

Zig は ReleaseSafe モードで境界チェック・アラインメント検証を有効にできる。

**方針**: リリースビルドも `ReleaseSafe` をデフォルトとする。

- 配列境界外アクセス → panic (silent corruption より安全)
- `@intToPtr` / `@ptrCast` の使用は最小限に制限し、コードレビューで監視
- Beta で発見した unsafe パターン (fixup 漏れ等) は comptime 検証で防止 (§9.1)
- `ReleaseFast` は明示的なベンチマーク用途でのみ提供

### 14.2 サンドボックスモデル

路線ごとに異なるサンドボックス戦略を採用する。

**native 路線**: allowlist 方式

- ファイルシステムアクセスは明示的に許可されたパスのみ
- ネットワークアクセスはデフォルト無効、`--allow-net` フラグで有効化
- 環境変数アクセスはフィルタリング可能
- Babashka の `--allow-*` フラグ体系を参考にする

```
clj-wasm --allow-read=/data --allow-write=/tmp script.clj
clj-wasm --allow-net=api.example.com script.clj
```

**wasm_rt 路線**: WASI capabilities

- WASI の capability-based security をそのまま活用
- ランタイム (Wasmtime 等) の `--dir`, `--env` フラグで制御
- 追加のサンドボックスレイヤーは不要 (WASI が担保)

### 14.3 Reader の入力検証

Beta では Reader に対する入力制限がなく、
悪意ある入力 (深いネスト、巨大リテラル) で OOM やスタックオーバーフローが起きうる。

正式版での対策:

| 制限                   | デフォルト値 | 設定方法              |
|------------------------|--------------|-----------------------|
| ネスト深さ上限         | 1024         | `--max-depth`         |
| 文字列リテラルサイズ   | 1MB          | `--max-string-size`   |
| コレクションリテラル数 | 100,000      | `--max-literal-count` |
| ソースファイルサイズ   | 10MB         | `--max-file-size`     |

- 制限超過時は明確なエラーメッセージを返す (panic ではない)
- REPL モードではより緩い制限をデフォルトにする

### 14.4 依存管理

**原則**: third-party ライブラリはベンダリング (ソースコピー) で管理する。

- `third-party/` ディレクトリにソースを配置 (§17 参照)
- バージョンは `third-party/versions.txt` で明示的に記録
- Zig の `build.zig.zon` による依存管理を活用
- submodule は使わない (ビルドの再現性を確保)

依存は最小限に:

| 依存               | 用途                     | 方針                       |
|--------------------|--------------------------|----------------------------|
| zware              | Wasm 実行エンジン        | ベンダリング               |
| (Wasmtime)         | 将来の Wasm バックエンド | 動的リンク or ベンダリング |
| Zig 標準ライブラリ | 基盤                     | Zig バージョン固定         |

### 14.5 SECURITY.md ポリシー

OSS 公開時に `SECURITY.md` を配置する:

- 脆弱性報告先 (メールアドレス、GitHub Security Advisories)
- 対応 SLA の目安 (Critical: 48h 確認、High: 1 week)
- サポート対象バージョン (最新 minor のみ)
- セキュリティ関連の設計判断は ADR (§18) として記録

---

## 15. C/Zig ABI と FFI 戦略

ClojureWasm の拡張性を3階層で設計する。
Beta は組み込み関数のみだったが、正式版ではユーザーが独自の拡張を追加できる機構を提供する。

### 15.1 拡張機構の3階層

| 階層            | 対象路線         | 安全性 | 配布性 | 用途                      |
|-----------------|------------------|--------|--------|---------------------------|
| Wasm モジュール | native + wasm_rt | 高     | 高     | ポータブルなプラグイン    |
| Zig プラグイン  | native のみ      | 中     | 低     | 高性能ネイティブ拡張      |
| C ABI           | native のみ      | 低     | 中     | 既存 C ライブラリとの統合 |

### 15.2 Wasm モジュール拡張

§1 の Wasm 活用の発展形。ユーザーが `.wasm` ファイルを読み込んで関数を呼べる。

```clojure
;; Wasm モジュールのロードと呼び出し (構想)
(def wasm-mod (wasm/load "image_resize.wasm"))
(def resize (wasm/fn wasm-mod "resize" [:i32 :i32 :i32] :i32))
(resize buf width height)
```

- 両路線で動作する唯一の拡張方式
- WASI 対応モジュールも利用可能
- 型安全な境界は §1 Phase 1-3 で段階的に整備

### 15.3 Zig プラグイン機構 (native 路線向け)

Zig が処理系ホスト言語であることを最大限活かし、
ユーザーが **Zig で書いた高性能ライブラリを自然に ClojureWasm に統合** できる仕組みを提供する。

#### 15.3.1 ビルド時統合 (推奨方式)

Zig の `build.zig` 依存グラフを使い、ユーザーの Zig コードを
ClojureWasm バイナリに**直接コンパイル**する。
動的リンク不要、Value 型共有、GC 追跡も comptime で統合される。

```zig
// ユーザーの build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const cljw = b.dependency("clojurewasm", .{});

    const exe = b.addExecutable(.{
        .name = "my-clojure-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "clojurewasm", .module = cljw.module("api") },
            },
        }),
    });
    b.installArtifact(exe);
}
```

```zig
// ユーザーの拡張 (src/my_extensions.zig)
const cljw = @import("clojurewasm");
const Value = cljw.Value;
const BuiltinDef = cljw.BuiltinDef;

/// 高速画像リサイズ — SIMD 活用
fn fastResize(allocator: std.mem.Allocator, args: []const Value) !Value {
    const buf = args[0].asBytes() orelse return error.TypeError;
    const width = args[1].asInt() orelse return error.TypeError;
    // ... SIMD を使った高速処理 ...
    return Value.fromBytes(allocator, result);
}

/// ClojureWasm に登録する関数テーブル
pub const builtins = [_]BuiltinDef{
    .{
        .name = "fast-resize",
        .func = fastResize,
        .doc = "High-performance image resize using SIMD",
        .arglists = "([buf width height])",
    },
};
```

```zig
// ユーザーの main.zig
const cljw = @import("clojurewasm");
const my_ext = @import("my_extensions.zig");

pub fn main() !void {
    var vm = try cljw.init(allocator, .{
        .extra_builtins = &.{
            .{ .ns = "my.image", .defs = &my_ext.builtins },
        },
    });
    defer vm.deinit();

    // Clojure コードからシームレスに呼べる
    // (require '[my.image :as img])
    // (img/fast-resize buf 1920 1080)
    try vm.evalFile("script.clj");
}
```

**ビルド時統合の利点**:

- **ゼロコスト統合**: Value 型が共有されるため、C FFI のような変換オーバーヘッドなし
- **comptime 検証**: 型不一致・名前重複をコンパイル時に検出 (registry.zig 方式)
- **GC 統合**: ユーザー関数が作成した Value も自動的に GC 追跡対象になる
- **SIMD/最適化**: Zig の `@Vector` や `@prefetch` がそのまま使える
- **単一バイナリ**: 動的リンクなし。配布が容易
- **IDE サポート**: ZLS の補完・型検査がユーザーの拡張コードにもそのまま効く

#### 15.3.2 動的ライブラリ方式 (上級者向け)

ビルド時統合ができない場合 (プラグインの後配布等) のために、
動的ライブラリ (`.so` / `.dylib`) 方式も提供する。

```zig
// プラグイン側 (my_plugin.zig) — 動的ライブラリとしてビルド
const Plugin = @import("clojurewasm").Plugin;

export fn cljw_plugin_init(api: *Plugin.Api) void {
    api.registerNs("my.plugin", &.{
        .{ .name = "process", .func = processFn, .doc = "..." },
    });
}

fn processFn(args: []const Plugin.Value) Plugin.Value {
    // Plugin.Value は C ABI 互換のラッパー (Value とは別型)
    // ...
}
```

```clojure
;; Clojure 側からのロード
(require '[clojurewasm.plugin :as plugin])
(plugin/load "path/to/my_plugin.so")
(my.plugin/process data)
```

- `Plugin.Value` は C ABI 互換のラッパー型 (内部 Value との変換コストあり)
- GC ルート登録 API を明示的に呼ぶ必要がある
- native 路線でのみ利用可能 (wasm_rt では Wasm モジュール拡張を使う)
- ビルド時統合と比べて安全性・性能で劣るが、柔軟性が高い

### 15.4 C ABI 統合

Zig の `@cImport` を活用し、C ライブラリを直接利用する。

想定される利用例:

| ライブラリ | 用途                 | 統合方法                  |
|------------|----------------------|---------------------------|
| SQLite     | データベースアクセス | `@cImport("sqlite3.h")`   |
| libcurl    | HTTP クライアント    | `@cImport("curl/curl.h")` |
| libpcre2   | 高速正規表現         | `@cImport("pcre2.h")`     |

- Beta の Zig フルスクラッチ regex は正しい判断だったが、
  性能が不足する場合は libpcre2 をオプショナルバックエンドとして提供可能
- C ABI 層は unsafe であり、メモリ管理の責任はプラグイン側

### 15.5 ClojureWasm をライブラリとして提供 (埋め込みモード)

ClojureWasm を **Zig/C ライブラリとしてビルド** し、
他のアプリケーションに Clojure ランタイムを埋め込むユースケース。
Lua, mruby, Wren 等の組み込み言語と同じパターン。

#### 15.5.1 Zig ライブラリ API (構想)

```zig
// ホストアプリケーション側 (Zig)
const cljw = @import("clojurewasm");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    // VM インスタンスを作成 (複数インスタンス共存可能)
    var vm = try cljw.VM.init(gpa.allocator(), .{});
    defer vm.deinit();

    // Clojure コードを評価
    const result = try vm.run("(+ 1 2 3)");
    std.debug.print("result: {}\n", .{result.asInt().?});

    // Zig から Clojure 関数を呼ぶ
    const map_fn = try vm.resolve("clojure.core", "map");
    const inc_fn = try vm.run("(fn [x] (+ x 1))");
    const data = try vm.run("[1 2 3]");
    const mapped = try vm.call(map_fn, &.{ inc_fn, data });

    // 結果を Zig の値に変換
    var iter = mapped.seqIterator();
    while (iter.next()) |v| {
        std.debug.print("{} ", .{v.asInt().?});
    }
}
```

#### 15.5.2 C ABI ライブラリ (構想)

Zig の `export fn` で C 互換 API を公開する。

```c
/* ホストアプリケーション側 (C) */
#include "clojurewasm.h"

int main(void) {
    cljw_vm_t *vm = cljw_vm_init(NULL); /* NULL = デフォルトアロケータ */

    cljw_value_t result = cljw_run(vm, "(reduce + (range 100))");
    printf("result: %ld\n", cljw_as_int(result));

    /* 値のライフタイムは GC が管理。
       ホスト側が保持したい値は pin する */
    cljw_pin(vm, result);
    /* ... 後で使う ... */
    cljw_unpin(vm, result);

    cljw_vm_destroy(vm);
    return 0;
}
```

```bash
# ビルド (Zig がクロスコンパイラとして機能)
zig build -Dtarget=x86_64-linux -Dlib-mode=true
# → libclojurewasm.a (静的) + libclojurewasm.so (動的) + clojurewasm.h
```

#### 15.5.3 設計上の課題と方針

| 課題                          | 方針                                                   |
|-------------------------------|--------------------------------------------------------|
| **GC 境界**                   | ホスト側が保持する Value を pin/unpin API で明示管理。  |
|                               | pin された値は GC ルートセットに追加される              |
| **複数 VM インスタンス**      | Beta のグローバル状態 (threadlocal current_env 等) を   |
|                               | VM 構造体にカプセル化。インスタンスごとに独立した       |
|                               | Env, GC ヒープ, バインディングスタックを持つ            |
| **メモリオーナーシップ**      | Zig API: ホスト側の Allocator を注入可能               |
|                               | C API: malloc/free ベースのデフォルト + カスタムフック  |
| **スレッド安全性**            | VM インスタンスはシングルスレッド前提。                 |
|                               | 複数スレッドからは複数 VM インスタンスを使う            |
| **core.clj AOT バイトコード** | ライブラリモードでも `@embedFile` で内蔵。              |
|                               | ホスト側のビルドステップは不要                          |
| **バイナリサイズ**            | 静的リンクで ~2-5MB (Zig の LTO でデッドコード除去)    |

#### 15.5.4 段階的実現

**前提条件**: §15.5 は §15.3 (ビルド時統合) の延長にある。
ビルド時統合で「ユーザーが ClojureWasm API を import して使う」パターンを
安定させることが、ライブラリ API の設計基盤になる。

- **Phase A**: ビルド時統合の安定化 (§15.3.1) — API surface の確定
- **Phase B**: Zig ライブラリモード — `cljw.VM.init()` でインスタンス化可能に。
  グローバル状態の除去 (threadlocal → VM フィールド) が必要
- **Phase C**: C ヘッダ自動生成 — Zig の `@export` + `zig build -Demit-h` で
  `clojurewasm.h` を自動出力
- **Phase D**: パッケージマネージャ対応 — vcpkg, Conan, Nix 等で配布

**率直な見通し**: Phase B の「グローバル状態の除去」が最大の設計変更。
Beta の threadlocal 変数 (defs.zig に 8 個) を全て VM 構造体のフィールドに
移動する必要がある。正式版の初期設計から VM をインスタンスとして
設計しておけば、後からの対応コストは大幅に下がる。

### 15.6 拡張方式の比較

| 基準             | Wasm モジュール        | Zig ビルド時統合         | Zig 動的プラグイン       | C ABI               |
|------------------|------------------------|--------------------------|--------------------------|----------------------|
| ポータビリティ   | 高 (どこでも動く)      | 中 (Zig ツールチェーン)  | 低 (OS/Arch 依存)        | 低 (OS/Arch 依存)    |
| 性能             | 中 (境界コスト)        | 最高 (ゼロコスト)        | 高 (直接呼び出し)        | 高 (直接呼び出し)    |
| 安全性           | 高 (サンドボックス)    | 高 (comptime 検証)       | 中 (メモリ共有)          | 低 (メモリ共有)      |
| GC 統合          | 不要 (分離メモリ)      | 自動 (型共有)            | 手動 (ルート登録)        | 手動 (pin/unpin)     |
| エコシステム     | 拡大中                 | Zig パッケージ           | 限定的                   | 成熟 (C ライブラリ)  |
| 推奨ユースケース | ユーザー配布プラグイン | 高性能カスタムビルド     | プラグインの後配布       | 既存 C 資産の活用    |

### 15.7 Beta からの段階的拡張

- **Phase 1** (正式版初期): Wasm モジュールロードの改善 (§1 Phase 1-3)
- **Phase 2** (v0.3 頃): Zig ビルド時統合 API の安定化 (§15.3.1)
- **Phase 3** (v0.5 頃): C ABI 層の公開、主要ライブラリバインディング
- **Phase 4** (v0.7 頃): 埋め込みモード (§15.5) — グローバル状態除去完了後
- **Phase 5** (v1.0 頃): 動的プラグイン (§15.3.2) — 安定 API 確定後

---

## 16. リポジトリ・プロジェクト管理

### 16.1 GitHub Organization 構成

```
clojurewasm/
├── clojurewasm          # メインリポジトリ (処理系 + docs + examples)
├── homebrew-tap         # macOS Homebrew Formula
└── (将来、必要になったら)
    ├── aur-clojurewasm  # Arch Linux AUR
    ├── nix-clojurewasm  # Nix flake overlay
    └── scoop-clojurewasm # Windows Scoop bucket
```

- **メインリポジトリに集約**: src, book/ (mdBook), examples/, bench/ を1リポに置く
  - ドキュメントとコードを同じコミットで更新できる
  - examples/ をテスト対象にできる (CI で壊れを検出)
  - `zig build test && mdbook build` が1パイプラインで完結
- **配布チャネルのみ別リポ**: Homebrew は `homebrew-xxx` 命名規則で別リポ必須。
  他の OS 向けパッケージマネージャも同様 (各ツールの慣習に従う)
- 配布チャネル以外の分離は、コントリビュータが増えて必要性が生じてから検討

### 16.2 ブランチ戦略: Trunk-based Development

**Git Flow を採用しない理由**:

- ClojureWasm は単一バイナリ配布で、複数バージョンの並行メンテナンスが不要
- リリースブランチの管理コストが個人〜小規模チームに見合わない
- feature branch のマージ衝突が増える

**Trunk-based の運用**:

- `main` ブランチが常にリリース可能な状態
- 機能開発は短命な feature branch (数日以内にマージ)
- リリースは `main` からタグを打つだけ
- 破壊的変更は feature flag ではなく SemVer で管理

### 16.3 PR ガイドライン

CONTRIBUTING.md の骨子:

- PR は小さく保つ (目安: 300 行以下)
- テストを含める (新機能は必須、バグ修正は推奨)
- `zig build test` が通ること
- `--compare` モードで回帰がないこと
- コミットメッセージは Conventional Commits 形式

```
feat: add persistent vector implementation
fix: resolve GC crash on deeply nested structures
docs: update FFI guide with C ABI examples
perf: optimize fused reduce for large sequences
test: import SCI core_test assertions
```

### 16.4 CI/CD パイプライン

GitHub Actions で以下を自動化:

```yaml
# .github/workflows/ci.yml (構想)
jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
        target: [native, wasm_rt]
    steps:
      - uses: actions/setup-zig@v1
      - run: zig build test
      - run: zig build test -Dbackend=${{ matrix.target }}

  compat:
    steps:
      - run: bash test/imported/run_all.sh
      - run: diff compat_status.yaml expected_status.yaml

  bench:
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    steps:
      - run: bash bench/run_bench.sh --quick --record
      - uses: actions/upload-artifact@v4

  release:
    if: startsWith(github.ref, 'refs/tags/v')
    steps:
      - run: zig build -Doptimize=ReleaseSafe
      - run: zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSafe
      - uses: softprops/action-gh-release@v1
```

### 16.5 タグ・リリース戦略

SemVer に従い、以下の段階でリリースする:

| フェーズ       | バージョン     | 意味                             |
|----------------|----------------|----------------------------------|
| 開発初期       | v0.1.0-alpha.N | API 不安定、破壊的変更あり       |
| 機能一通り実装 | v0.1.0-beta.N  | API 安定化中、フィードバック募集 |
| リリース候補   | v0.1.0-rc.N    | バグ修正のみ                     |
| 正式リリース   | v1.0.0         | API 安定、後方互換性を保証       |

- CHANGELOG.md は Keep a Changelog 形式 (§18)
- バイナリは GitHub Releases で配布 (Linux x86_64, macOS arm64/x86_64, wasm32)
- Homebrew は `homebrew-tap` リポジトリで管理

### 16.6 Issue ラベル体系

| ラベル             | 色   | 意味                        |
|--------------------|------|-----------------------------|
| `bug`              | 赤   | バグ報告                    |
| `enhancement`      | 青   | 機能追加リクエスト          |
| `compatibility`    | 紫   | 本家 Clojure との互換性問題 |
| `performance`      | 緑   | パフォーマンス改善          |
| `wasm_rt`          | 黄   | wasm_rt 路線固有            |
| `native`           | 橙   | native 路線固有             |
| `good-first-issue` | 水色 | 初参加者向け                |
| `help-wanted`      | 水色 | 協力者募集                  |
| `breaking`         | 赤   | 破壊的変更を含む            |

CODE_OF_CONDUCT.md は Contributor Covenant v2.1 を採用。

---

## 17. 正式版ディレクトリ構造

### 17.1 参考プロジェクトからの採用判断

| 参考元        | 採用するもの                | 不採用 (理由)                             |
|---------------|-----------------------------|-------------------------------------------|
| jank          | `third-party/` ベンダリング | `src/` + `include/` 分離 (Zig では不要)   |
| Babashka      | `doc/adr/` (ADR)            | feature-* サブモジュール (モノリポで十分) |
| SCI           | `api/` と `impl/` の分離    | —                                         |
| ClojureScript | フェーズ別モジュール分離    | —                                         |

### 17.2 ディレクトリツリー

```
clojurewasm/
├── src/
│   ├── api/                  # 公開 API (embed 用インターフェース)
│   │   ├── eval.zig          # evaluate(), load-file()
│   │   ├── repl.zig          # REPL エントリポイント
│   │   └── plugin.zig        # プラグイン API (§15)
│   │
│   ├── common/               # 両路線で共有
│   │   ├── reader/           # Tokenizer, Reader, Form
│   │   ├── analyzer/         # Analyzer, Node, macro expansion
│   │   ├── bytecode/         # OpCode 定義、定数テーブル
│   │   ├── value/            # Value 型定義
│   │   └── builtin/          # 組み込み関数 (意味論共通部)
│   │
│   ├── native/               # 超高速・単一バイナリ路線
│   │   ├── vm/               # VM 実行エンジン (NaN boxing)
│   │   ├── gc/               # 自前 GC
│   │   ├── optimizer/        # 定数畳み込み、fused reduce
│   │   └── main.zig
│   │
│   └── wasm_rt/              # Wasm ランタイムフリーライド路線
│       ├── vm/               # Wasm target VM
│       ├── gc_bridge/        # WasmGC 連携
│       ├── wasm_backend/     # WasmBackend trait 実装
│       └── main.zig
│
├── test/
│   ├── unit/                 # ユニットテスト (モジュール単位)
│   ├── e2e/                  # エンドツーエンドテスト
│   └── imported/             # upstream テスト (§10)
│       ├── sci/
│       ├── cljs/
│       └── clojure/
│
├── bench/                    # ベンチマークスイート
├── third-party/              # ベンダリングされた依存 (§14.4)
│   └── versions.txt
│
├── core/                     # Clojure ソース (AOT コンパイル対象、§9.6)
│   └── core.clj
│
├── book/                     # mdBook ソース (§18)
│   └── src/
│
├── doc/
│   └── adr/                  # Architecture Decision Records (§18)
│       ├── 0001-nan-boxing.md
│       ├── 0002-gc-strategy.md
│       └── template.md
│
├── examples/                 # サンプルコード
├── status/                   # 実装状況・ベンチマーク (Beta から継承)
│
├── build.zig                 # comptime で native / wasm_rt を選択
├── build.zig.zon             # Zig 依存管理
├── LICENSE                   # EPL-1.0
├── README.md
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
├── SECURITY.md               # §14.5
└── CHANGELOG.md              # §18
```

### 17.3 Beta からの変更点

| 項目         | Beta                         | 正式版                                    |
|--------------|------------------------------|-------------------------------------------|
| ソース構成   | `src/` フラット              | `src/api,common,native,wasm_rt/`          |
| Clojure ソース | なし (全て Zig)            | `core/core.clj` (AOT コンパイル、§9.6)    |
| テスト構成   | `test/` フラット             | `test/unit,e2e,imported/`                 |
| 依存管理     | Git submodule (zware)        | `third-party/` ベンダリング               |
| ドキュメント | `docs/` (Markdown)           | `book/` (mdBook) + `doc/adr/`             |
| 設計記録     | `plan/` (非公開ノート)       | `doc/adr/` (公開 ADR)                     |
| 実装状況追跡 | `status/vars.yaml`           | `status/vars.yaml` + `compat_status.yaml` |
| ビルド設定   | `build.zig` (単一ターゲット) | `build.zig` (comptime 切替)               |

### 17.4 §8 との関係

§8 のアーキテクチャ方針 (単一リポジトリ・comptime 切替) を具体化したのが本構造。
`src/common/` の共有境界は §8 の共有可能性テーブルに従う。

---

## 18. ドキュメント戦略

### 18.1 4層構造

| 層                 | 対象読者           | 内容                            | 形式          |
|--------------------|--------------------|---------------------------------|---------------|
| Getting Started    | 初めてのユーザー   | インストール、Hello World、REPL | mdBook Ch.1   |
| Language Reference | Clojure 経験者     | 互換性表、差異、独自機能        | mdBook Ch.2-5 |
| Developer Guide    | コントリビューター | ビルド方法、テスト、PR ガイド   | mdBook Ch.6-8 |
| Internals          | コア開発者         | VM 設計、GC、コンパイラ         | mdBook Ch.9+  |

### 18.2 mdBook 採用

jank が mdBook + GitHub Pages でドキュメントを公開しており、
Rust/Zig エコシステムでは事実上の標準。

メリット:
- Markdown ベースで記述コスト低
- `book.toml` + GitHub Actions で自動デプロイ
- 検索機能内蔵
- コードハイライト対応 (Clojure, Zig)

デプロイ:
- `main` push → GitHub Actions → GitHub Pages (`book.clojurewasm.org` 等)
- PR 時はプレビュービルドで確認

### 18.3 ADR (Architecture Decision Records)

Babashka が `doc/dev/` にメモを残す方式を採用しているが、
正式版ではより構造化された ADR 形式で記録する。

ADR テンプレート:

```markdown
# ADR-NNNN: タイトル

## Status
Accepted / Superseded by ADR-MMMM / Deprecated

## Context
なぜこの決定が必要か

## Decision
何を決定したか

## Consequences
この決定の結果として何が起きるか

## References
関連する ADR、Issue、外部リソース
```

初期 ADR 候補 (Beta の知見から):

| ADR  | タイトル                           | 根拠            |
|------|------------------------------------|-----------------|
| 0001 | NaN Boxing による値表現            | §3, §5 の知見   |
| 0002 | セミスペース GC + Arena 分離       | §5, §9.4 の知見 |
| 0003 | デュアルバックエンド (`--compare`) | §9.2 の知見     |
| 0004 | Fused Reduce パターン              | §9.3 の知見     |
| 0005 | Trunk-based Development            | §16.2 の判断    |
| 0006 | EPL-1.0 ライセンス選択             | §12 の判断      |
| 0007 | core.clj ビルド時 AOT コンパイル   | §9.6 の判断     |
| 0008 | VarKind 依存層分類                 | §10 の設計      |
| 0009 | 本家メタデータ採用方針             | §10 の設計      |
| 0010 | 名前空間対応保証                   | §10 の設計      |
| 0011 | Zig ビルド時統合 vs 動的プラグイン | §15.3 の判断    |
| 0012 | 埋め込みモード設計                 | §15.5 の構想    |

### 18.4 互換性ステータス自動生成

§10 の `compat_status.yaml` から以下を自動生成する:

- mdBook 内の互換性テーブル (関数ごとの pass/fail/skip 一覧)
- README.md のバッジ (`Compatibility: 87% (412/474 pass)`)
- GitHub Pages のダッシュボード

生成は CI/CD パイプライン (§16.4) で `main` push 時に実行。

### 18.5 CHANGELOG.md

Keep a Changelog 形式 (https://keepachangelog.com/) を採用:

```markdown
# Changelog

## [Unreleased]

### Added
- Persistent vector implementation

### Fixed
- GC crash on deeply nested let bindings

## [0.1.0-alpha.1] - 2025-XX-XX

### Added
- Initial release with core.clj 500+ functions
- Native backend with NaN boxing
```

- リリースごとにセクションを追加
- `[Unreleased]` セクションに開発中の変更を蓄積
- タグ打ち時に日付を確定

### 18.6 README.md 構成方針

README.md は簡潔に保ち、詳細は mdBook に誘導する:

1. プロジェクト概要 (3-5 行)
2. クイックスタート (インストール + 実行例)
3. 互換性バッジ
4. ベンチマーク結果 (簡易テーブル)
5. ドキュメントリンク
6. コントリビューション (CONTRIBUTING.md へのリンク)
7. ライセンス

### 18.7 Beta ドキュメントの移行

| Beta                                | 正式版                                | 扱い              |
|-------------------------------------|---------------------------------------|-------------------|
| `docs/reference/architecture.md`    | `book/src/internals/architecture.md`  | 英訳して移行      |
| `docs/reference/vm_design.md`       | ADR-0007 + `book/src/internals/vm.md` | 分割して移行      |
| `docs/reference/gc_design.md`       | ADR-0002 + `book/src/internals/gc.md` | 分割して移行      |
| `docs/reference/zig_guide.md`       | `book/src/dev/zig-guide.md`           | 英訳して移行      |
| `docs/reference/lessons_learned.md` | 各 ADR に分散                         | 個別 ADR に展開   |
| `plan/memo.md`                      | (移行しない)                          | Beta の開発記録   |
| `plan/roadmap.md`                   | (移行しない)                          | Beta の開発記録   |
| `docs/future.md`                    | ADR + book の設計章                   | 決定事項を ADR 化 |

---

## 19. 移行ロードマップ

> §11 の「進め方」を具体的なフェーズに展開したもの。

### Phase 0: 準備

- GitHub Organization (`clojurewasm`) の作成
- リポジトリ初期化 (§17 のディレクトリ構造)
- CI/CD パイプライン構築 (§16.4)
- `build.zig` に comptime 切替の骨格を実装
- LICENSE, CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md 配置
- ADR テンプレートと初期 ADR (§18.3) の記述

### Phase 1: Reader + Analyzer

- Beta の Reader を英語化・リファクタリングして移植
- 入力検証 (§14.3) を最初から組み込む
- Analyzer を移植。スペシャルフォームは comptime テーブル化 (§10)
- Beta のハードコードマクロ 54 個のうち、special form のみ Analyzer に残す
- `test/unit/reader/`, `test/unit/analyzer/` にテスト整備
- §10 Tier 1 の SCI テスト取り込み開始

### Phase 2: Native 路線 VM

- NaN boxing による値表現の実装 (ADR-0001)
- 新 GC の設計・実装 (ADR-0002、§5 の教訓を反映)
  - safe point の設計を最初から組む (§5 教訓2)
  - fixup の comptime 検証 (§5 教訓1)
- コンパイラ-VM 間の契約を型で表現 (§9.1)
- `--compare` モードの参照実装 (§9.2)
- 基本的な式評価が動く状態

### Phase 3: Builtin 関数 + core.clj AOT

- vm_intrinsic + runtime_fn を Zig builtin として実装 (§10 VarKind 参照)
- BuiltinDef にメタデータ (doc, arglists, added) を付与 (§10 メタデータ方針)
- core.clj を作成: マクロ 43+個 + 高レベル関数を Clojure で定義 (§9.6)
- ビルド時 AOT パイプライン構築: core.clj → bytecode → `@embedFile`
- `status/vars.yaml` で `defined_in`, `ns`, `added` を追跡
- 名前空間対応検証: 全 Var が本家と同じ NS に配置されていることを CI で確認
- テストオラクル (§10 L1) で基本動作を検証
- 目標: Beta で実装済みの 545 関数のうち主要 200 関数をカバー

### Phase 4: 最適化

- 定数畳み込み
- Fused Reduce パターン (§9.3) の VM 組み込み
- インラインキャッシング (頻出パスの高速化)
- ベンチマークスイートで効果測定 (§CLAUDE.md のベンチマーク手順)

### Phase 5: 標準ライブラリ

- `clojure.string`, `clojure.set`, `clojure.walk` 等の名前空間を実装
- 残りの clojure.core 関数を網羅 (core.clj への移行を優先)
- Beta の Zig builtin を core.clj に段階的に移行 (`defined_in` で追跡)
- §10 Tier 1-2 のテスト取り込みを加速
- `compat_status.yaml` の pass 率を追跡

### Phase 6: Wasm 連携強化

- §1 Phase 1-3 (型安全境界 → 構造データ → エコシステム) を実装
- Wasm モジュールのロード・呼び出し API (§15.2)
- native 路線での Wasm 実行エンジン統合 (§6)

### Phase 7: nREPL + ツール統合

- nREPL サーバー実装 (エディタ連携)
- REPL の改善 (補完、ヒストリ、マルチライン)
- `clj-wasm` CLI の成熟化

### Phase 8: Alpha リリース (v0.1.0-alpha)

- 全テストが pass する状態
- mdBook ドキュメントの初版公開 (§18)
- GitHub Releases でバイナリ配布
- コミュニティへのアナウンス
- フィードバック受付開始

### Phase 9: フィードバック反映

- Alpha ユーザーからのバグ報告・互換性問題への対応
- §10 Tier 3 のテスト取り込み (AI 補助 + 人間レビュー)
- パフォーマンスチューニング
- API の安定化

### Phase 10: wasm_rt 実験

- `zig build -Dtarget=wasm32-wasi` で処理系をビルド
- WasmGC 連携の実験 (§5)
- wasm_rt 固有のテスト整備
- native 路線が安定してから着手 (§7 の「一本化しない」方針)

### Phase 11: 正式版 (v1.0.0)

- API の後方互換性保証
- 互換性テスト pass 率の目標達成 (L0-L2 で 90%+)
- mdBook ドキュメント完成版
- Homebrew Formula, GitHub Actions セットアップ
- v1.0.0 タグ + GitHub Release

### リスク管理

| リスク                             | 影響 | 緩和策                                    |
|------------------------------------|------|-------------------------------------------|
| NaN boxing の実装難度が想定以上    | 高   | Beta の tagged union にフォールバック可能 |
| GC の safe point 設計が破綻        | 高   | 式境界 GC (Beta 方式) に縮退可能          |
| upstream テスト変換の工数超過      | 中   | Tier 1 (SCI) のみで初期リリース           |
| Zig のバージョンアップで破壊的変更 | 中   | `flake.lock` でバージョン固定             |
| wasm_rt 路線の WasmGC 連携が困難   | 中   | native 路線を優先、wasm_rt は実験扱い     |
| コミュニティからのネーミング異議   | 低   | リネーム対応可能な構造にしておく (§12)    |
| core.clj AOT のビルド時間増        | 中   | core.bc キャッシュ、インクリメンタルビルド |
| core.clj ブートストラップ順序の複雑さ | 中 | defmacro を special form に残すことで回避 |
| 個人開発のバス因子                 | 高   | ドキュメント・ADR・テストで知識を外部化   |

---

## 関連ドキュメント

- [agent_guide_ja.md](./agent_guide_ja.md) — コーディングエージェント開発ガイド
  (Claude Code の設定、TDD スキル、フェーズ別指示、Nix ツールチェーン)
