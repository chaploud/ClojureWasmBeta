;; clojure.math — 数学関数
;;
;; java.lang.Math 互換の数学関数を提供。
;; 内部は Zig std.math による実装。

(ns clojure.math)

;; 定数
(def E  2.718281828459045)
(def PI 3.141592653589793)

;; 三角関数
(defn sin  [a] (__math-sin a))
(defn cos  [a] (__math-cos a))
(defn tan  [a] (__math-tan a))
(defn asin [a] (__math-asin a))
(defn acos [a] (__math-acos a))
(defn atan [a] (__math-atan a))
(defn atan2 [y x] (__math-atan2 y x))

;; 双曲線関数
(defn sinh [a] (__math-sinh a))
(defn cosh [a] (__math-cosh a))
(defn tanh [a] (__math-tanh a))

;; 指数・対数
(defn exp   [a] (__math-exp a))
(defn expm1 [a] (__math-expm1 a))
(defn log   [a] (__math-log a))
(defn log10 [a] (__math-log10 a))
(defn log1p [a] (__math-log1p a))
(defn pow   [a b] (__math-pow a b))

;; 冪根・距離
(defn sqrt  [a] (__math-sqrt a))
(defn cbrt  [a] (__math-cbrt a))
(defn hypot [x y] (__math-hypot x y))

;; 丸め
(defn ceil  [a] (__math-ceil a))
(defn floor [a] (__math-floor a))
(defn rint  [a] (__math-rint a))
(defn round [a] (__math-round a))

;; 符号・浮動小数点
(defn signum    [a] (__math-signum a))
(defn copy-sign [magnitude sign] (__math-copy-sign magnitude sign))
(defn abs       [a] (__math-abs a))

;; 整数演算
(defn floor-div [x y] (__math-floor-div x y))
(defn floor-mod [x y] (__math-floor-mod x y))

;; その他
(defn IEEE-remainder [dividend divisor] (__math-IEEE-remainder dividend divisor))
(defn to-degrees [a] (__math-to-degrees a))
(defn to-radians [a] (__math-to-radians a))
(defn random [] (__math-random))
