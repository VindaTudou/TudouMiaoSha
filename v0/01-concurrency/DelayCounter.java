/**
 * V0.1 追问：把"读-改-写"之间的窗口人为撑宽，看丢失率怎么变。
 *
 * 这个实验的作用：把"窗口宽度"从一个抽象说法变成可测量的自变量。
 *   读 count → [自旋 spin 次] → 写回 count
 *
 * 预测：spin 越大，窗口越宽，别人越容易在你写回之前插进来，丢失率越高。
 *
 * 运行：java DelayCounter.java 100 2000 0
 *       java DelayCounter.java 100 2000 100
 */
public class DelayCounter {

    static int count = 0;

    public static void main(String[] args) throws Exception {
        int threads = args.length > 0 ? Integer.parseInt(args[0]) : 100;
        int iters = args.length > 1 ? Integer.parseInt(args[1]) : 2000;
        int spin = args.length > 2 ? Integer.parseInt(args[2]) : 0;
        long expect = (long) threads * iters;

        Thread[] ts = new Thread[threads];
        long start = System.nanoTime();
        for (int i = 0; i < threads; i++) {
            ts[i] = new Thread(() -> {
                for (int j = 0; j < iters; j++) {
                    int v = count;                                      // ① 读
                    for (int k = 0; k < spin; k++) Thread.onSpinWait(); // ② 窗口
                    count = v + 1;                                      // ③ 写
                }
            });
            ts[i].start();
        }
        for (Thread t : ts) t.join();
        long ms = (System.nanoTime() - start) / 1_000_000;

        System.out.println("---------- DelayCounter ----------");
        System.out.println("线程数     : " + threads);
        System.out.println("每线程次数 : " + iters);
        System.out.println("自旋次数   : " + spin);
        System.out.println("期望结果   : " + expect);
        System.out.println("实际结果   : " + count);
        System.out.println("丢失更新   : " + (expect - count));
        System.out.println("丢失率     : " + String.format("%.2f%%", (expect - count) * 100.0 / expect));
        System.out.println("耗时       : " + ms + " ms");
    }
}
