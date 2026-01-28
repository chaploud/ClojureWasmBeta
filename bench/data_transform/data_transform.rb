# 10000個のHashを作成・変換
items = (0...10000).map { |i| { id: i, value: i, doubled: i * 2 } }
puts items.length
