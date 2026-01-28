;; JVM Clojure warm benchmark runner
;; JIT warm-up 後の純粋な計算時間を計測する。
;; 使い方: clojure -M bench/clj_warm_bench.clj file1.clj file2.clj ...
;;
;; 出力形式 (1行/ファイル):
;;   <basename>=<ナノ秒>
;; 例:
;;   fib30=10586166
;;   sum_range=6466792

(doseq [bench-file *command-line-args*]
  (let [;; ベンチ名: ディレクトリ名を使う (bench/fib30/fib.clj → fib30)
        dir-name (-> bench-file
                     (clojure.string/split #"/")
                     butlast
                     last)
        ;; ファイル内の全フォームを読む
        forms (read-string (str "[" (slurp bench-file) "]"))
        ;; warm-up: 3回実行 (JIT コンパイル促進)
        _ (dotimes [_ 3]
            (binding [*out* (java.io.StringWriter.)]
              (doseq [form forms] (eval form))))
        ;; 計測: 5回実行して中央値
        times (for [_ (range 5)]
                (let [sw (java.io.StringWriter.)
                      t0 (System/nanoTime)
                      _  (binding [*out* sw]
                           (doseq [form forms] (eval form)))
                      t1 (System/nanoTime)]
                  (- t1 t0)))
        sorted (sort times)
        median (nth sorted 2)]
    (println (str dir-name "=" median))))
