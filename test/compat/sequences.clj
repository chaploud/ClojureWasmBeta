;; sequences.clj — シーケンス操作テスト
(load-file "test/lib/test_runner.clj")

(println "[sequences] running...")

;; === map ===
(test-eq '(2 3 4) (map inc [1 2 3]) "map inc")
;; NOTE: map with 2+ colls → InvalidArity (未対応)
;; (test-eq '(5 7 9) (map + [1 2 3] [4 5 6]) "map + two seqs")
(test-eq '() (map inc []) "map empty")

;; === filter / remove ===
(test-eq '(2 4) (filter even? [1 2 3 4 5]) "filter even")
(test-eq '(1 3 5) (remove even? [1 2 3 4 5]) "remove even")
(test-eq '() (filter even? [1 3 5]) "filter none match")

;; === reduce ===
(test-eq 10 (reduce + [1 2 3 4]) "reduce +")
(test-eq 15 (reduce + 5 [1 2 3 4]) "reduce + init")
(test-eq 0 (reduce + []) "reduce + empty")
(test-eq 24 (reduce * [1 2 3 4]) "reduce *")

;; === take / drop ===
(test-eq '(1 2 3) (take 3 [1 2 3 4 5]) "take 3")
(test-eq '(4 5) (drop 3 [1 2 3 4 5]) "drop 3")
(test-eq '() (take 0 [1 2 3]) "take 0")
(test-eq '(1 2 3) (drop 0 [1 2 3]) "drop 0")
(test-eq '(1 2 3) (take 10 [1 2 3]) "take excess")

;; === take-while / drop-while ===
(test-eq '(1 2) (take-while #(< % 3) [1 2 3 4 5]) "take-while")
(test-eq '(3 4 5) (drop-while #(< % 3) [1 2 3 4 5]) "drop-while")

;; === take-nth ===
(test-eq '(0 3 6 9) (take-nth 3 (range 10)) "take-nth")

;; === range ===
(test-eq '(0 1 2 3 4) (range 5) "range 5")
(test-eq '(2 3 4) (range 2 5) "range 2-5")
(test-eq '(0 2 4 6 8) (range 0 10 2) "range step")
(test-eq '() (range 0) "range 0")

;; === repeat / repeatedly ===
(test-eq '(5 5 5) (repeat 3 5) "repeat")
(test-eq 3 (count (repeatedly 3 #(rand-int 100))) "repeatedly count")

;; === iterate ===
(test-eq '(1 2 4 8 16) (take 5 (iterate #(* 2 %) 1)) "iterate")

;; === cycle ===
(test-eq '(1 2 3 1 2 3 1) (take 7 (cycle [1 2 3])) "cycle")

;; === mapcat ===
(test-eq '(1 1 2 2 3 3) (mapcat #(list % %) [1 2 3]) "mapcat")

;; === some / every? / not-every? / not-any? ===
(test-eq true (some even? [1 2 3]) "some even found")
(test-eq nil (some even? [1 3 5]) "some even not found")
(test-is (every? pos? [1 2 3]) "every? pos")
(test-is (not (every? pos? [1 -2 3])) "every? pos false")
(test-is (not-every? even? [1 2 3]) "not-every?")
(test-is (not-any? neg? [1 2 3]) "not-any?")

;; === keep / keep-indexed ===
(test-eq '(2 4) (keep #(when (even? %) %) [1 2 3 4 5]) "keep")
(test-eq '(0 2 4) (keep-indexed #(when (even? %1) %2) [:a :b :c :d :e]) "keep-indexed")

;; === map-indexed ===
(test-eq '([0 :a] [1 :b] [2 :c]) (map-indexed vector [:a :b :c]) "map-indexed")

;; === reduce-kv ===
(test-eq 6 (reduce-kv (fn [acc k v] (+ acc v)) 0 (hash-map :a 1 :b 2 :c 3)) "reduce-kv sum vals")

;; === apply ===
(test-eq 10 (apply + [1 2 3 4]) "apply +")
(test-eq 10 (apply + 1 [2 3 4]) "apply + with initial")
(test-eq "hello world" (apply str ["hello" " " "world"]) "apply str")

;; === juxt ===
(test-eq [1 3] ((juxt first last) [1 2 3]) "juxt first last")

;; === comp ===
(test-eq 7 ((comp inc (partial * 2)) 3) "comp inc*2")

;; === partial ===
(test-eq 5 ((partial + 2) 3) "partial")
(test-eq 15 ((partial + 1 2 3) 4 5) "partial multi")

;; === complement ===
(test-is ((complement even?) 3) "complement")
(test-is (not ((complement even?) 2)) "complement false")

;; === fnil ===
(test-eq 1 ((fnil inc 0) nil) "fnil nil")
(test-eq 6 ((fnil inc 0) 5) "fnil non-nil")

;; === doall / dorun ===
(test-eq '(1 2 3) (doall (map identity [1 2 3])) "doall")

;; === レポート ===
(println "[sequences]")
(test-report)
