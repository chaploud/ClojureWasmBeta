;; clojure.string — 文字列操作関数
;;
;; 本家 Clojure の clojure.string 互換 NS。
;; builtin 関数をラップして標準的な名前で提供。

(ns clojure.string)

;; ケース変換
(defn upper-case [s] (clojure.core/upper-case s))
(defn lower-case [s] (clojure.core/lower-case s))
(defn capitalize [s] (clojure.core/capitalize s))

;; トリム
(defn trim [s] (clojure.core/trim s))
(defn triml [s] (clojure.core/triml s))
(defn trimr [s] (clojure.core/trimr s))

;; 述語
(defn blank? [s] (clojure.core/blank? s))
(defn starts-with? [s substr] (clojure.core/starts-with? s substr))
(defn ends-with? [s substr] (clojure.core/ends-with? s substr))
(defn includes? [s substr] (clojure.core/includes? s substr))

;; 検索
(defn index-of
  ([s value] (clojure.core/index-of s value))
  ([s value from-index] (clojure.core/index-of s value from-index)))

(defn last-index-of
  ([s value] (clojure.core/last-index-of s value))
  ([s value from-index] (clojure.core/last-index-of s value from-index)))

;; 置換
(defn replace [s match replacement] (clojure.core/string-replace s match replacement))
(defn replace-first [s match replacement] (clojure.core/string-replace-first s match replacement))

;; 分割・結合
(defn split [s re] (clojure.core/string-split s re))
(defn join
  ([coll] (clojure.core/string-join "" coll))
  ([separator coll] (clojure.core/string-join separator coll)))

;; 反転
(defn reverse [s] (clojure.core/string-reverse s))

;; 分割・改行
(defn split-lines [s] (clojure.core/split-lines s))
(defn trim-newline [s] (clojure.core/trim-newline s))

;; エスケープ
(defn escape [s cmap] (clojure.core/escape s cmap))

;; re-quote-replacement
(defn re-quote-replacement [replacement] (clojure.core/re-quote-replacement replacement))
