;; string-ops: 文字列操作
;; N回の文字列結合 + 変換
(require '[clojure.string :as str])
(println
 (count
  (reduce str
          (map #(str/upper-case (str "item-" %))
               (range 10000)))))
