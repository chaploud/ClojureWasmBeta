;; clojure.data — データ差分
;;
;; diff 関数で2つのデータ構造を比較し、
;; [things-only-in-a things-only-in-b things-in-both] を返す。

(ns clojure.data)

(require 'clojure.set)

(declare diff)

(defn- diff-sequential
  [a b]
  (let [a-vec (vec a)
        b-vec (vec b)
        max-len (max (count a-vec) (count b-vec))
        only-a (atom [])
        only-b (atom [])
        both   (atom [])]
    (loop [i 0]
      (if (< i max-len)
        (let [av (if (< i (count a-vec)) (nth a-vec i) ::none)
              bv (if (< i (count b-vec)) (nth b-vec i) ::none)]
          (cond
            (= av bv)
            (do (swap! only-a conj nil)
                (swap! only-b conj nil)
                (swap! both conj av))

            (= av ::none)
            (do (swap! only-a conj nil)
                (swap! only-b conj bv)
                (swap! both conj nil))

            (= bv ::none)
            (do (swap! only-a conj av)
                (swap! only-b conj nil)
                (swap! both conj nil))

            :else
            (let [[sa sb sb2] (diff av bv)]
              (swap! only-a conj sa)
              (swap! only-b conj sb)
              (swap! both conj sb2)))
          (recur (inc i)))
        [(let [v @only-a] (if (every? nil? v) nil v))
         (let [v @only-b] (if (every? nil? v) nil v))
         (let [v @both]   (if (every? nil? v) nil v))]))))

(defn- diff-map
  [a b]
  (let [a-keys (set (keys a))
        b-keys (set (keys b))
        all-keys (clojure.set/union a-keys b-keys)
        only-a (atom {})
        only-b (atom {})
        both   (atom {})]
    (doseq [k all-keys]
      (let [in-a (contains? a k)
            in-b (contains? b k)]
        (cond
          (and in-a (not in-b))
          (swap! only-a assoc k (get a k))

          (and in-b (not in-a))
          (swap! only-b assoc k (get b k))

          :else
          (let [av (get a k)
                bv (get b k)]
            (if (= av bv)
              (swap! both assoc k av)
              (let [[sa sb sb2] (diff av bv)]
                (when (some? sa) (swap! only-a assoc k sa))
                (when (some? sb) (swap! only-b assoc k sb))
                (when (some? sb2) (swap! both assoc k sb2))))))))
    [(let [m @only-a] (if (empty? m) nil m))
     (let [m @only-b] (if (empty? m) nil m))
     (let [m @both]   (if (empty? m) nil m))]))

(defn- diff-set
  [a b]
  (let [only-a (clojure.set/difference a b)
        only-b (clojure.set/difference b a)
        both   (clojure.set/intersection a b)]
    [(if (empty? only-a) nil only-a)
     (if (empty? only-b) nil only-b)
     (if (empty? both) nil both)]))

(defn diff
  [a b]
  (cond
    (= a b)   [nil nil a]
    (and (nil? a) (nil? b)) [nil nil nil]
    (nil? a)  [nil b nil]
    (nil? b)  [a nil nil]
    (and (map? a) (map? b))               (diff-map a b)
    (and (set? a) (set? b))               (diff-set a b)
    (and (sequential? a) (sequential? b)) (diff-sequential a b)
    :else     [a b nil]))
