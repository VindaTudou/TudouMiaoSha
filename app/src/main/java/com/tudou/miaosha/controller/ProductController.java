package com.tudou.miaosha.controller;

import com.tudou.miaosha.model.Product;
import com.tudou.miaosha.service.ProductService;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/products")
public class ProductController {

    private final ProductService service;

    public ProductController(ProductService service) {
        this.service = service;
    }

    @GetMapping
    public List<Product> page(@RequestParam(defaultValue = "0") int page,
                              @RequestParam(defaultValue = "20") int size) {
        return service.page(page, size);
    }

    @GetMapping("/{id}")
    public Product detail(@PathVariable long id) {
        return service.detail(id);
    }
}
