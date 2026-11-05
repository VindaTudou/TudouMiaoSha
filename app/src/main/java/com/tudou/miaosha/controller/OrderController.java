package com.tudou.miaosha.controller;

import com.tudou.miaosha.service.OrderService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/orders")
public class OrderController {

    private final OrderService service;

    public OrderController(OrderService service) {
        this.service = service;
    }

    public record CreateOrderRequest(long userId, long productId, int quantity) {
    }

    /**
     * V2 的语义变了：
     *   200 + status=QUEUED  抢到了，正在异步落库（订单号已生成）
     *   409 SOLD_OUT         售罄
     *   409 DUPLICATE        该用户已下过单
     *   503 BUSY             发送 MQ 失败，库存已回滚，可重试
     */
    @PostMapping
    public ResponseEntity<OrderService.OrderResult> create(@RequestBody CreateOrderRequest req) {
        return ResponseEntity.ok(service.create(req.userId(), req.productId(), req.quantity()));
    }
}
