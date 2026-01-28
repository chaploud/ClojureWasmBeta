;; string-ops: 文字列操作
;; N回の upper-case + 結合 (apply str = StringBuilder 相当)
(require '[clojure.string :as str])
(println
 (count
  (apply str
         (map #(str/upper-case (str "item-" %))
              (range 10000)))))
