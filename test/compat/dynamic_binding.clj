;; dynamic_binding.clj — 動的バインディング テスト
(load-file "test/lib/test_runner.clj")

(println "[dynamic_binding] running...")

;; === def ^:dynamic / binding ===
(def ^:dynamic *x* 10)
(test-eq 10 *x* "dynamic default")

(binding [*x* 20]
  (test-eq 20 *x* "binding override"))

(test-eq 10 *x* "binding restored")

;; === binding with function call ===
(def ^:dynamic *multiplier* 1)
(defn compute [n] (* n *multiplier*))

(test-eq 5 (compute 5) "compute default")
(binding [*multiplier* 10]
  (test-eq 50 (compute 5) "compute bound"))
(test-eq 5 (compute 5) "compute restored")

;; === nested binding ===
(def ^:dynamic *a* 1)
(def ^:dynamic *b* 2)

(binding [*a* 10]
  (test-eq 10 *a* "nested outer")
  (binding [*b* 20]
    (test-eq 10 *a* "nested inner a")
    (test-eq 20 *b* "nested inner b"))
  (test-eq 2 *b* "nested b restored"))
(test-eq 1 *a* "nested a restored")

;; === binding with multiple vars ===
(binding [*a* 100 *b* 200]
  (test-eq 100 *a* "multi-bind a")
  (test-eq 200 *b* "multi-bind b"))

;; === thread-bound? ===
(test-is (not (thread-bound? #'*a*)) "not thread-bound outside")
(binding [*a* 10]
  (test-is (thread-bound? #'*a*) "thread-bound inside"))

;; === レポート ===
(println "[dynamic_binding]")
(test-report)
