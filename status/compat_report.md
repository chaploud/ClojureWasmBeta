# 互換性テストレポート

> 実行: `bash test/run_tests.sh`
>
> **注意**: 以下の T2/T4 セクションは初期テストフェーズ時点のスナップショット。
> 当時の失敗の多くはその後のフェーズ (Q1-Q5, U4, S1 等) で修正済み。
> 現在のテスト結果は **1036 pass / 1 fail (意図的)** を参照。

## 現在のテスト結果

```
TOTAL: 1036 pass, 1 fail, 0 error (total: 1037)
失敗ファイル: test/compat/test_framework_test.clj (意図的な失敗テスト)
```

---

## (参考) 初期テストフェーズ記録

### T2: カテゴリ別テスト (assert ベース, 初期スナップショット)

| カテゴリ      | テスト | Pass | Fail | Error | 率    |
|---------------|--------|------|------|-------|-------|
| core_basic    | 54     | 54   | 0    | 0     | 100%  |
| control_flow  | 43     | 43   | 0    | 0     | 100%  |
| predicates    | 91     | 90   | 1    | 0     | 99%   |
| sequences     | 48     | 46   | 2    | 0     | 96%   |
| strings       | 45     | 43   | 1    | 1     | 96%   |
| higher_order  | 33     | 30   | 3    | 0     | 91%   |
| collections   | 76     | 66   | 9    | 1     | 87%   |
| **小計**      | **390**| **372** | **16** | **2** | **95%** |

### T4: sci テストスイート移植 (clojure.test ベース, 初期スナップショット)

| テストファイル          | deftest | アサーション | Pass | Fail | Error | 率    |
|-------------------------|---------|--------------|------|------|-------|-------|
| sci/core_test           | 33      | 123          | 123  | 0    | 0     | 100%  |
| sci/vars_test           | 7       | 15           | 15   | 0    | 0     | 100%  |
| sci/hierarchies_test    | 5       | 5            | 5    | 0    | 0     | 100%  |
| **小計**                | **45**  | **143**      | **143** | **0** | **0** | **100%** |

## sci テスト移植で発見したバグ (多くは修正済み)

| バグ                             | 影響         | 状態                    |
|----------------------------------|--------------|-------------------------|
| map/set リテラル in macro body   | load-file 時 | Q2a で修正済み          |
| fn-level recur returns nil       | defn+recur   | Q2b で修正済み          |
| vector-list equality broken      | = [1] '(1)   | 修正済み                |
| map-as-fn 2-arity               | ({:a 1} k d) | U4a で修正済み          |
| symbol-as-fn                    | ('a map)     | U4a で修正済み          |
| defonce not preventing redef    | defonce      | Q3 で修正済み           |
| letfn mutual recursion          | letfn f→g    | Q4b で修正済み          |
| #'var as callable               | (#'foo)      | Q3 で修正済み           |
| var-set no effect               | var-set      | Q3 で修正済み           |
| alter-var-root uses thread-local | avr+binding  | Q3 で修正済み           |
| defmacro inside defn            | defmacro     | 既知の制限 (トップレベルで定義) |

## 既知の未対応機能

- map 複数コレクション引数 (`(map + [1 2] [3 4])`)
- for :when / :while 修飾子
- into 3-arity (transducer)
- transduce (multi-arity map 未対応のため)
- with-local-vars
- ^:const
- defmacro inside defn (トップレベルで定義が必要)
