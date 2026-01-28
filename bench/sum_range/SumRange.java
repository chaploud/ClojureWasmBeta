import java.util.stream.LongStream;

public class SumRange {
    public static void main(String[] args) {
        long sum = LongStream.range(0, 1000000).sum();
        System.out.println(sum);
    }
}
