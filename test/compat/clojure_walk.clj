;; clojure_walk.clj — clojure.walk namespace テスト
(load-file "test/lib/test_runner.clj")
(require 'clojure.walk)

(println "[clojure_walk] running...")

;; === postwalk ===
(test-eq [2 3 [4 5]]
         (clojure.walk/postwalk (fn [x] (if (number? x) (inc x) x)) [1 2 [3 4]])
         "postwalk inc vector")
(test-eq '(2 3 4)
         (clojure.walk/postwalk (fn [x] (if (number? x) (inc x) x)) '(1 2 3))
         "postwalk inc list")
(test-eq {:a 2 :b 3}
         (clojure.walk/postwalk (fn [x] (if (number? x) (inc x) x)) {:a 1 :b 2})
         "postwalk inc map")

;; === prewalk ===
(test-eq [1 2 [3 4]]
         (clojure.walk/prewalk identity [1 2 [3 4]])
         "prewalk identity")

;; === postwalk-replace ===
(test-eq [2 3 [4 5]]
         (clojure.walk/postwalk-replace {1 2, 2 3, 3 4, 4 5} [1 2 [3 4]])
         "postwalk-replace")

;; === prewalk-replace ===
(test-eq [:b :c]
         (clojure.walk/prewalk-replace {:a :b, :b :c} [:a :b])
         "prewalk-replace")

;; === keywordize-keys ===
(test-eq {:a 1 :b 2}
         (clojure.walk/keywordize-keys {"a" 1 "b" 2})
         "keywordize-keys")

;; === stringify-keys ===
(test-eq {"a" 1 "b" 2}
         (clojure.walk/stringify-keys {:a 1 :b 2})
         "stringify-keys")

;; === walk (基本) ===
(test-eq [2 3 4]
         (clojure.walk/walk inc vec [1 2 3])
         "walk vector inc")

(test-report)
