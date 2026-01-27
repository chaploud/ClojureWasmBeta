;; clojure.test — 最小 clojure.test 互換実装
;;
;; 対応: deftest, is, testing, run-tests
;; 非対応: are (手動で is に展開)
;;
;; 制限: defmacro の & body は1引数のみキャプチャするため、
;;       deftest の body は単一の (do ...) 式にラップする。
;;       ただし deftest マクロが自動で (do ...) ラップを行う。
;;
;; 使い方:
;;   (load-file "src/clj/clojure/test.clj")
;;   (deftest my-test
;;     (is (= 1 1))
;;     (is (< 1 2)))
;;   (run-tests)

;; --- 内部状態 ---
(def __ct-tests (atom []))
(def __ct-pass (atom 0))
(def __ct-fail (atom 0))
(def __ct-error (atom 0))
(def __ct-context (atom []))

;; --- is (関数版) ---
(defn is [result]
  (if result
    (do (swap! __ct-pass inc) true)
    (do
      (swap! __ct-fail inc)
      (println
       (str "  FAIL in " (string-join " > " @__ct-context)))
      false)))

;; --- testing (関数版) ---
;; (testing "desc" (fn [] body...))
(defn testing [desc body-fn]
  (swap! __ct-context conj desc)
  (body-fn)
  (swap! __ct-context pop))

;; --- register-test ---
(defn register-test [name test-fn]
  (swap! __ct-tests conj (hash-map :name name :fn test-fn)))

;; --- deftest マクロ ---
;; body は単一の式 (& body の制限で1つのみキャプチャ)
;; 複数のアサーションは (do ...) で囲む
(defmacro deftest [tname body]
  (list 'do
        (list 'defn tname [] body)
        (list 'register-test (str tname) tname)))

;; --- run-tests ---
(defn run-tests []
  (reset! __ct-pass 0)
  (reset! __ct-fail 0)
  (reset! __ct-error 0)
  (let [tests @__ct-tests]
    (doseq [t tests]
      (reset! __ct-context [(get t :name)])
      (println (str "\nTesting " (get t :name)))
      (try
        ((get t :fn))
        (catch Exception e
          (swap! __ct-error inc)
          (println (str "  ERROR in " (get t :name) ": " e)))))
    (println "")
    (let [total (+ @__ct-pass @__ct-fail @__ct-error)]
      (println (str "Ran " (count tests) " tests containing " total " assertions"))
      (println (str @__ct-pass " passed, " @__ct-fail " failed, " @__ct-error " errors")))
    (let [total-problems (+ @__ct-fail @__ct-error)]
      (if (= 0 total-problems)
        (println "ALL TESTS PASSED")
        (println (str total-problems " problem(s) found")))
      (= 0 total-problems))))
