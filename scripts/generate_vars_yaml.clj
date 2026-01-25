#!/usr/bin/env bb
;; Clojure 名前空間の Var を取得して YAML 形式で出力
;; 使用法: clj -M scripts/generate_vars_yaml.clj > status/vars.yaml

(require '[clojure.string :as str]
         '[clojure.repl]
         '[clojure.set]
         '[clojure.string]
         '[clojure.test]
         '[clojure.pprint]
         '[clojure.stacktrace]
         '[clojure.walk]
         '[clojure.edn]
         '[clojure.data]
         '[clojure.zip]
         '[clojure.template]
         '[clojure.instant]
         '[clojure.uuid])

;; Phase 1-4 の名前空間
(def target-namespaces
  [;; Phase 1: 必須
   {:ns 'clojure.core     :phase 1 :note "中核"}
   {:ns 'clojure.repl     :phase 1 :note "doc, source, apropos"}
   {:ns 'clojure.string   :phase 1 :note "文字列操作"}
   {:ns 'clojure.set      :phase 1 :note "集合操作"}

   ;; Phase 2: テスト・デバッグ
   {:ns 'clojure.test       :phase 2 :note "テストフレームワーク"}
   {:ns 'clojure.pprint     :phase 2 :note "Pretty Print"}
   {:ns 'clojure.stacktrace :phase 2 :note "スタックトレース"}
   {:ns 'clojure.walk       :phase 2 :note "データ構造走査"}

   ;; Phase 3: データ
   {:ns 'clojure.edn  :phase 3 :note "EDN読み書き"}
   {:ns 'clojure.data :phase 3 :note "diff等"}
   {:ns 'clojure.zip  :phase 3 :note "Zipper"}

   ;; Phase 4: その他
   {:ns 'clojure.template :phase 4 :note "テンプレート"}
   {:ns 'clojure.instant  :phase 4 :note "#inst処理"}
   {:ns 'clojure.uuid     :phase 4 :note "#uuid処理"}])

;; clojure.math は Clojure 1.11+ なので別途確認
(try
  (require '[clojure.math])
  (def target-namespaces
    (conj target-namespaces {:ns 'clojure.math :phase 4 :note "数学関数"}))
  (catch Exception _ nil))

;; 特殊形式のリスト（Compiler.java の specials から）
(def special-forms
  #{'def 'if 'do 'let* 'loop* 'recur 'quote 'var 'fn*
    'try 'catch 'finally 'throw 'monitor-enter 'monitor-exit
    'new 'set! '. 'import* 'deftype* 'reify* 'case*
    'letfn* 'clojure.core/import*})

(defn escape-yaml-key [s]
  (let [s (str s)]
    (if (or (str/includes? s ":")
            (str/includes? s "#")
            (str/includes? s "'")
            (str/includes? s "\"")
            (str/includes? s "*")
            (str/includes? s "&")
            (str/includes? s "[")
            (str/includes? s "]")
            (str/includes? s "{")
            (str/includes? s "}")
            (str/starts-with? s "-")
            (str/starts-with? s ".")
            (str/starts-with? s ">")
            (str/starts-with? s "<")
            (str/starts-with? s "=")
            (str/starts-with? s "+")
            (str/starts-with? s "/"))
      (str "\"" s "\"")
      s)))

(defn var-type [sym var-obj]
  (let [m (meta var-obj)]
    (cond
      (contains? special-forms sym) "special-form"
      (:macro m) "macro"
      (and (bound? var-obj)
           (fn? (deref var-obj))) "function"
      (:dynamic m) "dynamic-var"
      :else "var")))

(defn process-var [[sym var-obj]]
  (let [m (meta var-obj)
        type (var-type sym var-obj)]
    {:name (str sym)
     :type type
     :private (:private m)
     :dynamic (:dynamic m)
     :deprecated (boolean (:deprecated m))}))

(defn group-by-type [vars]
  (group-by :type vars))

(defn print-var-entry [{:keys [name type dynamic deprecated]}]
  (let [key (escape-yaml-key name)]
    (println (str "    " key ":"))
    (println (str "      type: " type))
    (println "      status: todo")
    (when dynamic
      (println "      dynamic: true"))
    (when deprecated
      (println "      deprecated: true"))))

;; 特殊形式の情報（Compiler.java から、ns-publicsでは取得不可）
(def special-form-info
  [{:name "def" :note "変数定義"}
   {:name "if" :note "条件分岐"}
   {:name "do" :note "逐次実行"}
   {:name "let*" :note "ローカル束縛（letマクロの展開先）"}
   {:name "loop*" :note "ループ（loopマクロの展開先）"}
   {:name "recur" :note "末尾再帰"}
   {:name "quote" :note "クォート"}
   {:name "var" :note "Var参照"}
   {:name "fn*" :note "無名関数（fnマクロの展開先）"}
   {:name "try" :note "例外処理"}
   {:name "catch" :note "例外捕捉（try内）"}
   {:name "finally" :note "後処理（try内）"}
   {:name "throw" :note "例外送出"}
   {:name "monitor-enter" :note "モニタ入（低レベル同期）"}
   {:name "monitor-exit" :note "モニタ出（低レベル同期）"}
   {:name "new" :note "インスタンス生成"}
   {:name "set!" :note "代入"}
   {:name "." :note "Javaメソッド呼び出し"}
   {:name "import*" :note "クラスインポート（低レベル）"}
   {:name "deftype*" :note "型定義（低レベル）"}
   {:name "reify*" :note "無名型（低レベル）"}
   {:name "case*" :note "case（低レベル）"}
   {:name "letfn*" :note "相互再帰関数（低レベル）"}])

(defn print-special-forms []
  (println "    # SPECIAL FORM (23個)")
  (println "    # 注: 特殊形式はVarではなくコンパイラに組み込み")
  (doseq [{:keys [name note]} (sort-by :name special-form-info)]
    (let [key (escape-yaml-key name)]
      (println (str "    " key ":"))
      (println "      type: special-form")
      (println "      status: todo")
      (when note
        (println (str "      note: \"" note "\""))))))

(defn print-namespace [{:keys [ns phase note]}]
  (let [ns-name (str ns)
        indent "  "]
    ;; 名前空間ヘッダー
    (println "")
    (println (str indent (str/replace ns-name "." "_") ":"))
    (println (str indent "  # Phase " phase ": " note))

    ;; clojure.core のみ特殊形式を出力
    (when (= ns 'clojure.core)
      (print-special-forms))

    ;; public vars を取得
    (let [all-vars (->> (ns-publics ns)
                        (map process-var)
                        (remove :private)
                        (sort-by :name))
          grouped (group-by-type all-vars)
          type-order ["macro" "function" "dynamic-var" "var"]]

      ;; タイプ別に出力
      (doseq [[idx type] (map-indexed vector type-order)]
        (when-let [vars (get grouped type)]
          (println (str indent "  # " (str/upper-case (str/replace type "-" " "))
                        " (" (count vars) "個)"))
          (doseq [v (sort-by :name vars)]
            (print-var-entry v)))))))

(defn main []
  ;; ヘッダー
  (println "---")
  (println "# Clojure Var 対応状況")
  (println "# 自動生成: scripts/generate_vars_yaml.clj")
  (println (str "# 生成日時: " (java.time.LocalDateTime/now)))
  (println "#")
  (println "# Phase 1: 必須 (clojure.core, clojure.repl, clojure.string, clojure.set)")
  (println "# Phase 2: テスト・デバッグ (clojure.test, clojure.pprint, clojure.stacktrace, clojure.walk)")
  (println "# Phase 3: データ (clojure.edn, clojure.data, clojure.zip)")
  (println "# Phase 4: その他 (clojure.template, clojure.instant, clojure.uuid, clojure.math)")
  (println "")
  (println "vars:")

  ;; 各名前空間を出力
  (doseq [ns-info target-namespaces]
    (print-namespace ns-info)))

(main)
