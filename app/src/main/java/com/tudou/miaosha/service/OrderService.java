package com.tudou.miaosha.service;

import com.tudou.miaosha.exception.NotFoundException;
import com.tudou.miaosha.exception.SoldOutException;
import com.tudou.miaosha.model.Product;
import com.tudou.miaosha.repository.OrderRepository;
import com.tudou.miaosha.repository.ProductRepository;
import com.tudou.miaosha.support.OrderNoGenerator;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;

@Service
public class OrderService {

    private final ProductRepository products;
    private final OrderRepository orders;

    public OrderService(ProductRepository products, OrderRepository orders) {
        this.products = products;
        this.orders = orders;
    }

    /**
     * V1-a：朴素下单。【故意不加任何并发保护】，用来复现超卖。
     *
     * 执行顺序：
     *   ① SELECT 库存      —— 快照读，不加锁
     *   ② 判断够不够        —— 基于①读到的值
     *   ③ UPDATE 库存 = ②算出的值  —— 当前读 + X 锁
     *   ④ INSERT 订单
     *
     * 问题出在 ① 和 ③ 之间：那道缝里的并发写会被 ③ 覆盖。
     * 这和 V0.1 的 count++ 是同一个 bug。
     *
     * @Transactional 让它成为一个事务：③ 拿到的锁要持有到 COMMIT，
     * 这一点在压测时会明显影响吞吐（锁持有时间 = 事务长度）。
     */
    @Transactional
    public String create(long userId, long productId, int quantity) {
        if (quantity <= 0) {
            throw new IllegalArgumentException("数量必须大于 0");
        }

        // 查出来是为了拿 price 算金额；库存判断【不】基于它
        Product p = products.findById(productId)
                .orElseThrow(() -> new NotFoundException("商品不存在: " + productId));

        // 唯一的判断点：把「够不够」塞进 UPDATE 的 WHERE，用影响行数当结果
        int affected = products.deductStock(productId, quantity);
        if (affected == 0) {
            throw new SoldOutException();
        }

        // ④ 落订单
        String orderNo = OrderNoGenerator.next();
        BigDecimal amount = p.price().multiply(BigDecimal.valueOf(quantity));
        orders.insert(orderNo, userId, productId, quantity, amount);
        return orderNo;
    }
}
