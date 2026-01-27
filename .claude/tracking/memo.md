# セッションメモ

> 現在地点・次回タスク。技術ノートは `notes.md` を参照。

---

## 現在地点

**Phase 24 完了 — 名前空間（本格実装）**

### 完了フェーズ

| Phase | 内容                                                                                          |
|-------|-----------------------------------------------------------------------------------------------|
| 1-4   | Reader, Runtime基盤, Analyzer, TreeWalk評価器                                                 |
| 5     | ユーザー定義関数 (fn, クロージャ)                                                             |
| 6     | マクロシステム (defmacro)                                                                     |
| 7     | CLI (-e, 複数式, 状態保持)                                                                    |
| 8.0   | VM基盤 (Bytecode, Compiler, VM, --compare)                                                    |
| 8.1   | クロージャ完成, 複数アリティfn, 可変長引数                                                    |
| 8.2   | 高階関数 (apply, partial, comp, reduce)                                                       |
| 8.3   | 分配束縛 (シーケンシャル・マップ)                                                             |
| 8.4   | シーケンス操作 (map, filter, take, drop, range 等)                                            |
| 8.5   | 制御フローマクロ・スレッディングマクロ                                                        |
| 8.6   | try/catch/finally 例外処理                                                                    |
| 8.7   | Atom 状態管理 (atom, deref, reset!, swap!)                                                    |
| 8.8   | 文字列操作拡充                                                                                |
| 8.9   | defn・dotimes・doseq・if-not・comment                                                         |
| 8.10  | condp・case・some->・some->>・as->・mapv・filterv                                             |
| 8.11  | キーワードを関数として使用                                                                    |
| 8.12  | every?/some/not-every?/not-any?                                                               |
| 8.13  | バグ修正・安定化                                                                              |
| 8.14  | マルチメソッド (defmulti, defmethod)                                                          |
| 8.15  | プロトコル (defprotocol, extend-type, extend-protocol)                                        |
| 8.16  | ユーティリティ関数・HOF・マクロ拡充                                                           |
| 8.17  | VM let-closure バグ修正                                                                       |
| 8.18  | letfn（相互再帰ローカル関数）                                                                 |
| 8.19  | 実用関数・マクロ大量追加（~83関数/マクロ）                                                    |
| 8.20  | 動的コレクションリテラル（変数を含む [x y], {:a x} 等）                                       |
| 9     | LazySeq — 真の遅延シーケンス（無限シーケンス対応）                                            |
| 9.1   | Lazy map/filter/concat — 遅延変換・連結                                                       |
| 9.2   | iterate/repeat/cycle/range()/mapcat — 遅延ジェネレータ・lazy mapcat                           |
| 11    | PURE述語(23)+コレクション/ユーティリティ(17)+ビット演算等(17) = +57関数                       |
| 12    | PURE残り: 述語(15)+型キャスト(6)+算術(5)+出力(4)+ハッシュ(4)+MM拡張(6)+HOF(6)+他(7) = +53関数 |
| 13    | DESIGN: delay/force(3)+volatile(4)+reduced(4) = 新型3種+11関数、deref拡張                     |
| 14    | DESIGN: transient(7)+transduce基盤(6) = Transient型+13関数                                    |
| 15    | DESIGN: Atom拡張(7)+Var操作(6)+メタデータ(3) = +16関数                                        |
| 17    | DESIGN: 階層システム(7) = make-hierarchy/derive/underive/isa?等                               |
| 18    | DESIGN: promise/deliver + ユーティリティ(10) = Promise型+UUID+他                              |
| 18b   | DESIGN: partitionv/splitv-at/tap/parse-uuid 等(9) = 追加ユーティリティ                        |
| 19a   | DESIGN: class/struct/accessor/xml-seq等(9) = struct操作+ユーティリティ                        |
| 19b   | DESIGN: eval/read-string/sorted/dynamic-vars(18+14dynvar) = eval基盤+ソートcol+動的Var        |
| 19c   | DESIGN: NS操作/Reader/定義マクロ等(27+2dynvar) = 名前空間スタブ+load+definline                |
| 20    | FINAL: 残り59一括実装 — binding/chunk/regex/IO/NS/defrecord/deftype/動的Var                   |
| 21    | GC: Mark-Sweep at Expression Boundary (GcAllocator + tracing + 式境界GC)                      |
| 22    | 正規表現エンジン（フルスクラッチ Zig 実装）                                                   |
| 23    | 動的バインディング（本格実装）                                                                |
| 24    | 名前空間（本格実装）                                                                          |

### 実装状況

549 done / 169 skip / 0 todo (概算)

照会: `yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' status/vars.yaml`

---

## Phase 24 実装詳細

### サブフェーズ

| Sub   | 内容                                                                            |
|-------|---------------------------------------------------------------------------------|
| 24a   | NS情報関数本格化 (all-ns/ns-name/ns-publics/ns-interns/ns-map/ns-refers 等)    |
| 24b   | refer/alias/ns-unmap/ns-unalias/remove-ns 本格実装                             |
| 24c   | (ns ...) マクロ展開 (:require/:use/:refer-clojure 対応)                        |
| 24d   | require 本格実装 (ファイルロード + :as/:refer/:rename + ロード済み管理)         |
| 24e   | E2E テスト 10件追加                                                             |

### 変更ファイル

| ファイル                       | 変更内容                                                            |
|--------------------------------|---------------------------------------------------------------------|
| `src/runtime/namespace.zig`    | VarMap/NsAliasMap pub化 + unmap/removeAlias/getAllRefers/getAllAliases |
| `src/runtime/env.zig`          | NsMap pub化 + removeNs/getAllNamespaces                              |
| `src/lib/core.zig`             | 17 NS関数を本格実装 + ファイルロード + ロード済み管理               |
| `src/analyzer/analyze.zig`     | expandNs 本格化 (:require/:use/:refer-clojure 展開)                |
| `src/main.zig`                 | initLoadedLibs 呼び出し追加                                        |
| `src/test_e2e.zig`             | Phase 24 E2E テスト 10件追加                                       |

### 本格実装された関数

| 関数           | 実装状態 | 内容                                                    |
|----------------|----------|---------------------------------------------------------|
| all-ns         | 本格     | 全NS をシンボルリストで返す                             |
| ns-name        | 本格     | NS の名前をシンボルで返す                               |
| ns-publics     | 本格     | NS の全定義 Var を {sym value} マップで返す             |
| ns-interns     | 本格     | ns-publics と同等                                       |
| ns-map         | 本格     | interns + refers を統合マップで返す                     |
| ns-refers      | 本格     | NS の refer された Var マップを返す                     |
| ns-aliases     | 本格     | NS のエイリアスマップ {alias-sym ns-sym} を返す         |
| ns-resolve     | 本格     | 指定 NS 内でシンボルを解決                              |
| ns-unmap       | 本格     | NS からシンボルのマッピングを除去                       |
| ns-unalias     | 本格     | NS からエイリアスを除去                                 |
| remove-ns      | 本格     | 環境から NS を削除 (clojure.core は保護)                |
| refer          | 本格     | 他 NS の Var を refer (:only/:exclude/:rename 対応)     |
| alias          | 本格     | NS エイリアスを設定                                     |
| require        | 本格     | NS ロード + :as/:refer/:reload (:refer :all も対応)     |
| use            | 本格     | require + refer :all 相当 (:only 対応)                  |
| in-ns          | 本格     | current_ns を実際に切り替え                             |
| load-file      | 本格     | ファイルを読み込んで全式を評価                          |
| loaded-libs    | 本格     | ロード済みライブラリのセットを返す                      |

### 設計ポイント

- **NS切り替え**: `in-ns` が `env.setCurrentNs()` を実際に呼ぶ
- **(ns ...) マクロ**: `(do (in-ns 'name) clauses... (refer 'clojure.core))` に展開
- **ファイルロード**: NS名のドットを `/` に、ハイフンを `_` に変換して `.clj` を検索
- **ロード済み管理**: `loaded_libs` (StringHashMap) でロード済みNSを追跡
- **NS復元**: `tryLoadFile` がロード前のNSを退避し、ロード後に復元
- **refer フィルタリング**: `:only`, `:exclude`, `:rename` をサポート

### 既知の制限

- `do` ブロック内で `in-ns` → `def` しても、Analyzer が先に全式を解析するため
  NS切り替え前の NS に定義される（トップレベル式境界でのみ反映）
- VM での `with-redefs` 後のユーザー関数呼び出しが signal 6 でクラッシュ (Phase 23 由来)
- ファイルロードはクラスパスルート未設定時は相対パスのみ（`addClasspathRoot` でルート追加可能）

---

## ロードマップ

### 次のフェーズ（品質向上・新機能）

```
Phase LAST: Wasm 連携
  └ 言語機能充実後
  └ Component Model 対応、.wasm ロード・呼び出し、型マッピング
```

---

## 設計判断の控え

1. **正規表現**: Zig フルスクラッチ実装。バックトラッキング方式で Java regex 互換。
2. **skip 方針**: 明確に JVM 固有（proxy, agent, STM, Java array, unchecked-*, BigDecimal）のみ skip。
   迷うものは実装する。
3. **JVM 型変換**: byte/short/long/float 等は Zig キャスト相当に簡略化。
   instance?/class は内部タグ検査。深追いせず最小限で。
4. **GC**: 式境界 Mark-Sweep。GcAllocator で全 persistent alloc を追跡。
   閾値超過時にのみ実行。CLI 用途では十分な性能。
5. **動的バインディング**: マクロ展開方式 (push+try/finally+pop)。
   新 Node/Opcode 不要。既存インフラを最大限活用。

詳細: `docs/reference/architecture.md`
