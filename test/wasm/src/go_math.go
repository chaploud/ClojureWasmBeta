package main

//export add
func add(a, b int32) int32 {
	return a + b
}

//export multiply
func multiply(a, b int32) int32 {
	return a * b
}

//export fibonacci
func fibonacci(n int32) int32 {
	if n <= 1 {
		return n
	}
	a, b := int32(0), int32(1)
	for i := int32(2); i <= n; i++ {
		a, b = b, a+b
	}
	return b
}

func main() {}
