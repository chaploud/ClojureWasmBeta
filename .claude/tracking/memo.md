# セッションメモ

> 前回完了・次回タスク・技術メモ
> 古い内容は削除して肥大化を防ぐ

---

## 現在地点

**Phase 8.16 実用ユーティリティ関数・高階関数拡充 完了**

### 完了した機能

| Phase | 内容 |
|-------|------|
| 1-4 | Reader, Runtime基盤, Analyzer, TreeWalk評価器 |
| 5 | ユーザー定義関数 (fn, クロージャ) |
| 6 | マクロシステム (defmacro) |
| 7 | CLI (-e, 複数式, 状態保持) |
| 8.0 | VM基盤 (Bytecode, Compiler, VM, --compare) |
| 8.1 | クロージャ完成, 複数アリティfn, 可変長引数 |
| 8.2 | 高階関数 (apply, partial, comp, reduce) |
| 8.3 | 分配束縛（シーケンシャル `[a b]`、マップ `{:keys [a]}`) |
| 8.4 | シーケンス操作 (map, filter, take, drop, range 等) |
| 8.5 | 制御フローマクロ・スレッディングマクロ・ユーティリティ関数 |
| 8.6 | try/catch/finally 例外処理 + ex-info/ex-message/ex-data |
| 8.7 | Atom 状態管理 (atom, deref/@, reset!, swap!, atom?) |
| 8.8 | 文字列操作拡充 (subs, name, namespace, join, trim 等) |
| 8.9 | defnマクロ・dotimes・doseq・if-not・comment + メモリ安全性修正 |
| 8.10 | condp・case・some->・some->>・as->・mapv・filterv・defn docstring |
| 8.11 | キーワードを関数として使用: `(:a {:a 1})` → `1` |
| 8.12 | every?/some/not-every?/not-any? + VMスタック管理修正 |
| 8.13 | バグ修正・安定化（エラー型保全, VM try/catch, comp, finally） |
| 8.14 | マルチメソッド (defmulti, defmethod) + :default フォールバック |
| 8.15 | プロトコル (defprotocol, extend-type, extend-protocol, satisfies?) |
| 8.16 | ユーティリティ関数 (merge, get-in, assoc-in 等) + HOF (take-while, drop-while, map-indexed) + マクロ (update, complement, constantly) |

### 組み込み関数

```
算術: +, -, *, /, inc, dec
比較: =, <, >, <=, >=, not=
論理: not, and, or
述語: nil?, number?, integer?, float?, string?, keyword?,
      symbol?, fn?, coll?, list?, vector?, map?, set?, empty?, contains?,
      some?, zero?, pos?, neg?, even?, odd?, atom?,
      every?, not-every?, not-any? (マクロ展開)
      some (述語版, マクロ展開)
コレクション: first, rest, cons, conj, count, nth, get, list, vector
マップ: hash-map, assoc, dissoc, keys, vals
シーケンス: take, drop, range, concat, into, reverse, seq, vec,
           repeat, distinct, flatten
数値: max, min, abs, mod
文字列: str, subs, name, namespace, string-join, char-at
       upper-case, lower-case, trim, triml, trimr
       blank?, starts-with?, ends-with?, includes?, string-replace
出力: println, pr-str
例外: ex-info, ex-message, ex-data
Atom: atom, deref, reset!, swap!
プロトコル: satisfies?
ユーティリティ: identity, merge, get-in, assoc-in, select-keys, zipmap, not-empty, type
```

### 特殊形式

```
制御: if, do, let, loop, recur
関数: fn, def, defmacro, quote
高階: apply, partial, comp, reduce, map, filter, take-while, drop-while, map-indexed
例外: try, throw
Atom: swap!
マルチメソッド: defmulti, defmethod
プロトコル: defprotocol, extend-type
```

### 組み込みマクロ

```
制御フロー: cond, when, when-not, if-let, when-let, if-not, and, or
条件分岐: condp, case
繰り返し: dotimes, doseq
定義: defn (docstring対応, 複数アリティ対応)
コメント: comment
スレッディング: ->, ->>, some->, some->>, as->
コレクション変換: mapv, filterv
述語系: every?, some (述語版), not-every?, not-any?
プロトコル: extend-protocol
ユーティリティ: update, complement, constantly
```

実装方式: Analyzer 内で Form→Form 変換（マクロ展開）後に再帰解析。
新しい Node 型は不要（既存の if, let, do 等に展開）。

---

## 次回タスク

### Phase 8.17 以降の候補

候補:
- VM の let-closure バグ修正（`(let [x 0] (fn [] x))` で x がキャプチャされない）
- LazySeq（真の遅延シーケンス）
- 正規表現
- letfn（相互再帰ローカル関数）
- defrecord（プロトコルと組み合わせ）

---

## 将来のフェーズ（優先順）

| Phase | 内容 | 依存 |
|-------|------|------|
| 8.12+ | 機能拡充 (プロトコル等) | - |
| 9 | LazySeq（真の遅延シーケンス）| 無限シーケンスに必要 |
| 10 | GC | LazySeq導入後に必須 |
| 11 | Wasm連携 | 言語機能充実後 |

詳細: `docs/reference/architecture.md`

---

## 申し送り (解消したら削除)

### Reader/Form
- 有理数は float で近似（Ratio 型は将来実装）

### Value/Runtime
- コレクションは配列ベースの簡易実装（永続データ構造は将来）
- BuiltinFn は value.zig では anyopaque、core.zig で型定義、evaluator.zig でキャスト
- char_val は Form に対応していない（valueToForm でエラー）

### メモリ管理
- **Deep Clone による scratch→persistent 安全化**:
  - `runDef`: def'd 値を deepClone してから bindRoot（scratch 上のコレクション参照を排除）
  - `runFn`: fn body ノードを deepClone（scratch 上の Node ツリーを persistent にコピー）
  - `runSwap` / `resetBang`: atom 更新前に値を deepClone
  - `Chunk.addConstant`: VM bytecode 定数を deepClone
  - `Value.deepClone`: Atom の内部値も再帰的にクローン
- **メモリリーク（Phase 10 GC で対応予定）**:
  - deepClone により古い値が孤立する（GC で回収予定）
  - evaluator.zig の args 配列（バインディングスタック改善で対応）
  - Value 所有権（Var 破棄時に内部 Fn が解放されない）
  - context.withBinding の配列（バインディング毎に新配列を確保）

### Analyzer
- `analyzeDef` で Var を init 式解析前に intern（再帰的 defn の自己参照を可能に）

### VM
- createClosure: frame.base > 0 のみキャプチャ（トップレベルクロージャバグ修正済み）
- **sp_depth コンパイル時スタック追跡**: ローカル変数のスロット位置を正確に計算
  - `Local.slot`: frame.base からの実際のスタック位置
  - `Compiler.sp_depth`: コンパイル時のスタック深度追跡（全 emit 関数で更新）
  - `scope_exit` 命令: let/loop スコープ終了時にローカルを除去し結果を保持
  - `loop_locals_base`: sp_depth ベースで正確なオフセットを計算（recur が正しいスロットに書き込む）
  - これにより `(+ 1 (let [x 2] x))` や `(not (loop ...))` 等のネストが正常動作

### compare モード
- Var スナップショット機構: 各バックエンドが独自の Var 状態を維持
  - `VarSnapshot` 構造体: Var roots の保存・復元
  - TreeWalk 実行後に tw_state 保存 → vm_snapshot 復元 → VM 実行後に vm_snapshot 保存 → tw_state 復元
  - Atom はスナップショット対象外（別インスタンスが作られる）

### シーケンス操作
- map/filter は Eager 実装（リスト全体を即座に生成）
- LazySeq が必要な場合（無限シーケンス、遅延実行）は別途実装が必要
- `(range)` 引数なし（無限シーケンス）は未サポート

### 例外処理
- throw は任意の Value を投げられる（Clojure 互換）
- 内部エラー（TypeError 等）も catch で捕捉可能（TreeWalk / VM 両方対応）
- thrown_value は threadlocal に `*anyopaque` で格納（レイヤリング維持）
- VM: ExceptionHandler スタックで try/catch の状態を管理、ネスト対応
- Zig 0.15.2 で `catch` + `continue` パターンが LLVM IR エラーを引き起こすため、ラッパー関数で回避

### Atom
- `swap!` は特殊形式（関数呼び出しが必要なため通常の BuiltinFn では不可）
- `atom`, `deref`, `reset!`, `atom?` は通常の組み込み関数

### VM: let-closure バグ（既知）
- `(let [x 0] (fn [] x))` のような let 内で定義した fn が let-local をキャプチャできない
- fn-within-fn パターン `((fn [x] (fn [] x)) 0)` は正常動作
- complement/constantly マクロは fn-within-fn で回避済み

### 組み込みマクロ
- and/or は短絡評価（let + if に展開）
- 合成シンボル名 `__and__`, `__or__`, `__items__`, `__condp__`, `__case__`, `__st__` 等を使用（gensym が理想）
- doseq の recur に `(seq (rest ...))` が必要（空リストは truthy なので nil 変換が必要）
- condp: `(pred test-val expr)` の順で呼び出し（Clojure互換）
- some->/some->>: 再帰的に let+if+nil? チェーンに展開
- as->: 連続 let バインディングに展開

### マルチメソッド
- MultiFn 型: dispatch_fn + methods (PersistentMap) + default_method
- defmulti/defmethod は専用 Node 型 (DefmultiNode, DefmethodNode) + 専用 OpCode (0x44, 0x45)
- :default キーワードのディスパッチ値は default_method フィールドに格納
- compare モードの E2E テストでは defmulti/defmethod と呼び出しを同一 do ブロック内に記述（バックエンド毎に独自の MultiFn が必要なため）

### プロトコル
- Protocol 型: name (Symbol) + method_sigs + impls (PersistentMap: type_keyword → method_map)
- ProtocolFn 型: protocol 参照 + method_name（ディスパッチ用）
- defprotocol/extend-type は専用 Node 型 + 専用 OpCode (0x46, 0x47)
- extend-protocol は組み込みマクロ（複数 extend-type に展開）
- 型名マッピング: "String"→"string", "Integer"→"integer" 等（mapUserTypeName 関数）
- compare モードのテストでは defprotocol/extend-type と呼び出しを同一 do ブロック内に記述

### CLI テスト時の注意
- bash/zsh 環境で `!` はスペース後に `\` が挿入される場合がある
- `swap!`, `reset!` 等を含む式は Write ツールでファイル経由で渡すか、`$(cat file)` で回避

---

## 開発ワークフロー

1. **TreeWalk で正しい振る舞いを実装**
2. **VM を同期（同じ結果を返すように）**
3. **`--compare` で回帰検出**
4. **テスト追加 → コミット**

```bash
# 開発時の確認コマンド
zig build                                    # ビルド
zig build test                              # 全テスト
./zig-out/bin/ClojureWasmBeta -e "(+ 1 2)"  # 式評価
./zig-out/bin/ClojureWasmBeta --compare -e "(+ 1 2)"  # 両バックエンド比較
```
