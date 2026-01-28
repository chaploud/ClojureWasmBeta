import java.util.stream.LongStream;

// filter odd, map square, take 10000, sum
public class MapFilter {
    public static void main(String[] args) {
        long sum = LongStream.range(0, 100000)
            .filter(x -> x % 2 == 1)
            .map(x -> x * x)
            .limit(10000)
            .sum();
        System.out.println(sum);
    }
}
