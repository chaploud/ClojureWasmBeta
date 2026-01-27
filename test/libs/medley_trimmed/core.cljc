(ns medley-trimmed.core
  "Trimmed medley v1.4.0 — Java interop/atom functions removed for ClojureWasmBeta testing.")

;; === Tier 1: 基本関数 (Java 依存なし) ===

(defn find-first
  "Finds the first item in a collection that matches a predicate."
  ([pred coll]
   (reduce (fn [_ x] (when (pred x) (reduced x))) nil coll)))

(defn dissoc-in
  "Dissociate a value in a nested associative structure."
  ([m ks]
   (if-let [[k & ks] (seq ks)]
     (if (seq ks)
       (let [v (dissoc-in (get m k) ks)]
         (if (empty? v)
           (dissoc m k)
           (assoc m k v)))
       (dissoc m k))
     m))
  ([m ks & kss]
   (if-let [[ks' & kss] (seq kss)]
     (recur (dissoc-in m ks) ks' kss)
     (dissoc-in m ks))))

(defn assoc-some
  "Associates a key k, with a value v in a map m, if and only if v is not nil."
  ([m k v]
   (if (nil? v) m (assoc m k v)))
  ([m k v & kvs]
   (reduce (fn [m [k v]] (assoc-some m k v))
           (assoc-some m k v)
           (partition 2 kvs))))

(defn update-existing
  "Updates a value in a map given a key and a function, if and only if the key exists."
  {:arglists '([m k f & args])
   :added    "1.1.0"}
  ([m k f]
   (if-let [kv (find m k)] (assoc m k (f (val kv))) m))
  ([m k f x]
   (if-let [kv (find m k)] (assoc m k (f (val kv) x)) m))
  ([m k f x y]
   (if-let [kv (find m k)] (assoc m k (f (val kv) x y)) m))
  ([m k f x y z]
   (if-let [kv (find m k)] (assoc m k (f (val kv) x y z)) m))
  ([m k f x y z & more]
   (if-let [kv (find m k)] (assoc m k (apply f (val kv) x y z more)) m)))

(defn update-existing-in
  "Updates a value in a nested associative structure, if and only if the key path exists."
  {:added "1.3.0"}
  [m ks f & args]
  (let [up (fn up [m ks f args]
             (let [[k & ks] ks]
               (if-let [kv (find m k)]
                 (if ks
                   (assoc m k (up (val kv) ks f args))
                   (assoc m k (apply f (val kv) args)))
                 m)))]
    (up m ks f args)))

(defn abs
  "Returns the absolute value of a number."
  [x]
  (if (neg? x) (- x) x))

;; === Tier 2: マップ操作 ===

(defn- editable? [coll]
  (instance? clojure.lang.IEditableCollection coll))

(defn- reduce-map [f coll]
  ;; record? は未実装のため省略、editable? のみ分岐
  (reduce-kv (f assoc) (empty coll) coll))

(defn map-kv
  "Maps a function over the key/value pairs of an associative collection."
  [f coll]
  (reduce-map (fn [xf] (fn [m k v] (let [[k v] (f k v)] (xf m k v)))) coll))

(defn map-keys
  "Maps a function over the keys of an associative collection."
  [f coll]
  (reduce-map (fn [xf] (fn [m k v] (xf m (f k) v))) coll))

(defn map-vals
  "Maps a function over the values of an associative collection."
  ([f coll]
   (reduce-map (fn [xf] (fn [m k v] (xf m k (f v)))) coll)))

(defn filter-kv
  "Returns a map containing only those entries in map for which (pred key val) returns true."
  [pred coll]
  (reduce-map (fn [xf] (fn [m k v] (if (pred k v) (xf m k v) m))) coll))

(defn filter-keys
  "Returns a map containing only those entries whose key satisfies the predicate."
  [pred coll]
  (reduce-map (fn [xf] (fn [m k v] (if (pred k) (xf m k v) m))) coll))

(defn filter-vals
  "Returns a map containing only those entries whose value satisfies the predicate."
  [pred coll]
  (reduce-map (fn [xf] (fn [m k v] (if (pred v) (xf m k v) m))) coll))

(defn remove-kv
  "Returns a map containing only those entries for which (pred key val) returns false."
  [pred coll]
  (filter-kv (complement pred) coll))

(defn remove-keys
  "Returns a map containing only those entries whose key does not satisfy the predicate."
  [pred coll]
  (filter-keys (complement pred) coll))

(defn remove-vals
  "Returns a map containing only those entries whose value does not satisfy the predicate."
  [pred coll]
  (filter-vals (complement pred) coll))

;; === Tier 3: 型判定 ===

(defn boolean?
  "Returns true if x is a boolean."
  [x]
  (or (true? x) (false? x)))

(defn least
  "Return the smallest argument (as determined by compare)."
  ([a] a)
  ([a b] (if (neg? (compare a b)) a b))
  ([a b & more] (reduce least (least a b) more)))

(defn greatest
  "Return the greatest argument (as determined by compare)."
  ([a] a)
  ([a b] (if (pos? (compare a b)) a b))
  ([a b & more] (reduce greatest (greatest a b) more)))

(defn deep-merge
  "Recursively merges maps."
  [& maps]
  (letfn [(inner-merge [& maps]
            (let [ms (remove nil? maps)]
              (if (every? map? ms)
                (apply merge-with inner-merge ms)
                (last ms))))]
    (apply inner-merge maps)))

(defn index-by
  "Returns a map of the elements of coll, indexed by (f elem)."
  [f coll]
  (persistent! (reduce #(assoc! %1 (f %2) %2) (transient {}) coll)))
