# 10000回の upper-case + 結合
result = (0...10000).map { |i| "item-#{i}".upcase }.join
puts result.length
