;; clojure.zip — 関数的階層 zipper
;; ツリー構造のナビゲーション・編集・走査

(ns clojure.zip
  (:refer-clojure :exclude [replace remove next]))

(defn zipper
  "汎用 zipper を作成する。
  branch? — ノードが子を持てるかを判定する述語
  children — ブランチノードの子の seq を返す関数
  make-node — 既存ノードと子の seq から新ブランチノードを作る関数
  root — ルートノード"
  [branch? children make-node root]
  (with-meta [root nil]
    {:zip/branch? branch?
     :zip/children children
     :zip/make-node make-node}))

(defn seq-zip
  "ネストされたシーケンス用の zipper を返す"
  [root]
  (zipper seq?
          identity
          (fn [node children]
            (let [m (meta node)]
              (if m (with-meta children m) children)))
          root))

(defn vector-zip
  "ネストされたベクター用の zipper を返す"
  [root]
  (zipper vector?
          seq
          (fn [node children]
            (let [m (meta node)]
              (if m (with-meta (vec children) m) (vec children))))
          root))

(defn xml-zip
  "XML 要素用の zipper を返す"
  [root]
  (zipper (complement string?)
          (comp seq :content)
          (fn [node children]
            (assoc node :content (and children (apply vector children))))
          root))

(defn node
  "loc のノードを返す"
  [loc]
  (loc 0))

(defn branch?
  "loc のノードがブランチなら true"
  [loc]
  ((:zip/branch? (meta loc)) (node loc)))

(defn children
  "loc のノードの子の seq を返す（ブランチでなければエラー）"
  [loc]
  (if (branch? loc)
    ((:zip/children (meta loc)) (node loc))
    (throw (ex-info "called children on a leaf node" {}))))

(defn make-node
  "既存ノードと新しい子から新ブランチノードを作る"
  [loc node children]
  ((:zip/make-node (meta loc)) node children))

(defn path
  "この loc に至るノードの seq を返す"
  [loc]
  (:pnodes (loc 1)))

(defn lefts
  "左兄弟の seq を返す"
  [loc]
  (seq (:l (loc 1))))

(defn rights
  "右兄弟の seq を返す"
  [loc]
  (:r (loc 1)))

(defn down
  "最左の子の loc を返す。子がなければ nil"
  [loc]
  (when (branch? loc)
    (let [n (node loc)
          p (loc 1)
          cs (children loc)]
      (when (seq cs)
        (let [c (first cs)
              cnext (clojure.core/next cs)]
          (with-meta [c {:l []
                         :pnodes (if p (conj (:pnodes p) n) [n])
                         :ppath p
                         :r cnext}]
            (meta loc)))))))

(defn up
  "親の loc を返す。トップなら nil"
  [loc]
  (let [n (node loc)
        p (loc 1)]
    (when (and p (:pnodes p))
      (let [l (:l p)
            ppath (:ppath p)
            pnodes (:pnodes p)
            r (:r p)
            changed (:changed? p)
            pnode (peek pnodes)]
        (with-meta (if changed
                     [(make-node loc pnode (concat l (cons n r)))
                      (and ppath (assoc ppath :changed? true))]
                     [pnode ppath])
          (meta loc))))))

(defn root
  "トップまで戻りルートノードを返す（変更を反映）"
  [loc]
  (if (= :end (loc 1))
    (node loc)
    (let [p (up loc)]
      (if p
        (recur p)
        (node loc)))))

(defn right
  "右兄弟の loc を返す。なければ nil"
  [loc]
  (let [n (node loc)
        p (loc 1)]
    (when (and p (:r p))
      (let [l (:l p)
            rs (:r p)
            r (first rs)
            rnext (clojure.core/next rs)]
        (with-meta [r (assoc p :l (conj l n) :r rnext)]
          (meta loc))))))

(defn rightmost
  "最右兄弟の loc を返す"
  [loc]
  (let [n (node loc)
        p (loc 1)]
    (if (and p (:r p))
      (with-meta [(last (:r p))
                  (assoc p
                         :l (apply conj (:l p) n (butlast (:r p)))
                         :r nil)]
        (meta loc))
      loc)))

(defn left
  "左兄弟の loc を返す。なければ nil"
  [loc]
  (let [n (node loc)
        p (loc 1)]
    (when (and p (seq (:l p)))
      (with-meta [(peek (:l p))
                  (assoc p :l (pop (:l p)) :r (cons n (:r p)))]
        (meta loc)))))

(defn leftmost
  "最左兄弟の loc を返す"
  [loc]
  (let [n (node loc)
        p (loc 1)]
    (if (and p (seq (:l p)))
      (with-meta [(first (:l p))
                  (assoc p
                         :l []
                         :r (concat (rest (:l p)) [n] (:r p)))]
        (meta loc))
      loc)))

(defn insert-left
  "左兄弟として item を挿入（移動しない）"
  [loc item]
  (let [p (loc 1)]
    (if (nil? p)
      (throw (ex-info "Insert at top" {}))
      (with-meta [(node loc)
                  (assoc p :l (conj (:l p) item) :changed? true)]
        (meta loc)))))

(defn insert-right
  "右兄弟として item を挿入（移動しない）"
  [loc item]
  (let [p (loc 1)]
    (if (nil? p)
      (throw (ex-info "Insert at top" {}))
      (with-meta [(node loc)
                  (assoc p :r (cons item (:r p)) :changed? true)]
        (meta loc)))))

(defn replace
  "loc のノードを置換（移動しない）"
  [loc node]
  (let [p (loc 1)]
    (with-meta [node (assoc p :changed? true)]
      (meta loc))))

(defn edit
  "loc のノードに (f node args) を適用して置換"
  [loc f & args]
  (replace loc (apply f (node loc) args)))

(defn insert-child
  "最左の子として item を挿入（移動しない）"
  [loc item]
  (replace loc (make-node loc (node loc) (cons item (children loc)))))

(defn append-child
  "最右の子として item を追加（移動しない）"
  [loc item]
  (replace loc (make-node loc (node loc) (concat (children loc) [item]))))

(defn next
  "深さ優先で次の loc に移動。終端に達したら end? で検出可能"
  [loc]
  (if (= :end (loc 1))
    loc
    (or
     (and (branch? loc) (down loc))
     (right loc)
     (loop [p loc]
       (if (up p)
         (or (right (up p)) (recur (up p)))
         [(node p) :end])))))

(defn prev
  "深さ優先で前の loc に移動。ルートなら nil"
  [loc]
  (let [lloc (left loc)]
    (if lloc
      (loop [l lloc]
        (if (and (branch? l) (down l))
          (recur (rightmost (down l)))
          l))
      (up loc))))

(defn end?
  "深さ優先走査の終端か"
  [loc]
  (= :end (loc 1)))

(defn remove
  "loc のノードを削除。深さ優先で前の loc を返す"
  [loc]
  (let [p (loc 1)]
    (if (nil? p)
      (throw (ex-info "Remove at top" {}))
      (if (pos? (count (:l p)))
        (loop [l (with-meta [(peek (:l p))
                             (assoc p :l (pop (:l p)) :changed? true)]
                   (meta loc))]
          (if (and (branch? l) (down l))
            (recur (rightmost (down l)))
            l))
        (with-meta [(make-node loc (peek (:pnodes p)) (:r p))
                    (and (:ppath p) (assoc (:ppath p) :changed? true))]
          (meta loc))))))
