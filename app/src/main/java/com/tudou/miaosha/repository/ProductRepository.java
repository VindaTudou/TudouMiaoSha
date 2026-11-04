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
     * V1-b：把「判断够不够」和「扣减」合成一条语句。
     *
     * UPDATE 是当前读 + 排他锁：定位到 id 那一行 → 加锁 → 读最新值 →
     * 判断 stock >= quantity → 成立才减 → 持有锁到事务提交。
     * 中间不给任何人插手的机会。
     *
     * 返回【影响行数】：
     *   1 = 抢到了，库存已扣
     *   0 = 库存不足，什么都没改
     *
     * 这就是「用影响行数当判断结果」，而不是先 SELECT 再判断。
     * 对应 V0.1 里 AtomicInteger 的 CAS，而不是 count++。
     */
    public int deductStock(long id, int quantity) {
        return jdbc.update(
                "UPDATE product SET stock = stock - ? WHERE id = ? AND stock >= ?",
                quantity, id, quantity);
    }
}
