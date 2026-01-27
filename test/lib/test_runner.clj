;; test_runner.clj — assert ベーステストランナー
;; try/catch + atom で pass/fail/error カウント
;;
;; 使い方:
;;   (load-file "test/lib/test_runner.clj")
;;   (test-is (= 1 1) "basic equality")
;;   (test-eq 3 (+ 1 2) "addition")
;;   (test-report)

(ns test.lib.test-runner)

;; --- カウンター ---
(def *pass* (atom 0))
(def *fail* (atom 0))
(def *error* (atom 0))
(def *test-name* (atom "unnamed"))

;; --- カウンターリセット ---
(defn reset-counters! []
  (reset! *pass* 0)
  (reset! *fail* 0)
  (reset! *error* 0))

;; --- テストマクロ ---
;; test-is: 式が truthy なら pass, falsey なら fail, 例外なら error
(defmacro test-is [expr msg]
  (list 'try
        (list 'if expr
              (list 'do (list 'swap! '*pass* 'inc) nil)
              (list 'do (list 'swap! '*fail* 'inc)
                    (list 'println "  FAIL:" msg)))
        (list 'catch 'Exception 'e
              (list 'do (list 'swap! '*error* 'inc)
                    (list 'println "  ERROR:" msg)))))

;; test-eq: expected と actual が等しいことを検証
(defmacro test-eq [expected actual msg]
  (list 'test-is (list '= expected actual) msg))

;; test-throws: 式が例外を投げることを検証
(defmacro test-throws [expr msg]
  (list 'let ['threw (list 'try expr 'false
                           (list 'catch 'Exception 'e 'true))]
        (list 'test-is 'threw msg)))

;; --- レポート ---
;; test-report: 結果を表示して成功なら true を返す
(defn test-report []
  (let [p @*pass* f @*fail* e @*error*]
    (println (str "PASS: " p ", FAIL: " f ", ERROR: " e))
    (= 0 (+ f e))))
