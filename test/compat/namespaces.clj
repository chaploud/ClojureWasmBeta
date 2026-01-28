;; namespaces.clj — 名前空間テスト
(load-file "test/lib/test_runner.clj")

(println "[namespaces] running...")

;; === all-ns ===

(test-is (seq? (all-ns)) "all-ns returns sequence")
(test-is (> (count (all-ns)) 0) "all-ns returns non-empty")

;; === find-ns ===

(test-is (not (nil? (find-ns 'clojure.core))) "find-ns clojure.core exists")
(test-is (nil? (find-ns 'nonexistent.ns)) "find-ns nonexistent returns nil")

;; === create-ns ===

(create-ns 'test.created)
(test-is (not (nil? (find-ns 'test.created))) "create-ns creates namespace")

;; === the-ns ===

(test-is (not (nil? (the-ns 'clojure.core))) "the-ns returns namespace")

;; === ns-resolve ===

(test-is (not (nil? (ns-resolve 'clojure.core '+))) "ns-resolve finds + in clojure.core")
(test-is (nil? (ns-resolve 'clojure.core 'nonexistent-fn-xyz)) "ns-resolve nil for missing")

;; === resolve ===

(test-is (not (nil? (resolve '+))) "resolve finds + in current context")

;; === in-ns (基本) ===
;; in-ns で新 NS を作り、そこで def して、元に戻って確認

(in-ns 'test.ns-basic)
(def ns-basic-val 42)
;; テストマクロは test.lib.test-runner にあるので戻る
(in-ns 'test.lib.test-runner)

;; 新 NS に変数が定義されたか確認
(test-is (not (nil? (find-ns 'test.ns-basic))) "in-ns creates namespace")
(test-is (not (nil? (ns-resolve 'test.ns-basic 'ns-basic-val))) "in-ns: def creates var in new ns")

;; === ns-publics ===

(in-ns 'test.pub-test)
(def pub-var-a 1)
(def pub-var-b 2)
(in-ns 'test.lib.test-runner)

(let [publics (ns-publics 'test.pub-test)]
  (test-is (map? publics) "ns-publics returns map")
  (test-is (contains? publics 'pub-var-a) "ns-publics contains pub-var-a")
  (test-is (contains? publics 'pub-var-b) "ns-publics contains pub-var-b"))

;; === alias ===

(alias 'cc 'clojure.core)
(test-is (map? (ns-aliases 'test.lib.test-runner)) "ns-aliases returns map")

;; === ns-name ===

(test-is (= 'clojure.core (ns-name (the-ns 'clojure.core))) "ns-name of clojure.core")

;; === remove-ns ===

(create-ns 'test.to-remove)
(test-is (not (nil? (find-ns 'test.to-remove))) "remove-ns: ns exists before")
(remove-ns 'test.to-remove)
(test-is (nil? (find-ns 'test.to-remove)) "remove-ns: ns removed")

;; === レポート ===
(println "[namespaces]")
(test-report)
