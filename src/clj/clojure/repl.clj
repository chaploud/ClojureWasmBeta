;; clojure.repl — REPL ユーティリティ
;;
;; doc, dir, find-doc, apropos は clojure.core にて実装済み。
;; clojure.repl として require 可能にするためのラッパー NS。

(ns clojure.repl)

;; === ドキュメント閲覧 ===
;; doc, dir はマクロとして clojure.core に実装済み（analyze.zig 展開）。
;; clojure.repl/doc のような修飾呼び出しには対応しないが、
;; (require 'clojure.repl) 後に (doc ...) (dir ...) は常にグローバルで動作。

;; find-doc: clojure.core/find-doc を委譲
(defn find-doc
  [re-string-or-pattern]
  (clojure.core/find-doc re-string-or-pattern))

;; apropos: clojure.core/apropos を委譲
(defn apropos
  [str-or-pattern]
  (clojure.core/apropos str-or-pattern))

;; === source (スタブ) ===
;; ソースコード表示。ソーステキスト保持は未実装のため nil を返す。
(defn source-fn
  [x]
  nil)

;; source はマクロとして提供（本家互換）
;; 本来は (source fn-name) → ソース文字列を表示
;; 現状はスタブ: "Source not available" を表示
(defmacro source
  [n]
  (list 'if-let ['s (list 'clojure.repl/source-fn (list 'quote n))]
        (list 'println 's)
        (list 'println "Source not available")))

;; === pst: 最新例外のスタックトレース表示 ===
;; *e に束縛された最新例外を表示
(defn pst
  ([] (pst *e))
  ([e]
   (if e
     (println (str e))
     (println "No exception found"))))

;; === demunge (Java 固有 — スタブ) ===
(defn demunge
  [fn-name]
  (str fn-name))

;; === root-cause ===
(defn root-cause
  [t]
  t)
