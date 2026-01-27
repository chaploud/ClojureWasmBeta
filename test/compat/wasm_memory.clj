;; wasm_memory.clj — Wasm メモリ操作テスト (Phase Lb)
(load-file "test/lib/test_runner.clj")

(println "[wasm_memory] running...")

;; 03_memory.wasm: store(offset, value), load(offset), sum_range(start, count)
(def mem-mod (wasm/load-module "test/wasm/fixtures/03_memory.wasm"))

;; === wasm/invoke による i32 メモリ書き込み/読み出し ===
(wasm/invoke mem-mod "store" 0 42)
(test-is (= 42 (wasm/invoke mem-mod "load" 0)) "store/load offset 0")

(wasm/invoke mem-mod "store" 4 100)
(test-is (= 100 (wasm/invoke mem-mod "load" 4)) "store/load offset 4")

;; sum_range: offset 0 から 2 つの i32 を合計
(test-is (= 142 (wasm/invoke mem-mod "sum_range" 0 2)) "sum_range 0 2 = 142")

;; === wasm/memory-size ===
(test-is (= 65536 (wasm/memory-size mem-mod)) "memory-size = 65536 (1 page)")

;; === wasm/memory-write + wasm/memory-read (文字列 round-trip) ===
(wasm/memory-write mem-mod 256 "Hello, Wasm!")
(test-is (= "Hello, Wasm!" (wasm/memory-read mem-mod 256 12)) "string round-trip")

;; 日本語文字列
(wasm/memory-write mem-mod 512 "こんにちは")
(test-is (= "こんにちは" (wasm/memory-read mem-mod 512 15)) "UTF-8 round-trip")

;; 空文字列
(wasm/memory-write mem-mod 1024 "")
(test-is (= "" (wasm/memory-read mem-mod 1024 0)) "empty string round-trip")

(println "[wasm_memory]")
(test-report)
