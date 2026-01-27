;; strings.clj — 文字列操作テスト
;; NOTE: ClojureWasmBeta では clojure.string/* は clojure.core の
;;       string-split, string-join, string-replace 等として実装されている
(load-file "test/lib/test_runner.clj")

(println "[strings] running...")

;; === str ===
(test-eq "" (str) "str empty")
(test-eq "hello" (str "hello") "str single")
(test-eq "hello world" (str "hello" " " "world") "str concat")
(test-eq "42" (str 42) "str number")
(test-eq ":a" (str :a) "str keyword")
(test-eq "" (str nil) "str nil")

;; === subs ===
(test-eq "llo" (subs "hello" 2) "subs from")
(test-eq "ll" (subs "hello" 2 4) "subs from-to")

;; === count (string) ===
(test-eq 5 (count "hello") "count string")
(test-eq 0 (count "") "count empty string")

;; === upper-case / lower-case ===
(test-eq "HELLO" (upper-case "hello") "upper-case")
(test-eq "hello" (lower-case "HELLO") "lower-case")

;; === trim / triml / trimr ===
(test-eq "hello" (trim "  hello  ") "trim")
(test-eq "hello  " (triml "  hello  ") "triml")
(test-eq "  hello" (trimr "  hello  ") "trimr")

;; === blank? ===
(test-is (blank? "") "blank? empty")
(test-is (blank? "  ") "blank? spaces")
(test-is (blank? nil) "blank? nil")
(test-is (not (blank? "a")) "blank? non-blank")

;; === starts-with? / ends-with? / includes? ===
(test-is (starts-with? "hello" "hel") "starts-with?")
(test-is (not (starts-with? "hello" "llo")) "starts-with? false")
(test-is (ends-with? "hello" "llo") "ends-with?")
(test-is (includes? "hello world" "lo wo") "includes?")

;; === string-split ===
(let [result (string-split "a,b,c" ",")]
  (test-eq ["a" "b" "c"] result "split comma"))
(let [result (string-split "a::b::c" "::")]
  (test-eq ["a" "b" "c"] result "split multi-char"))

;; === string-join ===
(test-eq "a,b,c" (string-join "," ["a" "b" "c"]) "join comma")
(test-eq "abc" (string-join ["a" "b" "c"]) "join no sep")

;; === string-replace ===
(test-eq "hxllo" (string-replace "hello" "e" "x") "replace str")
(test-eq "h-ll-" (string-replace "hello" #"[eo]" "-") "replace regex")

;; === string-replace-first ===
(test-eq "hxllo" (string-replace-first "hello" "e" "x") "replace-first")

;; === re-find / re-matches / re-seq ===
(test-eq "123" (re-find #"\d+" "abc123def") "re-find")
(test-eq nil (re-find #"\d+" "abcdef") "re-find nil")
(test-eq "123" (re-matches #"\d+" "123") "re-matches full")
(test-eq nil (re-matches #"\d+" "abc123") "re-matches partial")
(test-eq ["123" "456"] (re-seq #"\d+" "abc123def456") "re-seq")

;; === format ===
(test-eq "hello 42" (format "hello %d" 42) "format int")
(test-eq "abc" (format "%s" "abc") "format str")

;; === name / namespace (keyword/symbol) ===
(test-eq "a" (name :a) "name keyword")
(test-eq "a" (name 'a) "name symbol")
(test-eq "b" (name :a/b) "name ns-keyword")
(test-eq "a" (namespace :a/b) "namespace ns-keyword")
(test-eq nil (namespace :a) "namespace plain keyword")

;; === keyword / symbol 変換 ===
(test-eq :hello (keyword "hello") "keyword from string")
(test-eq 'hello (symbol "hello") "symbol from string")
(test-eq :ns/name (keyword "ns" "name") "keyword with ns")

;; === with-out-str ===
(test-eq "hello\n" (with-out-str (println "hello")) "with-out-str println")
(test-eq "12" (with-out-str (print 1) (print 2)) "with-out-str multi print")
(test-eq "" (with-out-str 42) "with-out-str no output")
(test-eq ":a 1\n" (with-out-str (prn :a 1)) "with-out-str prn")
(test-eq "42" (with-out-str (pr 42)) "with-out-str pr")
(test-eq "\n" (with-out-str (newline)) "with-out-str newline")
(test-eq "hello world" (with-out-str (print "hello") (print " ") (print "world")) "with-out-str concat")

;; ネストした with-out-str
(test-eq "inner"
         (with-out-str
           (print "inner")
           (with-out-str (print "hidden"))) ;; hidden は内側のキャプチャに入り、外に漏れない
         "with-out-str nested: inner captures")

;; 外側は内側キャプチャの結果を含まない
(let [outer (with-out-str
              (print "A")
              (let [inner (with-out-str (print "B"))]
                (print inner)))]
  (test-eq "AB" outer "with-out-str nested: outer gets inner result"))

;; === レポート ===
(println "[strings]")
(test-report)
