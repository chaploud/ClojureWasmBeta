;; 03_macros_atoms.clj — マクロ + アトム
;; デモ: form ごとに C-c C-e で評価

;; --- defmacro ---
(defmacro unless [pred then else]
  (list 'if pred else then))

(unless false "yes" "no")
;; => "yes"

(unless true "yes" "no")
;; => "no"

;; --- macroexpand-1 ---
(macroexpand-1 '(unless false "yes" "no"))
;; => (if false "no" "yes")

;; --- atom / swap! / deref ---
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
