;; clojure_string.clj — clojure.string namespace テスト
;; require 経由で標準名アクセスをテスト
(load-file "test/lib/test_runner.clj")
(require 'clojure.string)

(println "[clojure_string] running...")

;; === ケース変換 ===
(test-eq "HELLO" (clojure.string/upper-case "hello") "upper-case")
(test-eq "hello" (clojure.string/lower-case "HELLO") "lower-case")
(test-eq "Hello" (clojure.string/capitalize "hello") "capitalize lower")
(test-eq "Hello" (clojure.string/capitalize "HELLO") "capitalize upper")
(test-eq "" (clojure.string/capitalize "") "capitalize empty")

;; === トリム ===
(test-eq "hello" (clojure.string/trim "  hello  ") "trim")
(test-eq "hello  " (clojure.string/triml "  hello  ") "triml")
(test-eq "  hello" (clojure.string/trimr "  hello  ") "trimr")

;; === 述語 ===
(test-eq true (clojure.string/blank? "") "blank? empty")
(test-eq true (clojure.string/blank? "  ") "blank? spaces")
(test-eq false (clojure.string/blank? "a") "blank? non-empty")
(test-eq true (clojure.string/starts-with? "hello" "hel") "starts-with? true")
(test-eq false (clojure.string/starts-with? "hello" "xyz") "starts-with? false")
(test-eq true (clojure.string/ends-with? "hello" "llo") "ends-with? true")
(test-eq false (clojure.string/ends-with? "hello" "xyz") "ends-with? false")
(test-eq true (clojure.string/includes? "hello" "ell") "includes? true")
(test-eq false (clojure.string/includes? "hello" "xyz") "includes? false")

;; === 検索 ===
(test-eq 2 (clojure.string/index-of "hello" "ll") "index-of found")
(test-eq 0 (clojure.string/index-of "hello" "h") "index-of start")
(test-eq nil (clojure.string/index-of "hello" "xyz") "index-of not found")
(test-eq 3 (clojure.string/index-of "hello" "l" 3) "index-of from-index")
(test-eq 3 (clojure.string/last-index-of "hello" "l") "last-index-of found")
(test-eq 0 (clojure.string/last-index-of "hello" "h") "last-index-of start")
(test-eq nil (clojure.string/last-index-of "hello" "xyz") "last-index-of not found")

;; === 置換 ===
(test-eq "hero world" (clojure.string/replace "hello world" "llo" "ro") "replace")
(test-eq "baab" (clojure.string/replace-first "aaab" "a" "b") "replace-first")

;; === 分割・結合 ===
(test-eq ["a" "b" "c"] (clojure.string/split "a,b,c" #",") "split")
(test-eq "a, b, c" (clojure.string/join ", " ["a" "b" "c"]) "join separator")
(test-eq "abc" (clojure.string/join ["a" "b" "c"]) "join no separator")

;; === 反転 ===
(test-eq "olleh" (clojure.string/reverse "hello") "reverse")
(test-eq "" (clojure.string/reverse "") "reverse empty")

;; === re-quote-replacement ===
(test-eq "\\$1" (clojure.string/re-quote-replacement "$1") "re-quote-replacement")

(test-report)
