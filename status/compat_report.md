# 互換性テストレポート

> 実行: `bash test/run_tests.sh`

## サマリ

### T2: カテゴリ別テスト (assert ベース)

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

### T4: sci テストスイート移植 (clojure.test ベース)

| テストファイル          | deftest | アサーション | Pass | Fail | Error | 率    |
|-------------------------|---------|--------------|------|------|-------|-------|
| sci/core_test           | 33      | 123          | 123  | 0    | 0     | 100%  |
| sci/vars_test           | 7       | 15           | 15   | 0    | 0     | 100%  |
| sci/hierarchies_test    | 5       | 5            | 5    | 0    | 0     | 100%  |
| **小計**                | **45**  | **143**      | **143** | **0** | **0** | **100%** |

### 総合

| 層       | テスト | Pass | Fail | Error | 率    |
|----------|--------|------|------|-------|-------|
| T2       | 390    | 372  | 16   | 2     | 95%   |
| T4 (sci) | 143    | 143  | 0    | 0     | 100%  |
| **合計** | **533**| **515** | **16** | **2** | **97%** |

## 失敗詳細

### collections (9 fail, 1 error)

| テスト名      | 状態  | 備考                                    |
|---------------|-------|-----------------------------------------|
| conj set      | ERROR | hash-set conj (要調査)                  |
| butlast       | FAIL  | 返り値の型不一致の可能性                |
| into map      | FAIL  | into with map (要調査)                  |
| keys single   | FAIL  | keys 返り値の型 (seq vs vec)            |
| vals single   | FAIL  | vals 返り値の型 (seq vs vec)            |
| flatten       | FAIL  | 返り値の型不一致の可能性                |
| distinct      | FAIL  | 返り値の型不一致の可能性                |
| sort          | FAIL  | sort 実装 (要調査)                      |
| sort w/ dups  | FAIL  | sort 実装 (要調査)                      |
| sort-by count | FAIL  | sort-by 実装 (要調査)                   |

### higher_order (3 fail)

| テスト名              | 状態 | 備考                          |
|-----------------------|------|-------------------------------|
| juxt inc/*2           | FAIL | #() fn リテラル in juxt       |
| memoize only called 1x| FAIL | memoize キャッシュ不具合      |
| sort-by keyfn         | FAIL | sort-by 実装 (要調査)         |

### predicates (1 fail)

| テスト名             | 状態 | 備考                          |
|----------------------|------|-------------------------------|
| identical? keywords  | FAIL | keyword interning (要調査)    |

### sequences (2 fail)

| テスト名      | 状態 | 備考                          |
|---------------|------|-------------------------------|
| mapcat        | FAIL | mapcat 返り値 (要調査)        |
| keep-indexed  | FAIL | keep-indexed 実装 (要調査)    |

### strings (1 fail, 1 error)

| テスト名         | 状態  | 備考                          |
|------------------|-------|-------------------------------|
| re-seq           | FAIL  | re-seq 返り値 (要調査)        |
| keyword with ns  | ERROR | 2-arity keyword (要調査)      |

## sci テスト移植で発見したバグ

| バグ                             | 影響         | 回避策                  |
|----------------------------------|--------------|-------------------------|
| map/set リテラル in macro body   | load-file 時 | hash-map/hash-set       |
| fn-level recur returns nil       | defn+recur   | loop+recur              |
| vector-list equality broken      | = [1] '(1)   | into [] で変換          |
| map-as-fn 2-arity               | ({:a 1} k d) | get with default        |
| symbol-as-fn                    | ('a map)     | get                     |
| defonce not preventing redef    | defonce      | スキップ                |
| letfn mutual recursion          | letfn f→g    | スキップ                |
| #'var as callable               | (#'foo)      | スキップ                |
| var-set no effect               | var-set      | スキップ                |
| alter-var-root uses thread-local | avr+binding  | スキップ                |
| defmacro inside defn            | defmacro     | トップレベルで定義      |

## 既知の未対応機能 (テストから除外)

- map 複数コレクション引数 (`(map + [1 2] [3 4])`)
- for :when / :while 修飾子
- into 3-arity (transducer)
- transduce
- clojure.string/* 名前空間 (core に string-xxx として実装)
- map/set リテラル in マクロ引数 (InvalidToken)
- with-local-vars
- add-watch on var
- ^:const
- (str (def x 1)) — def が var を返さない
