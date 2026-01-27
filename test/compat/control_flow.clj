;; control_flow.clj — 制御フローテスト
(load-file "test/lib/test_runner.clj")

(println "[control_flow] running...")

;; === if ===
(test-eq 1 (if true 1 2) "if true")
(test-eq 2 (if false 1 2) "if false")
(test-eq nil (if false 1) "if false no-else")
(test-eq 1 (if 42 1 2) "if truthy")
(test-eq 2 (if nil 1 2) "if nil")

;; === when / when-not ===
(test-eq 1 (when true 1) "when true")
(test-eq nil (when false 1) "when false")
(test-eq 1 (when-not false 1) "when-not false")
(test-eq nil (when-not true 1) "when-not true")

;; === if-let / when-let / if-some / when-some ===
(test-eq 2 (if-let [x 1] (inc x) :nope) "if-let bound")
(test-eq :nope (if-let [x nil] (inc x) :nope) "if-let nil")
(test-eq 2 (when-let [x 1] (inc x)) "when-let bound")
(test-eq nil (when-let [x nil] (inc x)) "when-let nil")
(test-eq 2 (if-some [x 1] (inc x) :nope) "if-some bound")
(test-eq :nope (if-some [x nil] (inc x) :nope) "if-some nil")
(test-eq 1 (if-some [x false] 1 2) "if-some false")

;; === cond ===
(test-eq :big (cond (> 10 5) :big (< 10 5) :small) "cond true")
(test-eq :default (cond (> 1 5) :nope :else :default) "cond default")

;; === condp ===
(test-eq "one" (condp = 1 1 "one" 2 "two" "other") "condp match")
(test-eq "other" (condp = 3 1 "one" 2 "two" "other") "condp default")

;; === case ===
(test-eq "one" (case 1 1 "one" 2 "two" "other") "case match")
(test-eq "other" (case 3 1 "one" 2 "two" "other") "case default")

;; === do ===
(test-eq 3 (do 1 2 3) "do returns last")

;; === let ===
(test-eq 3 (let [a 1 b 2] (+ a b)) "let basic")
(test-eq 3 (let [a 1 b (+ a 2)] (* a b)) "let sequential")

;; === loop / recur ===
(test-eq 10 (loop [i 0 acc 0]
              (if (= i 5)
                acc
                (recur (inc i) (+ acc i))))
         "loop/recur sum")

(test-eq 120 (loop [n 5 acc 1]
               (if (= n 0)
                 acc
                 (recur (dec n) (* acc n))))
         "loop/recur factorial")

;; === fn + recur ===
(test-eq 55 ((fn fib [n]
               (loop [i 0 a 0 b 1]
                 (if (= i n)
                   a
                   (recur (inc i) b (+ a b)))))
             10)
         "fn recur fibonacci")

;; === doseq (副作用確認用) ===
(let [acc (atom 0)]
  (doseq [x [1 2 3 4 5]]
    (swap! acc + x))
  (test-eq 15 @acc "doseq sum"))

;; === dotimes ===
(let [acc (atom 0)]
  (dotimes [i 5]
    (swap! acc + i))
  (test-eq 10 @acc "dotimes sum"))

;; === for ===
(test-eq [1 4 2 5 3 6] (into [] (for [x [1 2 3] y [0 3]] (+ x y))) "for cartesian")
;; NOTE: for :when → InvalidBinding (未対応)
;; (test-eq '(2 4 6) (for [x (range 1 7) :when (even? x)] x) "for :when")

;; === threading macros ===
(test-eq 5 (-> 1 inc inc inc inc) "-> chain")
(test-eq 5 (-> 10 (- 3) (- 2)) "-> with args")
(test-eq '(3 2 1) (->> [1 2 3] (map identity) reverse) "->> chain")
(test-eq 6 (->> (range 1 4) (reduce +)) "->> reduce")

;; === some-> / some->> ===
(test-eq 3 (some-> 1 inc inc) "some-> chain")
(test-eq nil (some-> nil inc inc) "some-> nil")

;; === as-> ===
(test-eq 5 (as-> 0 x (inc x) (+ x 3) (inc x)) "as->")

;; === try / catch / finally ===
(test-eq "caught" (try (/ 1 0) (catch Exception e "caught")) "try/catch")
(let [side (atom nil)]
  (try (/ 1 0) (catch Exception e nil) (finally (reset! side :done)))
  (test-eq :done @side "finally runs"))

;; === throw ===
(test-throws (throw (ex-info "oops" (hash-map))) "throw ex-info")

;; === assert ===
(test-is (= nil (assert true)) "assert true")
(test-throws (assert false "bad") "assert false throws")

;; === レポート ===
(println "[control_flow]")
(test-report)
