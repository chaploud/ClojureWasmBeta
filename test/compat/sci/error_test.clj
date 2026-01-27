;; sci/error_test.clj — エラーハンドリングテスト
;;
;; sci error_test.cljc は sci 固有 API (stacktrace, format-stacktrace) に
;; 依存するため、Clojure 互換の try/catch/throw/ex-info テストを独自に作成。
;;
;; 制限回避:
;;   - マップリテラル {...} → (hash-map ...) (deftest body 内)
;;   - セットリテラル #{...} → (hash-set ...) (同上)
;;
(load-file "src/clj/clojure/test.clj")

(println "[sci/error_test] running...")

;; =========================================================================
;; try/catch 基本
;; =========================================================================
(deftest try-catch-basic-test
  (do
    ;; 正常系: catch に入らない
    (is (= 42 (try 42 (catch Exception e :err))))
    ;; エラー系: catch に入る
    (is (= :caught (try (/ 1 0) (catch Exception e :caught))))
    ;; 例外オブジェクトへのアクセス
    (is (= "test-msg"
           (try (throw (ex-info "test-msg" (hash-map :a 1)))
                (catch Exception e (ex-message e)))))
    ;; ex-data へのアクセス
    (is (= 1
           (try (throw (ex-info "msg" (hash-map :a 1)))
                (catch Exception e (:a (ex-data e))))))))

;; =========================================================================
;; finally
;; =========================================================================
;; ヘルパー: finally は常に実行される
(def __finally-atom (atom 0))

(defn __finally-normal-test []
  (reset! __finally-atom 0)
  (try (reset! __finally-atom 1)
       (catch Exception e nil)
       (finally (reset! __finally-atom 2)))
  @__finally-atom)

(defn __finally-error-test []
  (reset! __finally-atom 0)
  (try (do (reset! __finally-atom 1)
           (throw (ex-info "err" (hash-map)))
           (reset! __finally-atom 99))
       (catch Exception e (reset! __finally-atom 10))
       (finally (reset! __finally-atom 20)))
  @__finally-atom)

(deftest finally-test
  (do
    ;; 正常系: finally が最後に実行される
    (is (= 2 (__finally-normal-test)))
    ;; エラー系: catch → finally の順で実行
    (is (= 20 (__finally-error-test)))))

;; =========================================================================
;; ex-info / ex-data / ex-message
;; =========================================================================
(defn __exinfo-test []
  (try
    (throw (ex-info "my-error" (hash-map :code 404 :reason "not found")))
    (catch Exception e
      (vector (ex-message e)
              (:code (ex-data e))
              (:reason (ex-data e))))))

(deftest ex-info-test
  (do
    (is (= ["my-error" 404 "not found"] (__exinfo-test)))))

;; =========================================================================
;; ネストした try/catch
;; =========================================================================
(defn __nested-try-test []
  (try
    (try
      (throw (ex-info "inner" (hash-map)))
      (catch Exception e
        (throw (ex-info "rethrown" (hash-map :orig (ex-message e))))))
    (catch Exception e
      (vector (ex-message e) (:orig (ex-data e))))))

(deftest nested-try-test
  (do
    (is (= ["rethrown" "inner"] (__nested-try-test)))))

;; =========================================================================
;; try の戻り値
;; =========================================================================
(deftest try-return-value-test
  (do
    ;; try の body の値が返る
    (is (= 42 (try 42 (catch Exception e nil))))
    ;; catch の値が返る（エラー時）
    (is (= :caught (try (/ 1 0) (catch Exception e :caught))))
    ;; 複数式の最後の値が返る
    (is (= 3 (try 1 2 3 (catch Exception e nil))))))

;; =========================================================================
;; ユーザー例外の伝播
;; =========================================================================
(defn __throws [] (throw (ex-info "boom" (hash-map :level 1))))
(defn __calls-throws []
  (try (__throws) (catch Exception e (ex-message e))))

(deftest exception-propagation-test
  (do
    (is (= "boom" (__calls-throws)))))

;; --- 実行 ---
(run-tests)
