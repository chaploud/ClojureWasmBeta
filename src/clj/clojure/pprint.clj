;; clojure.pprint - Pretty print 実装
;; 本家 clojure.pprint のサブセット実装

(ns clojure.pprint)

;; === 設定変数 ===

(def ^:dynamic *print-right-margin* 72)
(def ^:dynamic *print-miser-width* 40)
(def ^:dynamic *print-suppress-namespaces* nil)

;; === 内部ヘルパー ===

(declare pprint-impl)

(defn- indent-str
  "インデント文字列を生成"
  [n]
  (apply str (repeat n " ")))

(defn- pprint-seq
  "シーケンス/リストをpprint"
  [s depth max-width indent]
  (let [ind (indent-str indent)]
    (print "(")
    (when (seq s)
      (loop [items s first? true]
        (when (seq items)
          (when (not first?)
            (print " "))
          (pprint-impl (first items) (inc depth) max-width (+ indent 1))
          (recur (rest items) false))))
    (print ")")))

(defn- pprint-vector
  "ベクターをpprint"
  [v depth max-width indent]
  (print "[")
  (when (seq v)
    (loop [items v first? true]
      (when (seq items)
        (when (not first?)
          (print " "))
        (pprint-impl (first items) (inc depth) max-width (+ indent 1))
        (recur (rest items) false))))
  (print "]"))

(defn- pprint-map
  "マップをpprint"
  [m depth max-width indent]
  (print "{")
  (when (seq m)
    (let [entries (seq m)
          ind (indent-str (+ indent 1))]
      (loop [es entries first? true]
        (when (seq es)
          (let [[k v] (first es)]
            (when (not first?)
              (println)
              (print ind))
            (pprint-impl k (inc depth) max-width (+ indent 1))
            (print " ")
            (pprint-impl v (inc depth) max-width (+ indent 1)))
          (recur (rest es) false)))))
  (print "}"))

(defn- pprint-set
  "セットをpprint"
  [s depth max-width indent]
  (print "#{")
  (when (seq s)
    (loop [items (seq s) first? true]
      (when (seq items)
        (when (not first?)
          (print " "))
        (pprint-impl (first items) (inc depth) max-width (+ indent 1))
        (recur (rest items) false))))
  (print "}"))

(defn- pprint-impl
  "pprint の内部実装"
  [x depth max-width indent]
  (cond
    (nil? x) (print "nil")
    (string? x) (pr x)
    (keyword? x) (print x)
    (symbol? x) (if *print-suppress-namespaces*
                  (print (name x))
                  (print x))
    (number? x) (print x)
    (true? x) (print "true")
    (false? x) (print "false")
    (vector? x) (pprint-vector x depth max-width indent)
    (map? x) (pprint-map x depth max-width indent)
    (set? x) (pprint-set x depth max-width indent)
    (seq? x) (pprint-seq x depth max-width indent)
    (list? x) (pprint-seq x depth max-width indent)
    (fn? x) (print "#<fn>")
    :else (pr x)))

;; === 公開 API ===

(defn pprint
  "Pretty print の実装。オブジェクトをインデント付きで出力する。"
  ([x]
   (pprint-impl x 0 *print-right-margin* 0)
   (println))
  ([x writer]
   ;; writer は無視（stdout のみサポート）
   (pprint x)))

(defn pp
  "Pretty print。(pprint *1) のショートカット。"
  []
  (pprint *1))

(defn write
  "pprint のエイリアス (簡易版)"
  [x & options]
  (pprint x))

(defn pprint-newline
  "条件付き改行 (簡易版 - 常に改行)"
  [kind]
  (println))

;; === print-table ===

(defn print-table
  "マップのコレクションをテーブル形式で出力する。
   ks でカラムキーを指定。省略時は最初の行のキーを使用。"
  ([ks rows]
   (when (seq rows)
     (let [ks-vec (vec ks)
           widths-vec (vec (map (fn [k]
                                  (apply max
                                         (count (str k))
                                         (map (fn [row] (count (str (get row k)))) rows)))
                                ks-vec))
           spacers-vec (vec (map (fn [w] (apply str (repeat w "-"))) widths-vec))
           fmt-cell (fn [s w]
                      (let [slen (count s)
                            pad (- w slen)]
                        (str (apply str (repeat pad " ")) s)))
           fmt-row (fn [leader divider trailer row]
                     (str leader
                          (apply str
                                 (interpose divider
                                            (map (fn [i]
                                                   (fmt-cell (str (get row (nth ks-vec i)))
                                                             (nth widths-vec i)))
                                                 (range (count ks-vec)))))
                          trailer))]
       (println)
       (println (fmt-row "| " " | " " |" (zipmap ks-vec ks-vec)))
       (println (fmt-row "|-" "-+-" "-|" (zipmap ks-vec spacers-vec)))
       (doseq [row rows]
         (println (fmt-row "| " " | " " |" row))))))
  ([rows]
   (print-table (keys (first rows)) rows)))

;; === cl-format (最小限) ===

(defn cl-format
  "Common Lisp format の最小限実装。
   基本的なディレクティブのみサポート: ~A, ~S, ~D, ~%, ~~"
  [writer fmt-str & args]
  (let [result (loop [i 0
                      args args
                      out-str ""]
                 (if (>= i (count fmt-str))
                   out-str
                   (let [c (subs fmt-str i (inc i))]
                     (if (= c "~")
                       (if (>= (inc i) (count fmt-str))
                         (str out-str "~")
                         (let [directive (subs fmt-str (inc i) (+ i 2))
                               next-i (+ i 2)]
                           (cond
                             (or (= directive "A") (= directive "a"))
                             (recur next-i (rest args) (str out-str (first args)))

                             (or (= directive "S") (= directive "s"))
                             (recur next-i (rest args) (str out-str (pr-str (first args))))

                             (or (= directive "D") (= directive "d"))
                             (recur next-i (rest args) (str out-str (first args)))

                             (= directive "%")
                             (recur next-i args (str out-str "\n"))

                             (= directive "~")
                             (recur next-i args (str out-str "~"))

                             :else
                             (recur next-i args (str out-str "~" directive)))))
                       (recur (inc i) args (str out-str c))))))]
    (if writer
      (print result)
      result)))
