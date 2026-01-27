;; wasm_host.clj — ホスト関数注入テスト (Phase Lc)
(load-file "test/lib/test_runner.clj")

(println "[wasm_host] running...")

;; === ホスト関数の準備 ===

;; print_i32 の出力をキャプチャ用 atom に蓄積
(def captured (atom []))

(defn my-print-i32 [n]
  (swap! captured conj n))

;; print_str: ptr と len を受け取る（メモリ読み出しは省略、引数をキャプチャ）
(defn my-print-str [ptr len]
  (swap! captured conj [ptr len]))

;; === モジュールロード（ホスト関数付き） ===
(def imports-mod
  (wasm/load-module "test/wasm/fixtures/04_imports.wasm"
                    {:imports {"env" {"print_i32" my-print-i32
                                      "print_str" my-print-str}}}))

(test-is (wasm/module? imports-mod) "module loaded with imports")

;; === greet 呼び出し: print_str(0, 16) を呼ぶ ===
(reset! captured [])
(wasm/invoke imports-mod "greet")
(test-is (= [[0 16]] @captured) "greet calls print_str(0, 16)")

;; === compute_and_print 呼び出し: print_i32(x+y) を呼ぶ ===
(reset! captured [])
(wasm/invoke imports-mod "compute_and_print" 3 7)
(test-is (= [10] @captured) "compute_and_print(3,7) calls print_i32(10)")

(reset! captured [])
(wasm/invoke imports-mod "compute_and_print" 100 200)
(test-is (= [300] @captured) "compute_and_print(100,200) calls print_i32(300)")

;; === with-out-str でホスト関数の println をキャプチャ ===
(def print-mod
  (wasm/load-module "test/wasm/fixtures/04_imports.wasm"
                    {:imports {"env" {"print_i32" (fn [n] (println "wasm:" n))
                                      "print_str" (fn [p l] nil)}}}))

(def output (with-out-str (wasm/invoke print-mod "compute_and_print" 5 3)))
(test-is (= "wasm: 8\n" output) "host fn println captured by with-out-str")

(println "[wasm_host]")
(test-report)
