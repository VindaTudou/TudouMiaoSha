package com.tudou.miaosha.service;

import com.tudou.miaosha.exception.NotFoundException;
import com.tudou.miaosha.model.Product;
import com.tudou.miaosha.repository.ProductRepository;
import org.springframework.stereotype.Service;

import java.util.List;

@Service
public class ProductService {

    private final ProductRepository products;

    public ProductService(ProductRepository products) {
        this.products = products;
    }

    public List<Product> page(int page, int size) {
        int safeSize = Math.min(Math.max(size, 1), 100);
        int safePage = Math.max(page, 0);
        return products.page(safePage * safeSize, safeSize);
    }

    public Product detail(long id) {
        return products.findById(id)
                .orElseThrow(() -> new NotFoundException("商品不存在: " + id));
    }
}
