/**
 * V0.1 实验三：用锁（synchronized）修好它。
 *
 * 锁保证同一时刻只有一个线程能进临界区，读-改-写天然不被打断。
 * 结果是正确的，但代价是：其他 99 个线程只能排队等。
 *
 * 记住这个代价。V1-b 你会看到一模一样的事：
 * 加上数据库条件更新，超卖没了，但 QPS 没涨——
 * 因为"正确"必须靠"排队"换来。
 *
 * 运行：java SyncCounter.java
 */
public class SyncCounter {

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
                    synchronized (SyncCounter.class) {  // <-- 同一时刻只放一个人进来
                        count++;
                    }
                }
            });
            ts[i].start();
        }
        for (Thread t : ts) t.join();
        long ms = (System.nanoTime() - start) / 1_000_000;

        System.out.println("---------- SyncCounter (synchronized 锁) ----------");
        System.out.println("线程数     : " + threads);
        System.out.println("每线程自增 : " + iters);
        System.out.println("期望结果   : " + expect);
        System.out.println("实际结果   : " + count);
        System.out.println("丢失更新   : " + (expect - count) + "  次");
        System.out.println("耗时       : " + ms + " ms");
    }
}
