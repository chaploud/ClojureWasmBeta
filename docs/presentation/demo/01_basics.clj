;; 01_basics.clj — REPL 基本 + 遅延シーケンス
;; デモ: form ごとに C-c C-e で評価

;; --- 基本演算 ---
(+ 1 2 3)
;; => 6

(* 10 20)
;; => 200

;; --- 関数定義 ---
(defn greet [name]
  (str "Hello, " name "!"))

(greet "Shibuya.lisp")
;; => "Hello, Shibuya.lisp!"

;; --- 遅延シーケンス ---
(take 10 (range))
;; => (0 1 2 3 4 5 6 7 8 9)

(take 10 (filter odd? (range)))
;; => (1 3 5 7 9 11 13 15 17 19)

;; --- threading macro ---
(->> (range 1 100)
     (filter #(zero? (mod % 3)))
     (map #(* % %))
     (reduce +))
;; => 105876

;; --- データ構造 ---
(def person {:name "Alice" :age 30})

(:name person)
;; => "Alice"

(assoc person :lang "Clojure")
;; => {:name "Alice", :age 30, :lang "Clojure"}

;; --- 多値関数 ---
(apply + (range 1 11))
;; => 55

(println "01_basics done.")
