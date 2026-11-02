import java.util.concurrent.atomic.AtomicInteger;

/**
 * V0.1 实验二：用 CAS（对比并交换）修好它。
 *
 * AtomicInteger 的 incrementAndGet() 底层是一条 CPU 指令
 * （ARM 上是 LDXR/STXR 这对，x86 上是 LOCK CMPXCHG），
 * 由硬件保证"读-改-写"三步不被打断。
 *
 * 注意：CAS 失败会重试（自旋），所以它不是"免费"的，
 * 线程越多，重试越多，吞吐会下降——但结果永远正确。
 *
 * 运行：java AtomicCounter.java
 */
public class AtomicCounter {

    static final AtomicInteger count = new AtomicInteger(0);

    public static void main(String[] args) throws Exception {
        int threads = args.length > 0 ? Integer.parseInt(args[0]) : 100;
        int iters = args.length > 1 ? Integer.parseInt(args[1]) : 1000;
        long expect = (long) threads * iters;

        Thread[] ts = new Thread[threads];
        long start = System.nanoTime();
        for (int i = 0; i < threads; i++) {
            ts[i] = new Thread(() -> {
                for (int j = 0; j < iters; j++) {
                    count.incrementAndGet();   // <-- 原子操作
                }
            });
            ts[i].start();
        }
        for (Thread t : ts) t.join();
        long ms = (System.nanoTime() - start) / 1_000_000;

        System.out.println("---------- AtomicCounter (CAS 原子操作) ----------");
        System.out.println("线程数     : " + threads);
        System.out.println("每线程自增 : " + iters);
        System.out.println("期望结果   : " + expect);
        System.out.println("实际结果   : " + count.get());
        System.out.println("丢失更新   : " + (expect - count.get()) + "  次");
        System.out.println("耗时       : " + ms + " ms");
    }
}
