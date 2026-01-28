# map-filter: HOF chain
from itertools import islice
result = sum(islice((x*x for x in range(100000) if x % 2 == 1), 10000))
print(result)
