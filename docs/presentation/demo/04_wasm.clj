;; 04_wasm.clj — Wasm 基本連携
;; デモ: CWD = プロジェクトルート (ClojureWasmBeta/) で実行

;; --- モジュールロード ---
(def math (wasm/load-module "test/wasm/fixtures/01_add.wasm"))
(println "loaded:" math)
;; => loaded: #<wasm-module>

;; --- 関数呼び出し (add) ---
(wasm/invoke math "add" 3 4)
;; => 7

(wasm/invoke math "add" 100 200)
;; => 300

;; --- fibonacci ---
(def fib-mod (wasm/load-module "test/wasm/fixtures/02_fibonacci.wasm"))

(wasm/invoke fib-mod "fib" 10)
;; => 55

(wasm/invoke fib-mod "fib" 20)
;; => 6765

;; --- メモリ操作 ---
(def mem-mod (wasm/load-module "test/wasm/fixtures/03_memory.wasm"))

;; i32 store/load
(wasm/invoke mem-mod "store" 0 42)
(wasm/invoke mem-mod "load" 0)
;; => 42

;; 文字列の書き込み/読み出し
(wasm/memory-write mem-mod 256 "Hello, Wasm!")
(wasm/memory-read mem-mod 256 12)
;; => "Hello, Wasm!"

;; 日本語もOK (UTF-8)
(wasm/memory-write mem-mod 512 "こんにちは")
(wasm/memory-read mem-mod 512 15)
;; => "こんにちは"

;; --- exports 一覧 ---
(wasm/exports math)

;; --- close ---
(wasm/close math)
(wasm/closed? math)
;; => true

(println "04_wasm done.")
