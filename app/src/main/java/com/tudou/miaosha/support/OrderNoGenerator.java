package com.tudou.miaosha.support;

import java.util.concurrent.atomic.AtomicLong;

/**
 * 订单号生成器。
 *
 * V1 第一版用了 "当前毫秒 + 4 位随机数"，高并发下同一毫秒内会撞车，
 * 被 orders.uk_order_no 唯一索引抓住（Duplicate entry）。
 *
 * 现在的做法：一个从当前毫秒起步的原子自增计数器，转成 36 进制。
 *   - 原子自增 → 同一个 JVM 内绝不会重复
 *   - 从毫秒起步 → 生成的号大致按时间递增，便于排查
 *   - 36 进制 → 11 个字符左右，比纯十进制短
 *
 * 【局限，V3 必须处理】
 *   这个方案只在单实例下正确。V3 起 3 个实例后，
 *   两台机器可能在同一毫秒各自从同一个种子开始，
 *   必须引入「机器位」—— 那就是 Snowflake 算法做的事：
 *   64 位 = 1 位符号 + 41 位时间戳 + 10 位机器号 + 12 位序列号。
 *   面试里被问"订单号怎么生成"，这条演进线就是答案。
 */
public final class OrderNoGenerator {

    private static final AtomicLong SEQ = new AtomicLong(System.currentTimeMillis());

    private OrderNoGenerator() {
    }

    public static String next() {
        long v = SEQ.incrementAndGet();
        return "O" + Long.toString(v, 36).toUpperCase();
    }
}
