;; regex.clj — 正規表現テスト
(load-file "test/lib/test_runner.clj")

(println "[regex] running...")

;; === re-find ===
(test-eq "123" (re-find #"\d+" "abc123def") "re-find digits")
(test-eq nil (re-find #"\d+" "abcdef") "re-find no match")
(test-eq "hello" (re-find #"hello" "say hello world") "re-find literal")

;; === re-find with groups ===
(test-eq ["123-456" "123" "456"] (re-find #"(\d+)-(\d+)" "abc123-456def") "re-find groups")

;; === re-matches ===
(test-eq "123" (re-matches #"\d+" "123") "re-matches full")
(test-eq nil (re-matches #"\d+" "abc123") "re-matches partial")
(test-eq nil (re-matches #"\d+" "123abc") "re-matches partial tail")

;; === re-seq ===
(test-eq '("123" "456") (re-seq #"\d+" "abc123def456") "re-seq")
(test-eq '("a" "b" "c") (re-seq #"[a-z]" "a1b2c3") "re-seq chars")
(test-eq '() (re-seq #"\d+" "abcdef") "re-seq no match")

;; === re-pattern ===
(let [pat (re-pattern "\\d+")]
  (test-eq "123" (re-find pat "abc123def") "re-pattern usage"))

;; === clojure.string/replace with regex ===
(test-eq "h-ll-" (clojure.string/replace "hello" #"[eo]" "-") "replace regex")
(test-eq "abc" (clojure.string/replace "a1b2c3" #"\d" "") "replace remove digits")

;; === clojure.string/split ===
(test-eq ["a" "b" "c"] (clojure.string/split "a,b,c" ",") "split comma")
(test-eq ["a" "b" "c"] (clojure.string/split "a::b::c" "::") "split multi-char")

;; === re-find 応用 ===
(test-is (some? (re-find #"^\d{3}-\d{4}$" "123-4567")) "re-find phone pattern")
(test-eq nil (re-find #"^\d{3}-\d{4}$" "12-4567") "re-find phone no match")

;; === レポート ===
(println "[regex]")
(test-report)
