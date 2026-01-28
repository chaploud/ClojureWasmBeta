;; clojure_math.clj — clojure.math namespace テスト
(load-file "test/lib/test_runner.clj")
(require 'clojure.math)

(println "[clojure_math] running...")

;; === 定数 ===
(test-is (> clojure.math/E 2.718) "E > 2.718")
(test-is (< clojure.math/E 2.719) "E < 2.719")
(test-is (> clojure.math/PI 3.141) "PI > 3.141")
(test-is (< clojure.math/PI 3.142) "PI < 3.142")

;; === 三角関数 ===
(test-eq 0.0 (clojure.math/sin 0) "sin(0) = 0")
(test-eq 1.0 (clojure.math/cos 0) "cos(0) = 1")
(test-eq 0.0 (clojure.math/tan 0) "tan(0) = 0")
(test-is (< (clojure.math/abs (- (clojure.math/sin clojure.math/PI) 0.0)) 1e-10) "sin(PI) ≈ 0")

;; === 逆三角関数 ===
(test-eq 0.0 (clojure.math/asin 0) "asin(0) = 0")
(test-eq 0.0 (clojure.math/acos 1) "acos(1) = 0")
(test-eq 0.0 (clojure.math/atan 0) "atan(0) = 0")
(test-is (< (clojure.math/abs (- (clojure.math/atan2 1 1) (/ clojure.math/PI 4))) 1e-10) "atan2(1,1) ≈ PI/4")

;; === 双曲線関数 ===
(test-eq 0.0 (clojure.math/sinh 0) "sinh(0) = 0")
(test-eq 1.0 (clojure.math/cosh 0) "cosh(0) = 1")
(test-eq 0.0 (clojure.math/tanh 0) "tanh(0) = 0")

;; === 指数・対数 ===
(test-eq 1.0 (clojure.math/exp 0) "exp(0) = 1")
(test-eq 0.0 (clojure.math/expm1 0) "expm1(0) = 0")
(test-is (< (clojure.math/abs (- (clojure.math/log clojure.math/E) 1.0)) 1e-10) "log(E) ≈ 1")
(test-is (< (clojure.math/abs (- (clojure.math/log10 100.0) 2.0)) 1e-10) "log10(100) ≈ 2")
(test-eq 0.0 (clojure.math/log1p 0) "log1p(0) = 0")
(test-eq 1024.0 (clojure.math/pow 2 10) "pow(2,10) = 1024")

;; === 冪根 ===
(test-eq 2.0 (clojure.math/sqrt 4) "sqrt(4) = 2")
(test-is (< (clojure.math/abs (- (clojure.math/cbrt 27.0) 3.0)) 1e-10) "cbrt(27) ≈ 3")
(test-eq 5.0 (clojure.math/hypot 3 4) "hypot(3,4) = 5")

;; === 丸め ===
(test-eq 4.0 (clojure.math/ceil 3.2) "ceil(3.2) = 4")
(test-eq 3.0 (clojure.math/floor 3.7) "floor(3.7) = 3")
(test-eq 4.0 (clojure.math/rint 3.5) "rint(3.5) = 4")
(test-eq 4 (clojure.math/round 3.5) "round(3.5) = 4")
(test-eq 3 (clojure.math/round 3.4) "round(3.4) = 3")

;; === 符号 ===
(test-eq 1.0 (clojure.math/signum 42.0) "signum(42) = 1")
(test-eq -1.0 (clojure.math/signum -3.0) "signum(-3) = -1")

;; === 絶対値 ===
(test-eq 5 (clojure.math/abs -5) "abs(-5) = 5")
(test-eq 3.14 (clojure.math/abs -3.14) "abs(-3.14) = 3.14")

;; === 整数演算 ===
(test-eq 3 (clojure.math/floor-div 7 2) "floor-div(7,2) = 3")
(test-eq 1 (clojure.math/floor-mod 7 2) "floor-mod(7,2) = 1")
(test-eq -4 (clojure.math/floor-div -7 2) "floor-div(-7,2) = -4")
(test-eq 1 (clojure.math/floor-mod -7 2) "floor-mod(-7,2) = 1")

;; === 変換 ===
(test-is (< (clojure.math/abs (- (clojure.math/to-degrees clojure.math/PI) 180.0)) 1e-10) "to-degrees(PI) ≈ 180")
(test-is (< (clojure.math/abs (- (clojure.math/to-radians 180.0) clojure.math/PI)) 1e-10) "to-radians(180) ≈ PI")

;; === random ===
(let [r (clojure.math/random)]
  (test-is (>= r 0.0) "random >= 0")
  (test-is (< r 1.0) "random < 1"))

(test-report)
