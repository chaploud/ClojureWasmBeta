;; basic.clj — 簡易ベンチマーク
;; 使用: time zig-out/bin/ClojureWasmBeta -e '(load-file "test/bench/basic.clj")'
;; 使用: time zig-out/bin/ClojureWasmBeta --backend=vm -e '(load-file "test/bench/basic.clj")'

(println "=== Benchmark: basic ===")

;; 1. フィボナッチ (再帰)
(defn fib [n]
  (if (<= n 1)
    n
    (+ (fib (- n 1)) (fib (- n 2)))))

(println "fib(25):" (fib 25))

;; 2. フィボナッチ (recur)
(defn fib-iter [n]
  (loop [a 0 b 1 i n]
    (if (zero? i) a (recur b (+ a b) (dec i)))))

(println "fib-iter(40):" (fib-iter 40))

;; 3. リスト操作 (map/filter/reduce)
(def nums (range 1000))
(println "sum 1-999:"
         (reduce + 0 (filter odd? (map inc nums))))

;; 4. 文字列操作
(println "str-concat:"
         (count (apply str (map str (range 500)))))

;; 5. Atom 操作
(def counter (atom 0))
(dotimes [_ 1000]
  (swap! counter inc))
(println "atom-inc-1000:" @counter)

;; 6. let/loop 集中
(defn sum-to [n]
  (loop [i 0 acc 0]
    (if (> i n) acc (recur (inc i) (+ acc i)))))

(println "sum-to(10000):" (sum-to 10000))

(println "=== Done ===")
