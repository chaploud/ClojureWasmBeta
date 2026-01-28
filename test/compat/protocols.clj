;; protocols.clj — プロトコル・型システムテスト
(load-file "test/lib/test_runner.clj")

(println "[protocols] running...")

;; === 基本 defprotocol + extend-type ===

(defprotocol Greet
  (greet [this])
  (farewell [this]))

(extend-type String
  Greet
  (greet [this] (str "Hello, " this))
  (farewell [this] (str "Goodbye, " this)))

(test-eq "Hello, World" (greet "World") "defprotocol + extend-type String greet")
(test-eq "Goodbye, World" (farewell "World") "defprotocol + extend-type String farewell")

;; === extend-type 複数型 ===

(extend-type Integer
  Greet
  (greet [this] (str "Number " this))
  (farewell [this] (str "Bye #" this)))

(test-eq "Number 42" (greet 42) "extend-type Integer greet")
(test-eq "Bye #42" (farewell 42) "extend-type Integer farewell")

;; === satisfies? ===

(test-is (satisfies? Greet "hello") "satisfies? String implements Greet")
(test-is (satisfies? Greet 42) "satisfies? Integer implements Greet")
(test-is (not (satisfies? Greet :keyword)) "satisfies? Keyword does not implement Greet")

;; === 複数プロトコル ===

(defprotocol Describable
  (describe [this]))

(defprotocol Sizeable
  (size [this]))

(extend-type Vector
  Describable
  (describe [this] (str "vector of " (count this) " elements"))
  Sizeable
  (size [this] (count this)))

(test-eq "vector of 3 elements" (describe [1 2 3]) "extend-type Vector Describable")
(test-eq 3 (size [1 2 3]) "extend-type Vector Sizeable")

;; === extend-protocol (複数型を一括) ===

(defprotocol Printable
  (to-str [this]))

(extend-protocol Printable
  String
  (to-str [this] (str "\"" this "\""))
  Integer
  (to-str [this] (str "int:" this))
  Keyword
  (to-str [this] (str "kw:" this)))

(test-eq "\"hello\"" (to-str "hello") "extend-protocol String")
(test-eq "int:42" (to-str 42) "extend-protocol Integer")
(test-eq "kw::foo" (to-str :foo) "extend-protocol Keyword")

;; === プロトコルメソッドは複数引数対応 ===

(defprotocol Calculator
  (calc [this x])
  (calc2 [this x y]))

(extend-type Integer
  Calculator
  (calc [this x] (+ this x))
  (calc2 [this x y] (+ this x y)))

(test-eq 15 (calc 10 5) "protocol method 2-arity")
(test-eq 60 (calc2 10 20 30) "protocol method 3-arity")

;; === defrecord (コンストラクタ) ===

(defrecord Point [x y])

(let [p (->Point 3 4)]
  (test-eq 3 (:x p) "defrecord ->Point :x")
  (test-eq 4 (:y p) "defrecord ->Point :y")
  (test-is (map? p) "defrecord produces map"))

(defrecord Person [name age])

(let [p (->Person "Alice" 30)]
  (test-eq "Alice" (:name p) "defrecord ->Person :name")
  (test-eq 30 (:age p) "defrecord ->Person :age"))

;; === type / class ===

(test-is (string? (type 42)) "type returns string")
(test-is (string? (class 42)) "class returns string")
(test-is (string? (type "hello")) "type of string")
(test-is (string? (type :kw)) "type of keyword")

;; === レポート ===
(println "[protocols]")
(test-report)
