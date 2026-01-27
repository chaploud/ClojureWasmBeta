;; sci/multimethods_test.clj — sci multimethods_test.cljc からの移植テスト
;;
;; 移植ルール:
;;   (eval* 'expr) → expr (直接実行)
;;   sci 固有 API  → スキップ
;;
;; 制限回避:
;;   - マップリテラル {...} → (hash-map ...) (deftest body 内)
;;   - セットリテラル #{...} → (hash-set ...) (同上)
;;   - ::keyword → :ns/keyword (明示的名前空間)
;;   - multi-arity defmethod → 未対応の可能性、要確認
;;
(load-file "src/clj/clojure/test.clj")

(println "[sci/multimethods_test] running...")

;; =========================================================================
;; default — :default ディスパッチ
;; =========================================================================
(defmulti mm-foo type)
(defmethod mm-foo :default [c] :default)

(deftest default-test
  (do
    (is (= :default (mm-foo :foo)))))

;; =========================================================================
;; defmethod — 関数ディスパッチ
;; =========================================================================
(defmulti mm-greeting (fn [x] (get x "language")))
(defmethod mm-greeting "English" [params] "Hello")

(deftest defmethod-test
  (do
    (is (= "Hello" (mm-greeting (hash-map "id" "1" "language" "English"))))))

;; =========================================================================
;; remove-method — メソッド除去後に :default へフォールバック
;; =========================================================================
(defmulti mm-greeting2 (fn [x] (get x "language")))
(defmethod mm-greeting2 "English" [params] "Hello")
(defmethod mm-greeting2 :default [params] "Default")
(remove-method mm-greeting2 "English")

(deftest remove-method-test
  (do
    (is (= "Default" (mm-greeting2 (hash-map "id" "1" "language" "English"))))))

;; =========================================================================
;; prefer-method — 曖昧解決
;; =========================================================================
(derive :mm/rect :mm/shape)
(defmulti mm-bar (fn [x y] [x y]))
(defmethod mm-bar [:mm/rect :mm/shape] [x y] :rect-shape)
(defmethod mm-bar [:mm/shape :mm/rect] [x y] :shape-rect)
(prefer-method mm-bar [:mm/rect :mm/shape] [:mm/shape :mm/rect])

(deftest prefer-method-test
  (do
    (is (= :rect-shape (mm-bar :mm/rect :mm/rect)))))

;; --- 実行 ---
(run-tests)
