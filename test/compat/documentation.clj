;; documentation.clj — doc/dir/find-doc/apropos テスト
(load-file "test/lib/test_runner.clj")

(println "[documentation] running...")

;; ヘルパー: 文字列に部分文字列が含まれるか
(defn str-contains? [s sub]
  (not (nil? (re-find sub s))))

;; === doc 基本 ===

(defn my-add "Adds two numbers together." [a b] (+ a b))

;; with-out-str で出力内容を検証
(let [out (with-out-str (doc my-add))]
  (test-is (string? out) "doc output is string")
  (test-is (> (count out) 0) "doc output is non-empty")
  ;; 関数名を含む
  (test-is (str-contains? out "my-add") "doc output contains function name")
  ;; arglists を含む
  (test-is (str-contains? out "\\[a b\\]") "doc output contains arglists")
  ;; docstring を含む
  (test-is (str-contains? out "Adds two numbers") "doc output contains docstring"))

;; === doc: 複数アリティ ===

(defn multi-fn
  "Multi-arity function."
  ([x] x)
  ([x y] (+ x y))
  ([x y z] (+ x y z)))

(let [out (with-out-str (doc multi-fn))]
  (test-is (str-contains? out "multi-fn") "doc multi-arity: contains name")
  (test-is (str-contains? out "Multi-arity") "doc multi-arity: contains docstring"))

;; === doc: docstring なし ===

(defn no-doc-fn [x] x)

(let [out (with-out-str (doc no-doc-fn))]
  (test-is (str-contains? out "no-doc-fn") "doc no-docstring: still shows name"))

;; === dir (現在の NS = test.lib.test-runner) ===

(defn dir-test-a [] :a)
(defn dir-test-b [] :b)
(defn dir-test-c [] :c)

(let [out (with-out-str (dir test.lib.test-runner))]
  (test-is (string? out) "dir produces output")
  (test-is (str-contains? out "dir-test-a") "dir shows dir-test-a")
  (test-is (str-contains? out "dir-test-b") "dir shows dir-test-b")
  (test-is (str-contains? out "dir-test-c") "dir shows dir-test-c"))

;; === find-doc ===

(defn searchable-fn "This function does unique-magic processing." [x] x)

(let [out (with-out-str (find-doc "unique-magic"))]
  (test-is (str-contains? out "searchable-fn") "find-doc finds function by docstring pattern"))

;; === apropos ===

(defn apropos-target-xyz [] nil)

(let [out (with-out-str (apropos "apropos-target"))]
  (test-is (str-contains? out "apropos-target-xyz") "apropos finds function by name pattern"))

;; === レポート ===
(println "[documentation]")
(test-report)
