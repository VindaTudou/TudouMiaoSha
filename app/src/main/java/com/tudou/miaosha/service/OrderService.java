package com.tudou.miaosha.service;

import com.tudou.miaosha.exception.DuplicateOrderException;
import com.tudou.miaosha.exception.SoldOutException;
import com.tudou.miaosha.exception.ServiceBusyException;
import com.tudou.miaosha.model.OrderMessage;
import com.tudou.miaosha.support.MiaoshaMetrics;
import com.tudou.miaosha.support.OrderNoGenerator;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;

/**
 * V2 下单：请求路径里【没有 MySQL】。
 *
 *   ① Redis Lua：原子完成「幂等检查 + 库存判断 + 扣减」
 *   ② 发 Kafka：把落库这件事交给消费者
 *   ③ 立刻返回「排队中」
 *
 * 对比 V1：V1 的请求线程要等 MySQL 加锁、写 undo/redo/binlog、等 fsync，
 * 一次 0.5ms，吞吐封顶 950/s。
 */
@Service
public class OrderService {

    private static final Logger log = LoggerFactory.getLogger(OrderService.class);

    private final StockService stock;
    private final OrderProducer producer;
    private final MiaoshaMetrics metrics;

    public OrderService(StockService stock, OrderProducer producer, MiaoshaMetrics metrics) {
        this.stock = stock;
        this.producer = producer;
        this.metrics = metrics;
    }

    public record OrderResult(String orderNo, String status) {
    }

    public OrderResult create(long userId, long productId, int quantity) {
        if (quantity <= 0) {
            throw new IllegalArgumentException("数量必须大于 0");
        }

        // ① 原子扣减
        long r = stock.tryDeduct(productId, userId, quantity);
        if (r == -2) {
            metrics.order(MiaoshaMetrics.ORDER_NOT_PREHEATED);
            throw new IllegalStateException("库存未预热: " + productId);
        }
        if (r == -1) {
            metrics.order(MiaoshaMetrics.ORDER_DUPLICATE);
            throw new DuplicateOrderException();
        }
        if (r == 0) {
            metrics.order(MiaoshaMetrics.ORDER_SOLDOUT);
            throw new SoldOutException();
        }

        // ② 发消息。失败就回滚 Redis，保证「扣了库存一定会有订单」
        String orderNo = OrderNoGenerator.next();
        BigDecimal amount = stock.price(productId).multiply(BigDecimal.valueOf(quantity));
        OrderMessage msg = new OrderMessage(
                orderNo, userId, productId, quantity, amount, System.currentTimeMillis());
        try {
            producer.send(msg);
        } catch (Exception e) {
            metrics.order(MiaoshaMetrics.ORDER_SEND_FAIL);
            stock.rollback(productId, userId, quantity);
            log.error("发送 MQ 失败，已回滚库存 orderNo={}", orderNo, e);
            throw new ServiceBusyException("下单繁忙，请重试");
        }

        // ③ 立刻返回，不等落库
        metrics.order(MiaoshaMetrics.ORDER_SUCCESS);
        return new OrderResult(orderNo, "QUEUED");
    }
}
