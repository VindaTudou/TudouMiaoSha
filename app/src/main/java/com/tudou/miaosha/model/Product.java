package com.tudou.miaosha.model;

import java.math.BigDecimal;

/** 商品。用 record 是因为它只读、不可变，天然适合做查询结果。 */
public record Product(long id, String name, BigDecimal price, int stock) {
}
