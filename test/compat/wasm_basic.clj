;; wasm_basic.clj — Wasm 基本テスト (Phase La)
(load-file "test/lib/test_runner.clj")

(println "[wasm_basic] running...")

;; === wasm/load-module ===
(def math (wasm/load-module "test/wasm/fixtures/01_add.wasm"))
(test-is (wasm/module? math) "load-module returns wasm-module")

;; === wasm/module? ===
(test-is (not (wasm/module? 42)) "module? int -> false")
(test-is (not (wasm/module? nil)) "module? nil -> false")
(test-is (not (wasm/module? "hello")) "module? string -> false")

;; === wasm/invoke (add) ===
(test-is (= 7 (wasm/invoke math "add" 3 4)) "invoke add 3 4 = 7")
(test-is (= 0 (wasm/invoke math "add" 0 0)) "invoke add 0 0 = 0")
(test-is (= -1 (wasm/invoke math "add" 1 -2)) "invoke add 1 -2 = -1")

;; === wasm/invoke (fibonacci) ===
(def fib-mod (wasm/load-module "test/wasm/fixtures/02_fibonacci.wasm"))
(test-is (= 1 (wasm/invoke fib-mod "fib" 1)) "fib 1 = 1")
(test-is (= 5 (wasm/invoke fib-mod "fib" 5)) "fib 5 = 5")
(test-is (= 55 (wasm/invoke fib-mod "fib" 10)) "fib 10 = 55")

;; === wasm/exports ===
(def exports (wasm/exports math))
(test-is (map? exports) "exports returns map")

;; === type ===
(test-is (= "wasm-module" (type math)) "type returns wasm-module")

(println "[wasm_basic]")
(test-report)
