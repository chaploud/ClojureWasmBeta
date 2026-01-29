;; 05_go_wasm.clj — Go → Wasm → ClojureWasm (多言語連携)
;; デモ: CWD = プロジェクトルート (ClojureWasmBeta/) で実行

;; --- Go のコードをコンパイルした Wasm をロード ---
;; TinyGo で test/wasm/src/go_math.go をコンパイル:
;;   tinygo build -o test/wasm/fixtures/08_go_math.wasm -target=wasi -no-debug test/wasm/src/go_math.go
(def go-math (wasm/load-wasi "test/wasm/fixtures/08_go_math.wasm"))

;; --- Go 関数を Clojure から呼び出し ---
(wasm/invoke go-math "add" 3 4)       ;; => 7
(wasm/invoke go-math "multiply" 6 7)  ;; => 42
(wasm/invoke go-math "fibonacci" 10)  ;; => 55

;; --- 組み合わせ: Clojure の高階関数で Go 関数を活用 ---
(map #(wasm/invoke go-math "fibonacci" %) (range 1 11))
;; => (1 1 2 3 5 8 13 21 34 55)

(reduce + (map #(wasm/invoke go-math "multiply" % %) (range 1 6)))
;; => 55  (1 + 4 + 9 + 16 + 25)

(println "05_go_wasm done.")
