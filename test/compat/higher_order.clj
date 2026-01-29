;; higher_order.clj — 高階関数テスト
(load-file "test/lib/test_runner.clj")
(require '[clojure.string :refer [upper-case]])

(println "[higher_order] running...")

;; === comp ===
(test-eq 7 ((comp inc (partial * 2)) 3) "comp inc*2")
(test-eq "HELLO" ((comp upper-case str) 'hello) "comp str+upper")
(test-eq 42 ((comp) 42) "comp identity")
(test-eq 3 ((comp inc inc) 1) "comp inc inc")

;; === partial ===
(test-eq 5 ((partial + 2) 3) "partial +")
(test-eq 15 ((partial + 1 2 3) 4 5) "partial multi-arg")
(test-eq "hello world" ((partial str "hello") " world") "partial str")

;; === juxt ===
(test-eq [1 3] ((juxt first last) [1 2 3]) "juxt first/last")
(test-eq [true false] ((juxt even? odd?) 2) "juxt even/odd")
(test-eq [3 4] ((juxt inc #(* 2 %)) 2) "juxt inc/*2")

;; === complement ===
(let [not-even? (complement even?)]
  (test-is (not-even? 3) "complement true")
  (test-is (not (not-even? 2)) "complement false"))

;; === fnil ===
(let [safe-inc (fnil inc 0)]
  (test-eq 1 (safe-inc nil) "fnil nil->0->inc")
  (test-eq 6 (safe-inc 5) "fnil non-nil"))

;; === every-pred / some-fn ===
(let [pos-even? (every-pred pos? even?)]
  (test-is (pos-even? 2) "every-pred true")
  (test-is (not (pos-even? 3)) "every-pred false odd")
  (test-is (not (pos-even? -2)) "every-pred false neg"))

(let [str-or-kw? (some-fn string? keyword?)]
  (test-is (str-or-kw? "hello") "some-fn string")
  (test-is (str-or-kw? :key) "some-fn keyword")
  (test-is (not (str-or-kw? 42)) "some-fn number"))

;; === memoize ===
(let [calls (atom 0)
      f (memoize (fn [x] (swap! calls inc) (* x x)))]
  (test-eq 9 (f 3) "memoize first call")
  (test-eq 9 (f 3) "memoize cached")
  (test-eq 1 @calls "memoize only called once"))

;; === trampoline ===
(test-eq 10 (trampoline (fn step [n]
                          (if (>= n 10)
                            n
                            #(step (inc n)))) 0)
         "trampoline")

;; === map / filter / reduce (as HOF) ===
(test-eq '(1 4 9) (map #(* % %) [1 2 3]) "map with lambda")
(test-eq '("a" "b") (filter string? [:a "a" :b "b"]) "filter string?")
(test-is (= (hash-map :a 1 :b 2)
            (reduce (fn [m [k v]] (assoc m k v))
                    (hash-map)
                    [[:a 1] [:b 2]]))
         "reduce build map")

;; === mapv / filterv ===
(test-eq [2 3 4] (mapv inc [1 2 3]) "mapv")
(test-eq [2 4] (filterv even? [1 2 3 4 5]) "filterv")

;; NOTE: into 3-arity (transducer) → InvalidArity (未対応)
;; (test-eq [2 4 6] (into [] (map #(* 2 %)) [1 2 3]) "into + map xf")
;; (test-eq [2 4] (into [] (filter even?) [1 2 3 4 5]) "into + filter xf")

;; NOTE: transduce → InvalidArity (未対応)
;; (test-eq 9 (transduce (filter odd?) + [1 2 3 4 5]) "transduce filter+sum")
;; (test-eq 19 (transduce (filter odd?) + 10 [1 2 3 4 5]) "transduce with init")

;; === keep ===
(test-eq '(2 4) (keep #(when (even? %) %) (range 1 6)) "keep even")

;; === sort-by with keyfn ===
(test-eq ["a" "bb" "ccc"] (sort-by count ["ccc" "a" "bb"]) "sort-by keyfn")

;; === group-by ===
(test-is (= (group-by even? [1 2 3 4])
            (hash-map true [2 4] false [1 3]))
         "group-by even?")

;; === frequencies ===
(test-is (= (frequencies [1 1 2 3 3 3])
            (hash-map 1 2 2 1 3 3))
         "frequencies")

;; === レポート ===
(println "[higher_order]")
(test-report)
