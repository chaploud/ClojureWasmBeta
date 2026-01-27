;; core_basic.clj — 基本関数テスト: 算術・比較・論理・型判定
(load-file "test/lib/test_runner.clj")

(println "[core_basic] running...")

;; === 算術 ===
(test-eq 3 (+ 1 2) "+ basic")
(test-eq 10 (+ 1 2 3 4) "+ variadic")
(test-eq 0 (+) "+ zero-arity")
(test-eq 5 (- 10 5) "- basic")
(test-eq -1 (- 1) "- unary negate")
(test-eq 6 (* 2 3) "* basic")
(test-eq 24 (* 1 2 3 4) "* variadic")
(test-eq 1 (*) "* zero-arity")
(test-is (== 5 (/ 10 2)) "/ basic")
(test-eq 3 (mod 10 7) "mod")
(test-eq 1 (rem 10 3) "rem")
(test-eq 2 (quot 10 4) "quot")
(test-eq 2 (inc 1) "inc")
(test-eq 0 (dec 1) "dec")
(test-eq 5 (max 1 5 3) "max")
(test-eq 1 (min 1 5 3) "min")
(test-eq 3 (abs -3) "abs")
(test-eq 0 (abs 0) "abs zero")

;; === 比較 ===
(test-is (= 1 1) "= equal")
(test-is (not= 1 2) "not= different")
(test-is (< 1 2) "< true")
(test-is (not (< 2 1)) "< false")
(test-is (<= 1 1) "<= equal")
(test-is (<= 1 2) "<= less")
(test-is (> 2 1) "> true")
(test-is (>= 2 2) ">= equal")
(test-is (< 1 2 3) "< chained")
(test-is (not (< 1 3 2)) "< chained false")

;; === 論理 ===
(test-is (and true true) "and true")
(test-is (not (and true false)) "and false")
(test-is (or false true) "or true")
(test-is (not (or false false)) "or false")
(test-is (not false) "not false")
(test-is (not nil) "not nil")
(test-is (true? true) "true? true")
(test-is (false? false) "false? false")

;; === 型判定 ===
;; NOTE: map/set リテラルはマクロ引数内で InvalidToken になるため
;;       hash-map/hash-set を使う (既知の制限)
(test-is (nil? nil) "nil? nil")
(test-is (not (nil? 0)) "nil? 0")
(test-is (number? 42) "number? int")
(test-is (number? 3.14) "number? float")
(test-is (string? "hello") "string? str")
(test-is (keyword? :a) "keyword? kw")
(test-is (symbol? 'x) "symbol? sym")
(test-is (fn? inc) "fn? inc")
(test-is (coll? [1 2]) "coll? vec")
(test-is (coll? (hash-map :a 1)) "coll? map")
(test-is (seq? (list 1 2)) "seq? list")
(test-is (vector? [1 2]) "vector? vec")
(test-is (map? (hash-map :a 1)) "map? map")
(test-is (set? (hash-set :a)) "set? set")
(test-is (integer? 42) "integer? 42")
(test-is (not (integer? 3.14)) "integer? 3.14")

;; === identity / constantly ===
(test-eq 42 (identity 42) "identity")
(test-eq 5 ((constantly 5) :ignored) "constantly")

;; === レポート ===
(println "[core_basic]")
(test-report)
