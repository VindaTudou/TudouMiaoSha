package com.tudou.miaosha.support;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;

/**
 * V3 的四个自定义指标。
 *
 * 为什么需要自己埋点，而不只是用 Spring Boot 自带的 http_server_requests：
 *   自带的只知道「这个 URL 花了多久」，它不知道
 *     - 这单是抢到了、售罄、重复、还是被限流
 *     - 这 37ms 里，Redis 占多少、Kafka 占多少      ← V2 没定位出来的那个问题
 *     - 消费者到底落库成功了几单、跳过了几单
 *
 * 指标命名遵循 Prometheus 惯例：
 *   Counter 用 _total，Timer 用 _seconds（Micrometer 自动加后缀）。
 */
@Component
public class MiaoshaMetrics {

    /** 下单结果，和 HTTP 状态码是两回事：一个 409 可能是售罄也可能是重复。 */
    public static final String ORDER_SUCCESS = "success";
    public static final String ORDER_SOLDOUT = "soldout";
    public static final String ORDER_DUPLICATE = "duplicate";
    public static final String ORDER_RATE_LIMITED = "ratelimited";
    public static final String ORDER_SEND_FAIL = "send_fail";
    public static final String ORDER_NOT_PREHEATED = "not_preheated";

    /** 消费者的三种结局。 */
    public static final String PERSIST_OK = "ok";
    public static final String PERSIST_DUP = "dup";
    public static final String PERSIST_SHORT = "short";        // Redis 有库存但 DB 没有 → 少卖
    public static final String PERSIST_BAD_MESSAGE = "bad_message";
    public static final String PERSIST_FAIL = "fail";

    private final Map<String, Counter> orderCounters = new ConcurrentHashMap<>();
    private final Map<String, Counter> persistCounters = new ConcurrentHashMap<>();
    private final MeterRegistry registry;
    private final Timer redisDeduct;
    private final Timer kafkaSend;

    public MiaoshaMetrics(MeterRegistry registry) {
        this.registry = registry;

        // 全部预注册：让指标从 0 开始就在，而不是等第一单发生才出现。
        // 否则 Grafana 上新实例的面板会是空洞，容易误判成"没有流量"。
        for (String r : List.of(ORDER_SUCCESS, ORDER_SOLDOUT, ORDER_DUPLICATE,
                ORDER_RATE_LIMITED, ORDER_SEND_FAIL, ORDER_NOT_PREHEATED)) {
            orderCounters.put(r, Counter.builder("miaosha.order")
                    .description("下单结果（业务视角，不是 HTTP 状态码）")
                    .tag("result", r)
                    .register(registry));
        }
        for (String r : List.of(PERSIST_OK, PERSIST_DUP, PERSIST_SHORT,
                PERSIST_BAD_MESSAGE, PERSIST_FAIL)) {
            persistCounters.put(r, Counter.builder("miaosha.consumer.persist")
                    .description("消费落库结果")
                    .tag("result", r)
                    .register(registry));
        }

        this.redisDeduct = Timer.builder("miaosha.redis.deduct")
                .description("Redis Lua 原子扣减耗时")
                .publishPercentiles(0.5, 0.95, 0.99)
                .register(registry);

        this.kafkaSend = Timer.builder("miaosha.kafka.send")
                .description("生产者发送并等待 ack 的耗时（含 linger 与网络往返）")
                .publishPercentiles(0.5, 0.95, 0.99)
                .register(registry);
    }

    public void order(String result) {
        orderCounters.computeIfAbsent(result, r -> Counter.builder("miaosha.order")
                .tag("result", r).register(registry)).increment();
    }

    public void persist(String result) {
        persistCounters.computeIfAbsent(result, r -> Counter.builder("miaosha.consumer.persist")
                .tag("result", r).register(registry)).increment();
    }

    /** 用 nanoTime 自己算，因为调用点要处理受检异常，包不进 Supplier。 */
    public void recordRedisDeduct(long nanos) {
        redisDeduct.record(nanos, TimeUnit.NANOSECONDS);
    }

    public void recordKafkaSend(long nanos) {
        kafkaSend.record(nanos, TimeUnit.NANOSECONDS);
    }
}
