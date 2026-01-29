;; 05_wasm_host.clj — ホスト関数注入
;; デモ: CWD = プロジェクトルート (ClojureWasmBeta/) で実行

;; --- atom でキャプチャ ---
(def captured (atom []))

(defn my-print-i32 [n]
  (swap! captured conj n))

(defn my-print-str [ptr len]
  (swap! captured conj [ptr len]))

;; --- ホスト関数付きモジュールロード ---
(def imports-mod
  (wasm/load-module "test/wasm/fixtures/04_imports.wasm"
                    {:imports {"env" {"print_i32" my-print-i32
                                      "print_str" my-print-str}}}))

;; --- greet: Wasm から Clojure 関数を呼ぶ ---
(reset! captured [])
(wasm/invoke imports-mod "greet")
@captured
;; => [[0 16]]  (print_str が ptr=0, len=16 で呼ばれた)

;; --- compute_and_print: 計算結果を Clojure に返す ---
(reset! captured [])
(wasm/invoke imports-mod "compute_and_print" 3 7)
@captured
;; => [10]  (print_i32 が 10 で呼ばれた)

;; --- println 版: with-out-str でキャプチャ ---
(def print-mod
  (wasm/load-module "test/wasm/fixtures/04_imports.wasm"
                    {:imports {"env" {"print_i32" (fn [n] (println "wasm:" n))
                                      "print_str" (fn [p l] nil)}}}))

(with-out-str (wasm/invoke print-mod "compute_and_print" 5 3))
;; => "wasm: 8\n"

(println "05_wasm_host done.")
