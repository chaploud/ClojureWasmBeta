#include <iostream>

long fib(long n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

int main() {
    long result = fib(38);
    std::cout << result << std::endl;
    return 0;
}
