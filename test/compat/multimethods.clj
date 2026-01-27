;; multimethods.clj — マルチメソッド テスト
(load-file "test/lib/test_runner.clj")

(println "[multimethods] running...")

;; === 基本 defmulti / defmethod ===
(defmulti greeting (fn [lang] lang))
(defmethod greeting :english [_] "Hello")
(defmethod greeting :japanese [_] "こんにちは")
(defmethod greeting :default [_] "???")

(test-eq "Hello" (greeting :english) "defmethod english")
(test-eq "こんにちは" (greeting :japanese) "defmethod japanese")
(test-eq "???" (greeting :french) "defmethod default")

;; === マルチメソッド with map dispatch ===
(defmulti area (fn [shape] (:type shape)))
(defmethod area :circle [s] (* 3.14 (:r s) (:r s)))
(defmethod area :rect [s] (* (:w s) (:h s)))

(test-eq 78.5 (area (hash-map :type :circle :r 5)) "area circle")
(test-eq 12 (area (hash-map :type :rect :w 3 :h 4)) "area rect")

;; === remove-method ===
(defmulti calc (fn [op] op))
(defmethod calc :add [_] "add")
(defmethod calc :sub [_] "sub")

(test-eq "add" (calc :add) "calc add before remove")
(remove-method calc :sub)
;; :sub は削除されたのでデフォルトメソッドが呼ばれるか例外

;; === methods ===
(defmulti op identity)
(defmethod op :a [_] 1)
(defmethod op :b [_] 2)
(test-is (map? (methods op)) "methods returns map")

;; === 階層的ディスパッチ (isa?) ===
(derive :rect :shape)
(derive :circle :shape)

(defmulti describe (fn [x] x))
(defmethod describe :shape [_] "a shape")
(defmethod describe :default [_] "unknown")

(test-eq "a shape" (describe :rect) "isa? dispatch rect->shape")
(test-eq "a shape" (describe :circle) "isa? dispatch circle->shape")
(test-eq "unknown" (describe :foo) "isa? dispatch default")

;; === isa? / parents / ancestors / descendants ===
(derive :poodle :dog)
(derive :dog :animal)

(test-is (isa? :poodle :dog) "isa? child")
(test-is (isa? :poodle :animal) "isa? transitive")
(test-is (not (isa? :animal :poodle)) "isa? not reverse")
(test-is (isa? :poodle :poodle) "isa? self")

(test-is (contains? (parents :poodle) :dog) "parents")
(test-is (contains? (ancestors :poodle) :animal) "ancestors transitive")
(test-is (contains? (descendants :animal) :poodle) "descendants transitive")

;; === レポート ===
(println "[multimethods]")
(test-report)
