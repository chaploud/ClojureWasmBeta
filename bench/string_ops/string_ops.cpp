#include <iostream>
#include <string>
#include <algorithm>

// 10000回の upper-case + 結合
int main() {
    std::string result;
    for (int i = 0; i < 10000; i++) {
        std::string s = "item-" + std::to_string(i);
        std::transform(s.begin(), s.end(), s.begin(), ::toupper);
        result += s;
    }
    std::cout << result.length() << std::endl;
    return 0;
}
