/**
 * V0.1 追问：把 count 加上 volatile，到底改了什么？
 *
 * 和 NaiveCounter 唯一的区别：static volatile int count = 0;
 *
 * 预测：仍然会丢。volatile 只保证"别人能看见你写的值"，
 *      不保证"读-改-写"这一串动作不被打断。
 *
 * 运行：java VolatileCounter.java 100 20000
 */
public class VolatileCounter {

    static volatile int count = 0;   // <-- 唯一的改动

    public static void main(String[] args) throws Exception {
        int threads = args.length > 0 ? Integer.parseInt(args[0]) : 100;
        int iters = args.length > 1 ? Integer.parseInt(args[1]) : 20000;
        long expect = (long) threads * iters;

        Thread[] ts = new Thread[threads];
        long start = System.nanoTime();
        for (int i = 0; i < threads; i++) {
            ts[i] = new Thread(() -> {
                for (int j = 0; j < iters; j++) {
                    count++;
                }
            });
            ts[i].start();
        }
        for (Thread t : ts) t.join();
        long ms = (System.nanoTime() - start) / 1_000_000;

        System.out.println("---------- VolatileCounter (volatile 修饰) ----------");
        System.out.println("期望结果   : " + expect);
        System.out.println("实际结果   : " + count);
        System.out.println("丢失更新   : " + (expect - count) + "  次");
        System.out.println("丢失率     : " + String.format("%.2f%%", (expect - count) * 100.0 / expect));
        System.out.println("耗时       : " + ms + " ms");
    }
}
