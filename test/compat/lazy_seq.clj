;; lazy_seq.clj — 遅延シーケンス テスト
(load-file "test/lib/test_runner.clj")

(println "[lazy_seq] running...")

;; === lazy-seq 基本 ===
(test-eq '(1 2 3) (lazy-seq (cons 1 (lazy-seq (cons 2 (lazy-seq (cons 3 nil)))))) "lazy-seq basic")

;; === map (lazy) ===
(test-eq '(2 3 4) (map inc [1 2 3]) "map lazy")
(test-eq '() (map inc []) "map empty")

;; === filter (lazy) ===
(test-eq '(2 4) (filter even? [1 2 3 4 5]) "filter lazy")
(test-eq '() (filter even? [1 3 5]) "filter none")

;; === mapcat (lazy) ===
(test-eq '(1 1 2 2 3 3) (mapcat (fn [x] (list x x)) [1 2 3]) "mapcat")
(test-eq '(:a 1 :b 2) (mapcat (fn [[k v]] [k v]) [[:a 1] [:b 2]]) "mapcat pairs")
(test-eq '() (mapcat (fn [x] (list x)) []) "mapcat empty")

;; === take / drop (lazy) ===
(test-eq '(0 1 2) (take 3 (range)) "take from infinite")
(test-eq '(5 6 7) (take 3 (drop 5 (range))) "take after drop infinite")

;; === iterate (lazy infinite) ===
(test-eq '(1 2 4 8 16) (take 5 (iterate (fn [x] (* 2 x)) 1)) "iterate doubles")
(test-eq '(0 1 2 3 4) (take 5 (iterate inc 0)) "iterate inc")

;; === cycle (lazy infinite) ===
(test-eq '(1 2 3 1 2 3 1) (take 7 (cycle [1 2 3])) "cycle")

;; === repeat (lazy) ===
(test-eq '(5 5 5) (repeat 3 5) "repeat finite")
(test-eq '(:x :x :x :x :x) (take 5 (repeat :x)) "repeat infinite")

;; === repeatedly ===
(test-eq 5 (count (repeatedly 5 (fn [] 1))) "repeatedly count")

;; === lazy-seq 等価比較 ===
(test-is (= '(1 1 2 2 3 3) (mapcat (fn [x] (list x x)) [1 2 3])) "lazy = list")
(test-is (= [1 2 3] (map identity [1 2 3])) "lazy = vec")
(test-is (= '(0 1 2 3 4) (range 5)) "range = list")
(test-is (= '(1 2 3) (take 3 (iterate inc 1))) "iterate = list")

;; === vec from lazy-seq ===
(test-eq [1 1 2 2] (vec (mapcat (fn [x] (list x x)) [1 2])) "vec from mapcat")
(test-eq [0 1 2 3 4] (vec (range 5)) "vec from range")

;; === doall ===
(test-eq '(1 2 3) (doall (map identity [1 2 3])) "doall realizes")

;; === concat (lazy) ===
(test-eq '(1 2 3 4) (concat [1 2] [3 4]) "concat vecs")
(test-eq '(1 2 3 4 5 6) (concat [1 2] [3 4] [5 6]) "concat 3 colls")
(test-eq '() (concat [] []) "concat empty")

;; === take-while / drop-while ===
(test-eq '(1 2) (take-while (fn [x] (< x 3)) [1 2 3 4 5]) "take-while")
(test-eq '(3 4 5) (drop-while (fn [x] (< x 3)) [1 2 3 4 5]) "drop-while")

;; === take-nth ===
(test-eq '(0 3 6 9) (take-nth 3 (range 10)) "take-nth")

;; === keep / keep-indexed ===
(test-eq '(2 4) (keep (fn [x] (when (even? x) x)) [1 2 3 4 5]) "keep")
(test-eq '(:a :c :e) (keep-indexed (fn [i v] (when (even? i) v)) [:a :b :c :d :e]) "keep-indexed")

;; === map-indexed ===
(test-eq '([0 :a] [1 :b] [2 :c]) (map-indexed vector [:a :b :c]) "map-indexed")

;; === partition / partition-all ===
(test-eq '((0 1 2) (3 4 5)) (partition 3 (range 7)) "partition drops remainder")
(test-eq '((0 1 2) (3 4 5) (6)) (partition-all 3 (range 7)) "partition-all keeps remainder")

;; === interleave / interpose ===
(test-eq '(1 :a 2 :b 3 :c) (interleave [1 2 3] [:a :b :c]) "interleave")
(test-eq '(1 0 2 0 3) (interpose 0 [1 2 3]) "interpose")

;; === flatten ===
(test-eq [1 2 3 4 5] (flatten [[1 2] [3 [4 5]]]) "flatten nested")
(test-eq [1 2 3] (flatten [1 2 3]) "flatten flat")

;; === distinct ===
(test-eq [1 2 3] (distinct [1 2 1 3 2]) "distinct")

;; === レポート ===
(println "[lazy_seq]")
(test-report)
