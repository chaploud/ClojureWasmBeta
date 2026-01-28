;; clojure.string — 文字列操作関数
;;
;; 本家 Clojure の clojure.string 互換 NS。
;; 全関数は Zig builtin として clojure.string 名前空間に直接登録済み
;; (src/lib/core/strings.zig の string_ns_builtins)。
;; このファイルは require 時のファイル解決用に存在する。

(ns clojure.string)
