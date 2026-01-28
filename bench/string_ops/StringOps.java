// 10000回の upper-case + 結合
public class StringOps {
    public static void main(String[] args) {
        StringBuilder result = new StringBuilder();
        for (int i = 0; i < 10000; i++) {
            result.append(("item-" + i).toUpperCase());
        }
        System.out.println(result.length());
    }
}
