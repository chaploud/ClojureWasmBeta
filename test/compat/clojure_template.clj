;; clojure_template.clj — clojure.template namespace テスト
(load-file "test/lib/test_runner.clj")
(require 'clojure.template)

(println "[clojure_template] running...")

;; === require が成功すること ===
(test-is (some? (find-ns 'clojure.template)) "clojure.template NS exists")

;; === apply-template: 基本置換 ===
(test-eq '(+ 1 2)
         (clojure.template/apply-template '[a b] '(+ a b) [1 2])
         "apply-template basic")

;; === apply-template: ネスト式 ===
(test-eq '(if true (+ 10 20) (- 10 20))
         (clojure.template/apply-template '[x y] '(if true (+ x y) (- x y)) [10 20])
         "apply-template nested")

;; === apply-template: 置換なし ===
(test-eq '(+ 1 2)
         (clojure.template/apply-template '[x] '(+ 1 2) [99])
         "apply-template no substitution")

;; === apply-template: 単一引数 ===
(test-eq '(inc 42)
         (clojure.template/apply-template '[n] '(inc n) [42])
         "apply-template single arg")

;; === apply-template: ベクター内置換 ===
(test-eq '[1 2 3]
         (clojure.template/apply-template '[a b c] '[a b c] [1 2 3])
         "apply-template in vector")

;; === apply-template: マップ内置換 ===
(test-eq '{:key 42}
         (clojure.template/apply-template '[v] '{:key v} [42])
         "apply-template in map")

;; === do-template: 基本展開 (関数版) ===
(def template-results (atom []))
(clojure.template/do-template '[x] '(swap! template-results conj x) [1 2 3])
(test-eq [1 2 3] @template-results "do-template single param")

;; === do-template: 複数引数 ===
(def template-pairs (atom []))
(clojure.template/do-template '[x y] '(swap! template-pairs conj [x y]) [:a 1 :b 2 :c 3])
(test-eq [[:a 1] [:b 2] [:c 3]] @template-pairs "do-template multiple params")

;; === do-template: 式の評価結果 ===
(def template-sums (atom []))
(clojure.template/do-template '[a b] '(swap! template-sums conj (+ a b)) [1 2 3 4 5 6])
(test-eq [3 7 11] @template-sums "do-template arithmetic")

(test-report)
