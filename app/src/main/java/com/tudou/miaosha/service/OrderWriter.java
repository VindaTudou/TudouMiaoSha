package com.tudou.miaosha.service;

import com.tudou.miaosha.model.OrderMessage;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 真正的落库动作，由 Kafka 消费者调用。
 *
 * 这里保留了 V1-b 的条件更新作为【兜底】：
 * 如果 Redis 和 MySQL 的库存出现偏差（比如 Redis 重启恢复后数据旧了），
 * 这一层保证 MySQL 里绝不会扣成负数。
 */
@Service
public class OrderWriter {

    private static final Logger log = LoggerFactory.getLogger(OrderWriter.class);

    private final JdbcTemplate jdbc;

    public OrderWriter(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * @return true = 落库成功；false = DB 库存不足（Redis 与 DB 不一致）
     */
    @Transactional
    public boolean persist(OrderMessage m) {
        int affected = jdbc.update(
                "UPDATE product SET stock = stock - ? WHERE id = ? AND stock >= ?",
                m.quantity(), m.productId(), m.quantity());

        if (affected == 0) {
            // 不改数据、不抛异常：抛了会无限重试。这是一笔「少卖」，
            // 记下来交给对账处理。
            log.warn("DB 库存不足，跳过 orderNo={} productId={}", m.orderNo(), m.productId());
            return false;
        }

        jdbc.update("""
                INSERT INTO orders (order_no, user_id, product_id, quantity, amount, status)
                VALUES (?, ?, ?, ?, ?, 0)
                """, m.orderNo(), m.userId(), m.productId(), m.quantity(), m.amount());
        return true;
    }
}
