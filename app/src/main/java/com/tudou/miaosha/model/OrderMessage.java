package com.tudou.miaosha.model;

import java.math.BigDecimal;

/**
 * 发到 Kafka 的订单消息。
 * key 用 productId：保证同一个商品的扣减消息进同一个分区，消费时严格有序。
 */
public record OrderMessage(
        String orderNo,
        long userId,
        long productId,
        int quantity,
        BigDecimal amount,
        long createdAt) {
}
