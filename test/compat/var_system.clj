;; Phase Q3: Var system tests
(load-file "test/lib/test_runner.clj")
(reset-counters!)

;; Q3a: def returns Var
(test-is (not (nil? (def test-var-q3a 42))) "def should return non-nil (Var)")
(test-is (= 42 test-var-q3a) "def'd var should be accessible")
(test-is (string? (pr-str (def test-var-q3a 42))) "def result should have string repr")

;; Q3b: #'var as callable
(defn add1-q3b [x] (+ x 1))
(test-is (= 2 (#'add1-q3b 1)) "#'var should be callable")
(test-is (= 5 (#'add1-q3b 4)) "#'var callable with different arg")

;; Q3c: var-set sets thread binding (within binding only)
(def ^:dynamic *vs-test* 0)
(binding [*vs-test* 1]
  (var-set #'*vs-test* 99)
  (test-is (= 99 *vs-test*) "var-set should update thread binding"))
(test-is (= 0 *vs-test*) "var-set should not affect root value")

;; Q3d: alter-var-root uses root value
(def ^:dynamic *avr-test* 10)
(binding [*avr-test* 999]
  (alter-var-root #'*avr-test* inc))
(test-is (= 11 *avr-test*) "alter-var-root should use root value (10+1=11)")

;; Q3e: defonce prevents redefinition
(defonce my-once-val 42)
(defonce my-once-val 99)
(test-is (= 42 my-once-val) "defonce should prevent redefinition")

;; Q2b: fn-level recur
(defn countdown [n] (if (zero? n) :done (recur (dec n))))
(test-is (= :done (countdown 5)) "fn-level recur basic")

(defn sum-loop [n acc] (if (zero? n) acc (recur (dec n) (+ acc n))))
(test-is (= 55 (sum-loop 10 0)) "fn-level recur with accumulator")
(test-is (= 0 (sum-loop 0 0)) "fn-level recur base case")

;; Q4a: VM reduced
(test-is (= 6 (reduce (fn [a x] (if (= x 4) (reduced a) (+ a x))) 0 [1 2 3 4 5]))
         "reduce with reduced early exit")

;; === レポート ===
(println "[var_system]")
(test-report)
