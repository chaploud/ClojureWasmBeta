;; clojure.zip テスト
(load-file "test/lib/test_runner.clj")
(require 'clojure.zip)

;; === vector-zip 基本テスト ===
(def data [[1 2] [3 [4 5]]])
(def dz (clojure.zip/vector-zip data))

(test-eq [[1 2] [3 [4 5]]] (clojure.zip/node dz) "vector-zip node")
(test-is (clojure.zip/branch? dz) "vector-zip branch?")
(test-eq (list [1 2] [3 [4 5]]) (clojure.zip/children dz) "vector-zip children")

;; === ナビゲーション: down/right/left ===
(def d1 (clojure.zip/down dz))
(test-eq [1 2] (clojure.zip/node d1) "down node")

(def r1 (clojure.zip/right d1))
(test-eq [3 [4 5]] (clojure.zip/node r1) "right node")

(def l1 (clojure.zip/left r1))
(test-eq [1 2] (clojure.zip/node l1) "left node")

;; down の子がないケース
(def d2 (clojure.zip/down d1))
(test-eq 1 (clojure.zip/node d2) "down into [1 2]")
(test-eq nil (clojure.zip/down d2) "down leaf nil")

;; === up ===
(test-eq [[1 2] [3 [4 5]]] (clojure.zip/node (clojure.zip/up d1)) "up from down")

;; === leftmost / rightmost ===
(test-eq [1 2] (clojure.zip/node (clojure.zip/leftmost r1)) "leftmost node")
(test-eq [3 [4 5]] (clojure.zip/node (clojure.zip/rightmost d1)) "rightmost node")

;; === root ===
(test-eq [[1 2] [3 [4 5]]] (clojure.zip/root dz) "root from root")
(test-eq [[1 2] [3 [4 5]]] (clojure.zip/root d1) "root from child")
(test-eq [[1 2] [3 [4 5]]] (clojure.zip/root d2) "root from deep")

;; === path / lefts / rights ===
(test-eq nil (clojure.zip/path dz) "path at root")
(test-eq (list [[1 2] [3 [4 5]]]) (clojure.zip/path d1) "path at d1")

(test-eq nil (clojure.zip/lefts d1) "lefts at leftmost")
(test-eq (list [1 2]) (clojure.zip/lefts r1) "lefts at r1")

(test-eq nil (clojure.zip/rights r1) "rights at r1")

;; === replace ===
(def rep (clojure.zip/replace d1 [10 20]))
(test-eq [10 20] (clojure.zip/node rep) "replace node")
(test-eq [[10 20] [3 [4 5]]] (clojure.zip/root rep) "replace root")

;; === edit ===
(def ed (clojure.zip/edit d2 inc))
(test-eq 2 (clojure.zip/node ed) "edit node")
(test-eq [[2 2] [3 [4 5]]] (clojure.zip/root ed) "edit root")

;; === insert-left / insert-right ===
(def il (clojure.zip/insert-left d1 [0 0]))
(test-eq [[0 0] [1 2] [3 [4 5]]] (clojure.zip/root il) "insert-left root")

(def ir (clojure.zip/insert-right d1 [99]))
(test-eq [[1 2] [99] [3 [4 5]]] (clojure.zip/root ir) "insert-right root")

;; === insert-child / append-child ===
(def ic (clojure.zip/insert-child dz [0]))
(test-eq [[0] [1 2] [3 [4 5]]] (clojure.zip/root ic) "insert-child root")

(def ac (clojure.zip/append-child dz [9 9]))
(test-eq [[1 2] [3 [4 5]] [9 9]] (clojure.zip/root ac) "append-child root")

;; === next / end? による走査 ===
(def simple (clojure.zip/vector-zip [1 [2 3]]))
(defn collect-nodes [root-zip]
  (loop [loc root-zip
         nodes []]
    (if (clojure.zip/end? loc)
      nodes
      (recur (clojure.zip/next loc) (conj nodes (clojure.zip/node loc))))))
(test-eq [[1 [2 3]] 1 [2 3] 2 3] (collect-nodes simple) "next traversal")

;; === remove ===
(def rem-data (clojure.zip/vector-zip [1 2 3]))
(def rem-d (clojure.zip/down rem-data))
(def rem-r (clojure.zip/right rem-d))
(def removed (clojure.zip/remove rem-r))
(test-eq [1 3] (clojure.zip/root removed) "remove root")

;; === prev ===
(def p-data (clojure.zip/vector-zip [1 [2 3]]))
(def p-next (clojure.zip/next (clojure.zip/next p-data)))
(test-eq 1 (clojure.zip/node (clojure.zip/prev p-next)) "prev to previous")

;; === seq-zip ===
(def sz (clojure.zip/seq-zip (list 1 (list 2 3))))
(test-eq (list 1 (list 2 3)) (clojure.zip/node sz) "seq-zip node")
(test-is (clojure.zip/branch? sz) "seq-zip branch?")
(def sz-d (clojure.zip/down sz))
(test-eq 1 (clojure.zip/node sz-d) "seq-zip down")

;; === zipper で深さ優先編集（全要素をインクリメント） ===
(def edit-data (clojure.zip/vector-zip [1 [2 [3]]]))
(defn inc-all [z]
  (loop [loc z]
    (if (clojure.zip/end? loc)
      (clojure.zip/root loc)
      (recur (clojure.zip/next
              (if (clojure.zip/branch? loc)
                loc
                (clojure.zip/edit loc inc)))))))
(test-eq [2 [3 [4]]] (inc-all edit-data) "edit-all inc")

;; === 結果 ===
(test-report)
