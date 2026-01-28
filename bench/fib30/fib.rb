def fib(n)
  return n if n <= 1
  fib(n - 1) + fib(n - 2)
end

# fib(30): baseline用。fib(38) は長時間テスト用
puts fib(30)
