;; clojure.set — 集合操作関数
;;
;; 本家 Clojure の clojure.set 互換 NS。
;; builtin 関数をラップして標準的な名前で提供。

(ns clojure.set)

;; 基本集合演算
(defn union
  ([] (hash-set))
  ([s1] s1)
  ([s1 s2] (clojure.core/set-union s1 s2))
  ([s1 s2 & sets] (reduce clojure.core/set-union (clojure.core/set-union s1 s2) sets)))

(defn intersection
  ([s1] s1)
  ([s1 s2] (clojure.core/set-intersection s1 s2))
  ([s1 s2 & sets] (reduce clojure.core/set-intersection (clojure.core/set-intersection s1 s2) sets)))

(defn difference
  ([s1] s1)
  ([s1 s2] (clojure.core/set-difference s1 s2))
  ([s1 s2 & sets] (reduce clojure.core/set-difference (clojure.core/set-difference s1 s2) sets)))

;; 述語
(defn subset? [s1 s2] (clojure.core/set-subset? s1 s2))
(defn superset? [s1 s2] (clojure.core/set-superset? s1 s2))

;; フィルタ
(defn select [pred s] (clojure.core/set-select pred s))

;; マップユーティリティ
(defn rename-keys [m kmap] (clojure.core/set-rename-keys m kmap))
(defn map-invert [m] (clojure.core/set-map-invert m))

;; project : マップの集合から特定キーのみ抽出
(defn project [xrel ks]
  (reduce (fn [acc m] (conj acc (select-keys m ks))) #{} xrel))

;; rename : マップの集合のキーを変換
(defn rename [xrel kmap]
  (reduce (fn [acc m] (conj acc (clojure.core/set-rename-keys m kmap))) #{} xrel))

;; index : マップの集合をキーでインデックス化
(defn index [xrel ks]
  (reduce
   (fn [m x]
     (let [ik (select-keys x ks)]
       (assoc m ik (conj (get m ik #{}) x))))
   {}
   xrel))
