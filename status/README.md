# 対応状況管理

Clojure本家との動作互換を追跡するための構造化データ。

---

## ファイル

| ファイル      | 内容                                      |
|---------------|-------------------------------------------|
| `tokens.yaml` | 字句解析レベルの対応状況                  |
| `vars.yaml`   | Var対応状況（関数、マクロ、特殊形式）     |
| `bench.yaml`  | ベンチマーク結果の変遷 (最適化効果追跡用) |

---

## ステータス定義

| ステータス | 意味                                     |
|------------|------------------------------------------|
| `todo`     | 未着手                                   |
| `wip`      | 実装中（存在するが動作未熟）             |
| `partial`  | 部分実装（一部機能のみ、先送り項目あり） |
| `done`     | 完成（テストあり）                       |
| `skip`     | 対応しない（JVM固有等）                  |

---

## Var の type 定義

Clojure 本家での種別。

| type           | 説明              |
|----------------|-------------------|
| `special-form` | 評価器で直接処理  |
| `function`     | 関数              |
| `macro`        | マクロ            |
| `dynamic-var`  | 動的束縛可能なVar |
| `var`          | 通常のVar         |

---

## impl_type 定義

このプロジェクトでの実装方式。

| impl_type      | 説明                                     |
|----------------|------------------------------------------|
| `builtin`      | core.zig の BuiltinFn                    |
| `special_form` | Analyzer の analyzeList 直接ディスパッチ |
| `macro`        | Analyzer の expandBuiltinMacro           |
| `none`         | 未実装                                   |

**暫定特殊形式の検出**: `type: function` かつ `impl_type: special_form` のエントリが「暫定特殊形式」（本家では関数だが特殊形式として実装）。

---

## layer 定義

| layer    | 説明                                                              |
|----------|-------------------------------------------------------------------|
| `host`   | Zig でしか実装できない（VM opcode, Value 型操作等）               |
| `bridge` | 原理的には Clojure で書けるが Zig で実装（ブートストラップ/性能） |
| `pure`   | 既存プリミティブの組合せで実装可能（将来 .clj 移行候補）          |

---

## bench.yaml 構造

```yaml
benchmarks:   # ベンチマーク定義 (5種類)
baseline:     # 他言語ベースライン (一度だけ記録)
history:      # ClojureWasmBeta 履歴 (最適化ごとに追記)
  - date: YYYY-MM-DD
    version: "フェーズ名"
    results:
      fib30: 秒数
      sum_range: 秒数
      ...
```

新しい最適化を行ったら `history` に新エントリを追加する。

---

## yq クエリ例

```bash
# 実装済み数
yq '.vars.clojure_core | to_entries | map(select(.value.status == "done")) | length' status/vars.yaml

# 暫定特殊形式（本家では関数）
yq '.vars.clojure_core | to_entries[] | select(.value.type == "function" and .value.impl_type == "special_form") | .key' status/vars.yaml

# layer 別集計
yq '[.vars.clojure_core | to_entries[] | select(.value.status == "done") | .value.layer] | group_by(.) | map({(.[0]): length})' status/vars.yaml

# 未実装で重要な関数を探す
yq '.vars.clojure_core | to_entries[] | select(.value.status == "todo" and .value.type == "function") | .key' status/vars.yaml

# スキップ済み（JVM固有）
yq '.vars.clojure_core | to_entries[] | select(.value.status == "skip") | .key' status/vars.yaml
```
