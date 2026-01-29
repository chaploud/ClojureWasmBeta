# 型設計: 3フェーズアーキテクチャ

Clojure処理系における値の3段階表現。sci/babashka/本家Clojureの設計を参考。

## 概要

```
┌─────────────────────────────────────────────────────┐
│ 1. Reader Phase: 構文表現                           │
│    src/reader/form.zig - Form型                     │
│    Symbol, List, Vector, Keyword, etc.              │
│    + メタデータ(line/column/file)                   │
└─────────────────────────────────────────────────────┘
                    ↓ analyze (マクロ展開含む)
┌─────────────────────────────────────────────────────┐
│ 2. Analyzer Phase: 実行可能ノード                   │
│    src/analyzer/node.zig - Node型                   │
│    fn(ctx, bindings) -> Value                       │
│    ConstantNode, VarNode, CallNode, IfNode, etc.    │
│    + スタック情報（ソース位置）                     │
└─────────────────────────────────────────────────────┘
                    ↓ 評価
┌─────────────────────────────────────────────────────┐
│ 3. Runtime Phase: 実際の値                          │
│    src/runtime/value.zig - Value型                  │
│    Var, Fn, 数値, 文字列, コレクション等            │
│    + thread-local dynamic bindings                  │
└─────────────────────────────────────────────────────┘
```

## ディレクトリ構成

```
src/
├── base/             # 共通基盤
│   └── error.zig     # エラー型
├── reader/           # Phase 1: Reader
│   ├── tokenizer.zig # トークナイザー
│   ├── reader.zig    # S式構築
│   └── form.zig      # Form型
├── analyzer/         # Phase 2: Analyzer
│   ├── analyze.zig   # 解析・マクロ展開
│   └── node.zig      # Node型
├── compiler/         # Node → Bytecode
│   ├── bytecode.zig  # バイトコード定義
│   └── emit.zig      # コード生成
├── vm/               # Bytecode 実行
│   └── vm.zig        # VM メインループ
├── runtime/          # Phase 3: Runtime
│   ├── value.zig     # Value型 (facade + 3 サブモジュール)
│   ├── var.zig       # Var
│   ├── namespace.zig # Namespace
│   ├── env.zig       # Env
│   ├── context.zig   # Context
│   ├── evaluator.zig # TreeWalk 評価器
│   ├── engine.zig    # Backend 切り替え
│   └── allocators.zig # 寿命別アロケータ
├── lib/              # 標準ライブラリ
│   ├── core.zig      # clojure.core facade (re-export)
│   └── core/         # ドメイン別サブモジュール (19ファイル)
├── gc/               # GC (セミスペース Arena)
├── wasm/             # Wasm 連携 (zware)
├── regex/            # 正規表現 (フルスクラッチ)
├── repl/             # REPL サポート
├── nrepl/            # nREPL サーバー
└── clj/              # Clojure ソースライブラリ (.clj)
```

## ファイル構成

| ファイル                    | 型        | フェーズ | 状態   |
|-----------------------------|-----------|----------|--------|
| `src/reader/form.zig`       | Form      | Reader   | 実装済 |
| `src/reader/reader.zig`     | Reader    | Reader   | 実装済 |
| `src/analyzer/node.zig`     | Node      | Analyzer | 実装済 |
| `src/analyzer/analyze.zig`  | Analyzer  | Analyzer | 実装済 |
| `src/runtime/value.zig`     | Value     | Runtime  | 実装済 |
| `src/runtime/var.zig`       | Var       | Runtime  | 実装済 |
| `src/runtime/namespace.zig` | Namespace | Runtime  | 実装済 |
| `src/runtime/env.zig`       | Env       | Runtime  | 実装済 |
| `src/runtime/context.zig`   | Context   | 評価器   | 実装済 |

## Form (Reader出力)

```zig
// src/reader/form.zig
pub const Form = union(enum) {
    // リテラル
    nil,
    bool_lit: bool,
    int_lit: i64,
    float_lit: f64,
    ratio_lit: Ratio,
    string_lit: []const u8,
    char_lit: u21,
    regex_lit: []const u8,

    // 識別子
    symbol: Symbol,
    keyword: Keyword,

    // コレクション（メタデータ付き）
    list: *FormList,
    vector: *FormVector,
    map: *FormMap,
    set: *FormSet,

    // Reader専用構文
    reader_cond: *ReaderConditional,  // #?
    tagged_lit: *TaggedLiteral,        // #inst, #uuid, etc.
};

pub const FormList = struct {
    items: []Form,
    meta: ?Metadata,
};
```

**特徴:**
- 構文的表現（評価前）
- メタデータでソース位置を保持
- マクロ展開の入力

## Node (Analyzer出力)

```zig
// src/analyzer/node.zig
pub const Node = union(enum) {
    // リテラル（即値）
    constant: Value,

    // 参照
    var_ref: VarRefNode,      // Var参照
    local_ref: LocalRefNode,  // ローカル変数参照

    // 制御構造
    if_node: *IfNode,
    do_node: *DoNode,
    let_node: *LetNode,
    loop_node: *LoopNode,
    recur_node: *RecurNode,

    // 関数
    fn_node: *FnNode,
    call_node: *CallNode,

    // 定義
    def_node: *DefNode,

    // スタック情報
    pub fn stack(self: Node) ?SourceLocation;

    // 評価実行
    pub fn run(self: Node, ctx: *Context) RunError!Value;
};

pub const VarRefNode = struct {
    var_ref: *Var,
    stack: SourceLocation,
};

pub const CallNode = struct {
    fn_node: *Node,
    args: []*Node,
    stack: SourceLocation,
};
```

**特徴:**
- 評価可能な中間表現
- スタック情報でエラー位置追跡
- `run()` で Value を返す

## Value (Runtime値)

```zig
// src/runtime/value.zig
pub const Value = union(enum) {
    // 基本型
    nil,
    bool_val: bool,
    int: i64,
    float: f64,
    char_val: u21,

    // 文字列・識別子
    string: *String,
    keyword: *Keyword,
    symbol: *Symbol,

    // コレクション（配列ベース）
    list: *PersistentList,
    vector: *PersistentVector,
    map: *PersistentMap,
    set: *PersistentSet,

    // 関数
    fn_val: *Fn,
    partial_fn: *PartialFn,   // 部分適用
    comp_fn: *CompFn,         // 合成関数
    multi_fn: *MultiFn,       // マルチメソッド
    protocol: *Protocol,      // プロトコル
    protocol_fn: *ProtocolFn, // プロトコル関数

    // VM用
    fn_proto: FnProtoPtr,     // コンパイル済み関数プロトタイプ

    // 遅延シーケンス
    lazy_seq: *LazySeq,

    // 参照
    var_val: *anyopaque,      // *Var（循環依存回避）
    atom: *Atom,

    // 遅延評価・ボックス
    delay_val: *Delay,
    volatile_val: *Volatile,
    reduced_val: *Reduced,
    transient: *Transient,
    promise: *Promise,

    // 正規表現
    regex: *Pattern,
    matcher: *RegexMatcher,

    // Wasm
    wasm_module: *WasmModule,
};
```

**特徴:**
- 実行時の実際の値
- GC 管理対象 (セミスペース Arena Mark-Sweep)
- コレクションは配列ベースの簡易実装(永続データ構造は将来)

## Var (変数)

```zig
// src/runtime/var.zig
pub const Var = struct {
    root: Value,              // グローバルバインディング
    sym: Symbol,
    ns: *Namespace,
    meta: Metadata,
    dynamic: bool,            // *dynamic* フラグ

    // Thread-local binding（将来）
    // thread_bindings: ThreadLocal(Frame),

    pub fn deref(self: *Var) Value;
    pub fn bindRoot(self: *Var, v: Value) void;
    pub fn isDynamic(self: *Var) bool;
};
```

## Namespace (名前空間)

```zig
// src/runtime/namespace.zig
pub const Namespace = struct {
    name: Symbol,
    mappings: SymbolVarMap,   // Symbol → *Var (intern済み)
    aliases: SymbolNsMap,     // Symbol → *Namespace (alias)
    refers: SymbolVarMap,     // Symbol → *Var (refer済み)
    imports: SymbolClassMap,  // Symbol → Class (import済み、将来)

    pub fn intern(self: *Namespace, sym: Symbol) *Var;
    pub fn refer(self: *Namespace, sym: Symbol, var_ref: *Var) void;
    pub fn alias(self: *Namespace, sym: Symbol, ns: *Namespace) void;
};
```

## Env (グローバル環境)

```zig
// src/runtime/env.zig
pub const Env = struct {
    namespaces: SymbolNsMap,  // Symbol → *Namespace

    // 設定
    features: FeatureSet,     // :clj, :cljs, etc. (reader conditional用)
    data_readers: TagReaderMap,

    pub fn findOrCreateNs(self: *Env, sym: Symbol) *Namespace;
    pub fn findNs(self: *Env, sym: Symbol) ?*Namespace;
};
```

## Context (評価コンテキスト)

```zig
// src/runtime/context.zig
pub const Context = struct {
    env: *Env,
    current_ns: *Namespace,

    // ローカルバインディング
    bindings: []Value,
    bindings_idx: SymbolIndexMap,  // Symbol → index

    // 制御フロー
    recur_target: ?*RecurTarget,

    // エラー追跡
    call_stack: CallStack,

    pub fn lookupLocal(self: *Context, sym: Symbol) ?Value;
    pub fn pushBindings(self: *Context, syms: []Symbol, vals: []Value) Context;
};
```

## 参考実装

| 概念         | 本家Clojure    | SCI           | このプロジェクト |
|--------------|----------------|---------------|------------------|
| Reader出力   | IObj + メタ    | edamame       | Form             |
| Analyzer出力 | Expr           | Node protocol | Node             |
| 実行時値     | Object         | any           | Value            |
| 変数         | Var.java       | Var type      | Var              |
| 名前空間     | Namespace.java | Namespace     | Namespace        |

### 参考ファイル

- sci: `~/Documents/OSS/sci/src/sci/impl/types.cljc`
- sci: `~/Documents/OSS/sci/src/sci/lang.cljc`
- 本家: `~/Documents/OSS/clojure/src/jvm/clojure/lang/Compiler.java`
- 本家: `~/Documents/OSS/clojure/src/jvm/clojure/lang/Var.java`
