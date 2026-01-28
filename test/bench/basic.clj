;; basic.clj — 簡易ベンチマーク
;; 使用: zig-out/bin/ClojureWasmBeta -e '(load-file "test/bench/basic.clj")'
;; 使用: zig-out/bin/ClojureWasmBeta --backend=vm -e '(load-file "test/bench/basic.clj")'

(println "=== Benchmark: basic ===")

;; 1. フィボナッチ (再帰)
(defn fib [n]
  (if (<= n 1)
    n
    (+ (fib (- n 1)) (fib (- n 2)))))

(print "fib(25): ")
(println (time (fib 25)))

;; 2. フィボナッチ (recur)
(defn fib-iter [n]
  (loop [a 0 b 1 i n]
    (if (zero? i) a (recur b (+ a b) (dec i)))))

(print "fib-iter(40): ")
(println (time (fib-iter 40)))

;; 3. リスト操作 (map/filter/reduce)
(print "map/filter/reduce(1000): ")
(println (time (reduce + 0 (filter odd? (map inc (range 1000))))))

;; 4. 文字列操作
(print "str-concat(500): ")
(println (time (count (apply str (map str (range 500))))))

;; 5. Atom 操作
(def counter (atom 0))
(print "atom-inc(1000): ")
(println (time (do (dotimes [_ 1000] (swap! counter inc)) @counter)))

;; 6. let/loop 集中
(defn sum-to [n]
  (loop [i 0 acc 0]
    (if (> i n) acc (recur (inc i) (+ acc i)))))

(print "sum-to(10000): ")
(println (time (sum-to 10000)))

;; 7. 大規模 reduce
(print "reduce-sum(10000): ")
(println (time (reduce + (range 10000))))

;; 8. ネスト map
(print "nested-map(500): ")
(println (time (count (map (fn [x] (map inc (range x))) (range 50)))))

;; 9. assoc 集中
(print "assoc-build(500): ")
(println (time (count (reduce (fn [m i] (assoc m (str i) i)) {} (range 500)))))

;; 10. 多値 dissoc/update
(def big-map (reduce (fn [m i] (assoc m (keyword (str "k" i)) i)) {} (range 200)))
(print "get-from-map(200x100): ")
(println (time (dotimes [_ 100]
                 (reduce (fn [acc k] (+ acc (get big-map k 0)))
                         0
                         (keys big-map)))))

(println "=== Done ===")
