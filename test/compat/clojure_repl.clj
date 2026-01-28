;; clojure_repl.clj — clojure.repl namespace テスト
(load-file "test/lib/test_runner.clj")
(require 'clojure.repl)

(println "[clojure_repl] running...")

;; === require が成功すること ===
(test-is (some? (find-ns 'clojure.repl)) "clojure.repl NS exists")

;; === find-doc は関数として呼び出し可能 ===
;; (find-doc は stdout に出力するため、戻り値は nil)
(test-eq nil (clojure.repl/find-doc "NO_SUCH_PATTERN_XYZ_12345") "find-doc returns nil")

;; === apropos は関数として呼び出し可能 ===
(test-eq nil (clojure.repl/apropos "NO_SUCH_PATTERN_XYZ_12345") "apropos returns nil")

;; === source-fn はスタブで nil を返す ===
(test-eq nil (clojure.repl/source-fn 'map) "source-fn returns nil (stub)")

;; === demunge はそのまま返す ===
(test-eq "foo" (clojure.repl/demunge "foo") "demunge returns input")
(test-eq "bar$baz" (clojure.repl/demunge "bar$baz") "demunge identity")

;; === root-cause はそのまま返す ===
(test-eq "error" (clojure.repl/root-cause "error") "root-cause returns input")
(test-eq nil (clojure.repl/root-cause nil) "root-cause nil")

;; === pst は例外なしでも動作 ===
;; pst は stdout に出力するため、エラーにならないことを確認
(test-is (do (clojure.repl/pst nil) true) "pst nil doesn't throw")

(test-report)
