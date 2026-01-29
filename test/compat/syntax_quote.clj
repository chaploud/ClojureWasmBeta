;; syntax_quote.clj — syntax-quote / unquote / unquote-splicing / auto-gensym テスト
(load-file "test/lib/test_runner.clj")

(println "[syntax_quote] running...")

;; === Level 1: リテラル・シンボル ===
(test-eq 42 `42 "sq literal int")
(test-eq 3.14 `3.14 "sq literal float")
(test-eq "hello" `"hello" "sq literal string")
(test-eq :foo `:foo "sq literal keyword")
(test-eq nil `nil "sq literal nil")
(test-eq true `true "sq literal true")
(test-eq false `false "sq literal false")
(test-eq 'foo `foo "sq symbol")

;; === Level 2: unquote ===
(let [x 42] (test-eq 42 `~x "sq unquote"))
(let [x 1] (test-eq '(1 2) `(~x 2) "sq unquote in list"))
(let [x "hi"] (test-eq '("hi" :a) `(~x :a) "sq unquote string"))

;; === Level 3: unquote-splicing ===
(let [xs [2 3]] (test-eq '(1 2 3) `(1 ~@xs) "sq splice"))
(let [xs []] (test-eq '(1) `(1 ~@xs) "sq splice empty"))
(let [xs [2 3 4]] (test-eq '(1 2 3 4 5) `(1 ~@xs 5) "sq splice middle"))

;; === Level 4: コレクション ===
(let [x 1] (test-eq [1 2] `[~x 2] "sq vector"))
(let [x 1] (test-eq {:a 1} `{:a ~x} "sq map"))
(let [x 1] (test-eq #{1 2 3} `#{~x 2 3} "sq set"))

;; === Level 5: ネストされた unquote ===
(let [x 1 y 2]
  (test-eq '(1 (2 3)) `(~x (~y 3)) "sq nested unquote"))

;; === Level 6: defmacro 統合 ===
(defmacro my-when [test & body]
  `(if ~test (do ~@body) nil))
(test-eq 42 (my-when true 42) "my-when true")
(test-eq nil (my-when false 42) "my-when false")

(defmacro my-unless [test & body]
  `(if ~test nil (do ~@body)))
(test-eq nil (my-unless true 42) "my-unless true")
(test-eq 42 (my-unless false 42) "my-unless false")

;; 複数式の body
(defmacro my-do-when [test & body]
  `(if ~test (do ~@body) nil))
(test-eq 3 (my-do-when true 1 2 3) "my-do-when multi body")

;; === Level 7: auto-gensym ===
(defmacro my-let1 [expr & body]
  `(let [v# ~expr] v#))
(test-eq 42 (my-let1 42) "auto-gensym basic")
(test-eq "hello" (my-let1 "hello") "auto-gensym string")

;; 同じ syntax-quote 内の同名 gensym は同じシンボルに展開される
(defmacro my-twice [expr]
  `(+ v# v#))  ;; 同じ v# が同じ gensym になることを確認（v# は未束縛だがパース確認）

;; 異なる syntax-quote 呼び出しでは異なる gensym になることを間接確認
(defmacro my-add-one [expr]
  `(let [tmp# ~expr] (+ tmp# 1)))
(test-eq 43 (my-add-one 42) "auto-gensym in macro")

;; === Level 8: syntax-quote of empty collections ===
;; `() → (seq (concat)) → nil （Clojure と同じ挙動）
(test-eq nil `() "sq empty list")
(test-eq [] `[] "sq empty vector")
(test-eq {} `{} "sq empty map")

(println "[syntax_quote]")
(test-report)
