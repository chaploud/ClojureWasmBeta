;; 第一級関数テスト
;; builtin 関数を変数経由・apply 経由で呼べることを確認
(load-file "test/lib/test_runner.clj")
(reset-counters!)

;; apply を変数経由で呼び出し
(let [f apply]
  (test-is (= 6 (f + [1 2 3])) "apply as first-class via let"))

;; apply を apply で呼び出し
(test-is (= 10 (apply apply [+ [1 2 3 4]])) "apply via apply")

;; partial を変数経由
(let [p partial]
  (test-is (= 5 ((p + 2) 3)) "partial as first-class via let"))

;; comp を変数経由
(let [c comp]
  (test-is (= 2 ((c inc inc) 0)) "comp as first-class via let"))

;; reduce を変数経由
(let [r reduce]
  (test-is (= 15 (r + 0 [1 2 3 4 5])) "reduce as first-class via let"))

;; sort-by を変数経由
(let [sb sort-by]
  (test-is (= '(1 2 3) (sb identity [3 1 2])) "sort-by as first-class via let"))

;; group-by を変数経由
(let [gb group-by]
  (test-is (= (hash-map true [2 4] false [1 3])
              (gb even? [1 2 3 4]))
           "group-by as first-class via let"))

;; swap! を変数経由（ファイル経由なので ! も問題なし）
(def test-atom (atom 0))
(let [s swap!]
  (s test-atom + 5)
  (test-is (= 5 @test-atom) "swap! as first-class via let"))

;; Q1b: map/filter/take-while/drop-while/map-indexed を第一級で使用
(test-is (= '(2 3 4) ((partial map inc) [1 2 3])) "partial with map")

(let [m map]
  (test-is (= '(2 3 4) (m inc [1 2 3])) "map as first-class via let"))

(let [f filter]
  (test-is (= '(2 4) (f even? [1 2 3 4 5])) "filter as first-class via let"))

(let [tw take-while]
  (test-is (= '(1 2 3) (tw pos? [1 2 3 0 -1])) "take-while as first-class via let"))

(let [dw drop-while]
  (test-is (= '(0 -1) (dw pos? [1 2 3 0 -1])) "drop-while as first-class via let"))

(let [mi map-indexed]
  (test-is (= '([0 :a] [1 :b] [2 :c]) (mi vector [:a :b :c])) "map-indexed as first-class via let"))

;; 遅延動作テスト（無限 range に対して）
(test-is (= '(1 2 3) (take 3 (map inc (range)))) "lazy map with infinite range")
(test-is (= '(1 3 5) (take 3 (filter odd? (range)))) "lazy filter with infinite range")
(test-is (= '() (take-while pos? [-1 0 1 2])) "take-while stops at first falsy")
(test-is (= '(0 1 2) (drop-while neg? [-2 -1 0 1 2])) "drop-while drops negatives")

;; reduce に reduced を使う（第一級 reduce）
(let [r reduce]
  (test-is (= 6 (r (fn [a x] (if (= x 4) (reduced a) (+ a x))) 0 [1 2 3 4 5]))
           "first-class reduce with reduced"))

;; === レポート ===
(println "[q1a_first_class]")
(test-report)
