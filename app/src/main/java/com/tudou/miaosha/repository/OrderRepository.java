package com.tudou.miaosha.repository;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.math.BigDecimal;

@Repository
public class OrderRepository {

    private final JdbcTemplate jdbc;

    public OrderRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * V1 故意不加 UNIQUE(user_id, product_id)：
     * 同一个用户连点两次会产生两笔订单。幂等方案留到 V2 讲。
     */
    public void insert(String orderNo, long userId, long productId, int quantity, BigDecimal amount) {
        jdbc.update("""
                INSERT INTO orders (order_no, user_id, product_id, quantity, amount, status)
                VALUES (?, ?, ?, ?, ?, 0)
                """, orderNo, userId, productId, quantity, amount);
    }
}
