# 10000回の upper-case + 結合
result = ''.join(f"item-{i}".upper() for i in range(10000))
print(len(result))
