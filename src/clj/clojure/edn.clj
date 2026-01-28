;; clojure.edn — EDN データリーダー
;;
;; 本家 Clojure の clojure.edn 互換 NS。
;; read-string は clojure.core/read-string のラッパー。
;; (#= 評価リーダーマクロ未実装のため、既にEDN安全)

(ns clojure.edn)

(defn read-string
  "Reads one object from the string s.
   Returns nil when s is nil or empty."
  [s]
  (clojure.core/read-string s))
