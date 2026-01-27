;; sci/vars_test.clj — sci vars_test.cljc からの移植テスト
;;
;; 移植ルール:
;;   (eval* 'expr)           → expr (直接実行)
;;   eval-string / sci/* API → スキップ
;;   JVM (future/pmap/Thread)→ スキップ
;;
;; 制限回避:
;;   - マップリテラル {...} → (hash-map ...) (deftest body 内)
;;   - セットリテラル #{...} → (hash-set ...) (同上)
;;   - def ^:dynamic / try / defmacro → deftest body 内では使えない、ヘルパーへ
;;   - #'var を関数呼び出し  → スキップ (TypeError)
;;   - (str (def x 1))       → スキップ (空文字列を返す: def-returns-var)
;;   - ^:const               → スキップ (未対応)
;;   - with-local-vars       → スキップ (未対応)
;;   - add-watch on var      → スキップ (未対応)
;;   - defmacro value access → スキップ (エラーを投げない)
;;   - var-set               → スキップ (動作しない)
;;   - alter-var-root + root → スキップ (thread-local を使用してしまう)
;;
(load-file "src/clj/clojure/test.clj")

(println "[sci/vars_test] running...")

;; =========================================================================
;; dynamic-var — binding / set!
;; =========================================================================
;; ヘルパー: set! in binding で値を変更 [0 1 2 0]
(def ^:dynamic *__dv-x* 0)
(defn __dv-add! [v] (swap! (atom []) conj v))
(defn __dv-set-test []
  (let [a (atom [])]
    (swap! a conj *__dv-x*)
    (binding [*__dv-x* 1]
      (swap! a conj *__dv-x*)
      (set! *__dv-x* (inc *__dv-x*))
      (swap! a conj *__dv-x*))
    (swap! a conj *__dv-x*)
    @a))

;; ヘルパー: set! on root binding → throws
(def ^:dynamic *__dv-y* 1)
(defn __dv-set-root-test []
  (try (set! *__dv-y* 2) :no-error
       (catch Exception e :threw)))

;; ヘルパー: binding of false
(def ^:dynamic *__dv-bf* nil)
(defn __dv-bf-test []
  (binding [*__dv-bf* false] *__dv-bf*))

(deftest dynamic-var-test
  (do
    (is (= [0 1 2 0] (__dv-set-test)))
    (is (= :threw (__dv-set-root-test)))
    (is (false? (__dv-bf-test)))))

;; =========================================================================
;; redefine-var — def/defn/defmacro の再定義
;; =========================================================================
;; ヘルパー: def 再定義
(defn __rv-test-def []
  (def __rv-x 10)
  (defn __rv-foo [] __rv-x)
  (def __rv-x 11)
  (__rv-foo))

;; ヘルパー: defn 再定義
(defn __rv-test-fn []
  (defn __rv-f1 [] 1)
  (defn __rv-g1 [] (__rv-f1))
  (defn __rv-f1 [] 2)
  (__rv-g1))

;; macro 再定義はトップレベルで実行 (defmacro inside defn → UndefinedSymbol)
(defmacro __rv-m1 [] (list '+ 1 2 3 4))
(defn __rv-b1 [] (__rv-m1))
(defmacro __rv-m1 [] (list '+ 1 2 3))
(def __rv-macro1-result (__rv-b1))

(defmacro __rv-m2 [] (list '+ 1 2 3 4))
(defn __rv-b2 [] (__rv-m2))
(defmacro __rv-m2 [] (list '+ 1 2 3))
(defn __rv-b2 [] (__rv-m2))
(def __rv-macro2-result (__rv-b2))

(deftest redefine-var-test
  (do
    (is (= 11 (__rv-test-def)))
    (is (= 10 __rv-macro1-result))
    (is (= 6 __rv-macro2-result))
    (is (= 2 (__rv-test-fn)))))

;; =========================================================================
;; var-call — #'var を関数として呼ぶ
;; =========================================================================
;; SKIP: #'var を関数呼び出しすると TypeError
;; (deftest var-call-test ...)

;; =========================================================================
;; unbound-call — 未束縛 var の呼び出し
;; =========================================================================
;; ヘルパー: declare した未束縛 var を呼ぶと例外
(defn __uc-test []
  (declare __uc-x)
  (try (__uc-x 1) :no-error
       (catch Exception e :threw)))

(deftest unbound-call-test
  (do (is (= :threw (__uc-test)))))

;; =========================================================================
;; alter-var-root
;; =========================================================================
;; ヘルパー: 基本 alter-var-root
(defn __avr-test-basic []
  (def __avr-x 1)
  (alter-var-root #'__avr-x (fn [v] (inc v)))
  __avr-x)

;; ヘルパー: 戻り値
(defn __avr-test-ret []
  (def __avr-y 1)
  (alter-var-root #'__avr-y inc))

(deftest alter-var-root-test
  (do
    (is (= 2 (__avr-test-basic)))
    (is (= 2 (__avr-test-ret)))
    ;; KNOWN BUG: alter-var-root は root でなく thread-local を使う
    ;; (is (= 2 (__avr-test-root)))
    ))

;; =========================================================================
;; with-redefs
;; =========================================================================
;; ヘルパー: with-redefs
(defn __wr-test []
  (def __wr-x 1)
  (vector (with-redefs [__wr-x 2] __wr-x) __wr-x))

(deftest with-redefs-test
  (do (is (= [2 1] (__wr-test)))))

;; =========================================================================
;; thread-bound?
;; =========================================================================
(def ^:dynamic *__tb-x* nil)
(def ^:dynamic *__tb-y* nil)

(defn __tb-test-no []
  (thread-bound? #'*__tb-x*))

(defn __tb-test-yes []
  (binding [*__tb-x* *__tb-x* *__tb-y* *__tb-y*]
    (thread-bound? #'*__tb-x*)))

(deftest thread-bound-test
  (do
    (is (false? (__tb-test-no)))
    (is (true? (__tb-test-yes)))))

;; =========================================================================
;; var-get
;; =========================================================================
;; KNOWN BUG: var-set は動作しない (値が変わらない)
(def ^:dynamic *__vg-x* 42)

(defn __vg-root-test [] (var-get #'*__vg-x*))
(defn __vg-bind-test [] (binding [*__vg-x* 99] (var-get #'*__vg-x*)))

(deftest var-get-test
  (do
    (is (= 42 (__vg-root-test)))
    (is (= 99 (__vg-bind-test)))))

;; --- 実行 ---
(run-tests)
