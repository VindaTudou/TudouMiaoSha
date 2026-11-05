package com.tudou.miaosha.controller;

import com.tudou.miaosha.service.StockService;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

/**
 * 运维接口：预热库存、查看 Redis 里的库存。
 * 压测前用 preheat 把 MySQL 的值重新灌进 Redis，保证每轮起点一致。
 */
@RestController
@RequestMapping("/api/admin")
public class AdminController {

    private final StockService stock;

    public AdminController(StockService stock) {
        this.stock = stock;
    }

    @PostMapping("/preheat/{productId}")
    public Map<String, Object> preheat(@PathVariable long productId) {
        int loaded = stock.preheat(productId);
        return Map.of("productId", productId, "loadedFromMysql", loaded);
    }

    @GetMapping("/stock/{productId}")
    public Map<String, Object> stock(@PathVariable long productId) {
        return Map.of("productId", productId, "redisStock", stock.currentStock(productId));
    }
}
