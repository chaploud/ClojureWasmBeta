#include <iostream>

// filter odd, map square, take 10000, sum
int main() {
    long sum = 0;
    int count = 0;
    for (long i = 0; i < 100000 && count < 10000; i++) {
        if (i % 2 == 1) {
            sum += i * i;
            count++;
        }
    }
    std::cout << sum << std::endl;
    return 0;
}
