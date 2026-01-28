#include <stdio.h>
#include <stdlib.h>

// 10000個の構造体を作成・変換
typedef struct { int id; int value; int doubled; } Item;

int main(void) {
    Item *items = malloc(sizeof(Item) * 10000);

    for (int i = 0; i < 10000; i++) {
        items[i].id = i;
        items[i].value = i;
        items[i].doubled = i * 2;
    }

    printf("%d\n", 10000);
    free(items);
    return 0;
}
