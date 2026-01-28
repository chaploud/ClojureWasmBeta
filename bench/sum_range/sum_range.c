#include <stdio.h>

int main(void) {
    long sum = 0;
    for (long i = 0; i < 1000000; i++) {
        sum += i;
    }
    printf("%ld\n", sum);
    return 0;
}
