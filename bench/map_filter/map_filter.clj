;; map-filter: HOF チェイン
;; (->> (range N) (filter odd?) (map #(* % %)) (take M) (reduce +))
(println (->> (range 100000)
              (filter odd?)
              (map (fn [x] (* x x)))
              (take 10000)
              (reduce +)))
