package com.tudou.miaosha.service;

import com.tudou.miaosha.repository.ProductRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.script.DefaultRedisScript;
import org.springframework.stereotype.Service;

import java.util.List;

/**
 * 活动期间的库存账本 —— 放在 Redis 里。
 *
 * 注意它【不是缓存】：缓存丢了从 MySQL 重建就行，这里的库存丢了会超卖。
 * 所以 Redis 必须配 AOF，活动结束后还要和 MySQL 对账。
 */
@Service
public class StockService {

    private static final Logger log = LoggerFactory.getLogger(StockService.class);
    private static final String STOCK_KEY = "seckill:stock:%d";
    private static final String USERS_KEY = "seckill:users:%d";
    private static final String PRICE_KEY = "seckill:price:%d";

    private final StringRedisTemplate redis;
    private final DefaultRedisScript<Long> stockDeductScript;
    private final ProductRepository products;

    public StockService(StringRedisTemplate redis,
                        DefaultRedisScript<Long> stockDeductScript,
                        ProductRepository products) {
        this.redis = redis;
        this.stockDeductScript = stockDeductScript;
        this.products = products;
    }

    /** 从 MySQL 把库存和价格预热进 Redis，并清空去重集合。 */
    public int preheat(long productId) {
        var p = products.findById(productId)
                .orElseThrow(() -> new IllegalArgumentException("商品不存在: " + productId));
        redis.opsForValue().set(stockKey(productId), String.valueOf(p.stock()));
        redis.opsForValue().set(priceKey(productId), p.price().toPlainString());
        redis.delete(usersKey(productId));
        log.info("预热完成 productId={} stock={} price={}", productId, p.stock(), p.price());
        return p.stock();
    }

    /**
     * 原子扣减。
     *
     * @return 1 抢到 / 0 售罄 / -1 重复 / -2 未预热
     */
    public long tryDeduct(long productId, long userId, int quantity) {
        Long r = redis.execute(
                stockDeductScript,
                List.of(stockKey(productId), usersKey(productId)),
                String.valueOf(quantity),
                String.valueOf(userId));
        return r == null ? -2 : r;
    }

    /** 发 MQ 失败时回滚，把库存和用户标记还回去。 */
    public void rollback(long productId, long userId, int quantity) {
        redis.opsForValue().increment(stockKey(productId), quantity);
        redis.opsForSet().remove(usersKey(productId), String.valueOf(userId));
        log.warn("已回滚 productId={} userId={} qty={}", productId, userId, quantity);
    }

    public long currentStock(long productId) {
        String v = redis.opsForValue().get(stockKey(productId));
        return v == null ? -1 : Long.parseLong(v);
    }

    public java.math.BigDecimal price(long productId) {
        String v = redis.opsForValue().get(priceKey(productId));
        return v == null ? java.math.BigDecimal.ZERO : new java.math.BigDecimal(v);
    }

    private String stockKey(long id) { return STOCK_KEY.formatted(id); }
    private String usersKey(long id) { return USERS_KEY.formatted(id); }
    private String priceKey(long id) { return PRICE_KEY.formatted(id); }
}
