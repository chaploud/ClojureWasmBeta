;; watches.clj — add-watch / remove-watch テスト (Atom + Var)
(load-file "test/lib/test_runner.clj")

(println "[watches] running...")

;; === Atom: reset! でウォッチャー発火 ===
(def log1 (atom []))
(def a1 (atom 0))
(add-watch a1 :w1
           (fn [k ref old-val new-val]
             (swap! log1 conj [k old-val new-val])))
(reset! a1 10)
(reset! a1 20)
(test-eq [[:w1 0 10] [:w1 10 20]] @log1 "atom reset! fires watcher")
(test-eq 20 @a1 "atom value after reset!")

;; === Atom: remove-watch で停止 ===
(remove-watch a1 :w1)
(reset! a1 30)
(test-eq [[:w1 0 10] [:w1 10 20]] @log1 "watcher not fired after remove-watch")

;; === Atom: swap! でウォッチャー発火 ===
(def log2 (atom []))
(def a2 (atom 0))
(add-watch a2 :w2
           (fn [k ref old-val new-val]
             (swap! log2 conj [old-val new-val])))
(swap! a2 inc)
(swap! a2 + 5)
(test-eq [[0 1] [1 6]] @log2 "atom swap! fires watcher")

;; === Var: alter-var-root でウォッチャー発火 ===
(def ^:dynamic *counter* 0)
(def var-log (atom []))
(add-watch #'*counter* :vw
           (fn [k ref old-val new-val]
             (swap! var-log conj [old-val new-val])))
(alter-var-root #'*counter* (fn [v] (+ v 100)))
(test-eq [[0 100]] @var-log "var alter-var-root fires watcher")
(test-eq 100 *counter* "var value after alter-var-root")

;; === Var: remove-watch で停止 ===
(remove-watch #'*counter* :vw)
(alter-var-root #'*counter* (fn [v] (+ v 200)))
(test-eq [[0 100]] @var-log "var watcher not fired after remove-watch")
(test-eq 300 *counter* "var value after second alter-var-root")

;; === Atom: 複数ウォッチャー ===
(def log-a (atom []))
(def log-b (atom []))
(def a3 (atom 0))
(add-watch a3 :wa (fn [k r o n] (swap! log-a conj n)))
(add-watch a3 :wb (fn [k r o n] (swap! log-b conj n)))
(reset! a3 42)
(test-eq [42] @log-a "multiple watchers: first fires")
(test-eq [42] @log-b "multiple watchers: second fires")

;; 片方だけ除去
(remove-watch a3 :wa)
(reset! a3 99)
(test-eq [42] @log-a "removed watcher stays silent")
(test-eq [42 99] @log-b "remaining watcher still fires")

(test-report)
