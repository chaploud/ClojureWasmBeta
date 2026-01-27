;; atoms.clj — Atom 状態管理テスト
(load-file "test/lib/test_runner.clj")

(println "[atoms] running...")

;; === atom / deref / reset! / swap! ===
(test-eq 0 (deref (atom 0)) "atom deref")
(test-eq 0 @(atom 0) "atom @")

(let [a (atom 0)]
  (reset! a 42)
  (test-eq 42 @a "reset!"))

(let [a (atom 0)]
  (swap! a inc)
  (test-eq 1 @a "swap! inc"))

(let [a (atom 0)]
  (swap! a + 10)
  (test-eq 10 @a "swap! + 10"))

(let [a (atom [1 2 3])]
  (swap! a conj 4)
  (test-eq [1 2 3 4] @a "swap! conj"))

;; === atom with map ===
(let [state (atom (hash-map :count 0 :name "test"))]
  (swap! state assoc :count 1)
  (test-eq 1 (:count @state) "swap! assoc map")
  ;; update は特殊形式のため swap! に直接渡せない — ラッパー fn で使用
  (swap! state (fn [m] (update m :count inc)))
  (test-eq 2 (:count @state) "swap! update map via fn"))

;; === memoize ===
(let [calls (atom 0)
      f (memoize (fn [x] (swap! calls inc) (* x x)))]
  (test-eq 9 (f 3) "memoize first call")
  (test-eq 9 (f 3) "memoize cached")
  (test-eq 1 @calls "memoize only called once")
  (test-eq 16 (f 4) "memoize different arg")
  (test-eq 2 @calls "memoize two distinct calls"))

;; === memoize multi-arity ===
(let [calls (atom 0)
      f (memoize (fn [a b] (swap! calls inc) (+ a b)))]
  (test-eq 3 (f 1 2) "memoize multi first")
  (test-eq 3 (f 1 2) "memoize multi cached")
  (test-eq 7 (f 3 4) "memoize multi different")
  (test-eq 2 @calls "memoize multi call count"))

;; === atom compare-and-set! ===
(let [a (atom 0)]
  (test-is (compare-and-set! a 0 1) "cas success")
  (test-eq 1 @a "cas value after success")
  (test-is (not (compare-and-set! a 0 2)) "cas fail")
  (test-eq 1 @a "cas value after fail"))

;; === swap-vals! / reset-vals! ===
(let [a (atom 0)]
  (test-eq [0 1] (swap-vals! a inc) "swap-vals!")
  (test-eq 1 @a "swap-vals! current"))

(let [a (atom 0)]
  (test-eq [0 42] (reset-vals! a 42) "reset-vals!")
  (test-eq 42 @a "reset-vals! current"))

;; === volatile ===
(let [v (volatile! 0)]
  (test-eq 0 @v "volatile deref")
  (vreset! v 42)
  (test-eq 42 @v "vreset!")
  (vswap! v inc)
  (test-eq 43 @v "vswap!"))

;; === delay / force ===
(let [calls (atom 0)
      d (delay (do (swap! calls inc) 42))]
  (test-is (not (realized? d)) "delay not realized")
  (test-eq 42 (force d) "force delay")
  (test-is (realized? d) "delay realized after force")
  (test-eq 42 @d "delay deref")
  (test-eq 1 @calls "delay only evaluated once"))

;; === レポート ===
(println "[atoms]")
(test-report)
