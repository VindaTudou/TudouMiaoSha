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

    public record CreateOrderResponse(String orderNo) {
    }

    /** 200 = 下单成功；409 = 售罄（业务正常结果） */
    @PostMapping
    public ResponseEntity<CreateOrderResponse> create(@RequestBody CreateOrderRequest req) {
        String orderNo = service.create(req.userId(), req.productId(), req.quantity());
        return ResponseEntity.ok(new CreateOrderResponse(orderNo));
    }
}
