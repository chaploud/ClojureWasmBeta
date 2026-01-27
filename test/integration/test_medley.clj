(ns test.integration.test-medley)

(require 'medley-trimmed.core)

;; === Tier 1: 基本関数テスト ===

;; abs
(assert (= (medley-trimmed.core/abs -3) 3) "abs -3")
(assert (= (medley-trimmed.core/abs 5) 5) "abs 5")
(assert (= (medley-trimmed.core/abs 0) 0) "abs 0")

;; find-first
(assert (= (medley-trimmed.core/find-first even? [1 3 4 5]) 4) "find-first even")
(assert (= (medley-trimmed.core/find-first even? [1 3 5]) nil) "find-first nil")

;; assoc-some
(assert (= (medley-trimmed.core/assoc-some {:a 1} :b 2) {:a 1 :b 2}) "assoc-some non-nil")
(assert (= (medley-trimmed.core/assoc-some {:a 1} :b nil) {:a 1}) "assoc-some nil")

;; dissoc-in
(assert (= (medley-trimmed.core/dissoc-in {:a {:b 1}} [:a :b]) {}) "dissoc-in basic")

;; update-existing
(assert (= (medley-trimmed.core/update-existing {:a 1 :b 2} :a inc) {:a 2 :b 2}) "update-existing found")
(assert (= (medley-trimmed.core/update-existing {:a 1 :b 2} :c inc) {:a 1 :b 2}) "update-existing not found")

;; === Tier 2: マップ操作テスト ===

;; map-keys
(assert (= (medley-trimmed.core/map-keys name {:a 1 :b 2}) {"a" 1 "b" 2}) "map-keys")

;; map-vals
(assert (= (medley-trimmed.core/map-vals inc {:a 1 :b 2}) {:a 2 :b 3}) "map-vals")

;; filter-keys (using fn instead of set-as-fn since sets-as-fn not yet supported)
(assert (= (medley-trimmed.core/filter-keys (fn [k] (or (= k :a) (= k :b))) {:a 1 :b 2 :c 3}) {:a 1 :b 2}) "filter-keys")

;; filter-vals
(assert (= (medley-trimmed.core/filter-vals even? {:a 1 :b 2 :c 3}) {:b 2}) "filter-vals")

;; === Tier 3: 型判定・ユーティリティ ===

;; boolean?
(assert (= (medley-trimmed.core/boolean? true) true) "boolean? true")
(assert (= (medley-trimmed.core/boolean? false) true) "boolean? false")
(assert (= (medley-trimmed.core/boolean? nil) false) "boolean? nil")

;; least / greatest
(assert (= (medley-trimmed.core/least 3 1 2) 1) "least")
(assert (= (medley-trimmed.core/greatest 3 1 2) 3) "greatest")

(prn "All medley integration tests passed!")
