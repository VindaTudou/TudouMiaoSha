package com.tudou.miaosha.repository;

import com.tudou.miaosha.model.Product;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.Optional;

@Repository
public class ProductRepository {

    private static final RowMapper<Product> ROW = (rs, i) -> new Product(
            rs.getLong("id"),
            rs.getString("name"),
            rs.getBigDecimal("price"),
            rs.getInt("stock"));

    private final JdbcTemplate jdbc;

    public ProductRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public List<Product> page(int offset, int size) {
        return jdbc.query(
                "SELECT id, name, price, stock FROM product ORDER BY id LIMIT ? OFFSET ?",
                ROW, size, offset);
    }

    public Optional<Product> findById(long id) {
        return jdbc.query("SELECT id, name, price, stock FROM product WHERE id = ?", ROW, id)
                .stream().findFirst();
    }

    /**
     * V1-a 的【错误写法】，故意保留：把应用算好的绝对值覆盖回去。
     *
     * 问题：从"读到 p.stock()"到"写回"之间，别人可能已经改过这一行。
     * 你写回的是一个基于过期数据的值，别人的修改就被覆盖了 —— 这就是丢失更新，
     * 在秒杀场景里表现为【超卖】。
     *
     * V1-b 会把它换成条件更新，并对比两者的压测数字。
     */
    public int overwriteStock(long id, int newStock) {
        return jdbc.update("UPDATE product SET stock = ? WHERE id = ?", newStock, id);
    }
}
