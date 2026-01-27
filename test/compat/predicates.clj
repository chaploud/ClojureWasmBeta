;; predicates.clj — 述語テスト
(load-file "test/lib/test_runner.clj")

(println "[predicates] running...")

;; === nil? ===
(test-is (nil? nil) "nil? nil")
(test-is (not (nil? false)) "nil? false")
(test-is (not (nil? 0)) "nil? 0")
(test-is (not (nil? "")) "nil? empty-str")

;; === some? ===
(test-is (some? 0) "some? 0")
(test-is (some? false) "some? false")
(test-is (not (some? nil)) "some? nil")

;; === true? / false? ===
(test-is (true? true) "true? true")
(test-is (not (true? 1)) "true? 1")
(test-is (not (true? nil)) "true? nil")
(test-is (false? false) "false? false")
(test-is (not (false? nil)) "false? nil")

;; === number? / integer? / float? / zero? / pos? / neg? ===
(test-is (number? 42) "number? int")
(test-is (number? 3.14) "number? float")
(test-is (not (number? "42")) "number? str")
(test-is (integer? 42) "integer? 42")
(test-is (not (integer? 3.14)) "integer? 3.14")
(test-is (float? 3.14) "float? 3.14")
(test-is (not (float? 42)) "float? 42")
(test-is (zero? 0) "zero? 0")
(test-is (not (zero? 1)) "zero? 1")
(test-is (pos? 1) "pos? 1")
(test-is (not (pos? 0)) "pos? 0")
(test-is (not (pos? -1)) "pos? -1")
(test-is (neg? -1) "neg? -1")
(test-is (not (neg? 0)) "neg? 0")
(test-is (even? 2) "even? 2")
(test-is (not (even? 3)) "even? 3")
(test-is (odd? 3) "odd? 3")
(test-is (not (odd? 2)) "odd? 2")

;; === NaN? / Inf? / pos-int? / neg-int? / nat-int? ===
(test-is (NaN? ##NaN) "NaN?")
(test-is (not (NaN? 1)) "NaN? 1")
(test-is (infinite? ##Inf) "infinite? +Inf")
(test-is (infinite? ##-Inf) "infinite? -Inf")
(test-is (not (infinite? 1)) "infinite? 1")
(test-is (pos-int? 1) "pos-int? 1")
(test-is (not (pos-int? 0)) "pos-int? 0")
(test-is (not (pos-int? -1)) "pos-int? -1")
(test-is (neg-int? -1) "neg-int? -1")
(test-is (not (neg-int? 0)) "neg-int? 0")
(test-is (nat-int? 0) "nat-int? 0")
(test-is (nat-int? 1) "nat-int? 1")
(test-is (not (nat-int? -1)) "nat-int? -1")

;; === string? / keyword? / symbol? ===
(test-is (string? "hello") "string? str")
(test-is (not (string? 42)) "string? int")
(test-is (keyword? :a) "keyword? kw")
(test-is (not (keyword? "a")) "keyword? str")
(test-is (symbol? 'x) "symbol? sym")
(test-is (not (symbol? :x)) "symbol? kw")

;; === fn? / ifn? ===
(test-is (fn? inc) "fn? inc")
(test-is (fn? (fn [x] x)) "fn? lambda")
(test-is (ifn? inc) "ifn? inc")
(test-is (ifn? :a) "ifn? keyword")
(test-is (ifn? (hash-map :a 1)) "ifn? map")

;; === coll? / seq? / list? / vector? / map? / set? ===
(test-is (coll? [1 2]) "coll? vec")
(test-is (coll? (list 1)) "coll? list")
(test-is (coll? (hash-map :a 1)) "coll? map")
(test-is (coll? (hash-set 1)) "coll? set")
(test-is (not (coll? "hello")) "coll? str")
(test-is (seq? (list 1 2)) "seq? list")
(test-is (not (seq? [1 2])) "seq? vec")
(test-is (list? (list 1 2)) "list? list")
(test-is (not (list? [1 2])) "list? vec")
(test-is (vector? [1 2]) "vector? vec")
(test-is (not (vector? (list 1))) "vector? list")
(test-is (map? (hash-map :a 1)) "map? map")
(test-is (not (map? [1 2])) "map? vec")
(test-is (set? (hash-set 1 2)) "set? set")
(test-is (not (set? [1 2])) "set? vec")

;; === sequential? / associative? / counted? / sorted? ===
(test-is (sequential? [1 2]) "sequential? vec")
(test-is (sequential? (list 1)) "sequential? list")
(test-is (not (sequential? (hash-map :a 1))) "sequential? map")
(test-is (associative? [1 2]) "associative? vec")
(test-is (associative? (hash-map :a 1)) "associative? map")
(test-is (not (associative? (list 1))) "associative? list")
(test-is (counted? [1 2]) "counted? vec")
(test-is (counted? (hash-map :a 1)) "counted? map")

;; === empty? / not-empty ===
(test-is (empty? []) "empty? empty-vec")
(test-is (empty? nil) "empty? nil")
(test-is (not (empty? [1])) "empty? non-empty")
(test-eq [1] (not-empty [1]) "not-empty non-empty")
(test-eq nil (not-empty []) "not-empty empty")

;; === identical? / = / == ===
(test-is (= 1 1) "= nums")
(test-is (= [1 2] [1 2]) "= vecs")
(test-is (not (= 1 "1")) "= diff types")
(test-is (== 1 1.0) "== numeric")
(test-is (identical? :a :a) "identical? keywords")

;; === compare ===
(test-eq 0 (compare 1 1) "compare equal")
(test-is (neg? (compare 1 2)) "compare less")
(test-is (pos? (compare 2 1)) "compare greater")
(test-is (neg? (compare "a" "b")) "compare strings")

;; === レポート ===
(println "[predicates]")
(test-report)
