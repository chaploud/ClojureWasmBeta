;; collections.clj — コレクション操作テスト
(load-file "test/lib/test_runner.clj")

(println "[collections] running...")

;; === conj ===
(test-eq [1 2 3] (conj [1 2] 3) "conj vec")
(test-eq '(0 1 2) (conj '(1 2) 0) "conj list")
(test-is (= (hash-set :a :b :c) (conj (hash-set :a :b) :c)) "conj set")

;; === assoc ===
(test-eq [10 2 3] (assoc [1 2 3] 0 10) "assoc vec")
(test-is (= (assoc (hash-map :a 1) :b 2) (hash-map :a 1 :b 2)) "assoc map")
(test-is (= (assoc (hash-map :a 1) :a 10) (hash-map :a 10)) "assoc map overwrite")

;; === dissoc ===
(test-is (= (dissoc (hash-map :a 1 :b 2) :a) (hash-map :b 2)) "dissoc")
(test-is (= (dissoc (hash-map :a 1 :b 2) :a :b) (hash-map)) "dissoc multi")

;; === get ===
(test-eq 1 (get (hash-map :a 1) :a) "get map")
(test-eq nil (get (hash-map :a 1) :b) "get map missing")
(test-eq :default (get (hash-map :a 1) :b :default) "get map default")
(test-eq "b" (get ["a" "b" "c"] 1) "get vec")
(test-eq nil (get ["a" "b" "c"] 5) "get vec out-of-bounds")

;; === get-in ===
(test-eq 1 (get-in (hash-map :a (hash-map :b 1)) [:a :b]) "get-in nested")
(test-eq :nope (get-in (hash-map :a 1) [:b :c] :nope) "get-in default")

;; === assoc-in ===
(test-is (= (assoc-in (hash-map :a (hash-map :b 1)) [:a :b] 2)
            (hash-map :a (hash-map :b 2)))
         "assoc-in nested")

;; === update ===
(test-is (= (update (hash-map :a 1) :a inc) (hash-map :a 2)) "update")

;; === update-in ===
(test-is (= (update-in (hash-map :a (hash-map :b 1)) [:a :b] inc)
            (hash-map :a (hash-map :b 2)))
         "update-in")

;; === contains? ===
(test-is (contains? (hash-map :a 1) :a) "contains? map true")
(test-is (not (contains? (hash-map :a 1) :b)) "contains? map false")
(test-is (contains? [1 2 3] 0) "contains? vec index")
(test-is (not (contains? [1 2 3] 5)) "contains? vec out")
(test-is (contains? (hash-set :a :b) :a) "contains? set")

;; === count ===
(test-eq 3 (count [1 2 3]) "count vec")
(test-eq 2 (count (hash-map :a 1 :b 2)) "count map")
(test-eq 0 (count []) "count empty vec")
(test-eq 0 (count nil) "count nil")
(test-eq 5 (count "hello") "count string")

;; === empty? / seq ===
(test-is (empty? []) "empty? vec")
(test-is (empty? nil) "empty? nil")
(test-is (not (empty? [1])) "empty? non-empty")
(test-is (seq [1 2]) "seq non-empty")
(test-is (not (seq [])) "seq empty")

;; === first / rest / next ===
(test-eq 1 (first [1 2 3]) "first vec")
(test-eq nil (first []) "first empty")
(test-eq nil (first nil) "first nil")
(test-eq '(2 3) (rest [1 2 3]) "rest vec")
(test-eq '() (rest []) "rest empty")
(test-eq '(2 3) (next [1 2 3]) "next vec")
(test-eq nil (next [1]) "next single")
(test-eq nil (next []) "next empty")

;; === last / butlast ===
(test-eq 3 (last [1 2 3]) "last vec")
(test-eq nil (last []) "last empty")
(test-eq [1 2] (butlast [1 2 3]) "butlast")
(test-eq nil (butlast []) "butlast empty")

;; === nth ===
(test-eq "b" (nth ["a" "b" "c"] 1) "nth vec")
(test-eq :default (nth [1 2] 5 :default) "nth default")

;; === peek / pop ===
(test-eq 3 (peek [1 2 3]) "peek vec")
(test-eq [1 2] (pop [1 2 3]) "pop vec")
(test-eq 1 (peek '(1 2 3)) "peek list")
(test-eq '(2 3) (pop '(1 2 3)) "pop list")

;; === into ===
(test-eq [1 2 3 4] (into [1 2] [3 4]) "into vec")
(test-is (= (into (hash-map) [[:a 1] [:b 2]]) (hash-map :a 1 :b 2)) "into map")
(test-is (= (hash-set 1 2 3) (into (hash-set) [1 2 3])) "into set")

;; === merge ===
(test-is (= (merge (hash-map :a 1) (hash-map :b 2))
            (hash-map :a 1 :b 2))
         "merge maps")
(test-is (= (merge (hash-map :a 1) (hash-map :a 2))
            (hash-map :a 2))
         "merge overwrite")

;; === keys / vals ===
(test-eq [:a] (keys (hash-map :a 1)) "keys single")
(test-eq [1] (vals (hash-map :a 1)) "vals single")

;; === select-keys ===
(test-is (= (select-keys (hash-map :a 1 :b 2 :c 3) [:a :c])
            (hash-map :a 1 :c 3))
         "select-keys")

;; === zipmap ===
(test-is (= (zipmap [:a :b :c] [1 2 3]) (hash-map :a 1 :b 2 :c 3)) "zipmap")

;; === frequencies ===
(test-is (= (frequencies [:a :b :a :c :b :a])
            (hash-map :a 3 :b 2 :c 1))
         "frequencies")

;; === group-by ===
(test-is (= (group-by even? [1 2 3 4 5])
            (hash-map true [2 4] false [1 3 5]))
         "group-by")

;; === vec / set / list* ===
(test-eq [1 2 3] (vec '(1 2 3)) "vec from list")
(test-is (= (hash-set 1 2 3) (set [1 2 3])) "set from vec")

;; === subvec ===
(test-eq [2 3] (subvec [1 2 3 4] 1 3) "subvec")

;; === flatten ===
(test-eq [1 2 3 4] (flatten [[1 2] [3 [4]]]) "flatten")

;; === distinct ===
(test-eq [1 2 3] (distinct [1 2 1 3 2]) "distinct")

;; === sort / sort-by ===
(test-eq [1 2 3 4 5] (sort [3 1 2 4 5]) "sort")
(test-eq [1 1 3 4 5] (sort [3 1 4 1 5]) "sort with dups")
(test-eq ["a" "bb" "ccc"] (sort-by count ["ccc" "a" "bb"]) "sort-by count")

;; === reverse ===
(test-eq '(3 2 1) (reverse [1 2 3]) "reverse")

;; === concat ===
(test-eq '(1 2 3 4) (concat [1 2] [3 4]) "concat")

;; === interleave / interpose ===
(test-eq '(1 :a 2 :b) (interleave [1 2] [:a :b]) "interleave")
(test-eq '(1 :sep 2 :sep 3) (interpose :sep [1 2 3]) "interpose")

;; === partition / partition-all ===
(test-eq '((1 2) (3 4)) (partition 2 [1 2 3 4]) "partition")
(test-eq '((1 2) (3 4) (5)) (partition-all 2 [1 2 3 4 5]) "partition-all")

;; === レポート ===
(println "[collections]")
(test-report)
