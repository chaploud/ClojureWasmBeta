def fib(n):
    if n <= 1:
        return n
    return fib(n - 1) + fib(n - 2)

# fib(30): baseline用。fib(38) は長時間テスト用
print(fib(30))
