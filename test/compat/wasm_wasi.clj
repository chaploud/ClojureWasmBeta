;; wasm_wasi.clj — WASI 基本サポートテスト (Phase Ld)
(load-file "test/lib/test_runner.clj")

(println "[wasm_wasi] running...")

;; === WASI モジュールのロード ===
(def wasi-mod (wasm/load-wasi "test/wasm/fixtures/07_wasi_hello.wasm"))
(test-is (wasm/module? wasi-mod) "WASI module loaded")

;; === _start 呼び出し（正常終了を確認）===
;; 注: WASI fd_write はシステムコール経由のため with-out-str ではキャプチャ不可
(wasm/invoke wasi-mod "_start")
(test-is true "_start executed without error")

;; === エクスポート確認 ===
(def exps (wasm/exports wasi-mod))
(test-is (= :func (:type (:_start exps))) "_start is func export")
(test-is (= :memory (:type (:memory exps))) "memory is memory export")

(println "[wasm_wasi]")
(test-report)
