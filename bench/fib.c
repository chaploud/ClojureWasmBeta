#include <stdio.h>

long fib(long n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

int main(void) {
    // fib(30): baseline用
    long result = fib(30);
    printf("%ld\n", result);
    return 0;
}
