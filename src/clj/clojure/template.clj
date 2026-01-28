;; clojure.template — テンプレートマクロユーティリティ
;;
;; apply-template と do-template を提供。
;; マクロで繰り返しコードを生成するためのユーティリティ。

(ns clojure.template)

(require 'clojure.walk)

;; apply-template: テンプレート内のシンボルを値で置換
;; argv = 仮引数シンボルのベクター
;; expr = テンプレート式
;; values = 実引数のベクター
;; 戻り値: 置換後の式
(defn apply-template
  [argv expr values]
  (let [bindings (zipmap argv values)]
    (clojure.walk/prewalk
     (fn [x]
       (if (contains? bindings x)
         (get bindings x)
         x))
     expr)))

;; do-template: テンプレートを繰り返し展開
;; 本家 Clojure では (do-template [x] (println x) 1 2 3) の形式だが、
;; 当実装の制限 (マクロ可変長引数が1要素のみ) のため、
;; 関数として提供: (do-template [x] '(println x) [1 2 3])
;; → (do (println 1) (println 2) (println 3)) を eval する
(defn do-template
  [argv expr values]
  (let [argc (count argv)
        groups (partition argc values)]
    (doseq [group groups]
      (eval (apply-template argv expr (vec group))))))
