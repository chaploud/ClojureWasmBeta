;; sci/hierarchies_test.clj — sci hierarchies_test.cljc からの移植テスト
;;
;; 移植ルール:
;;   (eval* 'expr) → expr (直接実行)
;;   sci 固有 API → スキップ
;;
;; 制限回避:
;;   - マップリテラル {...} → (hash-map ...) (deftest body 内)
;;   - セットリテラル #{...} → (hash-set ...) (同上)
;;   - 「セッション別」テスト → 共有状態のためスキップまたは調整
;;
(load-file "src/clj/clojure/test.clj")

(println "[sci/hierarchies_test] running...")

;; =========================================================================
;; derive + isa?
;; =========================================================================
(deftest derive-test
  (do
    (is (true? (do (derive :ht/foo :ht/bar) (isa? :ht/foo :ht/bar))))
    ;; SKIP: sci ではセッション別に分離されるが、ここでは共有状態
    ;; (is (false? (isa? :ht/foo :ht/bar)))
    ))

;; =========================================================================
;; descendants
;; =========================================================================
(deftest descendants-test
  (do
    (derive :ht/d-foo :ht/d-bar)
    (derive :ht/d-baz :ht/d-bar)
    (is (= (hash-set :ht/d-foo :ht/d-baz) (descendants :ht/d-bar)))))

;; =========================================================================
;; ancestors (transitive)
;; =========================================================================
(deftest ancestors-test
  (do
    (derive :ht/a-foo :ht/a-bar)
    (derive :ht/a-bar :ht/a-baz)
    (is (= (hash-set :ht/a-bar :ht/a-baz) (ancestors :ht/a-foo)))))

;; =========================================================================
;; parents
;; =========================================================================
(deftest parents-test
  (do
    (derive :ht/p-foo :ht/p-bar)
    (is (= (hash-set :ht/p-bar) (parents :ht/p-foo)))))

;; =========================================================================
;; underive
;; =========================================================================
(deftest underive-test
  (do
    (derive :ht/u-foo :ht/u-bar)
    (underive :ht/u-foo :ht/u-bar)
    (is (empty? (parents :ht/u-foo)))))

;; --- 実行 ---
(run-tests)
