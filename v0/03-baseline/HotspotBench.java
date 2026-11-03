import java.sql.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/**
 * 热点行并发基线压测（V0.4）
 *
 * 测什么：N 个连接同时执行同一条 UPDATE，打同一行，测出 MySQL 单行热点写的吞吐上限。
 * 为什么用 JDBC 而不是 mysql 命令行：命令行每次调用都有几十毫秒进程启动开销，
 *   会把真实 TPS 淹掉；JDBC 是长连接，测的才是数据库本身。
 *
 * 关键设计：
 *   1. 显式打印全部参数（V0.1 的教训：不打印参数的实验不可复现）
 *   2. 区分"影响 1 行"和"影响 0 行"——这是识别"卖完后空转"的关键
 *   3. 预热阶段单独跑，不计入统计（JIT + 连接池 + 缓存预热）
 *   4. 同时给出 QPS 和 p50/p95/p99，只看平均值会骗人
 *
 * 用法：
 *   java -cp "lib/*:." HotspotBench.java 16 10 3
 *   java -cp "lib/*:." -Dsql="UPDATE ..." HotspotBench.java 32 10 3
 */
public class HotspotBench {

    static final String URL = System.getProperty("url",
            "jdbc:mysql://127.0.0.1:3307/miaosha?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=Asia/Shanghai");
    static final String USER = System.getProperty("user", "root");
    static final String PASS = System.getProperty("pass", "root");
    static final String SQL = System.getProperty("sql",
            "UPDATE product SET stock = stock - 1 WHERE id = 1 AND stock >= 1");

    static volatile boolean RECORD = false;

    static class Res {
        long ok, zero, err;
        long[] lat = new long[500_000];
        int n;
    }

    public static void main(String[] args) throws Exception {
        int threads = args.length > 0 ? Integer.parseInt(args[0]) : 16;
        int seconds = args.length > 1 ? Integer.parseInt(args[1]) : 10;
        int warmupSec = args.length > 2 ? Integer.parseInt(args[2]) : 3;

        System.out.println("==================================================");
        System.out.printf(" 线程=%d  时长=%ds  预热=%ds%n", threads, seconds, warmupSec);
        System.out.println(" SQL: " + SQL);
        System.out.println("==================================================");

        // 预热：跑一遍完整的连接 + 语句，结果丢弃
        runPhase(threads, warmupSec, null);

        Res[] results = runPhase(threads, seconds, new Res[threads]);

        long ok = 0, zero = 0, err = 0;
        int total = 0;
        for (Res r : results) {
            ok += r.ok; zero += r.zero; err += r.err; total += r.n;
        }
        long[] all = new long[total];
        int p = 0;
        for (Res r : results) {
            System.arraycopy(r.lat, 0, all, p, r.n);
            p += r.n;
        }
        Arrays.sort(all);

        long totalReq = ok + zero + err;
        double qps = totalReq / (double) seconds;

        System.out.printf("%-14s %d%n", "总请求", totalReq);
        System.out.printf("%-14s %d  (%.2f%%)%n", "影响 1 行", ok, pct(ok, totalReq));
        System.out.printf("%-14s %d  (%.2f%%)%n", "影响 0 行", zero, pct(zero, totalReq));
        System.out.printf("%-14s %d  (%.2f%%)%n", "异常", err, pct(err, totalReq));
        System.out.printf("%-14s %.1f%n", "QPS", qps);
        if (total > 0) {
            System.out.printf("%-14s p50=%.2fms  p95=%.2fms  p99=%.2fms  max=%.2fms%n",
                    "延迟",
                    all[total / 2] / 1e6,
                    all[(int) (total * 0.95)] / 1e6,
                    all[Math.min(total - 1, (int) (total * 0.99))] / 1e6,
                    all[total - 1] / 1e6);
        }
        System.out.println();
    }

    static double pct(long a, long b) { return b == 0 ? 0 : a * 100.0 / b; }

    static Res[] runPhase(int threads, int seconds, Res[] recycled) throws Exception {
        RECORD = recycled != null;   // 预热阶段不记录延迟，省内存
        ExecutorService pool = Executors.newFixedThreadPool(threads);
        List<Future<Res>> futures = new ArrayList<>();
        final long deadline = System.nanoTime() + seconds * 1_000_000_000L;

        for (int i = 0; i < threads; i++) {
            futures.add(pool.submit(() -> {
                Res r = new Res();
                try (Connection c = DriverManager.getConnection(URL, USER, PASS)) {
                    c.setAutoCommit(true);   // 每条语句一个事务，和 V1 无 @Transactional 时一致
                    try (PreparedStatement ps = c.prepareStatement(SQL)) {
                        while (System.nanoTime() < deadline) {
                            long t0 = System.nanoTime();
                            try {
                                int rows = ps.executeUpdate();
                                long dt = System.nanoTime() - t0;
                                if (rows > 0) r.ok++; else r.zero++;
                                if (RECORD && r.n < r.lat.length) r.lat[r.n++] = dt;
                            } catch (SQLException e) {
                                r.err++;
                                if (r.err <= 3) System.err.println("  SQL 异常: " + e.getMessage());
                            }
                        }
                    }
                } catch (Exception e) {
                    System.err.println("  连接异常: " + e.getMessage());
                }
                return r;
            }));
        }
        Res[] out = new Res[threads];
        for (int i = 0; i < threads; i++) out[i] = futures.get(i).get();
        pool.shutdown();
        return out;
    }
}
