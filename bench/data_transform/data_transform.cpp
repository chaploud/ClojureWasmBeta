#include <iostream>
#include <vector>

// 10000個の構造体を作成・変換
struct Item { int id; int value; int doubled; };

int main() {
    std::vector<Item> items;
    items.reserve(10000);

    for (int i = 0; i < 10000; i++) {
        items.push_back({i, i, i * 2});
    }

    std::cout << items.size() << std::endl;
    return 0;
}
