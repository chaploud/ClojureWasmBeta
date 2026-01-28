;; clojure_edn.clj — clojure.edn namespace テスト
(load-file "test/lib/test_runner.clj")
(require 'clojure.edn)

(println "[clojure_edn] running...")

;; === read-string 基本 ===
(test-eq {:a 1 :b 2} (clojure.edn/read-string "{:a 1 :b 2}") "read-string map")
(test-eq [1 2 3] (clojure.edn/read-string "[1 2 3]") "read-string vector")
(test-eq '(+ 1 2) (clojure.edn/read-string "(+ 1 2)") "read-string list")
(test-eq #{:a :b} (clojure.edn/read-string "#{:a :b}") "read-string set")
(test-eq "hello" (clojure.edn/read-string "\"hello\"") "read-string string")
(test-eq 42 (clojure.edn/read-string "42") "read-string number")
(test-eq :foo (clojure.edn/read-string ":foo") "read-string keyword")
(test-eq true (clojure.edn/read-string "true") "read-string true")
(test-eq nil (clojure.edn/read-string "nil") "read-string nil")

(test-report)
