#include <iostream>

long fib(long n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

int main() {
    // fib(30): baseline用
    long result = fib(30);
    std::cout << result << std::endl;
    return 0;
}
