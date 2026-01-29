;; 04_wasm.clj — Wasm 連携 (基本 + ホスト関数)
;; デモ: CWD = プロジェクトルート (ClojureWasmBeta/) で実行

;; ============================================================
;; Part 1: 基本連携 — Wasm モジュールのロードと関数呼び出し
;; ============================================================

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

;; ============================================================
;; Part 2: ホスト関数注入 — Clojure 関数を Wasm にエクスポート
;; ============================================================

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
                                      "print_str" (fn [_ _] nil)}}}))

(with-out-str (wasm/invoke print-mod "compute_and_print" 5 3))
;; => "wasm: 8\n"

(println "04_wasm done.")
