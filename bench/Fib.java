public class Fib {
    static long fib(long n) {
        if (n <= 1) return n;
        return fib(n - 1) + fib(n - 2);
    }

    public static void main(String[] args) {
        // JIT ウォームアップ
        for (int i = 0; i < 3; i++) {
            fib(30);
        }
        // fib(30): baseline用
        long result = fib(30);
        System.out.println(result);
    }
}
