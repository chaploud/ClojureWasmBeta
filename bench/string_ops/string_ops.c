#include <stdio.h>
#include <string.h>
#include <ctype.h>
#include <stdlib.h>

// 10000回の upper-case + 結合
int main(void) {
    char *result = malloc(100000);
    result[0] = '\0';
    size_t len = 0;

    for (int i = 0; i < 10000; i++) {
        char buf[20];
        sprintf(buf, "ITEM-%d", i);
        size_t buf_len = strlen(buf);
        memcpy(result + len, buf, buf_len);
        len += buf_len;
    }
    result[len] = '\0';

    printf("%zu\n", len);
    free(result);
    return 0;
}
