;; clojure_set.clj — clojure.set namespace テスト
(load-file "test/lib/test_runner.clj")
(require 'clojure.set)

(println "[clojure_set] running...")

;; === union ===
(test-eq #{1 2 3} (clojure.set/union #{1 2} #{2 3}) "union overlap")
(test-eq #{1 2 3 4} (clojure.set/union #{1 2} #{3 4}) "union disjoint")
(test-eq #{1 2} (clojure.set/union #{1 2}) "union single")
(test-eq #{} (clojure.set/union) "union empty")

;; === intersection ===
(test-eq #{2 3} (clojure.set/intersection #{1 2 3} #{2 3 4}) "intersection overlap")
(test-eq #{} (clojure.set/intersection #{1 2} #{3 4}) "intersection disjoint")
(test-eq #{1 2 3} (clojure.set/intersection #{1 2 3}) "intersection single")

;; === difference ===
(test-eq #{1} (clojure.set/difference #{1 2 3} #{2 3 4}) "difference")
(test-eq #{1 2 3} (clojure.set/difference #{1 2 3} #{4 5}) "difference no overlap")
(test-eq #{} (clojure.set/difference #{1 2} #{1 2 3}) "difference subset")

;; === subset? / superset? ===
(test-eq true (clojure.set/subset? #{1 2} #{1 2 3}) "subset? true")
(test-eq false (clojure.set/subset? #{1 2 3} #{1 2}) "subset? false")
(test-eq true (clojure.set/subset? #{} #{1 2}) "subset? empty")
(test-eq true (clojure.set/superset? #{1 2 3} #{1 2}) "superset? true")
(test-eq false (clojure.set/superset? #{1 2} #{1 2 3}) "superset? false")
(test-eq true (clojure.set/superset? #{1 2} #{}) "superset? empty")

;; === select ===
(test-eq #{1 3} (clojure.set/select odd? #{1 2 3 4}) "select odd")
(test-eq #{2 4} (clojure.set/select even? #{1 2 3 4}) "select even")

;; === rename-keys ===
(test-eq {:new-a 1 :b 2} (clojure.set/rename-keys {:a 1 :b 2} {:a :new-a}) "rename-keys")
(test-eq {:a 1 :b 2} (clojure.set/rename-keys {:a 1 :b 2} {:c :d}) "rename-keys no match")

;; === map-invert ===
(test-eq {1 :a 2 :b} (clojure.set/map-invert {:a 1 :b 2}) "map-invert")

;; === project ===
(test-eq #{{:a 1} {:a 2}} (clojure.set/project #{{:a 1 :b 2} {:a 2 :b 3}} [:a]) "project")

;; === rename ===
(test-eq #{{:new-a 1 :b 2}} (clojure.set/rename #{{:a 1 :b 2}} {:a :new-a}) "rename")

;; === index ===
(def test-data #{{:name "a" :age 1} {:name "b" :age 2}})
(def test-idx (clojure.set/index test-data [:name]))
(test-eq #{{:name "a" :age 1}} (get test-idx {:name "a"}) "index lookup")

(test-report)
