import java.util.List;
import java.util.ArrayList;
import java.util.stream.IntStream;

// 10000個のレコードを作成・変換
record Item(int id, int value, int doubled) {}

public class DataTransform {
    public static void main(String[] args) {
        List<Item> items = IntStream.range(0, 10000)
            .mapToObj(i -> new Item(i, i, i * 2))
            .toList();
        System.out.println(items.size());
    }
}
