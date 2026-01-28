;; clojure_stacktrace.clj — clojure.stacktrace namespace テスト
(load-file "test/lib/test_runner.clj")
(require 'clojure.stacktrace)

(println "[clojure_stacktrace] running...")

;; === require が成功すること ===
(test-is (some? (find-ns 'clojure.stacktrace)) "clojure.stacktrace NS exists")

;; === root-cause ===
(test-eq "error" (clojure.stacktrace/root-cause "error") "root-cause returns input")
(test-eq nil (clojure.stacktrace/root-cause nil) "root-cause nil")

;; === print-throwable は例外を出力 (stdout) ===
(test-is (do (clojure.stacktrace/print-throwable "test-error") true) "print-throwable doesn't throw")
(test-is (do (clojure.stacktrace/print-throwable nil) true) "print-throwable nil doesn't throw")

;; === print-stack-trace ===
(test-is (do (clojure.stacktrace/print-stack-trace "err") true) "print-stack-trace 1-arity")
(test-is (do (clojure.stacktrace/print-stack-trace "err" 5) true) "print-stack-trace 2-arity")
(test-is (do (clojure.stacktrace/print-stack-trace nil) true) "print-stack-trace nil")

;; === print-cause-trace ===
(test-is (do (clojure.stacktrace/print-cause-trace "err") true) "print-cause-trace 1-arity")
(test-is (do (clojure.stacktrace/print-cause-trace "err" 5) true) "print-cause-trace 2-arity")

;; === e ===
(test-is (do (clojure.stacktrace/e) true) "e doesn't throw")

(test-report)
