# 10000個のdictを作成・変換
items = [{"id": i, "value": i, "doubled": i * 2} for i in range(10000)]
print(len(items))
