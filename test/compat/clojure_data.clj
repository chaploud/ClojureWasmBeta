;; clojure_data.clj — clojure.data namespace テスト
(load-file "test/lib/test_runner.clj")
(require 'clojure.data)

(println "[clojure_data] running...")

;; === 等しい値 ===
(test-eq [nil nil 1] (clojure.data/diff 1 1) "diff equal scalars")
(test-eq [nil nil :a] (clojure.data/diff :a :a) "diff equal keywords")
(test-eq [nil nil "hello"] (clojure.data/diff "hello" "hello") "diff equal strings")

;; === 異なるスカラー ===
(test-eq [1 2 nil] (clojure.data/diff 1 2) "diff different scalars")
(test-eq [:a :b nil] (clojure.data/diff :a :b) "diff different keywords")

;; === nil ===
(test-eq [nil nil nil] (clojure.data/diff nil nil) "diff nil nil")
(test-eq [nil 1 nil] (clojure.data/diff nil 1) "diff nil vs value")
(test-eq [1 nil nil] (clojure.data/diff 1 nil) "diff value vs nil")

;; === map diff ===
(let [[a b c] (clojure.data/diff {:a 1 :b 2} {:a 1 :c 3})]
  (test-eq {:b 2} a "map diff: only-in-a")
  (test-eq {:c 3} b "map diff: only-in-b")
  (test-eq {:a 1} c "map diff: in-both"))

;; === map diff — nested ===
(let [[a b c] (clojure.data/diff {:a {:x 1 :y 2}} {:a {:x 1 :y 3}})]
  (test-eq {:a {:y 2}} a "nested map diff: only-in-a")
  (test-eq {:a {:y 3}} b "nested map diff: only-in-b")
  (test-eq {:a {:x 1}} c "nested map diff: in-both"))

;; === set diff ===
(let [[a b c] (clojure.data/diff #{1 2 3} #{2 3 4})]
  (test-eq #{1} a "set diff: only-in-a")
  (test-eq #{4} b "set diff: only-in-b")
  (test-eq #{2 3} c "set diff: in-both"))

;; === sequential diff ===
(let [[a b c] (clojure.data/diff [1 2 3] [1 4 3])]
  (test-eq [nil 2 nil] a "seq diff: only-in-a")
  (test-eq [nil 4 nil] b "seq diff: only-in-b")
  (test-eq [1 nil 3] c "seq diff: in-both"))

;; === 異なる長さのシーケンス ===
(let [[a b c] (clojure.data/diff [1 2] [1 2 3])]
  (test-eq nil a "diff shorter a: only-in-a is nil")
  (test-eq [nil nil 3] b "diff shorter a: only-in-b")
  (test-eq [1 2 nil] c "diff shorter a: in-both"))

;; === empty map diff ===
(test-eq [nil nil {}] (clojure.data/diff {} {}) "diff empty maps")

;; === equal maps ===
(test-eq [nil nil {:a 1}] (clojure.data/diff {:a 1} {:a 1}) "diff equal maps")

(test-report)
