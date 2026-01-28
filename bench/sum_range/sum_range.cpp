#include <iostream>

int main() {
    // C++ ranges would be cleaner but this is portable
    long sum = 0;
    for (long i = 0; i < 1000000; i++) {
        sum += i;
    }
    std::cout << sum << std::endl;
    return 0;
}
