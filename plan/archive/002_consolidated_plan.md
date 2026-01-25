# ClojureWasm 統合設計プラン

> 001からの議論を統合し、方針を確定させる
> 最終更新: 2026-01-25

---

## 確定方針

### 1. 動作互換（ブラックボックス）を目指す

- 本家core.cljを「そのままロード」する方針は放棄
- `(. clojure.lang.*)` 形式のJavaInterOp再実装はしない
- 同じ入力 → 同じ出力を保証する

### 2. 初期はZigで全て実装

- セルフホスト.cljは魅力的だが、初期はスピード重視
- 全ての関数・特殊形式をZigで実装
- 後でマクロ等を.cljに移行可能なアーキテクチャにはしておく

### 3. 既存コードはフルスクラッチの参照点

- SandboxClojureWasm, ClojureWasmPre, ClojureWasmAlphaの知見は活用
- しかし次期計画では引っ張られずに独自設計
- 開発途上で得た苦しみポイントを事前に把握

### 4. 網羅的・精査的アプローチ

- かいつまんで考えるより、最初に網羅
- トークン、Reader、関数、マクロの全パターンを洗い出す
- 対応状況は構造化データで管理

---

## 開発フェーズ

### Phase 0: 調査・設計（現在）

1. **全トークンパターンの洗い出し**
   - Clojureで出現しうる全てのトークン
   - 入れ子パターン、エッジケース
   - マクロ展開後に現れるもの

2. **本家Varの利用頻度分析**
   - `clj` CLIでロードされているVar一覧を取得
   - 利用頻度順にソート
   - 実装優先度の決定

3. **本家テストスイートの分類**
   - JVM非依存テストの抽出
   - cljdocの利用例収集

4. **バイトコードVMアーキテクチャ議論**
   - 初期はツリーウォークインタプリタ
   - 将来の差し替えを見据えた設計

### Phase 1: Reader完成

**目標**: 全トークンをエラーなしに識別

```
トークン種別:
- リテラル: 数値, 文字列, キーワード, シンボル, 正規表現
- コレクション: (), [], {}, #{}
- リーダーマクロ: ', `, ~, ~@, @, ^, #', #_, #(), #{}
- ディスパッチマクロ: #inst, #uuid, #?
- 特殊: ##Inf, ##-Inf, ##NaN
```

テスト:
- 全トークンパターンの識別テスト
- 入れ子状況のテスト
- エラーケースのテスト

### Phase 2: 評価器基盤

**目標**: 特殊形式の完全実装

```
特殊形式:
- def, fn*, let*, loop*, recur
- if, do, quote, var
- try, catch, finally, throw
- new, . (将来のWasm連携用)
```

### Phase 3: コア関数実装

**目標**: clojure.coreの主要関数

利用頻度順に実装（Phase 0で決定した順序）

### Phase 4: 追加名前空間

```
clojure.string  → Zigのstd.mem, std.unicode活用
clojure.set     → Zigの永続Set活用
clojure.walk    → 純粋Clojure実装可能
clojure.edn     → Reader拡張
clojure.test    → テストフレームワーク
```

### Phase 5: 並行処理

```
優先度高: atom (よく使う)
優先度中: future, promise
優先度低: agent, ref, STM
```

### Phase 6: バイトコードVM

- ツリーウォークからの移行
- 最速Clojure処理系を目指す

---

## 対応状況管理

### ファイル形式

`status/` ディレクトリに構造化データで管理:

```
status/
├── tokens.yaml      # トークン対応状況
├── special_forms.yaml
├── core_functions.yaml
├── namespaces.yaml
└── tests.yaml       # テストカバレッジ
```

### 例: core_functions.yaml

```yaml
# clojure.core関数の対応状況
functions:
  - name: first
    status: done
    priority: 1
    tests: 5
    notes: "永続リスト、ベクタ、nil対応"

  - name: rest
    status: done
    priority: 1
    tests: 4

  - name: map
    status: wip
    priority: 2
    tests: 0
    notes: "トランスデューサ版は後回し"

  - name: transduce
    status: todo
    priority: 5
    notes: "トランスデューサ全体と一緒に"
```

### ステータス定義

| ステータス | 意味 |
|-----------|------|
| `todo` | 未着手 |
| `wip` | 実装中 |
| `done` | 実装完了、テストあり |
| `partial` | 一部機能のみ実装 |
| `skip` | 対応しない（JVM固有等） |

---

## ベンチマーク

初期から導入。将来まで継続的に有用。

```
bench/
├── micro/           # マイクロベンチ
│   ├── arithmetic.clj
│   ├── collections.clj
│   └── functions.clj
├── macro/           # マクロベンチ
│   ├── fib.clj
│   └── sort.clj
└── results/         # 結果履歴（JSON）
    └── 2026-01-25.json
```

実行:
```bash
zig build bench
# または
zig build run -- --bench bench/micro/arithmetic.clj
```

---

## バイトコードVM設計（将来）

初期はツリーウォークだが、アーキテクチャは意識しておく。

### 想定される命令セット

```
;; スタックマシン想定
PUSH_CONST 42      ; 定数プッシュ
PUSH_LOCAL 0       ; ローカル変数
PUSH_VAR "foo"     ; Var参照
CALL 3             ; 関数呼び出し（引数3個）
JUMP_IF_FALSE 10   ; 条件分岐
MAKE_CLOSURE 5     ; クロージャ生成
...
```

### ツリーウォークからの移行パス

1. Value型はそのまま使える
2. 評価器をバイトコードコンパイラ + VMに置き換え
3. 永続データ構造、GCは共通

**重要**: 評価器を差し替え可能なインターフェースにしておく

```zig
const Evaluator = union(enum) {
    tree_walk: TreeWalkEvaluator,
    bytecode: BytecodeVM,
};
```

---

## 既存プロジェクトからの知見

### SandboxClojureWasm

**良かった点:**
- GC (Mark-Sweep Phase 2) が動作
- 314テストの蓄積
- prelude.cljでマクロが動作

**苦しみポイント:**
- 本家互換性の担保が曖昧だった
- テストがあっても本家との差異が発見しづらい

### ClojureWasmPre

**良かった点:**
- 「カスタムcore.cljは技術的負債」という強い方針
- 本家の動作理解が進んだ

**苦しみポイント:**
- 学習プロジェクトで終わった

### ClojureWasmAlpha

**良かった点:**
- 本家core.cljを986行までロード
- Reader/エラー表示が充実
- interop層の知見（どのJavaクラスが必要か判明）

**苦しみポイント:**
- JavaInterOp再実装が無限に続く
- 変更追従の困難さ
- `(. clojure.lang.RT ...)` 形式が冗長

### 共通の教訓

1. **互換性検証の仕組みが最重要**
   - 本家と同じ結果を返すかの自動テスト

2. **網羅的なトークン/構文テスト**
   - Readerの問題は後で発覚すると大変

3. **対応状況の可視化**
   - 何ができて何ができないかを常に把握

---

## 次のアクション

### 調査タスク

1. [ ] clj CLIでVar一覧を取得する方法を確認
2. [ ] 本家テストスイートのJVM非依存部分を抽出
3. [ ] Clojureの全トークンパターンを網羅的に列挙
4. [ ] cljdocから利用例を収集する方法を調査

### 設計タスク

1. [ ] status/ ディレクトリ構造の決定
2. [ ] ベンチマーク仕組みの設計
3. [ ] バイトコードVM命令セットの初期案

---

## 議論ログ

### Round 3 (2026-01-25)

**ユーザーの方針:**

1. 初期はZigで全て実装（セルフホスト.cljは後）
2. 網羅的・精査的アプローチ（かいつまむより最初に網羅）
3. 全トークンパターンを出してReaderテストを先に完成
4. 既存コードは参照のみ、フルスクラッチで設計
5. バイトコードVMは将来必須、初期はツリーウォーク、ただしアーキテクチャは議論
6. 対応状況は構造化データで管理（ドキュメント化用）
7. ベンチマークは初期から導入
8. STM/並行処理は後回し、atomは優先
9. clojure.string等はZigの機能に乗っかる

---

### Round 4 (次回)

**議論予定:**
- [ ] 具体的な調査結果
- [ ] トークンパターン一覧
- [ ] status/の構造決定
