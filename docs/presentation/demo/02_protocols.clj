;; 02_protocols.clj — プロトコル + マルチメソッド
;; デモ: form ごとに , e f で評価

;; --- defprotocol + extend-type ---
(defprotocol Greetable
  (greet [this]))

;; 引数の型ごとに実装を追加

(extend-type String
  Greetable
  (greet [this] (str "Hello, " this)))

(greet "Shibuya.lisp")
;; => "Hello, Shibuya.lisp"

(extend-type Integer
  Greetable
  (greet [this] (str "Number " this)))

(greet 42)
;; => "Number 42"

;; --- satisfies? ---
;; 型がプロトコルを実装しているか確認
(satisfies? Greetable "hello")
;; => true

(satisfies? Greetable :keyword)
;; => false

;; --- defrecord ---
;; 構造体のようなものを定義
(defrecord Point [x y])

(def p (->Point 3 4))
(:x p)
;; => 3
(:y p)
;; => 4

;; --- マルチメソッド ---
;; 柔軟な引数による動的ディスパッチ
(defmulti area :shape)

(defmethod area :circle [{:keys [radius]}]
  (* 3.14159265 radius radius))

(defmethod area :rect [{:keys [w h]}]
  (* w h))

(area {:shape :circle :radius 5})
;; => 78.5398...

(area {:shape :rect :w 3 :h 4})
;; => 12

(println "02_protocols done.")
