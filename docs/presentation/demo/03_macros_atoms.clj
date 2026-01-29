;; 03_macros_atoms.clj — マクロ + アトム
;; デモ: form ごとに , e f で評価

;; --- defmacro ---
;; マクロ定義
(defmacro my-unless [pred then else]
  (list 'if pred else then))

(my-unless false "yes" "no")
;; => "yes"

(my-unless true "yes" "no")
;; => "no"

;; --- macroexpand-1 ---
(macroexpand-1 '(my-unless false "yes" "no"))
;; => (if false "no" "yes")

;; より複雑なマクロ定義

;; --- atom / swap! / deref ---
;; 単一情報源による状態管理
(def counter (atom 0))

(dotimes [_ 5]
  (swap! counter inc))

@counter
;; => 5

;; --- atom でログ蓄積 ---
(def log (atom []))

(doseq [x (range 1 4)]
  (swap! log conj (str "step-" x)))

@log
;; => ["step-1" "step-2" "step-3"]

;; --- reset! ---
(reset! counter 100)
@counter
;; => 100

(println "03_macros_atoms done.")
