/**
 * V0.1 实验一：不加任何保护的自增。
 *
 * 预期会看到：实际值 < 期望值，差值就是"丢失的更新"。
 * 这个 bug 的名字叫 Lost Update（丢失更新），
 * 它就是秒杀超卖的同一件事，只是发生在内存里而不是数据库里。
 *
 * 运行：java NaiveCounter.java            (默认 100 线程 x 1000 次)
 *       java NaiveCounter.java 100 100000 (100 线程 x 10 万次，丢失更明显)
 */
public class NaiveCounter {

    // 共享变量：100 个线程同时读它、加一、写回去
    static int count = 0;

    public static void main(String[] args) throws Exception {
        int threads = args.length > 0 ? Integer.parseInt(args[0]) : 100;
        int iters = args.length > 1 ? Integer.parseInt(args[1]) : 1000;
        long expect = (long) threads * iters;

        Thread[] ts = new Thread[threads];
        long start = System.nanoTime();
        for (int i = 0; i < threads; i++) {
            ts[i] = new Thread(() -> {
                for (int j = 0; j < iters; j++) {
                    count++;              // <-- 问题就在这一行
                }
            });
            ts[i].start();
        }
        for (Thread t : ts) t.join();
        long ms = (System.nanoTime() - start) / 1_000_000;

        System.out.println("---------- NaiveCounter (无任何保护) ----------");
        System.out.println("线程数     : " + threads);
        System.out.println("每线程自增 : " + iters);
        System.out.println("期望结果   : " + expect);
        System.out.println("实际结果   : " + count);
        System.out.println("丢失更新   : " + (expect - count) + "  次");
        System.out.println("耗时       : " + ms + " ms");
    }
}
