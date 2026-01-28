;; clojure.walk — データ構造走査関数
;;
;; 本家 Clojure の clojure.walk 互換 NS。
;; builtin 関数をラップして標準的な名前で提供。

(ns clojure.walk)

;; 基本 walk
(defn walk [inner outer form] (clojure.core/walk inner outer form))

;; ボトムアップ walk
(defn postwalk [f form] (clojure.core/postwalk f form))

;; トップダウン walk
(defn prewalk [f form] (clojure.core/prewalk f form))

;; postwalk-replace : 値の置換 (ボトムアップ)
(defn postwalk-replace [smap form]
  (postwalk (fn [x] (if (contains? smap x) (get smap x) x)) form))

;; prewalk-replace : 値の置換 (トップダウン)
(defn prewalk-replace [smap form]
  (prewalk (fn [x] (if (contains? smap x) (get smap x) x)) form))

;; keywordize-keys : マップのキーを全てキーワードに
(defn keywordize-keys [m]
  (postwalk
   (fn [x]
     (if (map? x)
       (reduce-kv
        (fn [acc k v] (assoc acc (if (string? k) (keyword k) k) v))
        {} x)
       x))
   m))

;; stringify-keys : マップのキーを全て文字列に
(defn stringify-keys [m]
  (postwalk
   (fn [x]
     (if (map? x)
       (reduce-kv
        (fn [acc k v] (assoc acc (if (keyword? k) (name k) (str k)) v))
        {} x)
       x))
   m))
