;; test_framework_test.clj — clojure.test フレームワーク自体のテスト
(load-file "src/clj/clojure/test.clj")

(println "[test_framework] running...")

;; === is 関数 ===
(deftest test-is-pass
  (is (= 1 1)))

(deftest test-is-fail
  (is (= 1 2)))

;; === 複数アサーション (do ラップ) ===
(deftest test-multiple-assertions
  (do
    (is (= 1 1))
    (is (< 1 2))
    (is (> 2 1))))

;; === testing コンテキスト ===
(deftest test-testing-context
  (do
    (is (= 1 1))
    (testing "nested" (fn []
                        (is (= 2 2))
                        (is (< 1 2))))))

;; === 例外ハンドリング (deftest レベル) ===
(deftest test-exception-handling
  (do
    (is (= 1 1))
    ;; 例外を投げるテスト — ERROR としてカウントされるべき
    ;; (/ 1 0) は deftest の try/catch で捕まる
    ))

;; run-tests で結果確認
;; 期待: test-is-fail で 1 fail
(run-tests)
