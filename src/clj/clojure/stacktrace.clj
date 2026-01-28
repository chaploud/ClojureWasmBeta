;; clojure.stacktrace — スタックトレースユーティリティ
;;
;; Java の StackTraceElement 系は JVM 固有のため、
;; 最小限のスタブ + 利用可能な機能を提供。

(ns clojure.stacktrace)

;; root-cause: 例外の根本原因を取得
;; JVM では getCause チェーンを辿るが、当実装では引数をそのまま返す
(defn root-cause
  [t]
  t)

;; print-throwable: 例外を出力
(defn print-throwable
  [tr]
  (when tr
    (println (str tr))))

;; print-stack-trace: 例外のスタックトレースを出力
;; JVM では StackTraceElement を表示するが、当実装では例外文字列のみ
(defn print-stack-trace
  ([tr] (print-stack-trace tr nil))
  ([tr n]
   (when tr
     (print-throwable tr))))

;; print-cause-trace: 原因チェーンを含むスタックトレース
(defn print-cause-trace
  ([tr] (print-cause-trace tr nil))
  ([tr n]
   (print-stack-trace (root-cause tr) n)))

;; e: 最新の例外を表示するユーティリティ
(defn e
  []
  (print-cause-trace *e))
