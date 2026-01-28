(defn fib [n]
  (if (<= n 1)
    n
    (+ (fib (- n 1)) (fib (- n 2)))))

;; fib(30): 約2秒。fib(35)=108秒, fib(38)=152秒は定期計測には長すぎる
(println (fib 30))
