;; data-transform: マップ/ベクター操作
;; N個のマップを作成して変換
(println
 (count
  (map (fn [m] (assoc m :doubled (* 2 (:value m))))
       (map (fn [i] {:id i :value i})
            (range 10000)))))
