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
;; マクロは「コードを生成するコード」
;; list でコード(リスト)を組み立て、& body で可変長引数を受け取る
;;
;; my-when: 条件が真のときだけ body を全部実行する
;;   - (cons 'do body) で (do 式1 式2 ...) を組み立てる
;;   - my-unless は引数固定だったが、こちらは可変長
(defmacro my-when [test & body]
  (list 'if test (cons 'do body) nil))

;; 使ってみる: 条件が true なので本体が順に実行される
(my-when true
         (println "hello")
         (println "world")
         42)
;; => hello
;;    world
;;    42

;; macroexpand-1 でマクロがどう展開されるか確認できる
(macroexpand-1 '(my-when true (println "hello") 42))
;; => (if true (do (println "hello") 42) nil)

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
