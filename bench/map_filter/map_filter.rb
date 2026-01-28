# map-filter: HOF chain
puts (0...100000).lazy.select(&:odd?).map { |x| x * x }.take(10000).sum
